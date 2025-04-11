use crate::atoms::{
    cannot_allocate_binary, cannot_encode, cannot_execute, cannot_fetch_row,
    cannot_open_database, cannot_prepare_statement, connection_not_found, timeout,
    unsupported_value,
};
use dashmap::DashMap;
use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;
use rustler::types::atom::{error, nil, ok};
use rustler::{Encoder, Env, OwnedBinary, Resource, ResourceArc, Term};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

type XqlitePool = Pool<SqliteConnectionManager>;
type XqlitePools = DashMap<u64, XqlitePool>;

#[derive(Debug)]
pub(crate) struct XqliteConn(u64);
#[resource_impl]
impl Resource for XqliteConn {}
impl Copy for XqliteConn {}
impl Clone for XqliteConn {
    fn clone(&self) -> Self {
        *self
    }
}
impl Encoder for XqliteConn {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        self.0.encode(env)
    }
}

#[derive(Debug)]
pub(crate) struct XqliteVal(rusqlite::types::Value);
impl Encoder for XqliteVal {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match &self.0 {
            rusqlite::types::Value::Null => nil().encode(env),
            rusqlite::types::Value::Integer(i) => i.encode(env),
            rusqlite::types::Value::Real(f) => f.encode(env),
            rusqlite::types::Value::Text(s) => s.encode(env),
            rusqlite::types::Value::Blob(b) => {
                let mut owned_binary = match OwnedBinary::new(b.len()) {
                    Some(owned_binary) => owned_binary,
                    None => {
                        return XqliteResult::<XqliteError>::Err(
                            XqliteError::CannotAllocateBinary,
                        )
                        .encode(env)
                    }
                };

                owned_binary.as_mut_slice().copy_from_slice(b);
                let binary = owned_binary.release(env);
                binary.encode(env)
            }
        }
    }
}

#[derive(Debug)]
enum XqliteError<'a> {
    UnsupportedValue(Term<'a>),
    ConnectionNotFound(XqliteConn),
    Timeout(r2d2::Error),
    CannotPrepareStatement(String, rusqlite::Error),
    CannotEncodeValue(usize, rusqlite::Error),
    CannotExecute(rusqlite::Error),
    CannotFetchRow(rusqlite::Error),
    CannotAllocateBinary,
    CannotOpenDatabase(String, r2d2::Error),
}

impl Encoder for XqliteError<'_> {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            XqliteError::UnsupportedValue(term) => {
                (error(), unsupported_value(), term).encode(env)
            }
            XqliteError::ConnectionNotFound(conn) => {
                (error(), connection_not_found(), conn).encode(env)
            }
            XqliteError::Timeout(err) => (error(), timeout(), err.to_string()).encode(env),
            XqliteError::CannotPrepareStatement(sql, err) => {
                (error(), cannot_prepare_statement(), sql, err.to_string()).encode(env)
            }
            XqliteError::CannotEncodeValue(index, err) => {
                (error(), cannot_encode(), index, err.to_string()).encode(env)
            }
            XqliteError::CannotExecute(err) => {
                (error(), cannot_execute(), err.to_string()).encode(env)
            }
            XqliteError::CannotFetchRow(err) => {
                (error(), cannot_fetch_row(), err.to_string()).encode(env)
            }
            XqliteError::CannotAllocateBinary => {
                (error(), cannot_allocate_binary()).encode(env)
            }
            XqliteError::CannotOpenDatabase(path, err) => {
                (error(), cannot_open_database(), path, err.to_string()).encode(env)
            }
        }
    }
}

#[derive(Debug)]
enum XqliteOk<T> {
    WithValue(T),
    WithoutValue,
}

impl<T> Encoder for XqliteOk<T>
where
    T: Encoder,
{
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            XqliteOk::WithValue(value) => (ok(), value).encode(env),
            XqliteOk::WithoutValue => (ok()).encode(env),
        }
    }
}

#[derive(Debug)]
enum XqliteResult<'a, T> {
    Ok(XqliteOk<T>),
    Err(XqliteError<'a>),
}

impl<T> Encoder for XqliteResult<'_, T>
where
    T: Encoder,
{
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        match self {
            XqliteResult::Ok(ok) => ok.encode(env),
            XqliteResult::Err(err) => err.encode(env),
        }
    }
}

