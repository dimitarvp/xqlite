use crate::connection::XqliteConn;
use crate::error::XqliteError;
use rusqlite::blob::Blob;
use rustler::{Resource, ResourceArc, resource_impl};
use std::sync::Mutex;

pub(crate) struct XqliteBlob {
    // SAFETY: the `Blob<'static>` is sound because `conn_resource_arc` keeps
    // the `XqliteConn` *resource* alive for at least as long as this handle.
    //
    // Lifetime is NOT the same as exclusion. Every `sqlite3_blob_*` call goes
    // through `with_blob`/`with_blob_mut`/`close`, which hold the *connection*
    // Mutex for the whole duration of the raw call — that is what serialises
    // against concurrent use of the same NOMUTEX connection (the raw-handle
    // locking rule). The per-blob Mutex only provides interior mutability and
    // guards the `Option` for explicit close.
    pub(crate) blob: Mutex<Option<Blob<'static>>>,
    pub(crate) conn_resource_arc: ResourceArc<XqliteConn>,
}

// SAFETY: Blob is protected by a Mutex. The connection is protected by its
// own Mutex. Access is serialized.
unsafe impl Send for XqliteBlob {}
unsafe impl Sync for XqliteBlob {}

#[resource_impl]
impl Resource for XqliteBlob {}

impl Drop for XqliteBlob {
    fn drop(&mut self) {
        let _ = close(self);
    }
}

/// Finalize the `sqlite3_blob` under the connection Mutex. Shared by the
/// `blob_close` NIF and `Drop`; idempotent (a second call is a no-op).
///
/// Lock order — connection Mutex, then the per-blob guard — matches
/// `with_blob`. A live blob keeps the db alive (`sqlite3_close` returns
/// `SQLITE_BUSY` while an internal blob cursor exists), so `sqlite3_blob_close`
/// is safe whenever we hold the connection lock cleanly, even after an
/// explicit `close/1`. On a poisoned connection lock we must not touch SQLite
/// state, so we leak the blob instead (mirrors `take_and_finalize_raw`).
pub(crate) fn close(blob_handle: &XqliteBlob) -> Result<(), XqliteError> {
    let conn_lock = blob_handle.conn_resource_arc.conn.lock();
    // Recover the per-blob guard even if poisoned: the blob MUST be torn down
    // here (leak-or-close), never left for the field's default `Drop` to close
    // without the connection lock.
    let mut blob_guard = match blob_handle.blob.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    };
    let Some(blob) = blob_guard.take() else {
        return Ok(());
    };
    match conn_lock {
        Ok(_conn_guard) => {
            // `sqlite3_blob_close` runs under the held connection Mutex.
            drop(blob);
            Ok(())
        }
        Err(_) => {
            std::mem::forget(blob);
            Err(XqliteError::LockError(
                "connection Mutex poisoned during blob close".to_string(),
            ))
        }
    }
}

#[inline]
pub(crate) fn with_blob<F, R>(
    blob_handle: &ResourceArc<XqliteBlob>,
    func: F,
) -> Result<R, XqliteError>
where
    F: FnOnce(&Blob<'static>) -> Result<R, XqliteError>,
{
    // Raw-handle locking rule: every `sqlite3_blob_*` call must hold the
    // connection Mutex. Acquire it first (order conn -> blob, matching
    // `close`), prove the connection open, then take the per-blob guard.
    let conn_guard = blob_handle
        .conn_resource_arc
        .conn
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    if conn_guard.is_none() {
        return Err(XqliteError::ConnectionClosed);
    }
    let guard = blob_handle
        .blob
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    match guard.as_ref() {
        Some(blob) => func(blob),
        None => Err(XqliteError::ConnectionClosed),
    }
}

#[inline]
pub(crate) fn with_blob_mut<F, R>(
    blob_handle: &ResourceArc<XqliteBlob>,
    func: F,
) -> Result<R, XqliteError>
where
    F: FnOnce(&mut Blob<'static>) -> Result<R, XqliteError>,
{
    let conn_guard = blob_handle
        .conn_resource_arc
        .conn
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    if conn_guard.is_none() {
        return Err(XqliteError::ConnectionClosed);
    }
    let mut guard = blob_handle
        .blob
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    match guard.as_mut() {
        Some(blob) => func(blob),
        None => Err(XqliteError::ConnectionClosed),
    }
}
