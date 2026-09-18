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
/// Every entry point that compiles SQL itself goes through here, so they all
/// classify one input the same way. The rule is rusqlite's
/// (`rusqlite::Connection::prepare_with_flags`): input that holds no statement
/// at all — empty, whitespace, comments, bare semicolons — is refused, and
/// text after the first statement is refused only when re-compiling it yields
/// a statement of its own. Trailing whitespace, comments and extra semicolons
/// therefore pass.
///
/// # Safety
/// The caller holds the connection Mutex for the whole call, and `db` is that
/// connection's live handle.
pub(crate) unsafe fn prepare_one(
    db: *mut ffi::sqlite3,
    sql: &str,
) -> Result<NonNull<ffi::sqlite3_stmt>, XqliteError> {
    let c_sql = CString::new(sql).map_err(|_| XqliteError::NulErrorInString)?;
    let len = sql_byte_len(&c_sql)?;
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

    let stmt = NonNull::new(raw_stmt).ok_or_else(no_statement)?;

    match tail_offset(c_sql.as_ptr(), tail_ptr, len) {
        None => Ok(stmt),
        // SAFETY: `db` is live and its Mutex is held (fn contract); `start` is
        // a byte offset strictly inside `c_sql`, which outlives the call.
        Some(start) => match unsafe { tail_holds_statement(db, &c_sql, start, len, sql) } {
            Ok(false) => Ok(stmt),
            Ok(true) => {
                // SAFETY: `stmt` came from the prepare above, is owned here,
                // and is finalized exactly once on this path.
                unsafe { ffi::sqlite3_finalize(stmt.as_ptr()) };
                Err(XqliteError::MultipleStatements)
            }
            Err(e) => {
                // SAFETY: as above — the only other path that drops `stmt`.
                unsafe { ffi::sqlite3_finalize(stmt.as_ptr()) };
                Err(e)
            }
        },
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

fn no_statement() -> XqliteError {
    XqliteError::CannotExecute("SQL contains no statement".to_string())
}

fn sql_byte_len(c_sql: &CStr) -> Result<c_int, XqliteError> {
    c_int::try_from(c_sql.to_bytes().len()).map_err(|_| {
        XqliteError::CannotExecute("SQL string length exceeds c_int range".to_string())
    })
}

/// Where the text SQLite did not compile starts, as a byte offset into the
/// buffer. `None` when SQLite reported no tail or consumed everything —
/// rusqlite's own bounds, so the two agree on what counts as a tail.
fn tail_offset(start: *const c_char, tail: *const c_char, len: c_int) -> Option<c_int> {
    if tail.is_null() {
        None
    } else {
        let n = (tail as isize) - (start as isize);
        if n <= 0 || n >= len as isize {
            None
        } else {
            c_int::try_from(n).ok()
        }
    }
}

/// Re-compiles the tail to decide whether it is a second statement or only
/// whitespace, comments and semicolons. A syntax error in the tail is the
/// caller's error, exactly as it is for `query`.
///
/// # Safety
/// The caller holds the connection Mutex, `db` is that connection's live
/// handle, and `start` is a byte offset strictly inside `c_sql`.
unsafe fn tail_holds_statement(
    db: *mut ffi::sqlite3,
    c_sql: &CStr,
    start: c_int,
    len: c_int,
    sql: &str,
) -> Result<bool, XqliteError> {
    let mut raw_stmt: *mut ffi::sqlite3_stmt = std::ptr::null_mut();
    // SAFETY: `start` is a byte offset strictly inside `c_sql` (fn contract),
    // so the offset pointer stays within that same allocation.
    let tail_ptr = unsafe { c_sql.as_ptr().offset(start as isize) };

    // SAFETY: `db` is live and its Mutex is held (fn contract). `c_sql` owns
    // the buffer `tail_ptr` points into and outlives the call; a null tail
    // out-param tells SQLite we do not want the tail back.
    let rc = unsafe {
        ffi::sqlite3_prepare_v2(
            db,
            tail_ptr,
            len - start,
            &mut raw_stmt,
            std::ptr::null_mut(),
        )
    };

    if rc != ffi::SQLITE_OK {
        let tail_sql = sql.get(start as usize..).unwrap_or(sql);
        // SAFETY: `db` is live and its Mutex is held (fn contract).
        return Err(unsafe { error::prepare_failure(db, rc, tail_sql) });
    }

    match NonNull::new(raw_stmt) {
        None => Ok(false),
        Some(trial) => {
            // SAFETY: `trial` came from the prepare above, is owned here, and
            // is finalized exactly once — the tail statement never escapes.
            unsafe { ffi::sqlite3_finalize(trial.as_ptr()) };
            Ok(true)
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
    /// refusal of the library's own leave it alone, and a bind SQLite refused
    /// after it had taken values clears it. SQLite itself reads a parameter
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

    /// A bind SQLite refused after it had already taken values leaves the
    /// statement half-bound, which is no state to run: it stops running until
    /// a bind succeeds or `clear_bindings` puts NULL everywhere.
    pub(crate) fn clear_parameters_set(&self) {
        self.parameters_set.store(false, Ordering::Release);
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
