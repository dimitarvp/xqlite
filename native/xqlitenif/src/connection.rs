use crate::atoms;
use crate::busy_handler::BusySlotState;
use crate::commit_hook::{self, CommitSubscriber};
use crate::error::XqliteError;
use crate::hook_util::{self, HookList};
use crate::progress_dispatch::{self, ProgressDispatch};
use crate::rollback_hook::{self, RollbackSubscriber};
use crate::update_hook::{self, UpdateSubscriber};
use crate::util::encode_text;
use crate::wal_hook::{self, WalDispatch};
use rusqlite::ffi;
use rusqlite::{Connection, Error as RusqliteError};
use rustler::{Encoder, Env, Resource, ResourceArc, Term, resource_impl, types::map::map_new};
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::AtomicPtr;
use std::sync::atomic::Ordering;

/// One raw handle xqlite opened on a connection: a prepared statement (a
/// stream owns one of those too) or an incremental blob. The cell is shared
/// with the resource that owns the handle, so whoever reaches it first —
/// the owner's finalize, its `Drop`, or the connection's own close — swaps
/// it to null and hands the handle back to SQLite exactly once.
#[derive(Debug)]
pub(crate) enum ChildHandle {
    Stmt(Arc<AtomicPtr<ffi::sqlite3_stmt>>),
    Blob(Arc<AtomicPtr<ffi::sqlite3_blob>>),
}

impl ChildHandle {
    fn key(&self) -> usize {
        match self {
            ChildHandle::Stmt(cell) => Arc::as_ptr(cell) as usize,
            ChildHandle::Blob(cell) => Arc::as_ptr(cell) as usize,
        }
    }

    /// Takes the raw handle out of the cell and gives it back to SQLite.
    ///
    /// # Safety
    ///
    /// The caller holds the owning connection's `Mutex` for the whole call —
    /// or holds it poisoned, which keeps every other thread out of SQLite on
    /// that connection — and the cell holds null or a handle SQLite created
    /// on that same connection.
    unsafe fn release(&self) {
        match self {
            ChildHandle::Stmt(cell) => {
                let ptr = cell.swap(std::ptr::null_mut(), Ordering::AcqRel);
                if !ptr.is_null() {
                    // SAFETY: the swap gives exclusive ownership of `ptr`, and the
                    // connection Mutex is held (fn contract). `sqlite3_finalize`
                    // echoes the statement's last evaluation error and destroys it
                    // either way; that error already reached the caller at step
                    // time, so it is deliberately discarded here.
                    let _ = unsafe { ffi::sqlite3_finalize(ptr) };
                }
            }
            ChildHandle::Blob(cell) => {
                let ptr = cell.swap(std::ptr::null_mut(), Ordering::AcqRel);
                if !ptr.is_null() {
                    // SAFETY: as above; `sqlite3_blob_close`'s flush result is
                    // discarded for the same reason — the blob is destroyed
                    // whatever it returns.
                    let _ = unsafe { ffi::sqlite3_blob_close(ptr) };
                }
            }
        }
    }
}

#[derive(Debug)]
pub(crate) struct XqliteConn {
    pub(crate) conn: Mutex<Option<Connection>>,

    // Every statement, stream and blob xqlite opened on this connection and
    // has not released yet, keyed by its cell's address. `close_connection`
    // drains it before dropping the `Connection`, so `sqlite3_close` finds
    // no Vdbe of ours and frees the handle instead of answering SQLITE_BUSY.
    // Statements a virtual-table module owns are not in here: SQLite
    // disconnects those itself during close. Lock order is always the
    // connection Mutex first, this one second.
    pub(crate) children: Mutex<HashMap<usize, ChildHandle>>,

    pub(crate) extensions_enabled: AtomicBool,

    // The busy slot: a single-slot retry POLICY (a policy cannot
    // compose) plus any number of observer subscribers, one C callback
    // serving both halves. Installed lazily, removed when both empty.
    pub(crate) busy_handler: AtomicPtr<BusySlotState>,

    // Multi-subscriber per-connection hook lists. Each holds N
    // `HookEntry<T>`s, one per registered subscriber. A master closure
    // (or C callback for FFI hooks) is installed exactly once at open
    // time; subscriber-level register/unregister only modifies the
    // HookList. `Arc<HookList>` for the rusqlite-closure hooks because
    // the closure captures a clone — this keeps the list alive across
    // the closure's lifetime independently of XqliteConn's drop order.
    //
    // `wal_hook` carries the subscriber list plus the emulated
    // autocheckpoint threshold (the wal_hook C slot and SQLite's
    // built-in autocheckpoint are mutually exclusive — see WalDispatch).
    // The master callback is re-installed by the `set_pragma` NIF when
    // the `wal_autocheckpoint` PRAGMA steals the slot.
    pub(crate) wal_hook: WalDispatch,
    pub(crate) update_hook: Arc<HookList<UpdateSubscriber>>,
    pub(crate) commit_hook: Arc<HookList<CommitSubscriber>>,
    pub(crate) rollback_hook: Arc<HookList<RollbackSubscriber>>,

