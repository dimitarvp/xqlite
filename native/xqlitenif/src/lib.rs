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
    code,
    columns,
    constraint_check,
    constraint_commit_hook,
    constraint_datatype,
    constraint_foreign_key,
    constraint_function,
    constraint_not_null,
    constraint_pinned,
    constraint_primary_key,
    constraint_rowid,
    constraint_trigger,
    constraint_unique,
    constraint_violation,
    constraint_vtab,
    error,
    execute_returned_results,
    expected,
    expected_keyword_list,
    expected_keyword_tuple,
    expected_list,
    float,
    from_sql_conversion_failure,
    function,
    integer,
    integral_value_out_of_range,
    internal_encoding_error,
    invalid_column_index,
    invalid_column_name,
    invalid_column_type,
    invalid_parameter_count,
    invalid_parameter_name,
    list,
    lock_error,
    map,
    message,
    multiple_statements,
    no_value,
    null_byte_in_string,
    num_rows,
    offset,
    pid,
    port,
    provided,
    reference,
    rows,
    sql,
    sql_input_error,
    sqlite_failure,
    text,
    to_sql_conversion_failure,
    tuple,
    unknown,
    unsupported_atom,
    unsupported_data_type,
    utf8_error,
}

use rusqlite::{ffi, types::Value, Connection, ErrorCode, Row, Rows, ToSql};
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

#[derive(Debug)]
pub(crate) enum XqliteError {
    // Input Conversion / Validation
    CannotConvertToSqliteValue {
        value_str: String,
        reason: String,
    },
    ToSqlConversionFailure {
        reason: String,
    },
    ExpectedKeywordList {
        value_str: String,
    },
    ExpectedKeywordTuple {
        value_str: String,
    },
    ExpectedList {
        value_str: String,
    },
    UnsupportedAtom {
        atom_value: String,
    },
    UnsupportedDataType {
        term_type: TermType,
    },
    CannotConvertAtomToString(String),
    InvalidParameterCount {
        provided: usize,
        expected: usize,
    },
    InvalidParameterName(String),
    NulErrorInString,
    MultipleStatements,

    // DB Open / Connection Errors
    CannotOpenDatabase(String, String),
    LockError(String),

    // Statement / Execution Errors
    CannotPrepareStatement(String, String),
    SqlInputError {
        code: i32,
        message: String,
        sql: String,
        offset: i32,
    },
    ExecuteReturnedResults,
    CannotExecute(String), // Generic execution error
    CannotExecutePragma {
        pragma: String,
        reason: String,
    },

    // Row / Column Errors
    CannotFetchRow(String),
    InvalidColumnIndex(usize),
    InvalidColumnName(String),
    InvalidColumnType {
        index: usize,
        name: String,
        sqlite_type: Atom,
    },
    FromSqlConversionFailure {
        index: usize,
        sqlite_type: Atom,
        reason: String,
    },
    IntegralValueOutOfRange {
        index: usize,
        value: i64,
    },
    Utf8Error {
        reason: String,
    },

    // Constraint Errors (from SqliteFailure)
    ConstraintViolation {
        kind: Option<Atom>,
        message: String,
    },

    // Generic Fallback
    SqliteFailure {
        code: i32,
        extended_code: i32,
        message: Option<String>,
    },

    // Internal
    InternalEncodingError {
        context: String,
    },
}

