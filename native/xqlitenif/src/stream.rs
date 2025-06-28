use crate::error::XqliteError;
use crate::nif::XqliteConn;
use crate::util::sqlite_row_to_elixir_terms;
use rusqlite::ffi;
use rusqlite::types::Value;
use rustler::{Env, Resource, ResourceArc, Term};
use std::os::raw::c_int;
use std::sync::atomic::{AtomicPtr, Ordering};

pub(crate) struct XqliteStream {
    // This AtomicPtr holds the raw SQLite statement.
    // If it's null_mut(), the stream is considered done/closed/finalized.
    pub(crate) atomic_raw_stmt: AtomicPtr<ffi::sqlite3_stmt>,

    // These are immutable after stream_open completes
    pub(crate) conn_resource_arc: ResourceArc<XqliteConn>,
    pub(crate) column_names: Vec<String>,
    pub(crate) column_count: usize,
}

#[rustler::resource_impl]
impl Resource for XqliteStream {}

impl XqliteStream {
    // Helper performs the atomic swap and finalization.
    // Called by Drop and by stream_close NIF.
    // It is pub(crate) for use by nif.rs.
    pub(crate) fn take_and_finalize_atomic_stmt(
        &self, // Takes &self to access atomic_raw_stmt and conn_resource_arc
    ) -> Result<(), XqliteError> {
        // Atomically swap the current pointer with null_mut(), getting the old pointer.
        // Ordering::AcqRel ensures that this operation synchronizes with other atomic
        // operations on other threads: acquire for the read (load of old value)
        // and release for the write (store of null_mut).
        let old_ptr = self
            .atomic_raw_stmt
            .swap(std::ptr::null_mut(), Ordering::AcqRel);

        if !old_ptr.is_null() {
            // If the old pointer was not null, it means we are responsible for finalizing it.
            // This is an unsafe FFI call.
            let result_code = unsafe { ffi::sqlite3_finalize(old_ptr) };
            if result_code != ffi::SQLITE_OK {
                // Attempt to get a more detailed error message from the connection.
                let ffi_err = ffi::Error::new(result_code);
                let mut message = format!(
                    "Failed to finalize SQLite statement (code: {result_code})"
                );

                // Try to lock the connection to get a specific SQLite error message.
                // This lock is on a different Mutex (the one inside XqliteConn).
                if let Ok(conn_guard) = self.conn_resource_arc.0.lock() {
                    // These FFI calls are unsafe.
                    let specific_sqlite_msg = unsafe {
                        let err_msg_ptr = ffi::sqlite3_errmsg(conn_guard.handle());
                        if !err_msg_ptr.is_null() {
                            std::ffi::CStr::from_ptr(err_msg_ptr)
                                .to_string_lossy()
                                .into_owned()
                        } else {
                            // No specific message from SQLite, keep our formatted one.
                            String::new()
                        }
                    };
                    if !specific_sqlite_msg.is_empty()
                        && specific_sqlite_msg.to_lowercase() != "not an error"
                    {
                        message = specific_sqlite_msg;
                    }
                } else {
                    // Failed to lock the connection; append to the generic message.
                    message.push_str(" (additionally, failed to lock connection for specific error message)");
                }

                let rusqlite_err = rusqlite::Error::SqliteFailure(ffi_err, Some(message));
                return Err(XqliteError::from(rusqlite_err));
            }
        }
        // If old_ptr was null, it was already finalized by another call or was never set.
        Ok(())
    }
}

impl Drop for XqliteStream {
    fn drop(&mut self) {
        // Call the helper method to take and finalize the statement.
        // `&mut self` allows access to `&self.atomic_raw_stmt` and `&self.conn_resource_arc`.
        if let Err(e) = self.take_and_finalize_atomic_stmt() {
            // Errors from Drop cannot be propagated. Log to stderr.
            // This indicates a problem during cleanup, potentially a resource leak
            // if SQLite itself failed to finalize properly.
            eprintln!(
                "[xqlite] Error finalizing SQLite statement during stream resource drop: {e:?}"
            );
        }
    }
}