    /// Multi-subscriber dispatch on SQLite's single
    /// `sqlite3_progress_handler` slot. Owned directly (no box
    /// indirection); its address is stable for the lifetime of the
    /// resource and is what we register with SQLite at open time.
    /// Holds two `HookList`s — `cancels` (cancellable-query lifetime)
    /// and `ticks` (per-conn, registered via `register_progress_hook`).
    pub(crate) progress_dispatch: ProgressDispatch,
}

#[resource_impl]
impl Resource for XqliteConn {}

impl XqliteConn {
    /// Records a child handle. The caller holds the connection Mutex, which
    /// is also what close takes, so no close can slip between opening the
    /// handle and registering it.
    pub(crate) fn register_child(&self, child: ChildHandle) -> Result<(), XqliteError> {
        let mut children = self
            .children
            .lock()
            .map_err(|e| XqliteError::LockError(e.to_string()))?;
        children.insert(child.key(), child);
        Ok(())
    }

    /// Releases one child handle and forgets it.
    ///
    /// # Safety
    ///
    /// As `ChildHandle::release`: the caller holds this connection's Mutex
    /// for the whole call, or holds it poisoned.
    pub(crate) unsafe fn release_child(&self, child: &ChildHandle) -> Result<(), XqliteError> {
        // SAFETY: forwarded from this function's own contract.
        unsafe { child.release() };
        let mut children = self
            .children
            .lock()
            .map_err(|e| XqliteError::LockError(e.to_string()))?;
        children.remove(&child.key());
        Ok(())
    }

    /// Releases every child handle still registered on this connection.
    ///
    /// # Safety
    ///
    /// As `ChildHandle::release`: the caller holds this connection's Mutex
    /// for the whole call.
    unsafe fn release_children(&self) -> Result<(), XqliteError> {
        let mut children = self
            .children
            .lock()
            .map_err(|e| XqliteError::LockError(e.to_string()))?;
        for (_key, child) in children.drain() {
            // SAFETY: forwarded from this function's own contract.
            unsafe { child.release() };
        }
        Ok(())
    }
}

impl Drop for XqliteConn {
    fn drop(&mut self) {
        // Field declaration order ensures `conn` (the SQLite Connection)
        // drops first, so no callback can fire while we reclaim
        // subscriber state below. Each HookList<T> reclaims its own
        // box via its Drop impl; busy_handler is the only remaining
        // boxed-pointer slot we manage explicitly.
        hook_util::drop_hook(&self.busy_handler);
    }
}

#[derive(Debug)]
pub(crate) struct XqliteQueryResult<'a> {
    pub(crate) columns: Vec<String>,
    pub(crate) rows: Vec<Vec<Term<'a>>>,
    pub(crate) num_rows: usize,
}

/// Encodes the column names as a list of binaries via the graceful
/// `encode_text` (fallible `OwnedBinary`) rather than rustler's `str` encoder,
/// so an allocation failure surfaces as a structured error instead of aborting
/// — consistent with the row-value TEXT path.
fn encode_column_names<'a>(env: Env<'a>, columns: &[String]) -> Result<Term<'a>, XqliteError> {
    let terms = columns
        .iter()
        .map(|name| encode_text(env, name.as_bytes()))
        .collect::<Result<Vec<Term<'a>>, XqliteError>>()?;
    Ok(terms.encode(env))
}

impl Encoder for XqliteQueryResult<'_> {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let map_value_result: Result<Term, String> = encode_column_names(env, &self.columns)
            .map_err(|e| format!("{e:?}"))
            .and_then(|columns| {
                map_new(env)
                    .map_put(atoms::columns(), columns)
                    .map_err(|_| "Failed to insert :columns key".to_string())
            })
            .and_then(|map| {
                map.map_put(atoms::rows(), &self.rows)
                    .map_err(|_| "Failed to insert :rows key".to_string())
            })
            .and_then(|map| {
                map.map_put(atoms::num_rows(), self.num_rows)
                    .map_err(|_| "Failed to insert :num_rows key".to_string())
            });

        match map_value_result {
            Ok(final_map) => final_map,
            Err(context) => {
                let err = XqliteError::InternalEncodingError { context };
                err.encode(env)
            }
        }
    }
}

