use crate::connection::{ChildHandle, XqliteConn};
use crate::error::XqliteError;
use crate::util::sqlite_row_to_elixir_terms;
use rusqlite::ffi;
use rusqlite::types::Value;
use rustler::{Env, Resource, ResourceArc, Term};
use std::io::Write;
use std::os::raw::c_int;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

pub(crate) struct XqliteStream {
    // Null means the stream is done/closed/finalized. Shared with the
    // connection's child registry, which finalizes it if the connection is
    // closed first.
    pub(crate) atomic_raw_stmt: Arc<AtomicPtr<ffi::sqlite3_stmt>>,

    // A step error a batch hit after it had already read rows. The rows go
    // back to the caller and this waits for the next fetch. Written and
    // taken with the connection Mutex held; `take_and_finalize_atomic_stmt`
    // empties it before it takes that Mutex, so the two never nest the
    // other way round.
    pending_error: Mutex<Option<XqliteError>>,

    // These are immutable after stream_open completes
    pub(crate) conn_resource_arc: ResourceArc<XqliteConn>,
    pub(crate) column_names: Vec<String>,
}

#[rustler::resource_impl]
impl Resource for XqliteStream {}

impl XqliteStream {
    pub(crate) fn new(
        atomic_raw_stmt: Arc<AtomicPtr<ffi::sqlite3_stmt>>,
        conn_resource_arc: ResourceArc<XqliteConn>,
        column_names: Vec<String>,
    ) -> Self {
        XqliteStream {
            atomic_raw_stmt,
            pending_error: Mutex::new(None),
            conn_resource_arc,
            column_names,
        }
    }

