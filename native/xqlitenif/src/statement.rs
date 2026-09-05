use crate::connection::XqliteConn;
use crate::error::{self, XqliteError};
use crate::stream::take_and_finalize_raw;
use rusqlite::ffi;
use rustler::{Resource, ResourceArc};
use std::ffi::{CStr, CString};
use std::io::Write;
use std::os::raw::{c_char, c_int};
use std::ptr::NonNull;
use std::sync::atomic::{AtomicPtr, Ordering};

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
/// The raw `sqlite3_stmt` lives in an `AtomicPtr` (null ⇒ finalized). The
/// owning connection's `ResourceArc` keeps the connection *resource* alive —
/// not the SQLite handle itself — so every statement operation, including
/// the GC-driven `Drop`, can always lock the connection Mutex per the
/// raw-handle locking rule. If the connection is explicitly closed first,
/// statement operations fail with `ConnectionClosed` and finalization stays
/// safe (the Mutex outlives the `Option<Connection>` it guards).
pub(crate) struct XqliteStatement {
    pub(crate) atomic_raw_stmt: AtomicPtr<ffi::sqlite3_stmt>,
    pub(crate) conn_resource_arc: ResourceArc<XqliteConn>,
    /// Prepare-time snapshot, served by `stmt_column_names` only after
    /// finalization; live statements read column metadata directly so
    /// v2 auto-reprepare (schema changes) is reflected.
    pub(crate) column_names: Vec<String>,
}

#[rustler::resource_impl]
impl Resource for XqliteStatement {}

impl XqliteStatement {
    pub(crate) fn take_and_finalize(&self) -> Result<(), XqliteError> {
        take_and_finalize_raw(&self.atomic_raw_stmt, &self.conn_resource_arc)
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
        f(ptr, db)
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
