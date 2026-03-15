use crate::connection::XqliteConn;
use crate::error::XqliteError;
use rusqlite::session::Session;
use rustler::{Resource, ResourceArc, resource_impl};
use std::sync::Mutex;

pub(crate) struct XqliteSession {
    // SAFETY: The Session<'static> is safe because the actual connection lifetime
    // is guaranteed by holding conn_resource_arc. The ResourceArc prevents the
    // connection from being dropped while this session exists. Session::new()
    // borrows the connection, but we erase the lifetime via transmute — the
    // borrow is logically enforced by the ResourceArc, not by Rust's borrow checker.
    pub(crate) session: Mutex<Option<Session<'static>>>,
    #[allow(dead_code)]
    pub(crate) conn_resource_arc: ResourceArc<XqliteConn>,
}

// SAFETY: Session is protected by a Mutex. The connection is protected by its
// own Mutex. Access is serialized.
unsafe impl Send for XqliteSession {}
unsafe impl Sync for XqliteSession {}

#[resource_impl]
impl Resource for XqliteSession {}

#[inline]
pub(crate) fn with_session<F, R>(
    session_handle: &ResourceArc<XqliteSession>,
    func: F,
) -> Result<R, XqliteError>
where
    F: FnOnce(&Session<'static>) -> Result<R, XqliteError>,
{
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
