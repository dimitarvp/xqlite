use crate::atoms::{
    atom, binary, cannot_convert_atom_to_string, cannot_convert_to_sqlite_value,
    cannot_decode_pool_option, cannot_execute, cannot_execute_pragma, cannot_fetch_row,
    cannot_open_database, cannot_prepare_statement, cannot_read_column, connection_not_found,
    expected_keyword_list, expected_keyword_tuple, float, fun, integer,
    invalid_idle_connection_count, invalid_pool_size, invalid_time_value, list, map, pid,
    port, r#false, r#true, reference, timeout, tuple, unknown, unsupported_atom,
    unsupported_data_type,
};
use dashmap::DashMap;
use r2d2::{ManageConnection, Pool};
use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::{types::Value, ToSql};
use rustler::types::atom::nil;
use rustler::{resource_impl, Atom, Binary, ListIterator, TermType};
use rustler::{Encoder, Env, Error as RustlerError, Resource, ResourceArc, Term};
use std::fmt::{self, Debug, Display};
use std::panic::RefUnwindSafe;
use std::sync::OnceLock;
use std::time::Duration;

type XqlitePool = Pool<SqliteConnectionManager>;
type XqlitePools = DashMap<String, XqlitePool>;

const DEFAULT_MAX_POOL_SIZE: u32 = 10;

#[derive(Debug, Clone)]
pub(crate) struct XqliteConn(String);
#[resource_impl]
impl Resource for XqliteConn {}
impl Encoder for XqliteConn {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        self.0.encode(env)
    }
}

#[derive(Debug)]
struct BlobResource(Vec<u8>);

#[resource_impl]
impl Resource for BlobResource {}

#[derive(Debug, Default)]
struct PoolOptions {
    connection_timeout_ms: Option<u64>,
    idle_timeout_ms: Option<u64>,
    max_lifetime_ms: Option<u64>,
    max_size: Option<u32>,
    min_idle: Option<u32>,
}

fn term_type_to_string(term_type: TermType) -> &'static str {
    match term_type {
        TermType::Atom => "atom",
        TermType::Binary => "binary",
        TermType::Float => "float",
        TermType::Fun => "function",
        TermType::Integer => "integer",
        TermType::List => "list",
        TermType::Map => "map",
        TermType::Pid => "pid",
        TermType::Port => "port",
        TermType::Ref => "reference",
        TermType::Tuple => "tuple",
        TermType::Unknown => "unknown",
    }
}

fn term_type_to_atom(_env: Env, term_type: TermType) -> Atom {
    match term_type {
        TermType::Atom => atom(),
        TermType::Binary => binary(),
        TermType::Float => float(),
        TermType::Fun => fun(),
        TermType::Integer => integer(),
        TermType::List => list(),
        TermType::Map => map(),
        TermType::Pid => pid(),
        TermType::Port => port(),
        TermType::Ref => reference(),
        TermType::Tuple => tuple(),
        TermType::Unknown => unknown(),
    }
}

