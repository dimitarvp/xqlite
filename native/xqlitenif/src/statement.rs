use crate::connection::XqliteConn;
use crate::error::XqliteError;
use crate::stream::take_and_finalize_raw;
use rusqlite::ffi;
use rustler::{Resource, ResourceArc};
use std::sync::atomic::{AtomicPtr, Ordering};

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
    pub(crate) column_names: Vec<String>,
    pub(crate) column_count: usize,
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
            // Errors from Drop cannot be propagated. Log to stderr.
            eprintln!(
                "[xqlite] Error finalizing SQLite statement during statement resource drop: {e:?}"
            );
        }
    }
}