impl Display for XqliteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            XqliteError::CannotConvertToSqliteValue { value_str, reason } => write!(f, "Cannot convert Elixir value '{}' to SQLite type: {}", value_str, reason),
            XqliteError::ToSqlConversionFailure { reason } => write!(f, "Cannot convert Rust value to SQLite type: {}", reason),
            XqliteError::ExpectedKeywordList { value_str } => write!(f, "Expected a keyword list for named parameters, got: {}", value_str),
            XqliteError::ExpectedKeywordTuple { value_str } => write!(f, "Expected a {{atom, value}} tuple inside keyword list, got: {}", value_str),
            XqliteError::ExpectedList { value_str } => write!(f, "Expected a List for parameters, got: {}", value_str),
            XqliteError::UnsupportedAtom { atom_value } => write!(f, "Unsupported atom value '{}'. Allowed values: nil, true, false", atom_value),
            XqliteError::UnsupportedDataType { term_type } => write!(f, "Unsupported data type {}. Allowed types: atom, integer, float, binary", term_type_to_string(*term_type)),
            XqliteError::CannotPrepareStatement(sql, reason) => write!(f, "Cannot prepare statement '{}': {}", sql, reason),
            XqliteError::CannotExecute(reason) => write!(f, "Cannot execute query/statement: {}", reason),
            XqliteError::CannotExecutePragma { pragma, reason } => write!(f, "Cannot execute PRAGMA '{}': {}", pragma, reason),
            XqliteError::CannotFetchRow(reason) => write!(f, "Cannot fetch row: {}", reason),
            XqliteError::CannotOpenDatabase(path, reason) => write!(f, "Cannot open database '{}': {}", path, reason),
            XqliteError::CannotConvertAtomToString(reason) => write!(f, "Cannot convert Elixir atom to string: {}", reason),
            XqliteError::LockError(reason) => write!(f, "Failed to lock connection mutex: {}", reason),
            XqliteError::InternalEncodingError { context } => write!(f, "Internal error during result encoding: {}", context),
            XqliteError::InvalidParameterCount { provided, expected } => write!(f, "Invalid parameter count: provided {}, expected {}", provided, expected),
            XqliteError::InvalidParameterName(name) => write!(f, "Invalid parameter name: '{}'", name),
            XqliteError::NulErrorInString => write!(f, "Input string contains embedded null byte"),
            XqliteError::MultipleStatements => write!(f, "Provided SQL string contains multiple statements"),
            XqliteError::InvalidColumnIndex(index) => write!(f, "Invalid column index: {}", index),
            XqliteError::InvalidColumnName(name) => write!(f, "Invalid column name: '{}'", name),
            XqliteError::InvalidColumnType { index, name, sqlite_type } => write!(f, "Invalid column type at index {} (name: '{}'): cannot convert SQLite type '{:?}'", index, name, sqlite_type),
            XqliteError::ExecuteReturnedResults => write!(f, "Execute returned results, expected no rows"),
            XqliteError::Utf8Error { reason } => write!(f, "UTF-8 decoding error: {}", reason),
            XqliteError::FromSqlConversionFailure { index, sqlite_type, reason } => write!(f, "Failed to convert SQLite type '{:?}' at index {} to Rust type: {}", sqlite_type, index, reason),
            XqliteError::IntegralValueOutOfRange { index, value } => write!(f, "Integral value {} at index {} out of range for requested Rust type", value, index),
            XqliteError::SqlInputError { code, message, sql: _, offset } => write!(f, "SQL input error (Code {}): '{}' near offset {}", code, message, offset),
            XqliteError::ConstraintViolation { kind: _, message } => write!(f, "Constraint violation: {}", message),
            XqliteError::SqliteFailure { code, extended_code, message } => write!(f, "SQLite failure (Code: {}, Extended: {}): {}", code, extended_code, message.as_deref().unwrap_or("No details")),
        }
    }
}

impl Encoder for XqliteError {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            XqliteError::CannotConvertToSqliteValue { value_str, reason } => {
                (cannot_convert_to_sqlite_value(), value_str, reason).encode(env)
            }
            XqliteError::ToSqlConversionFailure { reason } => {
                (to_sql_conversion_failure(), reason).encode(env)
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
            XqliteError::InvalidParameterCount { provided, expected } => {
                let map_result = map_new(env)
                    // Use crate::* to avoid shadowing
                    .map_put(crate::provided(), provided) // Use full path to atom fn
                    .and_then(|map| map.map_put(crate::expected(), expected)); // Use full path to atom fn
                match map_result {
                    Ok(map) => (invalid_parameter_count(), map).encode(env), // Use atom fn for tuple key
                    Err(_) => (
                        error(),
                        internal_encoding_error(),
                        "Failed map create for InvalidParameterCount",
                    )
                        .encode(env),
                }
            }
            XqliteError::InvalidParameterName(name) => {
                (invalid_parameter_name(), name).encode(env)
            }
            XqliteError::NulErrorInString => null_byte_in_string().encode(env),
            XqliteError::MultipleStatements => multiple_statements().encode(env),
            XqliteError::InvalidColumnIndex(index) => {
                (invalid_column_index(), index).encode(env)
            }
            XqliteError::InvalidColumnName(name) => (invalid_column_name(), name).encode(env),
            XqliteError::InvalidColumnType {
                index,
                name,
                sqlite_type,
            } => (invalid_column_type(), index, name, *sqlite_type).encode(env),
            XqliteError::ExecuteReturnedResults => execute_returned_results().encode(env),
            XqliteError::Utf8Error { reason } => (utf8_error(), reason).encode(env),
            XqliteError::FromSqlConversionFailure {
                index,
                sqlite_type,
                reason,
            } => (from_sql_conversion_failure(), index, *sqlite_type, reason).encode(env),
            XqliteError::IntegralValueOutOfRange { index, value } => {
                (integral_value_out_of_range(), index, value).encode(env)
            }
            // <<< Corrected map encoding for SqlInputError >>>
            XqliteError::SqlInputError {
                code,
                message,
                sql,
                offset,
            } => {
                let map_result = map_new(env)
                    // Scope the atom access to avoid shadowing with the `code` variable.
                    .map_put(crate::code(), code)
                    .and_then(|map| map.map_put(crate::message(), message)) // Use full path
                    .and_then(|map| map.map_put(crate::sql(), sql)) // Use full path
                    .and_then(|map| map.map_put(crate::offset(), offset));
                match map_result {
                    Ok(map) => (sql_input_error(), map).encode(env), // Use atom fn for tuple key
                    Err(_) => (
                        error(),
                        internal_encoding_error(),
                        "Failed map create for SqlInputError",
                    )
                        .encode(env),
                }
            }
            XqliteError::ConstraintViolation { kind, message } => {
                (constraint_violation(), *kind, message).encode(env)
            }
            XqliteError::SqliteFailure {
                code,
                extended_code,
                message,
            } => (sqlite_failure(), code, extended_code, message).encode(env),
        }
    }
}