fn encode_val(env: Env<'_>, val: rusqlite::types::Value) -> Term<'_> {
    match val {
        Value::Null => nil().encode(env),
        Value::Integer(i) => i.encode(env),
        Value::Real(f) => f.encode(env),
        Value::Text(s) => s.encode(env), // Moves `s` ownership
        Value::Blob(owned_vec) => {
            // Moves owned_vec
            let resource = ResourceArc::new(BlobResource(owned_vec));
            // Create a binary term referencing the resource (no copy or clone)
            resource
                .make_binary(env, |wrapper: &BlobResource| &wrapper.0)
                .encode(env)
        }
    }
}

fn ms_to_duration(ms: u64) -> Result<Duration, XqliteError> {
    if ms == 0 {
        Err(XqliteError::InvalidTimeValue(ms))
    } else {
        Ok(Duration::from_millis(ms))
    }
}

#[derive(Debug)]
pub(crate) enum XqliteError {
    CannotConvertToSqliteValue {
        value_str: String,
        reason: String,
    },
    ExpectedKeywordList {
        value_str: String,
    },
    ExpectedKeywordTuple {
        value_str: String,
    },
    UnsupportedAtom {
        atom_value: String,
    },
    UnsupportedDataType {
        term_type: TermType,
    },
    ConnectionNotFound(XqliteConn),
    Timeout(String),
    CannotPrepareStatement(String, String),
    CannotReadColumn(usize, String),
    CannotExecute(String),
    CannotExecutePragma {
        pragma: String,
        reason: String,
    },
    CannotFetchRow(String),
    CannotOpenDatabase(String, String),
    CannotConvertAtomToString(String),
    CannotDecodePoolOption {
        option_name: String,
        value_str: String,
        reason: String,
    },
    InvalidTimeValue(u64),
    InvalidPoolSize(u32),
    InvalidIdleConnectionCount {
        min_idle: u32,
        max_size: u32,
    },
}

impl Display for XqliteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            XqliteError::CannotConvertToSqliteValue { value_str, reason } => write!(
                f,
                "Cannot convert value '{}' to SQLite type: {}",
                value_str, reason
            ),
            XqliteError::ExpectedKeywordList { value_str } => {
                write!(f, "Expected a keyword list, got: {}", value_str)
            }
            XqliteError::ExpectedKeywordTuple { value_str } => {
                write!(f, "Expected a {{atom, value}} tuple, got: {}", value_str)
            }
            XqliteError::UnsupportedAtom { atom_value } => write!(
                f,
                "Unsupported atom value '{}'. Allowed values: nil, true, false",
                atom_value
            ),
            XqliteError::UnsupportedDataType { term_type } => write!(
                f,
                "Unsupported data type {}. Allowed types: atom, integer, float, binary",
                term_type_to_string(*term_type)
            ),
            XqliteError::ConnectionNotFound(conn) => {
                write!(f, "Connection pool not found for path: '{}'", conn.0)
            }
            XqliteError::Timeout(reason) => {
                write!(f, "Timeout getting connection: {}", reason)
            }
            XqliteError::CannotPrepareStatement(sql, reason) => {
                write!(f, "Cannot prepare statement '{}': {}", sql, reason)
            }
            XqliteError::CannotReadColumn(index, reason) => {
                write!(f, "Cannot read column value at index {}: {}", index, reason)
            }
            XqliteError::CannotExecute(reason) => {
                write!(f, "Cannot execute query: {}", reason)
            }
            XqliteError::CannotExecutePragma { pragma, reason } => {
                write!(f, "Cannot execute PRAGMA '{}': {}", pragma, reason)
            }
            XqliteError::CannotFetchRow(reason) => write!(f, "Cannot fetch row: {}", reason),
            XqliteError::CannotOpenDatabase(path, reason) => {
                write!(f, "Cannot open database '{}': {}", path, reason)
            }
            XqliteError::CannotConvertAtomToString(reason) => {
                write!(f, "Cannot convert Elixir atom to string: {}", reason)
            }
            XqliteError::CannotDecodePoolOption {
                option_name,
                value_str,
                reason,
            } => write!(
                f,
                "Cannot decode value '{}' for pool option '{}': {}",
                value_str, option_name, reason
            ),
            XqliteError::InvalidTimeValue(value) => write!(
                f,
                "Invalid time value '{}ms'. Timeouts and lifetimes must be greater than zero.",
                value
            ),
            XqliteError::InvalidPoolSize(value) => write!(
                f,
                "Invalid pool size '{}'. Pool size must be greater than zero.",
                value
            ),
            XqliteError::InvalidIdleConnectionCount { min_idle, max_size } => write!(
                f,
                "Invalid configuration: min_idle ({}) cannot be greater than max_size ({}).",
                min_idle, max_size
            ),
        }
    }
}

