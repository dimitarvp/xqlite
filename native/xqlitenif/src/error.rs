use crate::atoms;
use rusqlite::{Error as RusqliteError, ffi};
use rustler::{
    Atom, Encoder, Env, Term, TermType,
    types::{atom::nil, map::map_new},
};
use std::fmt::{self, Display};
use std::panic::RefUnwindSafe;

#[derive(Debug, Clone)]
pub(crate) enum SchemaErrorDetail {
    UnexpectedValue(String),
}

// Based on libsqlite3-sys constants
fn constraint_kind_to_atom_extended(extended_code: i32) -> Option<Atom> {
    // Base constraint error code (not "primary key" — that's SQLITE_CONSTRAINT_PRIMARYKEY)
    const SQLITE_CONSTRAINT_BASE: i32 = ffi::SQLITE_CONSTRAINT;

    match extended_code {
        ffi::SQLITE_CONSTRAINT_CHECK => Some(atoms::constraint_check()),
        ffi::SQLITE_CONSTRAINT_COMMITHOOK => Some(atoms::constraint_commit_hook()),
        ffi::SQLITE_CONSTRAINT_FOREIGNKEY => Some(atoms::constraint_foreign_key()),
        ffi::SQLITE_CONSTRAINT_FUNCTION => Some(atoms::constraint_function()),
        ffi::SQLITE_CONSTRAINT_NOTNULL => Some(atoms::constraint_not_null()),
        ffi::SQLITE_CONSTRAINT_PRIMARYKEY => Some(atoms::constraint_primary_key()),
        ffi::SQLITE_CONSTRAINT_ROWID => Some(atoms::constraint_rowid()),
        ffi::SQLITE_CONSTRAINT_TRIGGER => Some(atoms::constraint_trigger()),
        ffi::SQLITE_CONSTRAINT_UNIQUE => Some(atoms::constraint_unique()),
        ffi::SQLITE_CONSTRAINT_VTAB => Some(atoms::constraint_vtab()),
        ffi::SQLITE_CONSTRAINT_PINNED => Some(atoms::constraint_pinned()),
        ffi::SQLITE_CONSTRAINT_DATATYPE => Some(atoms::constraint_datatype()),

        // Catch-all: Check if the primary code part matches SQLITE_CONSTRAINT
        // This covers cases where SQLite might return, e.g., just 19 (SQLITE_CONSTRAINT)
        // without a specific extended code like (19 | (5 << 8)) for NOTNULL.
        // It also covers *future* extended constraint codes we don't know about yet.
        code if (code & 0xff) == SQLITE_CONSTRAINT_BASE => Some(atoms::constraint_violation()),

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
        TermType::Atom => atoms::atom(),
        TermType::Binary => atoms::binary(),
        TermType::Float => atoms::float(),
        TermType::Fun => atoms::function(),
        TermType::Integer => atoms::integer(),
        TermType::List => atoms::list(),
        TermType::Map => atoms::map(),
        TermType::Pid => atoms::pid(),
        TermType::Port => atoms::port(),
        TermType::Ref => atoms::reference(),
        TermType::Tuple => atoms::tuple(),
        TermType::Unknown => atoms::unknown(),
    }
}

fn sqlite_type_to_atom(t: rusqlite::types::Type) -> Atom {
    match t {
        rusqlite::types::Type::Null => nil(),
        rusqlite::types::Type::Integer => atoms::integer(),
        rusqlite::types::Type::Real => atoms::float(),
        rusqlite::types::Type::Text => atoms::text(),
        rusqlite::types::Type::Blob => atoms::binary(),
    }
}

#[derive(Debug, Clone)]
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
    InvalidPragmaName(String),
    NulErrorInString,
    MultipleStatements,

    // DB Open / Connection Errors
    CannotOpenDatabase {
        path: String,
        code: i32,
        message: String,
    },
    LockError(String),

    // Statement / Execution Errors
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
    DatabaseBusyOrLocked {
        message: String,
    },
    OperationCancelled,

    NoSuchTable {
        message: String,
    },
    NoSuchIndex {
        message: String,
    },
    TableExists {
        message: String,
    },
    IndexExists {
        message: String,
    },
    SchemaChanged {
        // SQLITE_SCHEMA
        message: String,
    },
    ReadOnlyDatabase {
        // SQLITE_READONLY
        message: String,
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

    // Errors during schema introspection NIFs
    SchemaParsingError {
        context: String, // e.g., "Parsing type affinity for column 'foo'"
        error_detail: SchemaErrorDetail,
    },

    InvalidStreamHandle {
        reason: String,
    },

    // Connection state
    ConnectionClosed,

    // Internal
    InternalEncodingError {
        context: String,
    },
}

