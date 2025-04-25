rustler::atoms! {
    atom,
    binary,
    cannot_convert_atom_to_string,
    cannot_convert_to_sqlite_value,
    cannot_execute,
    cannot_execute_pragma,
    cannot_fetch_row,
    cannot_open_database,
    cannot_prepare_statement,
    cannot_read_column,
    columns,
    error,
    expected_keyword_list,
    expected_keyword_tuple,
    expected_list,
    float,
    function,
    integer,
    internal_encoding_error,
    list,
    lock_error,
    map,
    no_value,
    num_rows,
    ok,
    pid,
    port,
    reference,
    rows,
    tuple,
    unknown,
    unsupported_atom,
    unsupported_data_type,
}

use rusqlite::{types::Value, Connection, Row, Rows, ToSql};
use rustler::types::atom::{false_, nil, true_};
use rustler::types::map::map_new;
use rustler::{resource_impl, Atom, Binary, ListIterator, TermType};
use rustler::{Encoder, Env, Error as RustlerError, Resource, ResourceArc, Term};
use std::fmt::{self, Debug, Display};
use std::panic::RefUnwindSafe;
use std::sync::{Arc, Mutex};

#[derive(Debug)]
pub(crate) struct XqliteConn(Arc<Mutex<Connection>>);
#[resource_impl]
impl Resource for XqliteConn {}

#[derive(Debug)]
struct XqliteQueryResult<'a> {
    columns: Vec<String>,
    rows: Vec<Vec<Term<'a>>>,
    num_rows: usize,
}

impl Encoder for XqliteQueryResult<'_> {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let map_value_result: Result<Term, String> = Ok(map_new(env))
            .and_then(|map| {
                map.map_put(columns(), self.columns.encode(env))
                    .map_err(|_| "Failed to insert :columns key".to_string())
            })
            .and_then(|map| {
                map.map_put(rows(), self.rows.encode(env))
                    .map_err(|_| "Failed to insert :rows key".to_string())
            })
            .and_then(|map| {
                map.map_put(num_rows(), self.num_rows.encode(env))
                    .map_err(|_| "Failed to insert :num_rows key".to_string())
            });

        match map_value_result {
            Ok(final_map) => final_map,
            Err(context) => {
                let err = XqliteError::InternalEncodingError { context };
                (error(), err).encode(env)
            }
        }
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
        TermType::Fun => function(),
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
        Value::Text(s) => s.encode(env),
        Value::Blob(owned_vec) => {
            let resource = ResourceArc::new(BlobResource(owned_vec));
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
    ExpectedList { value_str: String },
    UnsupportedAtom { atom_value: String },
    UnsupportedDataType { term_type: TermType },
    CannotPrepareStatement(String, String),
    CannotReadColumn(usize, String),
    CannotExecute(String),
    CannotExecutePragma { pragma: String, reason: String },
    CannotFetchRow(String),
    CannotOpenDatabase(String, String),
    CannotConvertAtomToString(String),
    LockError(String),
    InternalEncodingError { context: String }, // For failures during Term encoding
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
            XqliteError::ExpectedKeywordTuple { value_str } => write!(
                f,
                "Expected a {{atom, value}} tuple inside keyword list, got: {}",
                value_str
            ),
            XqliteError::ExpectedList { value_str } => {
                write!(f, "Expected a list, got: {}", value_str)
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
            XqliteError::LockError(reason) => {
                write!(f, "Failed to lock connection mutex: {}", reason)
            }
            XqliteError::InternalEncodingError { context } => {
                write!(f, "Internal error during result encoding: {}", context)
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
            XqliteError::ExpectedList { value_str } => {
                (expected_list(), value_str).encode(env)
            }
            XqliteError::UnsupportedAtom { atom_value: _ } => unsupported_atom().encode(env),
            XqliteError::UnsupportedDataType { term_type } => {
                (unsupported_data_type(), term_type_to_atom(env, *term_type)).encode(env)
            }
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
            XqliteError::LockError(reason) => (lock_error(), reason).encode(env),
            XqliteError::InternalEncodingError { context } => {
                (internal_encoding_error(), context).encode(env)
            }
        }
    }
}

impl RefUnwindSafe for XqliteError {}

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
            } else if term == true_().to_term(env) {
                Ok(Value::Integer(1))
            } else if term == false_().to_term(env) {
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
        key_string.insert(0, ':'); // Prepend ':' as SQLite expects it in named parameters
        let rusqlite_value = elixir_term_to_rusqlite_value(env, value_term)?;
        params.push((key_string, rusqlite_value));
    }
    Ok(params)
}

fn decode_plain_list_params<'a>(
    env: Env<'a>,
    list_term: Term<'a>,
) -> Result<Vec<Value>, XqliteError> {
    let iter: ListIterator<'a> =
        list_term.decode().map_err(|_| XqliteError::ExpectedList {
            value_str: format!("{:?}", list_term),
        })?;
    let mut values = Vec::new();
    for term in iter {
        values.push(elixir_term_to_rusqlite_value(env, term)?);
    }
    Ok(values)
}

fn process_rows<'a, 'rows>(
    env: Env<'a>,
    mut rows: Rows<'rows>, // Takes ownership of `rows`
    column_count: usize,
) -> Result<Vec<Vec<Term<'a>>>, XqliteError> {
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

