use crate::connection::XqliteConn;
use crate::error::XqliteError;
use rusqlite::blob::Blob;
use rustler::{Resource, ResourceArc, resource_impl};
use std::sync::Mutex;

pub(crate) struct XqliteBlob {
    // SAFETY: The Blob<'static> is safe because the actual connection lifetime
    // is guaranteed by holding conn_resource_arc. The ResourceArc prevents the
    // connection from being dropped while this blob handle exists.
    pub(crate) blob: Mutex<Option<Blob<'static>>>,
    #[allow(dead_code)]
    pub(crate) conn_resource_arc: ResourceArc<XqliteConn>,
}

// SAFETY: Blob is protected by a Mutex. The connection is protected by its
// own Mutex. Access is serialized.
unsafe impl Send for XqliteBlob {}
unsafe impl Sync for XqliteBlob {}

#[resource_impl]
impl Resource for XqliteBlob {}

#[inline]
pub(crate) fn with_blob<F, R>(
    blob_handle: &ResourceArc<XqliteBlob>,
    func: F,
) -> Result<R, XqliteError>
where
    F: FnOnce(&Blob<'static>) -> Result<R, XqliteError>,
{
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
    let mut guard = blob_handle
        .blob
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    match guard.as_mut() {
        Some(blob) => func(blob),
        None => Err(XqliteError::ConnectionClosed),
    }
}
