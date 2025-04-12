use crate::atoms::{
    cannot_allocate_binary, cannot_encode, cannot_execute, cannot_fetch_row,
    cannot_open_database, cannot_prepare_statement, connection_not_found, timeout,
    unsupported_value,
};
use dashmap::DashMap;
use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;
use rustler::resource_impl;
use rustler::types::atom::nil;
use rustler::{Encoder, Env, OwnedBinary, Resource, ResourceArc, Term};
use std::panic::RefUnwindSafe;
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
                    None => return XqliteError::CannotAllocateBinary.encode(env),
                };

                owned_binary.as_mut_slice().copy_from_slice(b);
                let binary = owned_binary.release(env);
                binary.encode(env)
            }
        }
    }
}
impl RefUnwindSafe for XqliteVal {}

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
            XqliteError::UnsupportedValue(term) => (unsupported_value(), term).encode(env),
            XqliteError::ConnectionNotFound(conn) => {
                (connection_not_found(), conn).encode(env)
            }
            XqliteError::Timeout(err) => (timeout(), err.to_string()).encode(env),
            XqliteError::CannotPrepareStatement(sql, err) => {
                (cannot_prepare_statement(), sql, err.to_string()).encode(env)
            }
            XqliteError::CannotEncodeValue(index, err) => {
                (cannot_encode(), index, err.to_string()).encode(env)
            }
            XqliteError::CannotExecute(err) => (cannot_execute(), err.to_string()).encode(env),
            XqliteError::CannotFetchRow(err) => {
                (cannot_fetch_row(), err.to_string()).encode(env)
            }
            XqliteError::CannotAllocateBinary => (cannot_allocate_binary()).encode(env),
            XqliteError::CannotOpenDatabase(path, err) => {
                (cannot_open_database(), path, err.to_string()).encode(env)
            }
        }
    }
}

impl RefUnwindSafe for XqliteError<'_> {}

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
fn nif_open<'a>(path: String) -> Result<ResourceArc<XqliteConn>, XqliteError<'a>> {
    create_pool(&path).map_or_else(
        |e| Err(XqliteError::CannotOpenDatabase(path, e)),
        |id| Ok(ResourceArc::new(XqliteConn(id))),
    )
}

#[rustler::nif(schedule = "DirtyIo")]
fn nif_exec<'a>(
    handle: ResourceArc<XqliteConn>,
    sql: String,
) -> Result<Vec<Vec<Result<XqliteVal, XqliteError<'a>>>>, XqliteError<'a>> {
    let pool = match get_pool(handle.0) {
        Some(pool) => pool,
        None => return Err(XqliteError::ConnectionNotFound(*handle)),
    };

    let conn = match pool.get() {
        Ok(conn) => conn,
        Err(e) => return Err(XqliteError::Timeout(e)),
    };

    let mut stmt = match conn.prepare(&sql) {
        Ok(stmt) => stmt,
        Err(e) => return Err(XqliteError::CannotPrepareStatement(sql, e)),
    };

    let column_count = stmt.column_count();
    let mut results: Vec<Vec<Result<XqliteVal, XqliteError>>> = Vec::new();

    let rows = match stmt.query_map([], |row| {
        let mut row_values: Vec<Result<XqliteVal, XqliteError>> =
            Vec::with_capacity(column_count);
        for i in 0..column_count {
            let value: Result<XqliteVal, XqliteError> = match row.get(i) {
                Ok(val) => Ok(XqliteVal(val)),
                Err(e) => Err(XqliteError::CannotEncodeValue(i, e)),
            };
            row_values.push(value);
        }
        Ok(row_values)
    }) {
        Ok(mapped_rows) => mapped_rows,
        Err(err) => return Err(XqliteError::CannotExecute(err)),
    };

    for row_result in rows {
        match row_result {
            Ok(row) => results.push(row),
            Err(e) => return Err(XqliteError::CannotFetchRow(e)),
        }
    }

    Ok(results)
}

#[rustler::nif(schedule = "DirtyIo")]
fn nif_close<'a>(handle: ResourceArc<XqliteConn>) -> Result<(), XqliteError<'a>> {
    if remove_pool(handle.0) {
        Ok(())
    } else {
        Err(XqliteError::ConnectionNotFound(*handle))
    }
}