pub(crate) fn handle_open_result(
    open_result: Result<Connection, RusqliteError>,
    path: String,
) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    match open_result {
        Ok(conn) => {
            let update_hook_list = Arc::new(HookList::new());
            let commit_hook_list = Arc::new(HookList::new());
            let rollback_hook_list = Arc::new(HookList::new());

            let handle = ResourceArc::new(XqliteConn {
                conn: Mutex::new(Some(conn)),
                children: Mutex::new(HashMap::new()),
                extensions_enabled: AtomicBool::new(false),
                busy_handler: AtomicPtr::new(std::ptr::null_mut()),
                wal_hook: WalDispatch::new(),
                update_hook: Arc::clone(&update_hook_list),
                commit_hook: Arc::clone(&commit_hook_list),
                rollback_hook: Arc::clone(&rollback_hook_list),
                progress_dispatch: ProgressDispatch::new(),
            });

            // Install master callbacks for every multi-subscriber hook.
            // Each is registered exactly once for the connection's
            // lifetime; subscriber-level register/unregister never
            // touches SQLite again.
            //
            // SAFETY for the FFI hooks (wal, progress): the WalDispatch
            // / ProgressDispatch references are taken from inside the
            // ResourceArc, so they live as long as `handle`. The conn
            // (and any in-flight callback) drops before subscriber
            // state via field declaration order.
            {
                let conn_guard = handle
                    .conn
                    .lock()
                    .map_err(|e| XqliteError::LockError(e.to_string()))?;
                if let Some(conn_ref) = conn_guard.as_ref() {
                    // SAFETY: the conn Mutex is held here; the wal/progress
                    // dispatch references live inside the same ResourceArc as
                    // `handle`, so they outlive any in-flight callback (see the
                    // field-order note above).
                    unsafe {
                        progress_dispatch::install_callback(
                            conn_ref,
                            &handle.progress_dispatch,
                        );
                        wal_hook::install_callback(conn_ref, &handle.wal_hook);
                    }
                    update_hook::install_callback(conn_ref, update_hook_list)?;
                    commit_hook::install_callback(conn_ref, commit_hook_list)?;
                    rollback_hook::install_callback(conn_ref, rollback_hook_list)?;
                }
            }
            Ok(handle)
        }
        Err(e) => Err(match e {
            RusqliteError::SqliteFailure(ffi_err, msg_opt) => {
                XqliteError::CannotOpenDatabase {
                    path,
                    code: ffi_err.extended_code,
                    message: msg_opt.unwrap_or_else(|| ffi_err.to_string()),
                }
            }
            other_err => XqliteError::CannotOpenDatabase {
                path,
                code: -1,
                message: other_err.to_string(),
            },
        }),
    }
}

pub(crate) fn close_connection(handle: &ResourceArc<XqliteConn>) -> Result<(), XqliteError> {
    let mut conn_guard = handle
        .conn
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;

    match conn_guard.as_ref() {
        // Second close is a no-op: the first one emptied the registry.
        None => Ok(()),
        Some(_) => {
            // SAFETY: the connection Mutex is held for the whole drain, so no
            // other thread is inside a `sqlite3_*` call on this handle, and
            // every registered cell holds null or a handle opened on it.
            unsafe { handle.release_children()? };
            // Dropping the Connection runs `sqlite3_close`, which now finds no
            // statement of ours outstanding and frees the handle.
            conn_guard.take();
            Ok(())
        }
    }
}

#[inline]
pub(crate) fn with_conn<F, R>(
    handle: &ResourceArc<XqliteConn>,
    func: F,
) -> Result<R, XqliteError>
where
    F: FnOnce(&Connection) -> Result<R, XqliteError>,
{
    let conn_guard = handle
        .conn
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    match conn_guard.as_ref() {
        Some(conn) => func(conn),
        None => Err(XqliteError::ConnectionClosed),
    }
}

#[inline]
pub(crate) fn with_conn_mut<F, R>(
    handle: &ResourceArc<XqliteConn>,
    func: F,
) -> Result<R, XqliteError>
where
    F: FnOnce(&mut Connection) -> Result<R, XqliteError>,
{
    let mut conn_guard = handle
        .conn
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    match conn_guard.as_mut() {
        Some(conn) => func(conn),
        None => Err(XqliteError::ConnectionClosed),
    }
}