fn is_keyword<'a>(list_term: Term<'a>) -> bool {
    match list_term.decode::<ListIterator<'a>>() {
        Ok(mut iter) => match iter.next() {
            Some(first_el) => first_el.decode::<(Atom, Term<'a>)>().is_ok(),
            None => false,
        },
        Err(_) => false,
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_open(path: String) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let conn = Connection::open(&path)
        .map_err(|e| XqliteError::CannotOpenDatabase(path, e.to_string()))?;
    let arc_mutex_conn = Arc::new(Mutex::new(conn));
    Ok(ResourceArc::new(XqliteConn(arc_mutex_conn)))
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_open_in_memory(uri: String) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let conn = Connection::open(&uri)
        .map_err(|e| XqliteError::CannotOpenDatabase(uri, e.to_string()))?;
    let arc_mutex_conn = Arc::new(Mutex::new(conn));
    Ok(ResourceArc::new(XqliteConn(arc_mutex_conn)))
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_open_temporary() -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let conn = Connection::open("")
        .map_err(|e| XqliteError::CannotOpenDatabase("".to_string(), e.to_string()))?;
    let arc_mutex_conn = Arc::new(Mutex::new(conn));
    Ok(ResourceArc::new(XqliteConn(arc_mutex_conn)))
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_query<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: String,
    params_term: Term<'a>,
) -> Result<XqliteQueryResult<'a>, XqliteError> {
    let conn_guard = handle
        .0
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    let conn: &Connection = &conn_guard;

    let sql_string_for_prepare = sql.to_string();
    let mut stmt = conn.prepare(sql.as_str()).map_err(|e| {
        XqliteError::CannotPrepareStatement(sql_string_for_prepare, e.to_string())
    })?;

    let column_names: Vec<String> =
        stmt.column_names().iter().map(|s| s.to_string()).collect();
    let column_count = column_names.len();

    // Branch based on parameter type
    let rows_result = match params_term.get_type() {
        TermType::List => {
            if is_keyword(params_term) {
                // keyword list: named arguments.
                let named_params_vec = decode_exec_keyword_params(env, params_term)?;
                let params_for_rusqlite: Vec<(&str, &dyn ToSql)> = named_params_vec
                    .iter()
                    .map(|(k, v)| (k.as_str(), v as &dyn ToSql))
                    .collect();
                stmt.query(params_for_rusqlite.as_slice())
            } else {
                // (assumed) list: positional arguments.
                let positional_values: Vec<Value> =
                    decode_plain_list_params(env, params_term)?;
                let params_slice: Vec<&dyn ToSql> =
                    positional_values.iter().map(|v| v as &dyn ToSql).collect();
                stmt.query(params_slice.as_slice())
            }
        }
        _ if params_term == nil().to_term(env) || params_term.is_empty_list() => {
            stmt.query([])
        }
        _ => {
            return Err(XqliteError::ExpectedList {
                value_str: format!("{:?}", params_term),
            });
        }
    };

    let rows = rows_result.map_err(|e| XqliteError::CannotExecute(e.to_string()))?;

    let results_vec: Vec<Vec<Term<'a>>> = process_rows(env, rows, column_count)?;

    let num_rows = results_vec.len();
    Ok(XqliteQueryResult {
        columns: column_names,
        rows: results_vec,
        num_rows,
    })
    // MutexGuard (conn_guard) is implicitly dropped here, releasing the lock
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_execute<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: String,
    params_term: Term<'a>,
) -> Result<usize, XqliteError> {
    let conn_guard = handle
        .0
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    let conn: &Connection = &conn_guard;

    // Decode parameters - MUST be a plain list for execute
    // decode_plain_list_params already returns ExpectedList if it's not a list term
    let positional_values: Vec<Value> = decode_plain_list_params(env, params_term)?;
    let params_slice: Vec<&dyn ToSql> =
        positional_values.iter().map(|v| v as &dyn ToSql).collect();

    // Use conn.execute for INSERT/UPDATE/DELETE etc.
    conn.execute(sql.as_str(), params_slice.as_slice())
        // Map rusqlite error to our generic execution error
        .map_err(|e| XqliteError::CannotExecute(e.to_string()))

    // MutexGuard (conn_guard) is implicitly dropped here, releasing the lock
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_pragma_write(
    handle: ResourceArc<XqliteConn>,
    pragma_sql: String,
) -> Result<usize, XqliteError> {
    let conn_guard = handle
        .0
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    let conn: &Connection = &conn_guard;
    conn.execute(&pragma_sql, [])
        .map_err(|e| XqliteError::CannotExecutePragma {
            pragma: pragma_sql,
            reason: e.to_string(),
        })
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_pragma_write_and_read<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    pragma_name: String,
    value_term: Term<'a>,
) -> Result<Term<'a>, XqliteError> {
    let conn_guard = handle
        .0
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    let conn: &Connection = &conn_guard;
    let pragma_value_to_set = elixir_term_to_rusqlite_value(env, value_term)?;

    let result = conn.pragma_update_and_check(
        None,
        &pragma_name,
        &pragma_value_to_set,
        |row: &Row<'_>| row.get(0),
    );

    drop(conn_guard);

    match result {
        Ok(value) => Ok(encode_val(env, value)),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(no_value().encode(env)),
        Err(other_err) => Err(XqliteError::CannotExecutePragma {
            pragma: format!("PRAGMA {} = {:?};", pragma_name, pragma_value_to_set),
            reason: other_err.to_string(),
        }),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_close(_handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    Ok(true)
}

fn on_load(_env: Env, _info: Term) -> bool {
    true
}

rustler::init!("Elixir.XqliteNIF", load = on_load);
