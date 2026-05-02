use crate::atoms;
use crate::busy_handler::BusyHandlerState;
use crate::commit_hook::{self, CommitSubscriber};
use crate::error::XqliteError;
use crate::hook_util::{self, HookList};
use crate::progress_dispatch::{self, ProgressDispatch};
use crate::rollback_hook::{self, RollbackSubscriber};
use crate::update_hook::{self, UpdateSubscriber};
use crate::wal_hook::{self, WalSubscriber};
use rusqlite::{Connection, Error as RusqliteError};
use rustler::{Encoder, Env, Resource, ResourceArc, Term, resource_impl, types::map::map_new};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::AtomicPtr;

#[derive(Debug)]
pub(crate) struct XqliteConn {
    pub(crate) conn: Mutex<Option<Connection>>,
    pub(crate) extensions_enabled: AtomicBool,

    // The remaining single-subscriber FFI hook (busy_handler) — its
    // callback returns a policy decision so multi-subscriber
    // composition is ill-defined; see project_busy_handler_observer_split.
    pub(crate) busy_handler: AtomicPtr<BusyHandlerState>,

    // Multi-subscriber per-connection hook lists. Each holds N
    // `HookEntry<T>`s, one per registered subscriber. A master closure
    // (or C callback for FFI hooks) is installed exactly once at open
    // time; subscriber-level register/unregister only modifies the
    // HookList. `Arc<HookList>` for the rusqlite-closure hooks because
    // the closure captures a clone — this keeps the list alive across
    // the closure's lifetime independently of XqliteConn's drop order.
    pub(crate) wal_hook: HookList<WalSubscriber>,
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

impl Encoder for XqliteQueryResult<'_> {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let map_value_result: Result<Term, String> = Ok(map_new(env))
            .and_then(|map| {
                map.map_put(atoms::columns(), &self.columns)
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
                (atoms::error(), err).encode(env)
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
                extensions_enabled: AtomicBool::new(false),
                busy_handler: AtomicPtr::new(std::ptr::null_mut()),
                wal_hook: HookList::new(),
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
            // SAFETY for the FFI hooks (wal, progress): the HookList
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
    // .take() drops the Connection, releasing the SQLite handle immediately.
    // Second close is a no-op — .take() on None returns None.
    conn_guard.take();
    Ok(())
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
