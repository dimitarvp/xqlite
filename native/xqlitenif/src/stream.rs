use crate::error::XqliteError;
use crate::nif::XqliteConn;
use crate::util::sqlite_row_to_elixir_terms;
use rusqlite::ffi;
use rusqlite::types::Value;
use rustler::{Env, Resource, ResourceArc, Term};
use std::os::raw::c_int;
use std::ptr::NonNull;
use std::sync::Mutex;

// Wrapper struct for the raw SQLite statement pointer to make it Send + Sync
// This is safe because we will only ever access the sqlite3_stmt* pointer
// from one thread at a time, typically the thread that owns the Elixir process
// calling the NIF, and the access is guarded by the XqliteStream's lifecycle
// and the connection's Mutex when necessary.
pub(crate) struct RawStmtPtr(pub(crate) NonNull<ffi::sqlite3_stmt>);

unsafe impl Send for RawStmtPtr {}
unsafe impl Sync for RawStmtPtr {} // Safe because Mutex will protect access to Option<RawStmtPtr>

// #[derive(Debug)]
pub(crate) struct StreamState {
    pub(crate) raw_stmt: Option<RawStmtPtr>,
    pub(crate) is_done: bool, // Now a simple bool
}

// Represents an active SQLite prepared statement for streaming
pub(crate) struct XqliteStream {
    // This Mutex protects all state that changes during the stream's lifecycle
    // (is_done and the presence of raw_stmt).
    pub(crate) state: Mutex<StreamState>,

    // These are immutable after stream_open completes
    pub(crate) conn_resource_arc: ResourceArc<XqliteConn>,
    pub(crate) column_names: Vec<String>,
    pub(crate) column_count: usize,
}

#[rustler::resource_impl]
impl Resource for XqliteStream {}

impl XqliteStream {
    // ensure_finalized now operates on the state within the Mutex
    pub(crate) fn ensure_finalized(&self) -> Result<(), XqliteError> {
        // Lock the entire state to check and finalize raw_stmt
        let mut state_guard = self.state.lock().map_err(|poison_err| {
            XqliteError::LockError(format!(
                "Failed to lock stream state for finalization: {:?}",
                poison_err
            ))
        })?;

        // state_guard is a MutexGuard<StreamState>
        if let Some(wrapped_ptr) = state_guard.raw_stmt.take() {
            // take() from the Option within StreamState
            let result_code = unsafe { ffi::sqlite3_finalize(wrapped_ptr.0.as_ptr()) };
            if result_code != ffi::SQLITE_OK {
                // state_guard is still held, so conn_resource_arc is accessible.
                // Drop the state_guard before attempting to lock the connection mutex,
                // to avoid potential (though unlikely here) deadlock if they were related.
                drop(state_guard);

                let conn_lock_result = self.conn_resource_arc.0.lock();
                match conn_lock_result {
                    Ok(_conn_guard_for_error) => {
                        let ffi_err = ffi::Error::new(result_code);
                        let rusqlite_err = rusqlite::Error::SqliteFailure(ffi_err, None);
                        return Err(XqliteError::from(rusqlite_err));
                    }
                    Err(poison_err_conn) => {
                        return Err(XqliteError::SqliteFailure {
                            code: result_code,
                            extended_code: result_code,
                            message: Some(format!(
                                "Failed to finalize statement (code: {}) and could not lock connection for details: {:?}",
                                result_code, poison_err_conn
                            )),
                        });
                    }
                }
            }
        }
        // If raw_stmt was None, it was already finalized.
        // Mark as done if not already, for consistency after finalization attempt.
        state_guard.is_done = true;
        Ok(())
    }
}

impl Drop for XqliteStream {
    fn drop(&mut self) {
        // `ensure_finalized` takes `&self` because `state` is `Mutex<StreamState>`
        if let Err(e) = self.ensure_finalized() {
            eprintln!(
                "[xqlite] Error finalizing SQLite statement during stream resource drop: {:?}",
                e
            );
        }
    }
}