impl Encoder for XqliteError {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            XqliteError::CannotConvertToSqliteValue { value_str, reason } => {
                (cannot_convert_to_sqlite_value(), value_str, reason).encode(env)
            }
            XqliteError::ExpectedKeywordList { value_str } => {
                (expected_keyword_list(), value_str).encode(env)
            }
            XqliteError::ExpectedKeywordTuple { value_str } => {
                (expected_keyword_tuple(), value_str).encode(env)
            }
            XqliteError::UnsupportedAtom { atom_value: _ } => unsupported_atom().encode(env),
            XqliteError::UnsupportedDataType { term_type } => {
                (unsupported_data_type(), term_type_to_atom(env, *term_type)).encode(env)
            }
            XqliteError::ConnectionNotFound(conn) => {
                (connection_not_found(), conn.0.clone()).encode(env)
            }
            XqliteError::Timeout(reason) => (timeout(), reason).encode(env),
            XqliteError::CannotPrepareStatement(sql, reason) => {
                (cannot_prepare_statement(), sql, reason).encode(env)
            }
            XqliteError::CannotReadColumn(index, reason) => {
                (cannot_read_column(), index, reason).encode(env)
            }
            XqliteError::CannotExecute(reason) => (cannot_execute(), reason).encode(env),
            XqliteError::CannotExecutePragma { pragma, reason } => {
                (cannot_execute_pragma(), pragma, reason).encode(env)
            }
            XqliteError::CannotFetchRow(reason) => (cannot_fetch_row(), reason).encode(env),
            XqliteError::CannotOpenDatabase(path, reason) => {
                (cannot_open_database(), path, reason).encode(env)
            }
            XqliteError::CannotConvertAtomToString(reason) => {
                (cannot_convert_atom_to_string(), reason).encode(env)
            }
            XqliteError::CannotDecodePoolOption {
                option_name,
                value_str,
                reason,
            } => (cannot_decode_pool_option(), option_name, value_str, reason).encode(env),
            XqliteError::InvalidTimeValue(value) => (invalid_time_value(), value).encode(env),
            XqliteError::InvalidPoolSize(value) => (invalid_pool_size(), value).encode(env),
            XqliteError::InvalidIdleConnectionCount { min_idle, max_size } => {
                (invalid_idle_connection_count(), *min_idle, *max_size).encode(env)
            }
        }
    }
}

impl RefUnwindSafe for XqliteError {}

impl From<r2d2::Error> for XqliteError {
    fn from(err: r2d2::Error) -> Self {
        XqliteError::Timeout(err.to_string())
    }
}

impl From<rusqlite::Error> for XqliteError {
    fn from(err: rusqlite::Error) -> Self {
        XqliteError::CannotExecute(err.to_string())
    }
}

fn elixir_term_to_rusqlite_value<'a>(
    env: Env<'a>,
    term: Term<'a>,
) -> Result<Value, XqliteError> {
    let make_convert_error = |term: Term<'a>, err: RustlerError| -> XqliteError {
        XqliteError::CannotConvertToSqliteValue {
            value_str: format!("{:?}", term),
            reason: format!("{:?}", err),
        }
    };

    let term_type = term.get_type();
    match term_type {
        TermType::Atom => {
            if term == nil().to_term(env) {
                Ok(Value::Null)
            } else if term == r#true().to_term(env) {
                Ok(Value::Integer(1))
            } else if term == r#false().to_term(env) {
                Ok(Value::Integer(0))
            } else {
                Err(XqliteError::UnsupportedAtom {
                    atom_value: term
                        .atom_to_string()
                        .unwrap_or_else(|_| format!("{:?}", term)),
                })
            }
        }
        TermType::Integer => term
            .decode::<i64>()
            .map(Value::Integer)
            .map_err(|e| make_convert_error(term, e)),
        TermType::Float => term
            .decode::<f64>()
            .map(Value::Real)
            .map_err(|e| make_convert_error(term, e)),
        TermType::Binary => match term.decode::<String>() {
            Ok(s) => Ok(Value::Text(s)),
            Err(_string_decode_err) => match term.decode::<Binary>() {
                Ok(bin) => Ok(Value::Blob(bin.as_slice().to_vec())),
                Err(binary_decode_err) => Err(make_convert_error(term, binary_decode_err)),
            },
        },
        _ => Err(XqliteError::UnsupportedDataType { term_type }),
    }
}

