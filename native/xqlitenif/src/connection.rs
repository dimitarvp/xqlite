use crate::atoms;
use crate::busy_handler::BusyHandlerState;
use crate::error::XqliteError;
use crate::hook_util;
use crate::wal_hook::WalHookState;
use rusqlite::{Connection, Error as RusqliteError};
use rustler::{Encoder, Env, Resource, ResourceArc, Term, resource_impl, types::map::map_new};
use std::sync::Mutex;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::AtomicPtr;

#[derive(Debug)]
pub(crate) struct XqliteConn {
    pub(crate) conn: Mutex<Option<Connection>>,
    pub(crate) extensions_enabled: AtomicBool,
    // Leaked `Box<*HookState>` pointers for the hooks that need FFI
    // state management (the rusqlite-closure-accepting hooks —
    // commit/rollback/update — do their own internal box management
    // and don't live here). `install` / `uninstall` in each module
    // manage the lifecycle; the `Drop` impl below reclaims stragglers
    // when the connection resource is GC'd.
    pub(crate) busy_handler: AtomicPtr<BusyHandlerState>,
    pub(crate) wal_hook: AtomicPtr<WalHookState>,
}

#[resource_impl]
impl Resource for XqliteConn {}

impl Drop for XqliteConn {
    fn drop(&mut self) {
        hook_util::drop_hook(&self.busy_handler);
        hook_util::drop_hook(&self.wal_hook);
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
        Ok(conn) => Ok(ResourceArc::new(XqliteConn {
            conn: Mutex::new(Some(conn)),
            extensions_enabled: AtomicBool::new(false),
            busy_handler: AtomicPtr::new(std::ptr::null_mut()),
            wal_hook: AtomicPtr::new(std::ptr::null_mut()),
        })),
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