impl RefUnwindSafe for XqliteError {}

impl From<rusqlite::Error> for XqliteError {
    fn from(err: rusqlite::Error) -> Self {
        match err {
            // --- Handle SqliteFailure: Check constraints first, then specific codes, then fallback ---
            rusqlite::Error::SqliteFailure(ffi_err, msg_opt) => {
                // Use the extended code primarily for specific constraint checks
                if let Some(kind_atom) =
                    constraint_kind_to_atom_extended(ffi_err.extended_code)
                {
                    // We got a specific kind (:constraint_*) or the generic :constraint_violation
                    XqliteError::ConstraintViolation {
                        kind: Some(kind_atom),
                        message: msg_opt.unwrap_or_else(|| ffi_err.to_string()), // Use ffi_err string if no specific message
                    }
                } else {
                    // Match on the primary ErrorCode already parsed by libsqlite3-sys
                    match ffi_err.code {
                        // Add specific mappings for primary codes here if needed for distinct handling
                        ErrorCode::NotFound => XqliteError::CannotExecute(
                            msg_opt.unwrap_or_else(|| "SQLite object not found".to_string()),
                        ),
                        ErrorCode::DatabaseCorrupt => XqliteError::CannotExecute(
                            msg_opt.unwrap_or_else(|| "SQLite database corrupt".to_string()),
                        ),
                        ErrorCode::ReadOnly => {
                            XqliteError::CannotExecute(msg_opt.unwrap_or_else(|| {
                                "Attempt to write a readonly database".to_string()
                            }))
                        }
                        // <<< Corrected: Use DatabaseBusy >>>
                        ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked => {
                            XqliteError::CannotExecute(msg_opt.unwrap_or_else(|| {
                                "Database/table is locked or busy".to_string()
                            }))
                        }
                        ErrorCode::ApiMisuse => XqliteError::CannotExecute(
                            msg_opt
                                .unwrap_or_else(|| "SQLite API misuse detected".to_string()),
                        ),
                        // Add more specific ErrorCode mappings here if desired

                        // If no specific primary code match, use the generic SqliteFailure fallback
                        _ => XqliteError::SqliteFailure {
                            code: ffi_err.code as i32, // Store the primary code integer value
                            extended_code: ffi_err.extended_code,
                            message: msg_opt,
                        },
                    }
                }
            }

            // --- Handle other rusqlite::Error variants ---
            rusqlite::Error::FromSqlConversionFailure(idx, sql_type, source_err) => {
                XqliteError::FromSqlConversionFailure {
                    index: idx,
                    sqlite_type: sqlite_type_to_atom(sql_type),
                    reason: source_err.to_string(),
                }
            }
            rusqlite::Error::IntegralValueOutOfRange(idx, val) => {
                XqliteError::IntegralValueOutOfRange {
                    index: idx,
                    value: val,
                }
            }
            rusqlite::Error::Utf8Error(utf8_err) => XqliteError::Utf8Error {
                reason: utf8_err.to_string(),
            },
            rusqlite::Error::NulError(_nul_err) => XqliteError::NulErrorInString,
            rusqlite::Error::InvalidParameterName(name) => {
                XqliteError::InvalidParameterName(name)
            }
            rusqlite::Error::InvalidParameterCount(provided, expected) => {
                XqliteError::InvalidParameterCount { provided, expected }
            }
            rusqlite::Error::ExecuteReturnedResults => XqliteError::ExecuteReturnedResults,
            rusqlite::Error::InvalidColumnIndex(idx) => XqliteError::InvalidColumnIndex(idx),
            rusqlite::Error::InvalidColumnName(name) => XqliteError::InvalidColumnName(name),
            rusqlite::Error::InvalidColumnType(idx, name, sql_type) => {
                XqliteError::InvalidColumnType {
                    index: idx,
                    name,
                    sqlite_type: sqlite_type_to_atom(sql_type),
                }
            }
            rusqlite::Error::ToSqlConversionFailure(source_err) => {
                XqliteError::ToSqlConversionFailure {
                    reason: source_err.to_string(),
                }
            }
            rusqlite::Error::MultipleStatement => XqliteError::MultipleStatements,

            rusqlite::Error::SqlInputError {
                error: ffi_err,
                msg,
                sql,
                offset,
            } => XqliteError::SqlInputError {
                code: ffi_err.code as i32,
                message: msg,
                sql,
                offset,
            },

            // Catch-all for any other rusqlite::Error variants not explicitly handled
            // Note: QueryReturnedNoRows is deliberately not caught here.
            other_err => XqliteError::CannotExecute(other_err.to_string()),
        }
    }
}