fn decode_exec_keyword_params<'a>(
    env: Env<'a>,
    list_term: Term<'a>,
) -> Result<Vec<(String, Value)>, XqliteError> {
    let iter: ListIterator<'a> =
        list_term
            .decode()
            .map_err(|_| XqliteError::ExpectedKeywordList {
                value_str: format!("{:?}", list_term),
            })?;

    let mut params: Vec<(String, Value)> = Vec::new();

    for term_item in iter {
        let (key_atom, value_term): (Atom, Term<'a>) =
            term_item
                .decode()
                .map_err(|_| XqliteError::ExpectedKeywordTuple {
                    value_str: format!("{:?}", term_item),
                })?;

        let mut key_string: String = key_atom
            .to_term(env)
            .atom_to_string()
            .map_err(|e| XqliteError::CannotConvertAtomToString(format!("{:?}", e)))?;
        key_string.insert(0, ':'); // Prepend ':' for SQLite named parameters

        let rusqlite_value = elixir_term_to_rusqlite_value(env, value_term)?;

        params.push((key_string, rusqlite_value));
    }
    Ok(params)
}

fn decode_pool_options<'a>(
    env: Env<'a>,
    list_term: Term<'a>,
) -> Result<PoolOptions, XqliteError> {
    let iter: ListIterator<'a> =
        list_term
            .decode()
            .map_err(|_| XqliteError::ExpectedKeywordList {
                value_str: format!("{:?}", list_term),
            })?;

    let mut options = PoolOptions::default();

    for term_item in iter {
        let (key_atom, value_term): (Atom, Term<'a>) =
            term_item
                .decode()
                .map_err(|_| XqliteError::ExpectedKeywordTuple {
                    value_str: format!("{:?}", term_item),
                })?;
        let key_str = key_atom
            .to_term(env)
            .atom_to_string()
            .map_err(|e| XqliteError::CannotConvertAtomToString(format!("{:?}", e)))?;

        // Helper closure for decoding errors
        let make_option_decode_error =
            |opt_name: &str, term: Term<'a>, err: RustlerError| -> XqliteError {
                XqliteError::CannotDecodePoolOption {
                    option_name: opt_name.to_string(),
                    value_str: format!("{:?}", term),
                    reason: format!("{:?}", err),
                }
            };

        match key_str.as_str() {
            "connection_timeout" => {
                let val = value_term
                    .decode::<u64>()
                    .map_err(|e| make_option_decode_error(&key_str, value_term, e))?;
                options.connection_timeout_ms = Some(val);
            }
            "idle_timeout" => {
                let val = value_term
                    .decode::<u64>()
                    .map_err(|e| make_option_decode_error(&key_str, value_term, e))?;
                options.idle_timeout_ms = Some(val);
            }
            "max_lifetime" => {
                let val = value_term
                    .decode::<u64>()
                    .map_err(|e| make_option_decode_error(&key_str, value_term, e))?;
                options.max_lifetime_ms = Some(val);
            }
            "max_size" => {
                let val = value_term
                    .decode::<u32>()
                    .map_err(|e| make_option_decode_error(&key_str, value_term, e))?;
                if val == 0 {
                    return Err(XqliteError::InvalidPoolSize(val));
                }
                options.max_size = Some(val);
            }
            "min_idle" => {
                let val = value_term
                    .decode::<u32>()
                    .map_err(|e| make_option_decode_error(&key_str, value_term, e))?;
                options.min_idle = Some(val);
            }
            // Ignore unknown keys
            _ => {}
        }
    }

    if let Some(min_idle) = options.min_idle {
        let max_size = options.max_size.unwrap_or(DEFAULT_MAX_POOL_SIZE);
        if min_idle > max_size {
            return Err(XqliteError::InvalidIdleConnectionCount { min_idle, max_size });
        }
    }

    Ok(options)
}

static POOLS: OnceLock<XqlitePools> = OnceLock::new();

fn pools() -> &'static XqlitePools {
    POOLS.get_or_init(|| DashMap::<String, XqlitePool>::with_capacity(16))
}

fn get_pool(path: &str) -> Option<XqlitePool> {
    pools().get(path).map(|x| x.value().clone())
}

fn remove_pool(path: &str) -> bool {
    pools().remove(path).is_some()
}

