use crate::{
    atom, binary, cannot_convert_atom_to_string, cannot_convert_to_sqlite_value,
    cannot_execute, cannot_execute_pragma, cannot_fetch_row, cannot_open_database,
    cannot_prepare_statement, constraint_check, constraint_commit_hook, constraint_datatype,
    constraint_foreign_key, constraint_function, constraint_not_null, constraint_pinned,
    constraint_primary_key, constraint_rowid, constraint_trigger, constraint_unique,
    constraint_violation, constraint_vtab, database_busy_or_locked, error,
    execute_returned_results, expected_keyword_list, expected_keyword_tuple, expected_list,
    float, from_sql_conversion_failure, function, index_exists, integer,
    integral_value_out_of_range, internal_encoding_error, invalid_column_index,
    invalid_column_name, invalid_column_type, invalid_parameter_count, invalid_parameter_name,
    list, lock_error, map, multiple_statements, no_such_index, no_such_table,
    null_byte_in_string, operation_cancelled, pid, port, read_only_database, reference,
    schema_changed, schema_parsing_error, sql_input_error, sqlite_failure, table_exists, text,
    to_sql_conversion_failure, tuple, unexpected_value, unknown, unsupported_atom,
    unsupported_data_type, utf8_error,
};
use rusqlite::{ffi, Error as RusqliteError};
use rustler::{
    types::{atom::nil, map::map_new},
    Atom, Encoder, Env, Term, TermType,
};
use std::fmt::{self, Display};
use std::panic::RefUnwindSafe;

#[derive(Debug, Clone)]
pub(crate) enum SchemaErrorDetail {
    UnexpectedValue(String),
}