    pub(crate) fn take_and_finalize_atomic_stmt(&self) -> Result<(), XqliteError> {
        // A closed stream answers `:done`, never a leftover error.
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
}

/// Finalizes a raw statement under the connection Mutex and drops it from the
/// connection's child registry. Shared by every resource that owns a raw
/// `sqlite3_stmt` (`XqliteStream`, `XqliteStatement`) — their Drop impls
/// and explicit close/finalize NIFs all funnel here.
///
/// The connection lock comes first and the cell is claimed under it: the
/// connection's own close drains these same cells while holding that lock, so
/// locking first is what keeps a finalize from running against a handle close
/// has already freed. It also keeps any other thread out of `sqlite3_step` on
/// this connection while the statement goes away.
pub(crate) fn take_and_finalize_raw(
    atomic_raw_stmt: &Arc<AtomicPtr<ffi::sqlite3_stmt>>,
    conn_resource_arc: &ResourceArc<XqliteConn>,
) -> Result<(), XqliteError> {
    // A null cell means the statement is already gone — finalized by an
    // earlier call, by the stream's own exhaustion, or by the connection's
    // close — and its registry entry went with it.
    if atomic_raw_stmt.load(Ordering::Acquire).is_null() {
        Ok(())
    } else {
        let _conn_guard = conn_resource_arc
            .conn
            .lock()
            .map_err(|e| XqliteError::LockError(e.to_string()))?;
        let child = ChildHandle::Stmt(Arc::clone(atomic_raw_stmt));
        // SAFETY: the connection Mutex is held for the whole release, so no
        // other thread is inside a `sqlite3_*` call on this connection, and
        // the cell holds a statement prepared on it.
        unsafe { conn_resource_arc.release_child(&child) }
    }
}

/// Finalizes a stream's statement with the connection Mutex already held by
/// the caller, and drops it from the child registry. `stream_fetch` uses this
/// when a batch exhausts or fails mid-loop.
///
/// # Safety
///
/// The caller holds the connection's Mutex for the whole call — or holds it
/// poisoned, which keeps every other thread out of SQLite on that connection.
pub(crate) unsafe fn finalize_stream_stmt_locked(
    stream: &XqliteStream,
) -> Result<(), XqliteError> {
    let child = ChildHandle::Stmt(Arc::clone(&stream.atomic_raw_stmt));
    // SAFETY: forwarded from this function's own contract.
    unsafe { stream.conn_resource_arc.release_child(&child) }
}

impl Drop for XqliteStream {
    fn drop(&mut self) {
        if let Err(e) = self.take_and_finalize_atomic_stmt() {
            // Errors from Drop cannot be propagated. Log to stderr —
            // writeln!, never eprintln!: eprintln! panics on a broken
            // stderr (EPIPE), and rustler 0.38 resource destructors have
            // no catch_unwind, so a panic here would unwind into C and
            // kill the VM. A failed finalize here is a potential resource
            // leak if SQLite itself failed to finalize.
            let _ = writeln!(
                std::io::stderr(),
                "[xqlite] Error finalizing SQLite statement during stream resource drop: {e:?}"
            );
        }
    }
}

/// Why a single step produced no row to deliver. The two are not
/// interchangeable: only `Unreadable` leaves a run that can carry on.
pub(crate) enum StepFailure {
    /// `sqlite3_step` returned neither a row nor done — a locked database, an
    /// I/O error, a runtime error in the SQL, a trigger's RAISE, a
    /// cancellation. No row was stepped past and the statement is finished
    /// where SQLite left it.
    Failed(XqliteError),
    /// A row came back and could not be turned into terms. SQLite has already
    /// stepped past it, so the run continues at the row after it.
    Unreadable(XqliteError),
}

impl From<StepFailure> for XqliteError {
    fn from(failure: StepFailure) -> Self {
        match failure {
            StepFailure::Failed(error) => error,
            StepFailure::Unreadable(error) => error,
        }
    }
}

/// Steps a prepared statement once and returns the row data if available.
///
/// The column count is read AFTER the step, not taken from a prepare-time
/// snapshot: sqlite3_step's v2 auto-reprepare after a schema change can
/// legitimately change it (e.g. `SELECT *` re-expansion).
///
/// # Safety
///
/// - `stmt_ptr` must be non-null and point to a valid, prepared `sqlite3_stmt`.
/// - `db_handle_for_error_reporting` must be the `sqlite3*` handle that owns `stmt_ptr`.
/// - The caller must hold the connection mutex for the duration of this call.
#[inline]
pub(crate) unsafe fn process_single_step<'a>(
    env: Env<'a>,
    stmt_ptr: *mut ffi::sqlite3_stmt,
    db_handle_for_error_reporting: *mut ffi::sqlite3,
) -> Result<Option<Vec<Term<'a>>>, StepFailure> {
    // SAFETY: Caller guarantees stmt_ptr and db_handle are valid and exclusively held.
    let step_result = unsafe { ffi::sqlite3_step(stmt_ptr) };

    match step_result {
        ffi::SQLITE_ROW => {
            // SAFETY: stmt_ptr is valid and we just confirmed SQLITE_ROW; the
            // mutex is held, so the post-step column count is stable while we
            // decode this row.
            let column_count = unsafe { ffi::sqlite3_column_count(stmt_ptr) } as usize;
            // SAFETY: stmt_ptr is valid and we just confirmed SQLITE_ROW.
            unsafe { sqlite_row_to_elixir_terms(env, stmt_ptr, column_count) }
                .map(Some)
                .map_err(StepFailure::Unreadable)
        }
        ffi::SQLITE_DONE => Ok(None),
        err_code => {
            // SAFETY: db_handle is valid for the lifetime of the connection mutex hold.
            let specific_message = unsafe {
                let err_msg_ptr = ffi::sqlite3_errmsg(db_handle_for_error_reporting);
                if err_msg_ptr.is_null() {
                    format!("SQLite error {err_code} during step; no specific message.")
                } else {
                    std::ffi::CStr::from_ptr(err_msg_ptr)
                        .to_string_lossy()
                        .into_owned()
                }
            };
            let rusqlite_err = rusqlite::Error::SqliteFailure(
                ffi::Error::new(err_code),
                Some(specific_message),
            );
            Err(StepFailure::Failed(XqliteError::from(rusqlite_err)))
        }
    }
}