impl Display for XqliteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            XqliteError::CannotConvertToSqliteValue { value_str, reason } => write!(
                f,
                "Cannot convert Elixir value '{value_str}' to SQLite type: {reason}"
            ),
            XqliteError::ToSqlConversionFailure { reason } => {
                write!(f, "Cannot convert Rust value to SQLite type: {reason}")
            }
            XqliteError::ExpectedKeywordList { value_str } => write!(
                f,
                "Expected a keyword list for named parameters, got: {value_str}"
            ),
            XqliteError::ExpectedKeywordTuple { value_str } => write!(
                f,
                "Expected a {{atom, value}} tuple inside keyword list, got: {value_str}"
            ),
            XqliteError::ExpectedList { value_str } => {
                write!(f, "Expected a List for parameters, got: {value_str}")
            }
            XqliteError::UnsupportedAtom { atom_value } => write!(
                f,
                "Unsupported atom value '{atom_value}'. Allowed values: nil, true, false"
            ),
            XqliteError::UnsupportedDataType { term_type } => write!(
                f,
                "Unsupported data type {}. Allowed types: atom, integer, float, binary",
                term_type_to_string(*term_type)
            ),
            XqliteError::CannotExecute(reason) => {
                write!(f, "Cannot execute query/statement: {reason}")
            }
            XqliteError::CannotExecutePragma { pragma, reason } => {
                write!(f, "Cannot execute PRAGMA '{pragma}': {reason}")
            }
            XqliteError::DatabaseBusyOrLocked { message } => {
                write!(f, "Database busy or locked: {message}")
            }
            XqliteError::OperationCancelled => {
                write!(f, "Database operation was cancelled")
            }
            XqliteError::NoSuchTable { message } => {
                write!(f, "No such table: {message}") // Message usually includes table name
            }
            XqliteError::NoSuchIndex { message } => {
                write!(f, "No such index: {message}") // Message usually includes index name
            }
            XqliteError::TableExists { message } => {
                write!(f, "Table already exists: {message}") // Message usually includes table name
            }
            XqliteError::IndexExists { message } => {
                write!(f, "Index already exists: {message}") // Message usually includes index name
            }
            XqliteError::SchemaChanged { message } => {
                write!(f, "Database schema changed: {message}") // SQLITE_SCHEMA
            }
            XqliteError::ReadOnlyDatabase { message } => {
                write!(f, "Database is read-only: {message}") // SQLITE_READONLY
            }
            XqliteError::CannotFetchRow(reason) => write!(f, "Cannot fetch row: {reason}"),
            XqliteError::CannotOpenDatabase {
                path,
                code,
                message,
            } => {
                write!(f, "Cannot open database '{path}' (Code: {code}): {message}")
            }
            XqliteError::CannotConvertAtomToString(reason) => {
                write!(f, "Cannot convert Elixir atom to string: {reason}")
            }
            XqliteError::LockError(reason) => {
                write!(f, "Failed to lock connection mutex: {reason}")
            }
            XqliteError::InvalidStreamHandle { reason } => {
                write!(f, "Invalid stream handle: {reason}")
            }
            XqliteError::ConnectionClosed => {
                write!(f, "Connection is closed")
            }
            XqliteError::InternalEncodingError { context } => {
                write!(f, "Internal error during result encoding: {context}")
            }
            XqliteError::InvalidParameterCount { provided, expected } => write!(
                f,
                "Invalid parameter count: provided {provided}, expected {expected}"
            ),
            XqliteError::InvalidParameterName(name) => {
                write!(f, "Invalid parameter name: '{name}'")
            }
            XqliteError::InvalidPragmaName(name) => {
                write!(f, "Invalid pragma name: '{name}'")
            }
            XqliteError::NulErrorInString => {
                write!(f, "Input string contains embedded null byte")
            }
            XqliteError::MultipleStatements => {
                write!(f, "Provided SQL string contains multiple statements")
            }
            XqliteError::InvalidColumnIndex(index) => {
                write!(f, "Invalid column index: {index}")
            }
            XqliteError::InvalidColumnName(name) => write!(f, "Invalid column name: '{name}'"),
            XqliteError::InvalidColumnType {
                index,
                name,
                sqlite_type,
            } => write!(
                f,
                "Invalid column type at index {index} (name: '{name}'): cannot convert SQLite type '{sqlite_type:?}'"
            ),
            XqliteError::ExecuteReturnedResults => {
                write!(f, "Execute returned results, expected no rows")
            }
            XqliteError::Utf8Error { reason } => write!(f, "UTF-8 decoding error: {reason}"),
            XqliteError::FromSqlConversionFailure {
                index,
                sqlite_type,
                reason,
            } => write!(
                f,
                "Failed to convert SQLite type '{sqlite_type:?}' at index {index} to Rust type: {reason}"
            ),
            XqliteError::IntegralValueOutOfRange { index, value } => write!(
                f,
                "Integral value {value} at index {index} out of range for requested Rust type"
            ),
            XqliteError::SqlInputError {
                code,
                message,
                sql: _,
                offset,
            } => write!(
                f,
                "SQL input error (Code {code}): '{message}' near offset {offset}"
            ),
            XqliteError::ConstraintViolation { kind: _, message } => {
                write!(f, "Constraint violation: {message}")
            }
            XqliteError::SchemaParsingError {
                context,
                error_detail,
            } => {
                let SchemaErrorDetail::UnexpectedValue(val) = error_detail;
                write!(f, "Schema parsing error ({context})")?;
                write!(f, ": Unexpected value '{val}'")
            }
            XqliteError::SqliteFailure {
                code,
                extended_code,
                message,
            } => write!(
                f,
                "SQLite failure (Code: {}, Extended: {}): {}",
                code,
                extended_code,
                message.as_deref().unwrap_or("No details")
            ),
        }
    }
}

