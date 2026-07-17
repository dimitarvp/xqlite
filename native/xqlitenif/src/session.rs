use crate::connection::XqliteConn;
use crate::error::XqliteError;
use rusqlite::session::Session;
use rustler::{Resource, ResourceArc, resource_impl};
use std::sync::Mutex;

pub(crate) struct XqliteSession {
    // SAFETY: the `Session<'static>` is sound because `conn_resource_arc`
    // keeps the `XqliteConn` *resource* alive for at least as long as this
    // handle. Session::new() borrows the connection; we erase the lifetime
    // via transmute at construction.
    //
    // Lifetime is NOT the same as exclusion. Every `sqlite3session_*` call
    // goes through `with_session`/`with_session_mut`/`close`, which hold the
    // *connection* Mutex for the whole duration of the raw call. The
    // per-session Mutex only provides interior mutability and guards the
    // `Option` for explicit delete.
    pub(crate) session: Mutex<Option<Session<'static>>>,
    pub(crate) conn_resource_arc: ResourceArc<XqliteConn>,
}

// SAFETY: Session is protected by a Mutex. The connection is protected by its
// own Mutex. Access is serialized.
unsafe impl Send for XqliteSession {}
unsafe impl Sync for XqliteSession {}

#[resource_impl]
impl Resource for XqliteSession {}

impl Drop for XqliteSession {
    fn drop(&mut self) {
        let _ = close(self);
    }
}

/// Delete the `sqlite3_session` under the connection Mutex. Shared by the
/// `session_delete` NIF and `Drop`; idempotent.
///
/// Lock order — connection Mutex, then the per-session guard — matches
/// `with_session`. Unlike a blob or statement, a session registers no
/// internal Vdbe, so an explicit `close/1` lets `sqlite3_close` free the db
/// out from under it — calling `sqlite3session_delete` afterward would be a
/// use-after-free. So we delete ONLY while the connection is still open; on a
/// closed or poisoned connection we leak the (small) session object instead.
pub(crate) fn close(session_handle: &XqliteSession) -> Result<(), XqliteError> {
    let conn_lock = session_handle.conn_resource_arc.conn.lock();
    // Recover the per-session guard even if poisoned: the session MUST be torn
    // down here (leak-or-delete), never left for the field's default `Drop` to
    // delete without the connection lock.
    let mut session_guard = match session_handle.session.lock() {
        Ok(g) => g,
        Err(p) => p.into_inner(),
    };
    let Some(session) = session_guard.take() else {
        return Ok(());
    };
    match conn_lock {
        Ok(ref conn_guard) if conn_guard.is_some() => {
            // `sqlite3session_delete` runs under the held connection Mutex.
            drop(session);
            Ok(())
        }
        _ => {
            // Connection closed (db already freed) or lock poisoned: leak the
            // session rather than dereference a freed db.
            std::mem::forget(session);
            Ok(())
        }
    }
}

#[inline]
pub(crate) fn with_session<F, R>(
    session_handle: &ResourceArc<XqliteSession>,
    func: F,
) -> Result<R, XqliteError>
where
    F: FnOnce(&Session<'static>) -> Result<R, XqliteError>,
{
    // Raw-handle locking rule: every `sqlite3session_*` call must hold the
    // connection Mutex. Acquire it first (order conn -> session, matching
    // `close`), prove the connection open, then take the per-session guard.
    let conn_guard = session_handle
        .conn_resource_arc
        .conn
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    if conn_guard.is_none() {
        return Err(XqliteError::ConnectionClosed);
    }
    let guard = session_handle
        .session
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    match guard.as_ref() {
        Some(session) => func(session),
        None => Err(XqliteError::ConnectionClosed),
    }
}

#[inline]
pub(crate) fn with_session_mut<F, R>(
    session_handle: &ResourceArc<XqliteSession>,
    func: F,
) -> Result<R, XqliteError>
where
    F: FnOnce(&mut Session<'static>) -> Result<R, XqliteError>,
{
    let conn_guard = session_handle
        .conn_resource_arc
        .conn
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    if conn_guard.is_none() {
        return Err(XqliteError::ConnectionClosed);
    }
    let mut guard = session_handle
        .session
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    match guard.as_mut() {
        Some(session) => func(session),
        None => Err(XqliteError::ConnectionClosed),
    }
}

#[inline]
pub(crate) fn to_owned_binary(
    bytes: &[u8],
    context: &str,
) -> Result<rustler::OwnedBinary, XqliteError> {
    let mut binary = rustler::OwnedBinary::new(bytes.len()).ok_or_else(|| {
        XqliteError::InternalEncodingError {
            context: format!("failed to allocate binary for {context}"),
        }
    })?;
    binary.as_mut_slice().copy_from_slice(bytes);
    Ok(binary)
}