// Based on libsqlite3-sys constants
fn constraint_kind_to_atom_extended(extended_code: i32) -> Option<Atom> {
    // Primary constraint code check
    const SQLITE_CONSTRAINT_PRIMARY: i32 = ffi::SQLITE_CONSTRAINT; // Get the base code

    match extended_code {
        ffi::SQLITE_CONSTRAINT_CHECK => Some(constraint_check()),
        ffi::SQLITE_CONSTRAINT_COMMITHOOK => Some(constraint_commit_hook()),
        ffi::SQLITE_CONSTRAINT_FOREIGNKEY => Some(constraint_foreign_key()),
        ffi::SQLITE_CONSTRAINT_FUNCTION => Some(constraint_function()),
        ffi::SQLITE_CONSTRAINT_NOTNULL => Some(constraint_not_null()),
        ffi::SQLITE_CONSTRAINT_PRIMARYKEY => Some(constraint_primary_key()),
        ffi::SQLITE_CONSTRAINT_ROWID => Some(constraint_rowid()),
        ffi::SQLITE_CONSTRAINT_TRIGGER => Some(constraint_trigger()),
        ffi::SQLITE_CONSTRAINT_UNIQUE => Some(constraint_unique()),
        ffi::SQLITE_CONSTRAINT_VTAB => Some(constraint_vtab()),
        ffi::SQLITE_CONSTRAINT_PINNED => Some(constraint_pinned()),
        ffi::SQLITE_CONSTRAINT_DATATYPE => Some(constraint_datatype()),

        // Catch-all: Check if the primary code part matches SQLITE_CONSTRAINT
        // This covers cases where SQLite might return, e.g., just 19 (SQLITE_CONSTRAINT)
        // without a specific extended code like (19 | (5 << 8)) for NOTNULL.
        // It also covers *future* extended constraint codes we don't know about yet.
        code if (code & 0xff) == SQLITE_CONSTRAINT_PRIMARY => Some(constraint_violation()), // Return the generic atom

        // Not a known extended constraint code, and not even a basic constraint code
        _ => None,
    }
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

fn sqlite_type_to_atom(t: rusqlite::types::Type) -> Atom {
    match t {
        rusqlite::types::Type::Null => nil(),
        rusqlite::types::Type::Integer => integer(),
        rusqlite::types::Type::Real => float(),
        rusqlite::types::Type::Text => text(),
        rusqlite::types::Type::Blob => binary(),
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

    // Use loop and match to handle Result<Option<Row>> from rows.next()
    loop {
        match rows.next() {
            Ok(Some(row)) => {
                // Successfully got a row
                let mut row_values: Vec<Term<'a>> = Vec::with_capacity(column_count);
                for i in 0..column_count {
                    // Use `?` here - if row.get fails, it returns rusqlite::Error,
                    // which will be converted via From/Into by the surrounding function's
                    // Result signature (XqliteError) if this closure doesn't map it.
                    // Or map it explicitly if needed (as done below, which is safer).
                    let value: Value = row.get::<usize, Value>(i)?; // This '?' uses the From impl
                    let term = encode_val(env, value);
                    row_values.push(term);
                }
                results.push(row_values);
            }
            Ok(None) => {
                // End of rows, break the loop successfully
                break;
            }
            Err(e) => {
                // Error fetching next row, map it and return Err
                return Err(XqliteError::CannotFetchRow(e.to_string()));
            }
        }
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

fn with_conn<F, R>(handle: &ResourceArc<XqliteConn>, func: F) -> Result<R, XqliteError>
where
    F: FnOnce(&Connection) -> Result<R, XqliteError>,
{
    let conn_guard = handle
        .0
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    func(&conn_guard)
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
    let sql_for_err = sql.clone();

    with_conn(&handle, |conn| {
        let mut stmt = conn
            .prepare(sql.as_str())
            .map_err(|e| XqliteError::CannotPrepareStatement(sql_for_err, e.to_string()))?;
        let column_names: Vec<String> =
            stmt.column_names().iter().map(|s| s.to_string()).collect();
        let column_count = column_names.len();

        let rows = match params_term.get_type() {
            TermType::List => {
                if is_keyword(params_term) {
                    let named_params_vec = decode_exec_keyword_params(env, params_term)?;
                    let params_for_rusqlite: Vec<(&str, &dyn ToSql)> = named_params_vec
                        .iter()
                        .map(|(k, v)| (k.as_str(), v as &dyn ToSql))
                        .collect();
                    stmt.query(params_for_rusqlite.as_slice())?
                } else {
                    let positional_values: Vec<Value> =
                        decode_plain_list_params(env, params_term)?;
                    let params_slice: Vec<&dyn ToSql> =
                        positional_values.iter().map(|v| v as &dyn ToSql).collect();
                    stmt.query(params_slice.as_slice())?
                }
            }
            _ if params_term == nil().to_term(env) || params_term.is_empty_list() => {
                stmt.query([])?
            }
            _ => {
                return Err(XqliteError::ExpectedList {
                    value_str: format!("{:?}", params_term),
                });
            }
        };

        let results_vec: Vec<Vec<Term<'a>>> = process_rows(env, rows, column_count)?;
        let num_rows = results_vec.len();

        Ok(XqliteQueryResult {
            columns: column_names,
            rows: results_vec,
            num_rows,
        })
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_execute<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: String,
    params_term: Term<'a>,
) -> Result<usize, XqliteError> {
    with_conn(&handle, |conn| {
        let positional_values: Vec<Value> = decode_plain_list_params(env, params_term)?;
        let params_slice: Vec<&dyn ToSql> =
            positional_values.iter().map(|v| v as &dyn ToSql).collect();
        // Use `?` which will now invoke the refined `From<rusqlite::Error>` impl
        Ok(conn.execute(sql.as_str(), params_slice.as_slice())?)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_execute_batch(
    handle: ResourceArc<XqliteConn>,
    sql_batch: String,
) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        conn.execute_batch(&sql_batch)?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_pragma_write(
    handle: ResourceArc<XqliteConn>,
    pragma_sql: String,
) -> Result<usize, XqliteError> {
    let pragma_sql_for_err = pragma_sql.clone();
    with_conn(&handle, |conn| {
        // Keep explicit mapping for pragmas to distinguish from general execute errors
        conn.execute(&pragma_sql, [])
            .map_err(|e| XqliteError::CannotExecutePragma {
                pragma: pragma_sql_for_err,
                reason: e.to_string(),
            })
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_pragma_write_and_read<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    pragma_name: String,
    value_term: Term<'a>,
) -> Result<Term<'a>, XqliteError> {
    let pragma_name_for_err = pragma_name.clone();
    let pragma_value_to_set = elixir_term_to_rusqlite_value(env, value_term)?;
    let value_for_err = pragma_value_to_set.clone();

    let result_option = with_conn(&handle, |conn| {
        match conn.pragma_update_and_check(
            None,
            &pragma_name,
            &pragma_value_to_set,
            |row: &Row<'_>| row.get::<usize, Value>(0),
        ) {
            Ok(value) => Ok(Some(value)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(other_err) => Err(XqliteError::CannotExecutePragma {
                // Keep explicit mapping
                pragma: format!("PRAGMA {} = {:?};", pragma_name_for_err, value_for_err),
                reason: other_err.to_string(),
            }),
        }
    })?;

    match result_option {
        Some(value) => Ok(encode_val(env, value)),
        None => Ok(no_value().encode(env)),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_begin(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        conn.execute("BEGIN;", [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_commit(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        conn.execute("COMMIT;", [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_rollback(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        conn.execute("ROLLBACK;", [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn raw_close(_handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    Ok(true)
}

fn on_load(_env: Env, _info: Term) -> bool {
    true
}

rustler::init!("Elixir.XqliteNIF", load = on_load);