impl Encoder for XqliteError {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            XqliteError::CannotConvertToSqliteValue { value_str, reason } => {
                (atoms::cannot_convert_to_sqlite_value(), value_str, reason).encode(env)
            }
            XqliteError::ToSqlConversionFailure { reason } => {
                (atoms::to_sql_conversion_failure(), reason).encode(env)
            }
            XqliteError::ExpectedKeywordList { value_str } => {
                (atoms::expected_keyword_list(), value_str).encode(env)
            }
            XqliteError::ExpectedKeywordTuple { value_str } => {
                (atoms::expected_keyword_tuple(), value_str).encode(env)
            }
            XqliteError::ExpectedList { value_str } => {
                (atoms::expected_list(), value_str).encode(env)
            }
            XqliteError::UnsupportedAtom { atom_value: _ } => {
                atoms::unsupported_atom().encode(env)
            }
            XqliteError::UnsupportedDataType { term_type } => (
                atoms::unsupported_data_type(),
                term_type_to_atom(env, *term_type),
            )
                .encode(env),
            XqliteError::CannotExecute(reason) => {
                (atoms::cannot_execute(), reason).encode(env)
            }
            XqliteError::CannotExecutePragma { pragma, reason } => {
                (atoms::cannot_execute_pragma(), pragma, reason).encode(env)
            }
            XqliteError::DatabaseBusyOrLocked { message } => {
                (atoms::database_busy_or_locked(), message).encode(env)
            }
            XqliteError::OperationCancelled => atoms::operation_cancelled().encode(env),
            XqliteError::NoSuchTable { message } => {
                (atoms::no_such_table(), message).encode(env)
            }
            XqliteError::NoSuchIndex { message } => {
                (atoms::no_such_index(), message).encode(env)
            }
            XqliteError::TableExists { message } => {
                (atoms::table_exists(), message).encode(env)
            }
            XqliteError::IndexExists { message } => {
                (atoms::index_exists(), message).encode(env)
            }
            XqliteError::SchemaChanged { message } => {
                (atoms::schema_changed(), message).encode(env)
            }
            XqliteError::ReadOnlyDatabase { message } => {
                (atoms::read_only_database(), message).encode(env)
            }
            XqliteError::CannotFetchRow(reason) => {
                (atoms::cannot_fetch_row(), reason).encode(env)
            }
            XqliteError::CannotOpenDatabase {
                path,
                code,
                message,
            } => (atoms::cannot_open_database(), path, code, message).encode(env),
            XqliteError::CannotConvertAtomToString(reason) => {
                (atoms::cannot_convert_atom_to_string(), reason).encode(env)
            }
            XqliteError::LockError(reason) => (atoms::lock_error(), reason).encode(env),
            XqliteError::InvalidStreamHandle { reason } => {
                (atoms::invalid_stream_handle(), reason).encode(env)
            }
            XqliteError::ConnectionClosed => atoms::connection_closed().encode(env),
            XqliteError::InternalEncodingError { context } => {
                (atoms::internal_encoding_error(), context).encode(env)
            }
            XqliteError::InvalidParameterCount { provided, expected } => {
                let map_result = map_new(env)
                    .map_put(atoms::provided(), provided)
                    .and_then(|map| map.map_put(atoms::expected(), expected));
                match map_result {
                    Ok(map) => (atoms::invalid_parameter_count(), map).encode(env),
                    Err(_) => {
                        let err = XqliteError::InternalEncodingError {
                            context: "Failed map create for InvalidParameterCount".to_string(),
                        };
                        (atoms::error(), err).encode(env)
                    }
                }
            }
            XqliteError::InvalidParameterName(name) => {
                (atoms::invalid_parameter_name(), name).encode(env)
            }
            XqliteError::InvalidPragmaName(name) => {
                (atoms::invalid_pragma_name(), name).encode(env)
            }
            XqliteError::NulErrorInString => atoms::null_byte_in_string().encode(env),
            XqliteError::MultipleStatements => atoms::multiple_statements().encode(env),
            XqliteError::InvalidColumnIndex(index) => {
                (atoms::invalid_column_index(), index).encode(env)
            }
            XqliteError::InvalidColumnName(name) => {
                (atoms::invalid_column_name(), name).encode(env)
            }
            XqliteError::InvalidColumnType {
                index,
                name,
                sqlite_type,
            } => (atoms::invalid_column_type(), index, name, *sqlite_type).encode(env),
            XqliteError::ExecuteReturnedResults => {
                atoms::execute_returned_results().encode(env)
            }
            XqliteError::Utf8Error { reason } => (atoms::utf8_error(), reason).encode(env),
            XqliteError::FromSqlConversionFailure {
                index,
                sqlite_type,
                reason,
            } => (
                atoms::from_sql_conversion_failure(),
                index,
                *sqlite_type,
                reason,
            )
                .encode(env),
            XqliteError::IntegralValueOutOfRange { index, value } => {
                (atoms::integral_value_out_of_range(), index, value).encode(env)
            }
            XqliteError::SqlInputError {
                code,
                message,
                sql,
                offset,
            } => {
                let map_result = map_new(env)
                    .map_put(atoms::code(), code)
                    .and_then(|map| map.map_put(atoms::message(), message))
                    .and_then(|map| map.map_put(atoms::sql(), sql))
                    .and_then(|map| map.map_put(atoms::offset(), offset));
                match map_result {
                    Ok(map) => (atoms::sql_input_error(), map).encode(env),
                    Err(_) => {
                        let err = XqliteError::InternalEncodingError {
                            context: "Failed map create for SqlInputError".to_string(),
                        };
                        (atoms::error(), err).encode(env)
                    }
                }
            }
            XqliteError::ConstraintViolation { kind, message } => {
                (atoms::constraint_violation(), *kind, message).encode(env)
            }
            XqliteError::SchemaParsingError {
                context,
                error_detail,
            } => {
                let SchemaErrorDetail::UnexpectedValue(val) = error_detail;
                let detail_term = (atoms::unexpected_value(), val).encode(env);
                (atoms::schema_parsing_error(), context, detail_term).encode(env)
            }
            XqliteError::SqliteFailure {
                code,
                extended_code,
                message,
            } => (atoms::sqlite_failure(), code, extended_code, message).encode(env),
        }
    }
}