// Based on libsqlite3-sys constants
fn constraint_kind_to_atom_extended(extended_code: i32) -> Option<Atom> {
    // Primary constraint code check
    const SQLITE_CONSTRAINT_PRIMARY: i32 = ffi::SQLITE_CONSTRAINT;

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
        code if (code & 0xff) == SQLITE_CONSTRAINT_PRIMARY => Some(constraint_violation()),

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
            XqliteError::DatabaseBusyOrLocked { message } => {
                write!(f, "Database busy or locked: {}", message)
            }
            XqliteError::OperationCancelled => {
                write!(f, "Database operation was cancelled")
            }
            XqliteError::NoSuchTable { message } => {
                write!(f, "No such table: {}", message) // Message usually includes table name
            }
            XqliteError::NoSuchIndex { message } => {
                write!(f, "No such index: {}", message) // Message usually includes index name
            }
            XqliteError::TableExists { message } => {
                write!(f, "Table already exists: {}", message) // Message usually includes table name
            }
            XqliteError::IndexExists { message } => {
                write!(f, "Index already exists: {}", message) // Message usually includes index name
            }
            XqliteError::SchemaChanged { message } => {
                write!(f, "Database schema changed: {}", message) // SQLITE_SCHEMA
            }
            XqliteError::ReadOnlyDatabase { message } => {
                write!(f, "Database is read-only: {}", message) // SQLITE_READONLY
            }
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
            XqliteError::SchemaParsingError { context, error_detail } => {
                let SchemaErrorDetail::UnexpectedValue(val) = error_detail;
                write!(f, "Schema parsing error ({})", context)?;
                write!(f, ": Unexpected value '{}'", val)
            }
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
            XqliteError::DatabaseBusyOrLocked { message } => {
                (database_busy_or_locked(), message).encode(env)
            }
            XqliteError::OperationCancelled => operation_cancelled().encode(env),
            XqliteError::NoSuchTable { message } => (no_such_table(), message).encode(env),
            XqliteError::NoSuchIndex { message } => (no_such_index(), message).encode(env),
            XqliteError::TableExists { message } => (table_exists(), message).encode(env),
            XqliteError::IndexExists { message } => (index_exists(), message).encode(env),
            XqliteError::SchemaChanged { message } => (schema_changed(), message).encode(env),
            XqliteError::ReadOnlyDatabase { message } => {
                (read_only_database(), message).encode(env)
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
                    .map_put(crate::provided(), provided)
                    .and_then(|map| map.map_put(crate::expected(), expected));
                match map_result {
                    Ok(map) => (invalid_parameter_count(), map).encode(env),
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
            XqliteError::SchemaParsingError {
                context,
                error_detail,
            } => {
                let SchemaErrorDetail::UnexpectedValue(val) = error_detail;
                let detail_term = (unexpected_value(), val).encode(env);
                (schema_parsing_error(), context, detail_term).encode(env)
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

impl From<RusqliteError> for XqliteError {
    fn from(err: RusqliteError) -> Self {
        match err {
            RusqliteError::SqliteFailure(ffi_err, msg_opt) => {
                let message_string = msg_opt.unwrap_or_else(|| ffi_err.to_string());
                let lower_msg = message_string.to_lowercase();

                // Prioritize the SQLITE_READONLY check
                if ffi_err.code == rusqlite::ffi::ErrorCode::ReadOnly {
                    return XqliteError::ReadOnlyDatabase {
                        message: message_string,
                    };
                }
                // As a fallback, also check message content if code wasn't explicitly ReadOnly
                // (though it should be if that's the root cause from SQLite)
                if lower_msg.contains("readonly database")
                    || lower_msg.contains("read-only database")
                {
                    return XqliteError::ReadOnlyDatabase {
                        message: message_string,
                    };
                }

                // Check common messages FIRST for logical errors often reported via code 1
                if lower_msg.starts_with("no such table") {
                    return XqliteError::NoSuchTable {
                        message: message_string,
                    };
                } else if lower_msg.starts_with("no such index") {
                    return XqliteError::NoSuchIndex {
                        message: message_string,
                    };
                } else if lower_msg.contains("already exists") {
                    if lower_msg.starts_with("table") {
                        return XqliteError::TableExists {
                            message: message_string,
                        };
                    } else if lower_msg.starts_with("index") {
                        return XqliteError::IndexExists {
                            message: message_string,
                        };
                    }
                }

                // If not a known message pattern, check primary C API codes
                match ffi_err.code as i32 {
                    ffi::SQLITE_BUSY | ffi::SQLITE_LOCKED => {
                        XqliteError::DatabaseBusyOrLocked {
                            message: message_string,
                        }
                    }
                    ffi::SQLITE_INTERRUPT => XqliteError::OperationCancelled,
                    ffi::SQLITE_READONLY => XqliteError::ReadOnlyDatabase {
                        message: message_string,
                    },
                    ffi::SQLITE_SCHEMA => XqliteError::SchemaChanged {
                        message: message_string,
                    },
                    ffi::SQLITE_CONSTRAINT => {
                        // Also check extended for constraints
                        if let Some(kind) =
                            constraint_kind_to_atom_extended(ffi_err.extended_code)
                        {
                            XqliteError::ConstraintViolation {
                                kind: Some(kind),
                                message: message_string,
                            }
                        } else {
                            // Fallback if primary is CONSTRAINT but extended unknown
                            XqliteError::SqliteFailure {
                                code: ffi::SQLITE_CONSTRAINT,
                                extended_code: ffi_err.extended_code,
                                message: Some(message_string),
                            }
                        }
                    }
                    // Add other specific primary code checks here if needed
                    _ => {
                        // Fallback for any other code, check constraints as last resort
                        if let Some(kind) =
                            constraint_kind_to_atom_extended(ffi_err.extended_code)
                        {
                            XqliteError::ConstraintViolation {
                                kind: Some(kind),
                                message: message_string,
                            }
                        } else {
                            // Generic fallback
                            XqliteError::SqliteFailure {
                                code: ffi_err.code as i32,
                                extended_code: ffi_err.extended_code,
                                message: Some(message_string),
                            }
                        }
                    }
                }
            }

            RusqliteError::SqlInputError {
                error: ffi_err,
                msg,
                sql,
                offset,
            } => {
                let lower_msg = msg.to_lowercase();
                // Check specific messages even for SqlInputError
                if lower_msg.contains("already exists") {
                    if lower_msg.starts_with("table") {
                        XqliteError::TableExists { message: msg }
                    } else if lower_msg.starts_with("index") {
                        XqliteError::IndexExists { message: msg }
                    } else {
                        XqliteError::SqlInputError {
                            code: ffi_err.code as i32,
                            message: msg,
                            sql,
                            offset,
                        }
                    }
                } else if lower_msg.starts_with("no such table") {
                    XqliteError::NoSuchTable { message: msg }
                } else {
                    XqliteError::SqlInputError {
                        code: ffi_err.code as i32,
                        message: msg,
                        sql,
                        offset,
                    }
                }
            }

            // --- Other specific rusqlite::Error variants (consuming `err`) ---
            RusqliteError::ExecuteReturnedResults => XqliteError::ExecuteReturnedResults,
            RusqliteError::InvalidParameterCount(p, e) => XqliteError::InvalidParameterCount {
                provided: p,
                expected: e,
            },
            RusqliteError::InvalidParameterName(name) => {
                XqliteError::InvalidParameterName(name)
            } // Move String
            RusqliteError::NulError(_) => XqliteError::NulErrorInString,
            RusqliteError::Utf8Error(e) => XqliteError::Utf8Error {
                reason: e.to_string(),
            }, // Allocates
            RusqliteError::FromSqlConversionFailure(idx, sql_type, source_err) => {
                // Need sqlite_type_to_atom here! Re-add it.
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
            } // Copies i64
            RusqliteError::ToSqlConversionFailure(e) => XqliteError::ToSqlConversionFailure {
                reason: e.to_string(),
            }, // Allocates
            RusqliteError::InvalidColumnIndex(idx) => XqliteError::InvalidColumnIndex(idx), // Copies usize
            RusqliteError::InvalidColumnName(name) => XqliteError::InvalidColumnName(name), // Move String
            RusqliteError::InvalidColumnType(idx, name, sql_type) => {
                // Need sqlite_type_to_atom here! Re-add it.
                XqliteError::InvalidColumnType {
                    index: idx,
                    name,
                    sqlite_type: sqlite_type_to_atom(sql_type),
                }
            }
            RusqliteError::MultipleStatement => XqliteError::MultipleStatements,

            // Catch-all MUST be last
            other_err => XqliteError::CannotExecute(other_err.to_string()), // Allocates
        }
    }
}
