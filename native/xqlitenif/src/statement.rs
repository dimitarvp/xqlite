use crate::cancel::cancel_if_signalled;
use crate::connection::{self, XqliteConn};
use crate::error::{self, XqliteError};
use crate::stream::take_and_finalize_raw;
use rusqlite::ffi;
use rustler::{Resource, ResourceArc};
use std::ffi::{CStr, CString};
use std::io::Write;
use std::os::raw::{c_char, c_int};
use std::ptr::NonNull;
use std::sync::atomic::{AtomicBool, AtomicPtr, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

/// Compiles exactly one SQL statement and hands the raw statement to the
/// caller, who owns it and must finalize it.
///
/// Every function that runs one statement goes through here, so they all
/// classify one input alike: no statement at all is rejected, and so is a tail
/// holding more than `blank_len` passes over. SQLite applies PRAGMAs while
/// compiling, so the tail is never compiled and a leading PRAGMA is judged first.
///
/// # Safety
/// The caller holds the connection Mutex for the whole call, and `db` is that
/// connection's live handle.
pub(crate) unsafe fn prepare_one(
    db: *mut ffi::sqlite3,
    sql: &str,
) -> Result<NonNull<ffi::sqlite3_stmt>, XqliteError> {
    crate::query::reject_interior_nul(sql)?;
    let len = sql_byte_len(sql.len())?;
    if leading_pragma_holds_more(sql.as_bytes()) {
        return Err(XqliteError::MultipleStatements);
    }
    let c_sql = CString::new(sql).map_err(|_| XqliteError::NulErrorInString)?;
    let mut raw_stmt: *mut ffi::sqlite3_stmt = std::ptr::null_mut();
    let mut tail_ptr: *const c_char = std::ptr::null();

    // SAFETY: `db` is live and its Mutex is held (fn contract). `c_sql` owns
    // the buffer SQLite reads and the one it writes `tail_ptr` into, and it
    // outlives every read of either below.
    let rc = unsafe {
        ffi::sqlite3_prepare_v2(db, c_sql.as_ptr(), len, &mut raw_stmt, &mut tail_ptr)
    };

    if rc != ffi::SQLITE_OK {
        // SAFETY: `db` is live and its Mutex is held (fn contract).
        return Err(unsafe { error::prepare_failure(db, rc, sql) });
    }

    let stmt = NonNull::new(raw_stmt).ok_or(XqliteError::NoStatement)?;
    let tail_blank = tail_offset(c_sql.as_ptr(), tail_ptr, len)
        .is_none_or(|start| blank_end(sql.as_bytes(), start) == sql.len());

    match tail_blank {
        true => Ok(stmt),
        false => {
            // SAFETY: `stmt` came from the prepare above, is owned here, and
            // is finalized exactly once, on this path.
            unsafe { ffi::sqlite3_finalize(stmt.as_ptr()) };
            Err(XqliteError::MultipleStatements)
        }
    }
}

/// Whether a first statement that is a PRAGMA, `EXPLAIN [QUERY PLAN]` in front
/// or not, is followed by anything after its first semicolon outside quotes and
/// comments, where a PRAGMA ends. A keyword ends where SQLite's words end.
fn leading_pragma_holds_more(sql: &[u8]) -> bool {
    let word_end = |at: usize, word: &[u8]| {
        let end = at + word.len();
        let id_char = |c: &u8| c.is_ascii_alphanumeric() || b"_$".contains(c) || *c > 127;
        let spelled = sql.get(at..end)?.eq_ignore_ascii_case(word);
        (spelled && !sql.get(end).is_some_and(id_char)).then_some(end)
    };
    let lead = blank_end(sql, 0);
    let explain = word_end(lead, b"EXPLAIN").map(|end| blank_end(sql, end));
    let plan = explain
        .and_then(|at| word_end(at, b"QUERY"))
        .and_then(|end| word_end(blank_end(sql, end), b"PLAN"))
        .map(|end| blank_end(sql, end));
    word_end(plan.or(explain).unwrap_or(lead), b"PRAGMA")
        .and_then(|end| semicolon_end(sql, end))
        .is_some_and(|after| blank_end(sql, after) < sql.len())
}

/// The byte after the first semicolon from `from` on outside a comment and a
/// quoted string or name (`'…'`, `"…"`, `` `…` ``, `[…]`).
fn semicolon_end(sql: &[u8], from: usize) -> Option<usize> {
    let mut at = from;
    while let Some(rest) = sql.get(at..).filter(|rest| !rest.is_empty()) {
        at += match rest {
            [b';', ..] => return Some(at + 1),
            [open, body @ ..] if b"'\"`[".contains(open) => {
                let close = if *open == b'[' { b']' } else { *open };
                let closed = body.iter().position(|c| *c == close);
                closed.map_or(rest.len(), |i| i + 2)
            }
            _ => blank_len(rest).unwrap_or(1),
        };
    }
    None
}

/// Where the text from `from` on stops being what `blank_len` passes over.
fn blank_end(sql: &[u8], from: usize) -> usize {
    let mut at = from;
    while let Some(len) = sql.get(at..).and_then(blank_len) {
        at += len;
    }
    at
}

/// How many bytes at the start of `rest` SQLite passes over without starting a
/// statement (`sqlite3GetToken`): `;`, a `--` or `/*` comment (`/*` needs a
/// byte after it), a UTF-8 byte order mark, or a whitespace run, which `\v` only continues.
fn blank_len(rest: &[u8]) -> Option<usize> {
    let space = |c: &&u8| c.is_ascii_whitespace() || **c == 0x0b;
    match rest {
        [b';', ..] => Some(1),
        [0xEF, 0xBB, 0xBF, ..] => Some(3),
        [b'-', b'-', ..] => Some(rest.iter().take_while(|c| **c != b'\n').count()),
        [b'/', b'*', body @ ..] if !body.is_empty() => {
            let closed = body.windows(2).position(|pair| pair == b"*/");
            Some(closed.map_or(rest.len(), |i| i + 4))
        }
        [c, ..] if c.is_ascii_whitespace() => Some(rest.iter().take_while(space).count()),
        _token_or_end => None,
    }
}

/// Runs every statement of a batch in turn and answers the first failure.
///
/// Each statement is compiled from the rest of the text in place: the text is
/// NUL-terminated and handed over with length -1, so SQLite copies nothing and
/// the batch costs time linear in its length. The tokens are read once a
/// statement is compiled and before its first step, so a signal stops the
/// batch before the next statement and text after the last one is never
/// answered as cancelled.
///
/// # Safety
/// The caller holds the connection Mutex for the whole call, and `db` is that
/// connection's live handle.
pub(crate) unsafe fn execute_batch(
    db: *mut ffi::sqlite3,
    sql: &str,
    tokens: &[Arc<AtomicBool>],
) -> Result<(), XqliteError> {
    let c_sql = CString::new(sql).map_err(|_| XqliteError::NulErrorInString)?;
    let mut tail: *const c_char = c_sql.as_ptr();

    loop {
        let rest = sql
            .get((tail as usize).wrapping_sub(c_sql.as_ptr() as usize)..)
            .unwrap_or(sql);
        let mut raw_stmt: *mut ffi::sqlite3_stmt = std::ptr::null_mut();

        // SAFETY: `db` is live and its Mutex is held (fn contract). `tail`
        // points into `c_sql`, NUL-terminated and alive for the whole loop, and
        // SQLite writes it back pointing into the same buffer.
        let rc = unsafe { ffi::sqlite3_prepare_v2(db, tail, -1, &mut raw_stmt, &mut tail) };

        let stmt = match (rc, NonNull::new(raw_stmt)) {
            (ffi::SQLITE_OK, Some(stmt)) => PreparedStmt::new(stmt),
            (ffi::SQLITE_OK, None) => return Ok(()),
            // SAFETY: `db` is live and its Mutex is held (fn contract).
            (rc, _) => return Err(unsafe { error::prepare_failure(db, rc, rest) }),
        };

        cancel_if_signalled(tokens)?;

        let rc = loop {
            // SAFETY: `stmt` is a live statement of `db`, whose Mutex is held.
            let rc = unsafe { ffi::sqlite3_step(stmt.as_ptr()) };
            if rc != ffi::SQLITE_ROW {
                break rc;
            }
        };

        if rc != ffi::SQLITE_DONE {
            // SAFETY: `db` is live and its Mutex is held (fn contract); the
            // message is read before `stmt` drops and finalizes.
            return Err(unsafe { error::prepare_failure(db, rc, rest) });
        }
    }
}

/// Owns a freshly prepared statement until something else takes it over.
///
/// A statement that is prepared and then dropped without being registered
/// anywhere is a statement nothing can ever finalize, and SQLite refuses to
/// close a connection that still owns one — for the life of the process. The
/// holder makes that impossible: every way out of the scope it lives in, an
/// error included, finalizes it, and the one path that hands the statement to
/// a resource calls `release` first. It must stay a local of the closure that
/// holds the connection Mutex, because `sqlite3_finalize` runs in its drop.
pub(crate) struct PreparedStmt {
    ptr: *mut ffi::sqlite3_stmt,
}

impl PreparedStmt {
    pub(crate) fn new(stmt: NonNull<ffi::sqlite3_stmt>) -> Self {
        PreparedStmt { ptr: stmt.as_ptr() }
    }

    pub(crate) fn as_ptr(&self) -> *mut ffi::sqlite3_stmt {
        self.ptr
    }

    /// Gives the statement up: the caller owns it from here, and this holder
    /// finalizes nothing.
    pub(crate) fn release(mut self) -> *mut ffi::sqlite3_stmt {
        let released = self.ptr;
        self.ptr = std::ptr::null_mut();
        released
    }
}

impl Drop for PreparedStmt {
    fn drop(&mut self) {
        if self.ptr.is_null() {
            return;
        }

        // SAFETY: the pointer came from `sqlite3_prepare_v2` on the connection
        // whose Mutex the holder's scope holds, nothing else owns it — that is
        // what `release` is for — and this runs once, the pointer being nulled
        // as it is taken.
        unsafe { ffi::sqlite3_finalize(self.ptr) };
    }
}

/// A live statement answers the names of its current program, which SQLite's
/// automatic re-prepare after a schema change can replace (a `SELECT *`
/// expands anew).
///
/// # Safety
/// The caller holds the connection Mutex for the whole call and `stmt` is a
/// live prepared statement of that connection.
pub(crate) unsafe fn column_names(
    stmt: *mut ffi::sqlite3_stmt,
) -> Result<Vec<String>, XqliteError> {
    // SAFETY: forwarded from this function's own contract; every index is below
    // the count, and a name stays valid until the next call on the statement,
    // after its copy. Null means SQLite could not allocate the name.
    unsafe {
        (0..ffi::sqlite3_column_count(stmt))
            .map(|index| {
                let name = ffi::sqlite3_column_name(stmt, index);
                match name.is_null() {
                    true => Err(XqliteError::InternalEncodingError {
                        context: format!("SQLite returned null column name for index {index}"),
                    }),
                    false => utf8_column_name(CStr::from_ptr(name).to_bytes(), index),
                }
            })
            .collect()
    }
}

fn utf8_column_name(bytes: &[u8], index: c_int) -> Result<String, XqliteError> {
    std::str::from_utf8(bytes)
        .map(str::to_string)
        .map_err(|_not_utf8| XqliteError::ColumnNameNotUtf8 {
            column: index as usize,
            name: bytes.to_vec(),
        })
}

fn sql_byte_len(len: usize) -> Result<c_int, XqliteError> {
    c_int::try_from(len).map_err(|_| {
        XqliteError::from(rusqlite::Error::SqliteFailure(
            ffi::Error::new(ffi::SQLITE_TOOBIG),
            None,
        ))
    })
}

/// Where the text SQLite did not compile starts, as a byte offset into the
/// buffer. `None` when SQLite reported no tail or consumed everything.
fn tail_offset(start: *const c_char, tail: *const c_char, len: c_int) -> Option<usize> {
    if tail.is_null() {
        None
    } else {
        let n = (tail as isize) - (start as isize);
        if n <= 0 || n >= len as isize {
            None
        } else {
            usize::try_from(n).ok()
        }
    }
}

/// A manually managed prepared statement: prepare → (bind → step /
/// multi_step → reset)* → finalize.
///
/// The raw `sqlite3_stmt` lives in an `AtomicPtr` (null ⇒ finalized), shared
/// with the connection's child registry. The owning connection's
/// `ResourceArc` keeps the connection *resource* alive — not the SQLite
/// handle itself — so every statement operation, including the GC-driven
/// `Drop`, can always lock the connection Mutex per the raw-handle locking
/// rule. Closing the connection first finalizes this statement through the
/// registry: its operations then fail with `ConnectionClosed` and its
/// `finalize` finds a null cell and answers `:ok`.
pub(crate) struct XqliteStatement {
    pub(crate) atomic_raw_stmt: Arc<AtomicPtr<ffi::sqlite3_stmt>>,

    /// A value read that failed after the batch had already read rows. Those
    /// rows go back to the caller and the error waits here for the next call,
    /// exactly as a stream holds one back. Written and taken with the
    /// connection Mutex held; `take_and_finalize` empties it before it takes
    /// that Mutex, so the two never nest the other way round.
    pending_error: Mutex<Option<XqliteError>>,

    pub(crate) conn_resource_arc: ResourceArc<XqliteConn>,
    /// Prepare-time snapshot, served by `stmt_column_names` only after
    /// finalization; live statements read column metadata directly so
    /// v2 auto-reprepare (schema changes) is reflected.
    pub(crate) column_names: Vec<String>,

    /// How many parameters the statement takes, read once at prepare.
    parameter_count: usize,

    /// Whether anything has set this statement's parameters. False from
    /// prepare for a statement that takes some, true for one that takes
    /// none; a successful bind and `clear_bindings` set it, a reset and a
    /// bind that took no value leave it alone, and a bind that failed after at
    /// least one value was taken clears it. SQLite itself reads a parameter
    /// nothing bound as NULL and runs the statement anyway, which is what the
    /// flag is here to refuse.
    parameters_set: AtomicBool,
}

#[rustler::resource_impl]
impl Resource for XqliteStatement {}

impl XqliteStatement {
    pub(crate) fn new(
        atomic_raw_stmt: Arc<AtomicPtr<ffi::sqlite3_stmt>>,
        conn_resource_arc: ResourceArc<XqliteConn>,
        column_names: Vec<String>,
        parameter_count: usize,
    ) -> Self {
        XqliteStatement {
            atomic_raw_stmt,
            pending_error: Mutex::new(None),
            conn_resource_arc,
            column_names,
            parameter_count,
            parameters_set: AtomicBool::new(parameter_count == 0),
        }
    }

    /// A bind that got as far as SQLite, and `clear_bindings`, both leave the
    /// statement's parameters set — the second to NULL, which is the one way
    /// a caller asks for that on purpose.
    pub(crate) fn mark_parameters_set(&self) {
        self.parameters_set.store(true, Ordering::Release);
    }

    /// A bind that failed after at least one value was taken leaves the
    /// statement half-bound, which is no state to run: it stops running until
    /// a bind succeeds or `clear_bindings` puts NULL everywhere.
    pub(crate) fn clear_parameters_set(&self) {
        self.parameters_set.store(false, Ordering::Release);
    }

    /// Whether the statement takes any parameters at all. One that takes none
    /// has nothing a clear could release, so a clear on it is the no-op it has
    /// always been, whatever the statement is doing.
    pub(crate) fn takes_parameters(&self) -> bool {
        self.parameter_count > 0
    }

    pub(crate) fn require_parameters_set(&self) -> Result<(), XqliteError> {
        match self.parameters_set.load(Ordering::Acquire) {
            true => Ok(()),
            false => Err(XqliteError::ParametersUnbound {
                expected: self.parameter_count,
            }),
        }
    }

    pub(crate) fn take_and_finalize(&self) -> Result<(), XqliteError> {
        // A finalized statement answers its lifecycle error, never a
        // leftover value error.
        let _ = self.take_pending_error();
        take_and_finalize_raw(&self.atomic_raw_stmt, &self.conn_resource_arc)
    }

    pub(crate) fn take_pending_error(&self) -> Option<XqliteError> {
        self.pending_slot().take()
    }

    pub(crate) fn store_pending_error(&self, error: XqliteError) {
        *self.pending_slot() = Some(error);
    }

    // The slot holds one Option and nothing that can panic runs while it is
    // held, so a poisoned Mutex is recovered rather than reported.
    fn pending_slot(&self) -> MutexGuard<'_, Option<XqliteError>> {
        match self.pending_error.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    /// Runs `f` with the connection Mutex held, the connection proven open,
    /// and the raw statement pointer proven live.
    ///
    /// Lock-then-load ordering makes this sound against a concurrent
    /// finalize: a finalizer may swap the pointer to null at any moment, but
    /// it cannot call `sqlite3_finalize` without this same Mutex — so a
    /// pointer loaded non-null *under the lock* remains valid until the
    /// guard drops.
    pub(crate) fn with_live_stmt<F, R>(&self, f: F) -> Result<R, XqliteError>
    where
        F: FnOnce(*mut ffi::sqlite3_stmt, *mut ffi::sqlite3) -> Result<R, XqliteError>,
    {
        let guard = self
            .conn_resource_arc
            .conn
            .lock()
            .map_err(|e| XqliteError::LockError(e.to_string()))?;
        let conn = guard.as_ref().ok_or(XqliteError::ConnectionClosed)?;

        let ptr = self.atomic_raw_stmt.load(Ordering::Acquire);
        if ptr.is_null() {
            return Err(XqliteError::StatementFinalized);
        }

        // SAFETY: handle() only extracts the raw sqlite3*; `guard` keeps the
        // Connection alive (and the connection exclusively ours) for the
        // whole duration of `f`.
        let db = unsafe { conn.handle() };
        connection::with_busy_timeout_rule(&self.conn_resource_arc, || f(ptr, db))
    }
}

impl Drop for XqliteStatement {
    fn drop(&mut self) {
        if let Err(e) = self.take_and_finalize() {
            // Errors from Drop cannot be propagated. Log to stderr —
            // writeln!, never eprintln!: eprintln! panics on a broken
            // stderr, and rustler 0.38 resource destructors have no
            // catch_unwind, so a panic here would unwind into C and kill
            // the VM.
            let _ = writeln!(
                std::io::stderr(),
                "[xqlite] Error finalizing SQLite statement during statement resource drop: {e:?}"
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::raw::c_void;

    /// # Safety
    /// `token` points to an `AtomicBool` that outlives the connection.
    unsafe extern "C" fn signal(token: *mut c_void) -> c_int {
        // SAFETY: the fn contract.
        unsafe { (*(token as *const AtomicBool)).store(true, Ordering::Release) };
        0
    }

    #[test]
    fn the_tokens_are_read_between_statements_and_never_after_the_last() {
        for (batch, cancelled) in [
            ("INSERT INTO t VALUES (1); INSERT INTO t VALUES (2);", true),
            ("INSERT INTO t VALUES (1); -- tail", false),
        ] {
            let token = Arc::new(AtomicBool::new(false));
            let conn =
                rusqlite::Connection::open_in_memory().expect("an in-memory connection");
            conn.execute_batch("CREATE TABLE t (x)").expect("a table");
            // SAFETY: this thread owns the connection, and `token` outlives it.
            let answer = unsafe {
                let flag = Arc::as_ptr(&token) as *mut c_void;
                ffi::sqlite3_progress_handler(conn.handle(), 1, Some(signal), flag);
                execute_batch(conn.handle(), batch, std::slice::from_ref(&token))
            };
            let rows: i64 = conn
                .query_row("SELECT count(*) FROM t", [], |row| row.get(0))
                .expect("a count");

            assert!(token.load(Ordering::Acquire));
            assert_eq!(
                (matches!(answer, Err(XqliteError::OperationCancelled)), rows),
                (cancelled, 1)
            );
        }
    }

    #[test]
    fn sql_past_c_int_answers_too_big() {
        assert!(matches!(
            sql_byte_len(2_147_483_648),
            Err(XqliteError::TooBig {
                extended_code: 18,
                ..
            })
        ));
        assert_eq!(sql_byte_len(2_147_483_647).ok(), Some(c_int::MAX));
    }
}