// Helper to bind a single rusqlite::types::Value to a raw statement at a given index.
// Needs the raw connection pointer for detailed error reporting if sqlite3_bind_* fails.
fn bind_value_to_raw_stmt(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    bind_idx: c_int,
    value: &Value,                 // Use fully qualified type
    _db_handle: *mut ffi::sqlite3, // For error reporting context
) -> Result<(), XqliteError> {
    let rc = unsafe {
        match value {
            Value::Null => {
                // Use fully qualified type
                ffi::sqlite3_bind_null(raw_stmt_ptr, bind_idx)
            }
            Value::Integer(val) => {
                // Use fully qualified type
                ffi::sqlite3_bind_int64(raw_stmt_ptr, bind_idx, *val)
            }
            Value::Real(val) => {
                // Use fully qualified type
                ffi::sqlite3_bind_double(raw_stmt_ptr, bind_idx, *val)
            }
            Value::Text(s_val) => {
                // Use fully qualified type
                let c_text = std::ffi::CString::new(s_val.as_str())
                    .map_err(|_e| XqliteError::NulErrorInString)?; // _e to avoid unused warning for now
                ffi::sqlite3_bind_text(
                    raw_stmt_ptr,
                    bind_idx,
                    c_text.as_ptr(),
                    c_text.as_bytes().len() as c_int,
                    ffi::SQLITE_TRANSIENT(),
                )
            }
            Value::Blob(b_val) => {
                // Use fully qualified type
                ffi::sqlite3_bind_blob(
                    raw_stmt_ptr,
                    bind_idx,
                    b_val.as_ptr() as *const std::ffi::c_void,
                    b_val.len() as c_int,
                    ffi::SQLITE_TRANSIENT(),
                )
            }
        }
    };

    if rc != ffi::SQLITE_OK {
        // Correct way to construct the error:
        let ffi_err = ffi::Error::new(rc);
        // Let rusqlite derive the message. The db_handle isn't directly used by
        // SqliteFailure constructor but is implicitly needed if .to_string() on the
        // resulting error tries to call sqlite3_errmsg(db_handle).
        // The presence of `db_handle` as an argument ensures it's available in this scope.
        // We don't need to explicitly use `db_handle` in this line unless we were calling
        // ffi::sqlite3_errmsg ourselves.
        let rusqlite_err = rusqlite::Error::SqliteFailure(
            ffi_err, None, // Let rusqlite derive the message string
        );
        return Err(XqliteError::from(rusqlite_err));
    }
    Ok(())
}

// Helper to bind positional parameters.
// db_handle is needed for error reporting from bind_value_to_raw_stmt.
pub(crate) fn bind_positional_params_ffi(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    params: &[Value],
    db_handle: *mut ffi::sqlite3,
) -> Result<(), XqliteError> {
    for (i, value) in params.iter().enumerate() {
        bind_value_to_raw_stmt(raw_stmt_ptr, (i + 1) as c_int, value, db_handle)?;
    }
    Ok(())
}

// Helper to bind named parameters.
// db_handle is needed for error reporting.
pub(crate) fn bind_named_params_ffi(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    params: &[(String, Value)], // Vec of (name, value)
    db_handle: *mut ffi::sqlite3,
) -> Result<(), XqliteError> {
    for (name, value) in params {
        let c_name = std::ffi::CString::new(name.as_str())
            .map_err(|_| XqliteError::InvalidParameterName(name.clone()))?; // Interior NUL in name

        let bind_idx =
            unsafe { ffi::sqlite3_bind_parameter_index(raw_stmt_ptr, c_name.as_ptr()) };

        if bind_idx == 0 {
            // Parameter name not found in SQL statement
            return Err(XqliteError::InvalidParameterName(name.clone()));
        }
        bind_value_to_raw_stmt(raw_stmt_ptr, bind_idx, value, db_handle)?;
    }
    Ok(())
}

// Helper to process a single sqlite3_step.
// Returns Ok(Some(row_data)) if a row is fetched.
// Returns Ok(None) if SQLITE_DONE is reached.
// Returns Err(XqliteError) if a step or conversion error occurs.
// This function does NOT modify stream_handle.state itself.
pub(crate) unsafe fn process_single_step(
    env: Env<'_>,
    stmt_ptr: *mut ffi::sqlite3_stmt,
    column_count: usize, // Pass column_count directly
    // Pass the raw db_handle for error reporting from SQLite if step fails
    db_handle_for_error_reporting: *mut ffi::sqlite3,
) -> Result<Option<Vec<Term<'_>>>, XqliteError> {
    let step_result = ffi::sqlite3_step(stmt_ptr);

    match step_result {
        ffi::SQLITE_ROW => {
            match sqlite_row_to_elixir_terms(env, stmt_ptr, column_count) {
                Ok(row_terms) => Ok(Some(row_terms)),
                Err(e) => Err(e), // Propagate row conversion error
            }
        }
        ffi::SQLITE_DONE => {
            Ok(None) // Signal DONE to the caller
        }
        err_code => {
            // Get specific error message from the connection
            let specific_message = {
                // Scoped for err_msg_ptr
                let err_msg_ptr = ffi::sqlite3_errmsg(db_handle_for_error_reporting);
                if err_msg_ptr.is_null() {
                    format!(
                        "SQLite error {} during step; no specific message.",
                        err_code
                    )
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
            Err(XqliteError::from(rusqlite_err))
        }
    }
}