impl RefUnwindSafe for XqliteError {}

fn classify_sqlite_error(ffi_err: ffi::Error, message_string: String) -> XqliteError {
    let lower_msg = message_string.to_lowercase();
    let primary_code = ffi_err.extended_code & 0xFF;

    match primary_code {
        ffi::SQLITE_READONLY => XqliteError::ReadOnlyDatabase {
            message: message_string,
        },
        ffi::SQLITE_INTERRUPT => XqliteError::OperationCancelled,
        ffi::SQLITE_BUSY | ffi::SQLITE_LOCKED => XqliteError::DatabaseBusyOrLocked {
            message: message_string,
        },
        ffi::SQLITE_SCHEMA => XqliteError::SchemaChanged {
            message: message_string,
        },
        ffi::SQLITE_CONSTRAINT => {
            if let Some(kind) = constraint_kind_to_atom_extended(ffi_err.extended_code) {
                XqliteError::ConstraintViolation {
                    kind: Some(kind),
                    message: message_string,
                }
            } else {
                XqliteError::ConstraintViolation {
                    kind: None,
                    message: message_string,
                }
            }
        }
        // Handle common errors by inspecting the message text.
        _ if lower_msg.starts_with("no such table") => XqliteError::NoSuchTable {
            message: message_string,
        },
        _ if lower_msg.starts_with("no such index") => XqliteError::NoSuchIndex {
            message: message_string,
        },
        _ if lower_msg.starts_with("table") && lower_msg.contains("already exists") => {
            XqliteError::TableExists {
                message: message_string,
            }
        }
        _ if lower_msg.starts_with("index") && lower_msg.contains("already exists") => {
            XqliteError::IndexExists {
                message: message_string,
            }
        }
        // Fallback for any other SQLite error.
        _ => XqliteError::SqliteFailure {
            code: ffi_err.extended_code & 0xFF,
            extended_code: ffi_err.extended_code,
            message: Some(message_string),
        },
    }
}

