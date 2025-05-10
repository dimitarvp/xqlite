use crate::error::XqliteError;
use crate::nif::XqliteConn;
use rusqlite::ffi;
use rusqlite::types::Value;
use rustler::{Resource, ResourceArc};
use std::os::raw::c_int;
use std::ptr::NonNull;
use std::sync::atomic::{AtomicBool, Ordering}; // Ordering will be used by is_done
use std::sync::Mutex;

// Wrapper struct for the raw SQLite statement pointer to make it Send + Sync
// This is safe because we will only ever access the sqlite3_stmt* pointer
// from one thread at a time, typically the thread that owns the Elixir process
// calling the NIF, and the access is guarded by the XqliteStream's lifecycle
// and the connection's Mutex when necessary.
pub(crate) struct RawStmtPtr(pub(crate) NonNull<ffi::sqlite3_stmt>);

unsafe impl Send for RawStmtPtr {}
unsafe impl Sync for RawStmtPtr {} // Safe because Mutex will protect access to Option<RawStmtPtr>

// Represents an active SQLite prepared statement for streaming
pub(crate) struct XqliteStream {
    pub(crate) raw_stmt: Mutex<Option<RawStmtPtr>>, // Store the wrapped pointer

    pub(crate) conn_resource_arc: ResourceArc<XqliteConn>,

    pub(crate) column_names: Vec<String>,
    pub(crate) column_count: usize,

    pub(crate) is_done: AtomicBool,
}

#[rustler::resource_impl]
impl Resource for XqliteStream {}

impl XqliteStream {
    pub(crate) fn ensure_finalized(&self) -> Result<(), XqliteError> {
        let mut stmt_option_guard = self.raw_stmt.lock().map_err(|_| {
            XqliteError::LockError(
                "Failed to lock raw_stmt mutex for finalization".to_string(),
            )
        })?;

        if let Some(wrapped_ptr) = stmt_option_guard.take() {
            let result_code = unsafe { ffi::sqlite3_finalize(wrapped_ptr.0.as_ptr()) };
            if result_code != ffi::SQLITE_OK {
                let lock_result = self.conn_resource_arc.0.lock();
                match lock_result {
                    Ok(_conn_guard) => {
                        // Construct ffi::Error from the code.
                        let ffi_err = ffi::Error::new(result_code);
                        // Create a RusqliteError::SqliteFailure.
                        // The message will be fetched from sqlite3_errmsg by rusqlite
                        // when it converts ffi::Error to a string, or if not, it uses a generic one.
                        let rusqlite_err = rusqlite::Error::SqliteFailure(
                            ffi_err,
                            None,
                            // Some(format!(
                            //     "Failed to finalize SQLite statement (code: {})",
                            //     result_code
                            // )),
                        );
                        return Err(XqliteError::from(rusqlite_err));
                    }
                    Err(_) => {
                        return Err(XqliteError::SqliteFailure {
                            code: result_code,
                            extended_code: result_code,
                            message: Some("Failed to finalize statement and could not lock connection for details.".into()),
                        });
                    }
                }
            }
        }
        Ok(())
    }
}

impl Drop for XqliteStream {
    fn drop(&mut self) {
        // The `raw_stmt` field is a Mutex, so we access it through `self.raw_stmt.lock()`.
        // `ensure_finalized` handles the locking.
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
