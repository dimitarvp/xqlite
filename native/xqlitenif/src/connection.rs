use crate::error::XqliteError;
use rusqlite::{Connection, Error as RusqliteError};
use rustler::{Encoder, Env, Resource, ResourceArc, Term, resource_impl, types::map::map_new};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::atoms;

#[derive(Debug)]
pub(crate) struct XqliteConn {
    pub(crate) conn: Mutex<Connection>,
    pub(crate) closed: AtomicBool,
}

#[resource_impl]
impl Resource for XqliteConn {}

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
            conn: Mutex::new(conn),
            closed: AtomicBool::new(false),
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
    handle.closed.store(true, Ordering::Release);
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
    if handle.closed.load(Ordering::Acquire) {
        return Err(XqliteError::ConnectionClosed);
    }
    func(&conn_guard)
}
