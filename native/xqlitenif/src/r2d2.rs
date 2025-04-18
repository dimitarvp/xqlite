use crate::atoms::{
    atom, binary, cannot_convert_atom_to_string, cannot_convert_to_sqlite_value,
    cannot_execute, cannot_execute_pragma, cannot_fetch_row, cannot_open_database,
    cannot_prepare_statement, cannot_read_column, connection_not_found, expected_keyword_list,
    expected_keyword_tuple, float, fun, integer, list, map, pid, port, r#false, r#true,
    reference, timeout, tuple, unknown, unsupported_atom, unsupported_data_type,
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
struct BlobResource(Vec<u8>);

#[resource_impl]
impl Resource for BlobResource {}

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
    // Takes ownership of val
    match val {
        Value::Null => nil().encode(env),
        Value::Integer(i) => i.encode(env),
        Value::Real(f) => f.encode(env),
        Value::Text(s) => s.encode(env), // Moves s
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

#[derive(Debug)]
pub(crate) enum XqliteError {
    CannotConvertToSqliteValue { value_str: String, reason: String },
    ExpectedKeywordList { value_str: String },
    ExpectedKeywordTuple { value_str: String },
    UnsupportedAtom { atom_value: String },
    UnsupportedDataType { term_type: TermType },
    ConnectionNotFound(XqliteConn),
    Timeout(String),
    CannotPrepareStatement(String, String),
    CannotReadColumn(usize, String),
    CannotExecute(String),
    CannotExecutePragma { pragma: String, reason: String },
    CannotFetchRow(String),
    CannotOpenDatabase(String, String),
    CannotConvertAtomToString(String),
}

impl Display for XqliteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            XqliteError::CannotConvertToSqliteValue { value_str, reason } => {
                write!(
                    f,
                    "Cannot convert value '{}' to SQLite type: {}",
                    value_str, reason
                )
            }
            XqliteError::ExpectedKeywordList { value_str } => {
                write!(f, "Expected a keyword list, got: {}", value_str)
            }
            XqliteError::ExpectedKeywordTuple { value_str } => {
                write!(f, "Expected a {{atom, value}} tuple, got: {}", value_str)
            }
            XqliteError::UnsupportedAtom { atom_value } => {
                write!(
                    f,
                    "Unsupported atom value '{}'. Allowed values: nil, true, false",
                    atom_value
                )
            }
            XqliteError::UnsupportedDataType { term_type } => {
                write!(
                    f,
                    "Unsupported data type {}. Allowed types: atom, integer, float, binary",
                    term_type_to_string(*term_type)
                )
            }
            XqliteError::ConnectionNotFound(conn) => {
                write!(f, "Connection not found: {:?}", conn)
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
                (connection_not_found(), conn).encode(env)
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

fn decode_keyword_params<'a>(
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

static POOLS: OnceLock<XqlitePools> = OnceLock::new();
static NEXT_ID: AtomicU64 = AtomicU64::new(0);

fn pools() -> &'static XqlitePools {
    POOLS.get_or_init(|| DashMap::<u64, XqlitePool>::with_capacity(16))
}

fn get_pool(id: u64) -> Option<XqlitePool> {
    pools().get(&id).map(|x| x.value().clone())
}

fn remove_pool(id: u64) -> bool {
    pools().remove(&id).is_some()
}

fn xqlite_open(path: &str) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let path_clone = path.to_string();

    // 1. Create the connection manager
    let manager = SqliteConnectionManager::file(path);

    // 2. Attempt a direct connection using the manager to validate path/permissions immediately.
    //    This bypasses r2d2's pool logic for the initial check.
    match manager.connect() {
        Ok(_conn) => {
            // Initial connection succeeded. Drop `_conn` before the block finishes.
            // Now, it's safe to build the actual pool.
            let pool = Pool::builder()
                .build(manager)
                // Pool building itself can fail for config reasons
                .map_err(|e| XqliteError::CannotOpenDatabase(path_clone, e.to_string()))?;

            let id = NEXT_ID.fetch_add(1, Ordering::SeqCst);
            pools().insert(id, pool);
            let conn_handle = XqliteConn(id);
            let resource = ResourceArc::new(conn_handle);
            Ok(resource)
        }
        Err(e) => {
            // The direct manager.connect() failed. This is the fast failure.
            // Map the rusqlite::Error (contained within r2d2::Error::ConnectionError)
            // or other r2d2::Error directly.
            Err(XqliteError::CannotOpenDatabase(path_clone, e.to_string()))
        }
    }
}

fn xqlite_exec<'a>(
    env: Env<'a>,
    handle: &XqliteConn,
    sql: &str,
    params_term: Term<'a>,
) -> Result<Vec<Vec<Term<'a>>>, XqliteError> {
    let pool = get_pool(handle.0).ok_or(XqliteError::ConnectionNotFound(*handle))?;
    let conn = pool.get()?;
    let named_params_vec = decode_keyword_params(env, params_term)?;

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

    // Outer Vec now holds Vec<Term<'a>>>
    let mut results: Vec<Vec<Term<'a>>> = Vec::new();

    while let Some(row) = rows
        .next()
        .map_err(|e| XqliteError::CannotFetchRow(e.to_string()))?
    {
        // Inner Vec now holds Term<'a>
        let mut row_values: Vec<Term<'a>> = Vec::with_capacity(column_count);
        for i in 0..column_count {
            // Get owned `Value`
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
    let pool = get_pool(handle.0).ok_or(XqliteError::ConnectionNotFound(*handle))?;
    let conn = pool.get()?;

    conn.execute(pragma_sql, [])
        .map_err(|e| XqliteError::CannotExecutePragma {
            pragma: pragma_sql.to_string(),
            reason: e.to_string(),
        })
}

fn xqlite_close(handle: &XqliteConn) -> Result<(), XqliteError> {
    if remove_pool(handle.0) {
        Ok(())
    } else {
        Err(XqliteError::ConnectionNotFound(*handle))
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_open(path: String) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    xqlite_open(&path)
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