#[inline]
fn bind_value_to_raw_stmt(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    bind_idx: c_int,
    value: &Value,
    db_handle: *mut ffi::sqlite3,
) -> Result<(), XqliteError> {
    // SAFETY: raw_stmt_ptr and db_handle are guaranteed valid by the caller
    // (stream_open holds the connection mutex). SQLITE_TRANSIENT tells SQLite
    // to copy the data immediately, so our local CString/slice can be dropped safely.
    let rc = unsafe {
        match value {
            Value::Null => ffi::sqlite3_bind_null(raw_stmt_ptr, bind_idx),
            Value::Integer(val) => ffi::sqlite3_bind_int64(raw_stmt_ptr, bind_idx, *val),
            Value::Real(val) => ffi::sqlite3_bind_double(raw_stmt_ptr, bind_idx, *val),
            Value::Text(s_val) => {
                // Bind with an explicit length instead of a CString: TEXT may
                // legitimately contain interior NUL bytes (SQLite stores them
                // fine), and sqlite3_bind_text never needs NUL termination
                // when a length is supplied. SQLITE_TRANSIENT copies at once.
                let len = c_int::try_from(s_val.len()).map_err(|_| {
                    XqliteError::CannotConvertToSqliteValue {
                        value_str: format!("<text len {}>", s_val.len()),
                        reason: "text length exceeds c_int range".to_string(),
                    }
                })?;
                ffi::sqlite3_bind_text(
                    raw_stmt_ptr,
                    bind_idx,
                    s_val.as_ptr() as *const std::os::raw::c_char,
                    len,
                    ffi::SQLITE_TRANSIENT(),
                )
            }
            Value::Blob(b_val) => {
                let len = c_int::try_from(b_val.len()).map_err(|_| {
                    XqliteError::CannotConvertToSqliteValue {
                        value_str: format!("<blob len {}>", b_val.len()),
                        reason: "blob length exceeds c_int range".to_string(),
                    }
                })?;
                ffi::sqlite3_bind_blob(
                    raw_stmt_ptr,
                    bind_idx,
                    b_val.as_ptr() as *const std::ffi::c_void,
                    len,
                    ffi::SQLITE_TRANSIENT(),
                )
            }
        }
    };

    if rc != ffi::SQLITE_OK {
        let ffi_err = ffi::Error::new(rc);
        // SAFETY: db_handle is valid (caller holds mutex). sqlite3_errmsg returns
        // a pointer to an internal buffer valid until the next API call; we copy immediately.
        let message = unsafe {
            let err_msg_ptr = ffi::sqlite3_errmsg(db_handle);
            if err_msg_ptr.is_null() {
                format!("Parameter binding failed at index {bind_idx} (code {rc})")
            } else {
                std::ffi::CStr::from_ptr(err_msg_ptr)
                    .to_string_lossy()
                    .into_owned()
            }
        };
        let rusqlite_err = rusqlite::Error::SqliteFailure(ffi_err, Some(message));
        return Err(XqliteError::from(rusqlite_err));
    }
    Ok(())
}

/// Refuses a positional parameter list whose length is not the statement's
/// own parameter count, before anything is bound.
///
/// SQLite itself refuses neither shape: a parameter nothing was bound to
/// reads as NULL, so a short list silently writes NULLs, and a long one only
/// fails at the first index past the last parameter. Every raw-FFI door goes
/// through here so that all of them answer what rusqlite's checked binding
/// already answers for `query`, `execute` and `query_with_changes`.
///
/// The caller holds the connection Mutex and `raw_stmt_ptr` is a live
/// prepared statement of that connection.
pub(crate) fn require_parameter_count(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    provided: usize,
) -> Result<(), XqliteError> {
    // SAFETY: raw_stmt_ptr is a live prepared statement and the connection
    // Mutex is held, per this function's contract.
    let expected = unsafe { ffi::sqlite3_bind_parameter_count(raw_stmt_ptr) } as usize;

    match provided == expected {
        true => Ok(()),
        false => Err(XqliteError::InvalidParameterCount { provided, expected }),
    }
}

pub(crate) fn bind_positional_params_ffi(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    params: &[Value],
    db_handle: *mut ffi::sqlite3,
) -> Result<(), XqliteError> {
    require_parameter_count(raw_stmt_ptr, params.len())?;

    for (i, value) in params.iter().enumerate() {
        // SQLite bind indices are 1-based
        bind_value_to_raw_stmt(raw_stmt_ptr, (i + 1) as c_int, value, db_handle)?;
    }
    Ok(())
}

pub(crate) fn bind_named_params_ffi(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    params: &[(String, Value)],
    db_handle: *mut ffi::sqlite3,
) -> Result<(), XqliteError> {
    for (name, value) in params {
        let c_name = std::ffi::CString::new(name.as_str())
            .map_err(|_| XqliteError::InvalidParameterName(name.clone()))?;

        // SAFETY: raw_stmt_ptr is valid (caller holds mutex). c_name is a valid
        // null-terminated CString. Returns 0 if parameter name not found (not UB).
        let bind_idx =
            unsafe { ffi::sqlite3_bind_parameter_index(raw_stmt_ptr, c_name.as_ptr()) };

        if bind_idx == 0 {
            return Err(XqliteError::InvalidParameterName(name.clone()));
        }
        bind_value_to_raw_stmt(raw_stmt_ptr, bind_idx, value, db_handle)?;
    }
    Ok(())
}