// Initialize only once: global map of SQLite connection pools.
static POOLS: OnceLock<XqlitePools> = OnceLock::new();

// Initialize only once: an atomic counter for a non-locking monotonically increasing value.
// This will be the "handle" to an SQLite connection that we return to the Elixir code.
// It's also the key in the global SQLite connection map.
static NEXT_ID: AtomicU64 = AtomicU64::new(0);

fn pools() -> &'static XqlitePools {
    POOLS.get_or_init(|| DashMap::<u64, XqlitePool>::with_capacity(16))
}

fn create_pool(path: &str) -> Result<u64, r2d2::Error> {
    let manager = SqliteConnectionManager::file(path);
    let pool = Pool::new(manager)?;
    let id = NEXT_ID.fetch_add(1, Ordering::SeqCst);
    pools().insert(id, pool);
    Ok(id)
}

fn get_pool(id: u64) -> Option<XqlitePool> {
    // This could theoretically deadlock but we never hold onto mutable references to the map.
    pools().get(&id).map(|x| x.value().clone())
}

fn remove_pool(id: u64) -> bool {
    pools().remove(&id).is_some()
}

#[rustler::nif(schedule = "DirtyIo")]
fn nif_open(env: Env, path: String) -> Term {
    create_pool(&path).map_or_else(
        |e| {
            XqliteResult::<XqliteError>::Err(XqliteError::CannotOpenDatabase(path, e))
                .encode(env)
        },
        |id| {
            XqliteResult::Ok(XqliteOk::WithValue(ResourceArc::new(XqliteConn(id)))).encode(env)
        },
    )
}

#[rustler::nif(schedule = "DirtyIo")]
fn nif_exec(env: Env, handle: ResourceArc<XqliteConn>, sql: String) -> Term {
    let pool = match get_pool(handle.0) {
        Some(pool) => pool,
        None => {
            return XqliteResult::<XqliteError>::Err(XqliteError::ConnectionNotFound(*handle))
                .encode(env)
        }
    };

    let conn = match pool.get() {
        Ok(conn) => conn,
        Err(e) => {
            return XqliteResult::<XqliteError>::Err(XqliteError::Timeout(e)).encode(env)
        }
    };

    let mut stmt = match conn.prepare(&sql) {
        Ok(stmt) => stmt,
        Err(e) => {
            return XqliteResult::<XqliteError>::Err(XqliteError::CannotPrepareStatement(
                sql, e,
            ))
            .encode(env)
        }
    };

    let column_count = stmt.column_count();
    let mut results: Vec<Vec<XqliteResult<XqliteVal>>> = Vec::new();

    let rows = match stmt.query_map([], |row| {
        let mut row_values: Vec<XqliteResult<XqliteVal>> = Vec::with_capacity(column_count);
        for i in 0..column_count {
            let value: XqliteResult<XqliteVal> = match row.get(i) {
                Ok(val) => XqliteResult::Ok(XqliteOk::WithValue(XqliteVal(val))),
                Err(e) => XqliteResult::Err(XqliteError::CannotEncodeValue(i, e)),
            };
            row_values.push(value);
        }
        Ok(row_values)
    }) {
        Ok(mapped_rows) => mapped_rows,
        Err(err) => {
            return XqliteResult::<XqliteError>::Err(XqliteError::CannotExecute(err))
                .encode(env)
        }
    };

    for row_result in rows {
        match row_result {
            Ok(row) => results.push(row),
            Err(e) => {
                return XqliteResult::<XqliteError>::Err(XqliteError::CannotFetchRow(e))
                    .encode(env)
            }
        }
    }

    XqliteResult::Ok(XqliteOk::WithValue(results)).encode(env)
}

#[rustler::nif(schedule = "DirtyIo")]
fn nif_close(env: Env, handle: ResourceArc<XqliteConn>) -> Term {
    if remove_pool(handle.0) {
        return XqliteResult::<XqliteOk<XqliteConn>>::Ok(XqliteOk::WithoutValue).encode(env);
    } else {
        return XqliteResult::<XqliteError>::Err(XqliteError::ConnectionNotFound(*handle))
            .encode(env);
    }
}
