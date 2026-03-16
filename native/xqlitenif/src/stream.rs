use crate::connection::XqliteConn;
use crate::error::XqliteError;
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
            // Acquire the connection lock before finalizing. This ensures no other
            // thread is currently inside sqlite3_step on this connection. Without
            // this lock, a concurrent stream_fetch could be mid-step when we finalize
            // the statement out from under it.
            let conn_guard = self
                .conn_resource_arc
                .conn
                .lock()
                .map_err(|e| XqliteError::LockError(e.to_string()))?;

            // SAFETY: old_ptr was obtained via atomic swap, guaranteeing exclusive
            // ownership. The connection lock is held, ensuring no concurrent sqlite3_step.
            let result_code = unsafe { ffi::sqlite3_finalize(old_ptr) };
            if result_code != ffi::SQLITE_OK {
                let ffi_err = ffi::Error::new(result_code);
                let mut message =
                    format!("Failed to finalize SQLite statement (code: {result_code})");

                if let Some(conn) = conn_guard.as_ref() {
                    // SAFETY: conn_guard holds the mutex. sqlite3_errmsg returns a
                    // pointer valid until the next API call; we copy immediately.
                    let specific_sqlite_msg = unsafe {
                        let err_msg_ptr = ffi::sqlite3_errmsg(conn.handle());
                        if !err_msg_ptr.is_null() {
                            std::ffi::CStr::from_ptr(err_msg_ptr)
                                .to_string_lossy()
                                .into_owned()
                        } else {
                            String::new()
                        }
                    };
                    if !specific_sqlite_msg.is_empty()
                        && specific_sqlite_msg.to_lowercase() != "not an error"
                    {
                        message = specific_sqlite_msg;
                    }
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

/// Steps a prepared statement once and returns the row data if available.
///
/// # Safety
///
/// - `stmt_ptr` must be non-null and point to a valid, prepared `sqlite3_stmt`.
/// - `db_handle_for_error_reporting` must be the `sqlite3*` handle that owns `stmt_ptr`.
/// - `column_count` must match the statement's actual column count.
/// - The caller must hold the connection mutex for the duration of this call.
#[inline]
pub(crate) unsafe fn process_single_step<'a>(
    env: Env<'a>,
    stmt_ptr: *mut ffi::sqlite3_stmt,
    column_count: usize,
    db_handle_for_error_reporting: *mut ffi::sqlite3,
) -> Result<Option<Vec<Term<'a>>>, XqliteError> {
    // SAFETY: Caller guarantees stmt_ptr and db_handle are valid and exclusively held.
    let step_result = unsafe { ffi::sqlite3_step(stmt_ptr) };

    match step_result {
        ffi::SQLITE_ROW => {
            // SAFETY: stmt_ptr is valid and we just confirmed SQLITE_ROW.
            unsafe { sqlite_row_to_elixir_terms(env, stmt_ptr, column_count) }.map(Some)
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
            Err(XqliteError::from(rusqlite_err))
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
                let c_text = std::ffi::CString::new(s_val.as_str())
                    .map_err(|_e| XqliteError::NulErrorInString)?;
                let len = c_int::try_from(c_text.as_bytes().len()).map_err(|_| {
                    XqliteError::CannotConvertToSqliteValue {
                        value_str: format!("<text len {}>", c_text.as_bytes().len()),
                        reason: "text length exceeds c_int range".to_string(),
                    }
                })?;
                ffi::sqlite3_bind_text(
                    raw_stmt_ptr,
                    bind_idx,
                    c_text.as_ptr(),
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