fn xqlite_open(
    path: String,
    options: PoolOptions,
) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    // Use DashMap's entry API for atomic get-or-insert logic.
    // Clones the path string once here to use as the map key if insertion happens.
    let entry = pools().entry(path.clone());

    // Attempt to insert a new pool only if the entry is vacant.
    // Meaning that the closure runs only if `path` is not already a key.
    entry.or_try_insert_with(|| {
        // Clone path again only for error reporting within this closure scope.
        let path_for_error = path.clone();
        let manager = SqliteConnectionManager::file(&path);

        // 1. Direct connection check *before* building the pool.
        match manager.connect() {
            Ok(_conn) => {
                // Initial connection succeeded. Drop the connection (`_conn`).
                // Now, it's safe to build the actual pool for the map.

                // Apply pool options
                let mut builder = Pool::builder();
                if let Some(ms) = options.connection_timeout_ms {
                    builder = builder.connection_timeout(ms_to_duration(ms)?);
                }
                if let Some(ms) = options.idle_timeout_ms {
                    builder = builder.idle_timeout(Some(ms_to_duration(ms)?));
                }
                if let Some(ms) = options.max_lifetime_ms {
                    builder = builder.max_lifetime(Some(ms_to_duration(ms)?));
                }
                if let Some(size) = options.max_size {
                    builder = builder.max_size(size);
                }
                if let Some(min) = options.min_idle {
                    builder = builder.min_idle(Some(min));
                }

                builder.build(manager).map_err(|e| {
                    XqliteError::CannotOpenDatabase(path_for_error, e.to_string())
                })
            }
            Err(e) => {
                // The direct manager.connect() failed. Return the error immediately
                Err(XqliteError::CannotOpenDatabase(
                    path_for_error,
                    e.to_string(),
                ))
            }
        }
    })?; // Propagate any error returned from the closure (connection or pool build error).

    // If we reach here, the entry exists (was already present or was successfully inserted).
    // The `entry` variable holds a reference to the occupied entry.

    // Create the resource handle containing the path string.
    // The original `path` String is moved into the handle here.
    let conn_handle = XqliteConn(path);
    let resource = ResourceArc::new(conn_handle);

    Ok(resource)
}

fn xqlite_exec<'a>(
    env: Env<'a>,
    handle: &XqliteConn,
    sql: &str,
    params_term: Term<'a>,
) -> Result<Vec<Vec<Term<'a>>>, XqliteError> {
    let pool = get_pool(&handle.0).ok_or(XqliteError::ConnectionNotFound(handle.clone()))?;
    let conn = pool.get()?;
    let named_params_vec = decode_exec_keyword_params(env, params_term)?;

    let sql_string = sql.to_string();
    let mut stmt = conn
        .prepare(sql)
        .map_err(|e| XqliteError::CannotPrepareStatement(sql_string, e.to_string()))?;

    let column_count = stmt.column_count();

    let params_for_rusqlite: Vec<(&str, &dyn ToSql)> = named_params_vec
        .iter()
        .map(|(k, v)| (k.as_str(), v as &dyn ToSql))
        .collect();

    let mut rows = stmt.query(params_for_rusqlite.as_slice())?;

    let mut results: Vec<Vec<Term<'a>>> = Vec::new();

    while let Some(row) = rows
        .next()
        .map_err(|e| XqliteError::CannotFetchRow(e.to_string()))?
    {
        let mut row_values: Vec<Term<'a>> = Vec::with_capacity(column_count);
        for i in 0..column_count {
            let value: Value = row
                .get::<usize, Value>(i)
                .map_err(|e| XqliteError::CannotReadColumn(i, e.to_string()))?;

            let term = encode_val(env, value);
            row_values.push(term);
        }
        results.push(row_values);
    }

    Ok(results)
}

fn xqlite_pragma_write(handle: &XqliteConn, pragma_sql: &str) -> Result<usize, XqliteError> {
    let pool = get_pool(&handle.0).ok_or(XqliteError::ConnectionNotFound(handle.clone()))?;
    let conn = pool.get()?;

    conn.execute(pragma_sql, [])
        .map_err(|e| XqliteError::CannotExecutePragma {
            pragma: pragma_sql.to_string(),
            reason: e.to_string(),
        })
}

fn xqlite_close(handle: &XqliteConn) -> Result<(), XqliteError> {
    if remove_pool(&handle.0) {
        Ok(())
    } else {
        Err(XqliteError::ConnectionNotFound(handle.clone()))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_open<'a>(
    env: Env<'a>,
    path: String,
    options_term: Term<'a>,
) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let options = decode_pool_options(env, options_term)?;
    xqlite_open(path, options)
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_exec<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: String,
    params_term: Term<'a>,
) -> Result<Vec<Vec<Term<'a>>>, XqliteError> {
    xqlite_exec(env, &handle, &sql, params_term)
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_pragma_write(
    handle: ResourceArc<XqliteConn>,
    pragma_sql: String,
) -> Result<usize, XqliteError> {
    xqlite_pragma_write(&handle, &pragma_sql)
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_close(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    xqlite_close(&handle).map(|_| true)
}