// Helper to process a single sqlite3_step.
// Returns Ok(Some(row_data)) if a row is fetched.
// Returns Ok(None) if SQLITE_DONE is reached.
// Returns Err(XqliteError) if a step or conversion error occurs.
// This function does NOT modify any shared XqliteStream state (like an is_done flag).
// It is unsafe because it dereferences stmt_ptr and calls unsafe FFI functions.
pub(crate) unsafe fn process_single_step<'a>(
    env: Env<'a>,
    stmt_ptr: *mut ffi::sqlite3_stmt, // Assumed to be valid and non-null by caller
    column_count: usize,
    db_handle_for_error_reporting: *mut ffi::sqlite3, // For sqlite3_errmsg
) -> Result<Option<Vec<Term<'a>>>, XqliteError> {
    let step_result = ffi::sqlite3_step(stmt_ptr);

    match step_result {
        ffi::SQLITE_ROW => {
            // sqlite_row_to_elixir_terms is also unsafe
            match sqlite_row_to_elixir_terms(env, stmt_ptr, column_count) {
                Ok(row_terms) => Ok(Some(row_terms)),
                Err(e) => Err(e),
            }
        }
        ffi::SQLITE_DONE => {
            Ok(None) // Signal DONE to the caller
        }
        err_code => {
            // Any other SQLite error code from sqlite3_step
            // Get specific error message from the connection using the provided db_handle
            let specific_message = {
                let err_msg_ptr = ffi::sqlite3_errmsg(db_handle_for_error_reporting);
                if err_msg_ptr.is_null() {
                    format!(
                        "SQLite error {err_code} during step; no specific message."
                    )
                } else {
                    // This is an unsafe FFI call
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

fn bind_value_to_raw_stmt(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    bind_idx: c_int,
    value: &Value,
    db_handle: *mut ffi::sqlite3,
) -> Result<(), XqliteError> {
    let rc = unsafe {
        match value {
            Value::Null => ffi::sqlite3_bind_null(raw_stmt_ptr, bind_idx),
            Value::Integer(val) => ffi::sqlite3_bind_int64(raw_stmt_ptr, bind_idx, *val),
            Value::Real(val) => ffi::sqlite3_bind_double(raw_stmt_ptr, bind_idx, *val),
            Value::Text(s_val) => {
                let c_text = std::ffi::CString::new(s_val.as_str())
                    .map_err(|_e| XqliteError::NulErrorInString)?;
                ffi::sqlite3_bind_text(
                    raw_stmt_ptr,
                    bind_idx,
                    c_text.as_ptr(),
                    c_text.as_bytes().len() as c_int,
                    ffi::SQLITE_TRANSIENT(),
                )
            }
            Value::Blob(b_val) => ffi::sqlite3_bind_blob(
                raw_stmt_ptr,
                bind_idx,
                b_val.as_ptr() as *const std::ffi::c_void,
                b_val.len() as c_int,
                ffi::SQLITE_TRANSIENT(),
            ),
        }
    };

    if rc != ffi::SQLITE_OK {
        let ffi_err = ffi::Error::new(rc);
        // Get specific message using db_handle if possible
        let message = unsafe {
            let err_msg_ptr = ffi::sqlite3_errmsg(db_handle);
            if err_msg_ptr.is_null() {
                format!(
                    "Parameter binding failed at index {bind_idx} (code {rc})"
                )
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

pub(crate) fn bind_positional_params_ffi(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    params: &[Value],
    db_handle: *mut ffi::sqlite3,
) -> Result<(), XqliteError> {
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

        // This is an unsafe FFI call
        let bind_idx =
            unsafe { ffi::sqlite3_bind_parameter_index(raw_stmt_ptr, c_name.as_ptr()) };

        if bind_idx == 0 {
            return Err(XqliteError::InvalidParameterName(name.clone()));
        }
        bind_value_to_raw_stmt(raw_stmt_ptr, bind_idx, value, db_handle)?;
    }
    Ok(())
}