impl From<RusqliteError> for XqliteError {
    fn from(err: RusqliteError) -> Self {
        match err {
            RusqliteError::SqliteFailure(ffi_err, msg_opt) => {
                let message_string = msg_opt.unwrap_or_else(|| ffi_err.to_string());
                classify_sqlite_error(ffi_err, message_string)
            }

            RusqliteError::SqlInputError {
                error: ffi_err,
                msg,
                sql,
                offset,
            } => {
                let classified = classify_sqlite_error(ffi_err, msg);
                // Preserve the richer SqlInputError if classification is generic
                if let XqliteError::SqliteFailure { .. } = classified {
                    XqliteError::SqlInputError {
                        code: ffi_err.extended_code,
                        message: classified.to_string(),
                        sql,
                        offset,
                    }
                } else {
                    classified
                }
            }

            // --- Other specific rusqlite::Error variants ---
            RusqliteError::ExecuteReturnedResults => XqliteError::ExecuteReturnedResults,
            RusqliteError::InvalidParameterCount(p, e) => XqliteError::InvalidParameterCount {
                provided: p,
                expected: e,
            },
            RusqliteError::InvalidParameterName(name) => {
                XqliteError::InvalidParameterName(name)
            }
            RusqliteError::NulError(_) => XqliteError::NulErrorInString,
            RusqliteError::Utf8Error(e) => XqliteError::Utf8Error {
                reason: e.to_string(),
            },
            RusqliteError::FromSqlConversionFailure(idx, sql_type, source_err) => {
                XqliteError::FromSqlConversionFailure {
                    index: idx,
                    sqlite_type: sqlite_type_to_atom(sql_type),
                    reason: source_err.to_string(),
                }
            }
            RusqliteError::IntegralValueOutOfRange(idx, val) => {
                XqliteError::IntegralValueOutOfRange {
                    index: idx,
                    value: val,
                }
            }
            RusqliteError::ToSqlConversionFailure(e) => XqliteError::ToSqlConversionFailure {
                reason: e.to_string(),
            },
            RusqliteError::InvalidColumnIndex(idx) => XqliteError::InvalidColumnIndex(idx),
            RusqliteError::InvalidColumnName(name) => XqliteError::InvalidColumnName(name),
            RusqliteError::InvalidColumnType(idx, name, sql_type) => {
                XqliteError::InvalidColumnType {
                    index: idx,
                    name,
                    sqlite_type: sqlite_type_to_atom(sql_type),
                }
            }
            RusqliteError::MultipleStatement => XqliteError::MultipleStatements,

            // --- Final Catch-all for any other rusqlite::Error types ---
            other_err => {
                let message_string = other_err.to_string();
                if message_string == "interrupted" {
                    XqliteError::OperationCancelled
                } else {
                    XqliteError::CannotExecute(message_string)
                }
            }
        }
    }
}
