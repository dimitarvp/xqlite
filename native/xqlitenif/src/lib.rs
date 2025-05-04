rustler::atoms! {
    asc,
    atom,
    binary,
    cannot_convert_atom_to_string,
    cannot_convert_to_sqlite_value,
    cannot_execute,
    cannot_execute_pragma,
    cannot_fetch_row,
    cannot_open_database,
    cannot_prepare_statement,
    cascade,
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
    create_index,
    database_busy_or_locked,
    desc,
    error,
    execute_returned_results,
    expected,
    expected_keyword_list,
    expected_keyword_tuple,
    expected_list,
    float,
    from_sql_conversion_failure,
    full,
    function,
    index_exists,
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
    no_action,
    no_such_index,
    no_such_table,
    no_value,
    none,
    null_byte_in_string,
    num_rows,
    numeric,
    offset,
    operation_cancelled,
    partial,
    pid,
    port,
    primary_key_constraint,
    provided,
    read_only_database,
    reference,
    restrict,
    rows,
    schema_changed,
    schema_parsing_error,
    sequence,
    set_default,
    set_null,
    shadow,
    simple,
    sql,
    sql_input_error,
    sqlite_failure,
    table,
    table_exists,
    text,
    to_sql_conversion_failure,
    tuple,
    unexpected_value,
    unique_constraint,
    unknown,
    unsupported_atom,
    unsupported_data_type,
    utf8_error,
    r#virtual,
    view
}

use rusqlite::{ffi, types::Value, Connection, Error as RusqliteError, Rows, ToSql};
use rustler::types::atom::{false_, nil, true_};
use rustler::types::map::map_new;
use rustler::{
    resource_impl, Atom, Binary, Encoder, Env, Error as RustlerError, ListIterator, NifStruct,
    Resource, ResourceArc, Term, TermType,
};
use std::convert::TryFrom;
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

#[derive(Debug, Clone, NifStruct)]
#[module = "Xqlite.Schema.DatabaseInfo"]
pub(crate) struct DatabaseInfo {
    pub name: String,
    pub file: Option<String>,
}

#[derive(Debug, Clone, NifStruct)]
#[module = "Xqlite.Schema.SchemaObjectInfo"]
pub(crate) struct SchemaObjectInfo {
    pub schema: String,
    pub name: String,
    pub object_type: Atom,
    pub column_count: i64,
    pub is_writable: bool,
    pub strict: bool,
}

#[derive(Debug, Clone, NifStruct)]
#[module = "Xqlite.Schema.ColumnInfo"]
pub(crate) struct ColumnInfo {
    pub column_id: i64,
    pub name: String,
    pub type_affinity: Atom,
    pub declared_type: String,
    pub nullable: bool,
    pub default_value: Option<String>,
    pub primary_key_index: u8,
}

#[derive(Debug, Clone, NifStruct)]
#[module = "Xqlite.Schema.ForeignKeyInfo"]
pub(crate) struct ForeignKeyInfo {
    pub id: i64,
    pub column_sequence: i64,
    pub target_table: String,
    pub from_column: String,
    pub to_column: String,
    pub on_update: Atom,
    pub on_delete: Atom,
    pub match_clause: Atom,
}

#[derive(Debug, Clone, NifStruct)]
#[module = "Xqlite.Schema.IndexInfo"]
pub(crate) struct IndexInfo {
    pub name: String,
    pub unique: bool,
    pub origin: Atom,
    pub partial: bool,
}

#[derive(Debug, Clone, NifStruct)]
#[module = "Xqlite.Schema.IndexColumnInfo"]
pub(crate) struct IndexColumnInfo {
    pub index_column_sequence: i64,
    pub table_column_id: i64,
    pub name: Option<String>,
    pub sort_order: Atom,
    pub collation: String,
    pub is_key_column: bool,
}

// Details for schema parsing errors.
#[derive(Debug, Clone)]
pub(crate) enum SchemaErrorDetail {
    UnexpectedValue(String), // Holds the raw unexpected string from PRAGMA/query
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
    // Use alias RusqliteError for brevity
    fn from(err: RusqliteError) -> Self {
        match err {
            // --- Handle SqliteFailure: Map specific C API codes first ---
            RusqliteError::SqliteFailure(ffi_err, msg_opt) => {
                // Compute the definitive error message string ONCE.
                // Clone msg_opt if present, otherwise use ffi_err string.
                let message_string = msg_opt.unwrap_or_else(|| ffi_err.to_string());

                // Use the primary C API result code (ffi_err.code as i32)
                match ffi_err.code as i32 {
                    // --- Directly mapped Operational Errors ---
                    ffi::SQLITE_BUSY | ffi::SQLITE_LOCKED => {
                        XqliteError::DatabaseBusyOrLocked {
                            // Use the computed message string
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

                    // --- Errors often related to object existence ---
                    ffi::SQLITE_ERROR => {
                        // Primary code 1
                        // Check extended code for constraints first
                        if let Some(kind_atom) =
                            constraint_kind_to_atom_extended(ffi_err.extended_code)
                        {
                            XqliteError::ConstraintViolation {
                                kind: Some(kind_atom),
                                message: message_string,
                            }
                        } else {
                            // Check common messages for specific errors mapped from SQLITE_ERROR
                            let lower_msg = message_string.to_lowercase(); // Use computed string
                            if lower_msg.starts_with("no such table") {
                                XqliteError::NoSuchTable {
                                    message: message_string,
                                }
                            } else if lower_msg.starts_with("no such index") {
                                XqliteError::NoSuchIndex {
                                    message: message_string,
                                }
                            } else if lower_msg.contains("already exists") {
                                if lower_msg.starts_with("table") {
                                    XqliteError::TableExists {
                                        message: message_string,
                                    }
                                } else if lower_msg.starts_with("index") {
                                    XqliteError::IndexExists {
                                        message: message_string,
                                    }
                                } else {
                                    XqliteError::SqliteFailure {
                                        code: 1,
                                        extended_code: ffi_err.extended_code,
                                        message: Some(message_string),
                                    }
                                }
                            } else {
                                // Fallback for generic SQLITE_ERROR(1)
                                XqliteError::SqliteFailure {
                                    code: 1,
                                    extended_code: ffi_err.extended_code,
                                    message: Some(message_string),
                                }
                            }
                        }
                    }

                    // --- Fallback for other unmapped SQLite codes ---
                    other_code => {
                        // Use variable name `other_code` for clarity
                        // Check constraints again just in case
                        if let Some(kind_atom) =
                            constraint_kind_to_atom_extended(ffi_err.extended_code)
                        {
                            XqliteError::ConstraintViolation {
                                kind: Some(kind_atom),
                                message: message_string,
                            }
                        } else {
                            // Truly unmapped SQLite error code
                            XqliteError::SqliteFailure {
                                code: other_code, // Use the actual code
                                extended_code: ffi_err.extended_code,
                                message: Some(message_string), // Use computed string
                            }
                        }
                    }
                }
            } // End SqliteFailure arm

            // --- Handle other specific rusqlite::Error variants ---
            // (No changes needed here from the previous version)
            RusqliteError::ExecuteReturnedResults => XqliteError::ExecuteReturnedResults,
            RusqliteError::InvalidParameterCount(p, e) => XqliteError::InvalidParameterCount {
                provided: p,
                expected: e,
            },
            RusqliteError::InvalidParameterName(n) => XqliteError::InvalidParameterName(n),
            RusqliteError::NulError(_) => XqliteError::NulErrorInString,
            RusqliteError::Utf8Error(e) => XqliteError::Utf8Error {
                reason: e.to_string(),
            },
            RusqliteError::FromSqlConversionFailure(idx, st, e) => {
                XqliteError::FromSqlConversionFailure {
                    index: idx,
                    sqlite_type: sqlite_type_to_atom(st),
                    reason: e.to_string(),
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
            RusqliteError::InvalidColumnName(n) => XqliteError::InvalidColumnName(n),
            RusqliteError::InvalidColumnType(idx, n, st) => XqliteError::InvalidColumnType {
                index: idx,
                name: n,
                sqlite_type: sqlite_type_to_atom(st),
            },
            RusqliteError::SqlInputError {
                error,
                msg,
                sql,
                offset,
            } => XqliteError::SqlInputError {
                code: error.code as i32,
                message: msg,
                sql,
                offset,
            },
            RusqliteError::MultipleStatement => XqliteError::MultipleStatements,
            // Catch-all
            other_err => XqliteError::CannotExecute(other_err.to_string()),
        } // End match err
    } // End from
} // End impl

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

fn format_term_for_pragma<'a>(env: Env<'a>, term: Term<'a>) -> Result<String, XqliteError> {
    // Based on elixir_term_to_rusqlite_value, but produces SQL literal strings
    let term_type = term.get_type();
    match term_type {
        TermType::Atom => {
            if term == nil().to_term(env) {
                Ok("NULL".to_string())
            } else if term == true_().to_term(env) {
                Ok("ON".to_string()) // Common PRAGMA boolean values
            } else if term == false_().to_term(env) {
                Ok("OFF".to_string()) // Common PRAGMA boolean values
            } else {
                // Allow other atoms if they represent valid PRAGMA keywords (like WAL, DELETE)
                term.atom_to_string()
                    .map_err(|e| XqliteError::CannotConvertAtomToString(format!("{:?}", e)))
            }
        }
        TermType::Integer => term
            .decode::<i64>()
            .map(|i| i.to_string()) // Convert integer directly to string
            .map_err(|e| XqliteError::CannotConvertToSqliteValue {
                value_str: format!("{:?}", term),
                reason: format!("{:?}", e),
            }),
        // Floats are usually not set via PRAGMA, but handle just in case
        TermType::Float => term.decode::<f64>().map(|f| f.to_string()).map_err(|e| {
            XqliteError::CannotConvertToSqliteValue {
                value_str: format!("{:?}", term),
                reason: format!("{:?}", e),
            }
        }),
        // Binaries interpreted as Strings, need single quotes
        TermType::Binary => term
            .decode::<String>()
            .map(|s| format!("'{}'", s.replace('\'', "''"))) // Single quote and escape
            .map_err(|e| XqliteError::CannotConvertToSqliteValue {
                value_str: format!("{:?}", term),
                reason: format!("Failed to decode binary as string for PRAGMA: {:?}", e),
            }),
        _ => Err(XqliteError::UnsupportedDataType { term_type }),
    }
}

fn process_rows<'a, 'rows>(
    env: Env<'a>,
    mut rows: Rows<'rows>, // Takes ownership of `rows`
    column_count: usize,
) -> Result<Vec<Vec<Term<'a>>>, XqliteError> {
    let mut results: Vec<Vec<Term<'a>>> = Vec::new();

    loop {
        match rows.next() {
            Ok(Some(row)) => {
                // Got a row
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
                // No more rows
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

#[inline]
fn quote_savepoint_name(name: &str) -> String {
    format!("'{}'", name.replace('\'', "''"))
}

/// Maps PRAGMA table_list type string to an atom.
#[inline]
fn object_type_to_atom(s: &str) -> Result<Atom, &str> {
    match s {
        "table" => Ok(table()),
        "view" => Ok(view()),
        "shadow" => Ok(shadow()),
        "virtual" => Ok(r#virtual()),
        "sequence" => Ok(sequence()),
        _ => Err(s),
    }
}

/// Maps PRAGMA table_info type affinity string to an atom.
#[inline]
fn type_affinity_to_atom(s: &str) -> Result<Atom, &str> {
    match s {
        "TEXT" => Ok(text()),
        "NUMERIC" => Ok(numeric()),
        "INTEGER" => Ok(integer()),
        "REAL" => Ok(float()),
        "BLOB" => Ok(binary()),
        // NOTE: "NONE" affinity technically exists but is resolved to BLOB
        // by SQLite before PRAGMA table_info reports it.
        _ => Err(s),
    }
}

/// Maps PRAGMA foreign_key_list action string to an atom.
#[inline]
fn fk_action_to_atom(s: &str) -> Result<Atom, &str> {
    match s {
        "NO ACTION" => Ok(no_action()),
        "RESTRICT" => Ok(restrict()),
        "SET NULL" => Ok(set_null()),
        "SET DEFAULT" => Ok(set_default()),
        "CASCADE" => Ok(cascade()),
        _ => Err(s),
    }
}

/// Maps PRAGMA foreign_key_list match string to an atom.
#[inline]
fn fk_match_to_atom(s: &str) -> Result<Atom, &str> {
    match s {
        "NONE" => Ok(none()),
        "SIMPLE" => Ok(simple()),
        "PARTIAL" => Ok(partial()),
        "FULL" => Ok(full()),
        _ => Err(s),
    }
}

/// Maps PRAGMA index_list origin char to a descriptive atom.
#[inline]
fn index_origin_to_atom(s: &str) -> Result<Atom, &str> {
    match s {
        "c" => Ok(create_index()),
        "u" => Ok(unique_constraint()),
        "pk" => Ok(primary_key_constraint()),
        _ => Err(s),
    }
}

/// Maps PRAGMA index_xinfo sort order value (0/1) to an atom.
/// Assumes the input 'val' is derived from an integer column.
#[inline]
fn sort_order_to_atom(val: i64) -> Result<Atom, String> {
    // Final version returns Result<Atom, String>
    match val {
        0 => Ok(asc()),
        1 => Ok(desc()),
        _ => Err(val.to_string()), // Convert unexpected i64 to String for consistent error detail
    }
}

/// Quotes an identifier (like table name) for safe inclusion in PRAGMA commands
/// where strings are accepted. Uses single quotes for consistency.
#[inline]
fn quote_identifier(name: &str) -> String {
    format!("'{}'", name.replace('\'', "''"))
}

/// Converts the 'notnull' integer flag from PRAGMA table_info to a boolean 'nullable'.
/// Returns Err with the unexpected value as String if input is not 0 or 1.
#[inline]
fn notnull_to_nullable(notnull_flag: i64) -> Result<bool, String> {
    match notnull_flag {
        0 => Ok(true),                      // 0 means NULL allowed -> nullable = true
        1 => Ok(false),                     // 1 means NOT NULL -> nullable = false
        _ => Err(notnull_flag.to_string()), // Unexpected value
    }
}

/// Converts the 'pk' integer flag from PRAGMA table_info to a u8 index.
/// Returns Err with the unexpected value as String if input is negative or > 255.
#[inline]
fn pk_value_to_index(pk_flag: i64) -> Result<u8, String> {
    u8::try_from(pk_flag).map_err(|_| pk_flag.to_string()) // Handles negative and overflow
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
fn open(path: String) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let conn = Connection::open(&path)
        .map_err(|e| XqliteError::CannotOpenDatabase(path, e.to_string()))?;
    let arc_mutex_conn = Arc::new(Mutex::new(conn));
    Ok(ResourceArc::new(XqliteConn(arc_mutex_conn)))
}

#[rustler::nif(schedule = "DirtyIo")]
fn open_in_memory(uri: String) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let conn = Connection::open(&uri)
        .map_err(|e| XqliteError::CannotOpenDatabase(uri, e.to_string()))?;
    let arc_mutex_conn = Arc::new(Mutex::new(conn));
    Ok(ResourceArc::new(XqliteConn(arc_mutex_conn)))
}

#[rustler::nif(schedule = "DirtyIo")]
fn open_temporary() -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let conn = Connection::open("")
        .map_err(|e| XqliteError::CannotOpenDatabase("".to_string(), e.to_string()))?;
    let arc_mutex_conn = Arc::new(Mutex::new(conn));
    Ok(ResourceArc::new(XqliteConn(arc_mutex_conn)))
}

#[rustler::nif(schedule = "DirtyIo")]
fn query<'a>(
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
fn execute<'a>(
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
fn execute_batch(
    handle: ResourceArc<XqliteConn>,
    sql_batch: String,
) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        conn.execute_batch(&sql_batch)?;
        Ok(true)
    })
}

/// Reads the current value of an SQLite PRAGMA.
#[rustler::nif(schedule = "DirtyIo")]
fn get_pragma(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    pragma_name: String,
) -> Result<Term<'_>, XqliteError> {
    // This function contains the logic previously in Step 2 of pragma_write_and_read
    with_conn(&handle, |conn| {
        // Assuming with_conn is available (e.g., pub(crate) in util.rs)
        let read_sql = format!("PRAGMA {};", pragma_name);
        match conn.query_row(&read_sql, [], |row| row.get::<usize, Value>(0)) {
            Ok(value) => Ok(encode_val(env, value)), // Assuming encode_val is available
            Err(RusqliteError::QueryReturnedNoRows) => Ok(no_value().to_term(env)), // Use atoms module
            Err(e) => Err(XqliteError::CannotExecutePragma {
                pragma: read_sql,
                reason: e.to_string(),
            }),
        }
    })
}

/// Sets an SQLite PRAGMA to a specific value.
/// Returns {:ok, true} on success, or {:error, reason} on failure.
/// Does NOT return the new value; call get_pragma separately if needed for verification.
#[rustler::nif(schedule = "DirtyIo")]
fn set_pragma<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    pragma_name: String,
    value_term: Term<'a>,
) -> Result<bool, XqliteError> {
    // Returns bool now
    // Convert Elixir term to SQL literal string suitable for PRAGMA value
    let value_literal = format_term_for_pragma(env, value_term)?;

    with_conn(&handle, |conn| {
        // Construct the full SQL command for setting the PRAGMA.
        let write_sql = format!("PRAGMA {} = {};", pragma_name, value_literal);
        {
            // Scope for statement finalization via Drop
            // Prepare the statement. This can fail (e.g., syntax error in pragma name).
            let mut write_stmt =
                conn.prepare(&write_sql)
                    .map_err(|e| XqliteError::CannotExecutePragma {
                        // Use the fully formatted SQL in the error context.
                        pragma: write_sql.clone(),
                        reason: e.to_string(),
                    })?;

            // Execute using query([]), immediately consuming and discarding the Rows iterator.
            // This robustly handles PRAGMA SET commands regardless of whether they
            // internally return rows or not, using only public rusqlite API.
            // The '?' propagates any execution errors (like constraint issues, invalid values).
            let _ = write_stmt.query([])?;

            // If query([]) succeeded, the PRAGMA SET command executed without error.
            // Statement finalized automatically when write_stmt goes out of scope here.
        }
        Ok(true) // Return simple success if no error occurred
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn begin(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        conn.execute("BEGIN;", [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn commit(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        conn.execute("COMMIT;", [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn rollback(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        conn.execute("ROLLBACK;", [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn savepoint(handle: ResourceArc<XqliteConn>, name: String) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        let quoted_name = quote_savepoint_name(&name);
        let sql = format!("SAVEPOINT {};", quoted_name);
        conn.execute(&sql, [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn rollback_to_savepoint(
    handle: ResourceArc<XqliteConn>,
    name: String,
) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        let quoted_name = quote_savepoint_name(&name);
        let sql = format!("ROLLBACK TO SAVEPOINT {};", quoted_name);
        conn.execute(&sql, [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn release_savepoint(
    handle: ResourceArc<XqliteConn>,
    name: String,
) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        let quoted_name = quote_savepoint_name(&name);
        let sql = format!("RELEASE SAVEPOINT {};", quoted_name);
        conn.execute(&sql, [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_databases(
    handle: ResourceArc<XqliteConn>,
) -> Result<Vec<DatabaseInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        let mut stmt = conn.prepare("PRAGMA database_list;")?;

        let db_infos: Vec<DatabaseInfo> = stmt
            .query_map([], |row| {
                // PRAGMA database_list columns: seq(0), name(1), file(2)
                let name: String = row.get(1)?;
                let file: Option<String> = row.get(2)?;
                Ok(DatabaseInfo { name, file })
            })? // Propagate errors from query_map (e.g., statement execution)
            .collect::<Result<Vec<_>, _>>()?; // Collect results, propagating row mapping errors

        Ok(db_infos)
    })
}

/// Temporary struct for holding intermediate results during object list parsing.
#[derive(Debug)]
struct TempObjectInfo {
    schema: String,
    name: String,
    obj_type_atom: Result<Atom, String>,
    column_count: i64,
    wr_flag: i64,     // Raw value from PRAGMA 'wr' column (0 or 1)
    strict_flag: i64, // Raw value from PRAGMA 'strict' column (0 or 1)
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_list_objects(
    handle: ResourceArc<XqliteConn>,
    schema: Option<String>,
) -> Result<Vec<SchemaObjectInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        let sql = "PRAGMA table_list;";
        let mut stmt = conn.prepare(sql)?;

        // Step 1: Query and map, returning Vec<Result<TempObjectInfo, rusqlite::Error>>
        let temp_results: Vec<Result<TempObjectInfo, rusqlite::Error>> = stmt
            .query_map([], |row| {
                // PRAGMA table_list columns: schema(0), name(1), type(2), ncol(3), wr(4), strict(5)
                let obj_schema: String = row.get(0)?;
                let obj_name: String = row.get(1)?;
                let obj_type_str: String = row.get(2)?;
                let column_count: i64 = row.get(3)?;
                let wr_flag: i64 = row.get(4)?;
                let strict_flag: i64 = row.get(5)?;

                let obj_type_atom_result =
                    object_type_to_atom(&obj_type_str).map_err(|s| s.to_string());

                Ok(TempObjectInfo {
                    schema: obj_schema,
                    name: obj_name,
                    obj_type_atom: obj_type_atom_result,
                    column_count,
                    wr_flag,
                    strict_flag,
                })
            })?
            .collect();

        // Step 2: Process results, apply filter, and map errors
        let mut final_objects: Vec<SchemaObjectInfo> = Vec::new();
        for temp_result in temp_results {
            match temp_result {
                Ok(temp_info) => {
                    // Apply schema filter
                    if let Some(filter_schema) = &schema {
                        if temp_info.schema != *filter_schema {
                            continue;
                        }
                    }

                    // Finalize atom conversion
                    let atom = match temp_info.obj_type_atom {
                        Ok(atom) => atom,
                        Err(unexpected_val) => {
                            return Err(XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing object type for '{}'.'{}'",
                                    temp_info.schema, temp_info.name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    unexpected_val,
                                ),
                            });
                        }
                    };

                    // Convert wr_flag (0/1) to boolean
                    let is_writable = match temp_info.wr_flag {
                        0 => false,
                        1 => true,
                        _ => {
                            return Err(XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'wr' flag for object '{}'.'{}'",
                                    temp_info.schema, temp_info.name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    temp_info.wr_flag.to_string(),
                                ),
                            })
                        }
                    };

                    // Convert strict_flag (0/1) to boolean
                    let is_strict = match temp_info.strict_flag {
                        0 => false,
                        1 => true,
                        _ => {
                            return Err(XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'strict' flag for object '{}'.'{}'",
                                    temp_info.schema, temp_info.name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    temp_info.strict_flag.to_string(),
                                ),
                            })
                        }
                    };

                    final_objects.push(SchemaObjectInfo {
                        schema: temp_info.schema,
                        name: temp_info.name,
                        object_type: atom,
                        column_count: temp_info.column_count,
                        is_writable,
                        strict: is_strict,
                    });
                }
                Err(rusqlite_err) => {
                    return Err(rusqlite_err.into());
                }
            }
        }

        Ok(final_objects)
    })
}

/// Temporary struct for holding intermediate results during column info parsing.
#[derive(Debug)]
struct TempColumnData {
    cid: i64,
    name: String,
    type_str: String, // This holds the original declared type string
    notnull_flag: i64,
    dflt_value: Option<String>,
    pk_flag: i64,
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_columns(
    handle: ResourceArc<XqliteConn>,
    table_name: String,
) -> Result<Vec<ColumnInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        // Quote table name for safety in PRAGMA
        let quoted_table_name = quote_identifier(&table_name);
        let sql = format!("PRAGMA table_info({});", quoted_table_name);
        let mut stmt = conn.prepare(&sql)?;

        // Step 1: Query and map raw data, returning Vec<Result<TempColumnData, rusqlite::Error>>
        let temp_results: Vec<Result<TempColumnData, rusqlite::Error>> = stmt
            .query_map([], |row| {
                // Inside query_map, return Result<_, rusqlite::Error>
                Ok(TempColumnData {
                    cid: row.get(0)?,
                    name: row.get(1)?,
                    type_str: row.get(2)?,
                    notnull_flag: row.get(3)?,
                    dflt_value: row.get(4)?,
                    pk_flag: row.get(5)?,
                })
            })? // Handles rusqlite errors from prepare/query
            .collect(); // Collect into Vec<Result<TempColumnData, rusqlite::Error>>

        // Step 2: Process results, validate/convert, and map errors
        let mut final_columns: Vec<ColumnInfo> = Vec::with_capacity(temp_results.len());
        for temp_result in temp_results {
            match temp_result {
                Ok(temp_data) => {
                    // Perform conversions using helpers, mapping errors to SchemaParsingError
                    let type_affinity_atom = type_affinity_to_atom(&temp_data.type_str)
                        .map_err(|unexpected_val| XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing type affinity for column '{}' in table '{}'",
                                temp_data.name, table_name
                            ),
                            error_detail: SchemaErrorDetail::UnexpectedValue(
                                unexpected_val.to_string(),
                            ),
                        })?;

                    let nullable = notnull_to_nullable(temp_data.notnull_flag).map_err(
                        |unexpected_val| XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'notnull' flag for column '{}' in table '{}'",
                                temp_data.name, table_name
                            ),
                            error_detail: SchemaErrorDetail::UnexpectedValue(unexpected_val),
                        },
                    )?;

                    let primary_key_index =
                        pk_value_to_index(temp_data.pk_flag).map_err(|unexpected_val| {
                            XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'pk' flag for column '{}' in table '{}'",
                                    temp_data.name, table_name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    unexpected_val,
                                ),
                            }
                        })?;

                    // Construct final struct if all conversions succeeded
                    final_columns.push(ColumnInfo {
                        column_id: temp_data.cid,
                        name: temp_data.name,
                        type_affinity: type_affinity_atom,
                        declared_type: temp_data.type_str, // Assign the original type string
                        nullable,
                        default_value: temp_data.dflt_value,
                        primary_key_index,
                    });
                }
                Err(rusqlite_err) => {
                    // Propagate rusqlite errors encountered during row mapping
                    return Err(rusqlite_err.into()); // Use From trait
                }
            }
        }

        Ok(final_columns)
    })
}

/// Temporary struct for holding intermediate results during foreign key parsing.
#[derive(Debug)]
struct TempForeignKeyData {
    id: i64,
    seq: i64,
    table: String,
    from: String,
    to: String,
    on_update_str: String,
    on_delete_str: String,
    match_str: String,
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_foreign_keys(
    handle: ResourceArc<XqliteConn>,
    table_name: String,
) -> Result<Vec<ForeignKeyInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        let quoted_table_name = quote_identifier(&table_name);
        let sql = format!("PRAGMA foreign_key_list({});", quoted_table_name);
        let mut stmt = conn.prepare(&sql)?;

        // Step 1: Query and map raw data
        let temp_results: Vec<Result<TempForeignKeyData, rusqlite::Error>> = stmt
            .query_map([], |row| {
                // PRAGMA foreign_key_list columns:
                // id(0), seq(1), table(2), from(3), to(4), on_update(5), on_delete(6), match(7)
                Ok(TempForeignKeyData {
                    id: row.get(0)?,
                    seq: row.get(1)?,
                    table: row.get(2)?,
                    from: row.get(3)?,
                    to: row.get(4)?, // Column 'to' can be NULL for FKs targeting a UNIQUE constraint not on the PK
                    on_update_str: row.get(5)?,
                    on_delete_str: row.get(6)?,
                    match_str: row.get(7)?,
                })
            })?
            .collect();

        // Step 2: Process results, convert strings to atoms, map errors
        let mut final_fks: Vec<ForeignKeyInfo> = Vec::with_capacity(temp_results.len());
        for temp_result in temp_results {
            match temp_result {
                Ok(temp_data) => {
                    // Perform atom conversions, mapping errors
                    let on_update_atom = fk_action_to_atom(&temp_data.on_update_str).map_err(
                        |unexpected_val| XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'on_update' action for FK id {} on table '{}'",
                                temp_data.id, table_name
                            ),
                            error_detail: SchemaErrorDetail::UnexpectedValue(
                                unexpected_val.to_string(),
                            ),
                        },
                    )?;

                    let on_delete_atom = fk_action_to_atom(&temp_data.on_delete_str).map_err(
                        |unexpected_val| XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'on_delete' action for FK id {} on table '{}'",
                                temp_data.id, table_name
                            ),
                            error_detail: SchemaErrorDetail::UnexpectedValue(
                                unexpected_val.to_string(),
                            ),
                        },
                    )?;

                    let match_clause_atom =
                        fk_match_to_atom(&temp_data.match_str).map_err(|unexpected_val| {
                            XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'match' clause for FK id {} on table '{}'",
                                    temp_data.id, table_name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    unexpected_val.to_string(),
                                ),
                            }
                        })?;

                    // Construct final struct
                    final_fks.push(ForeignKeyInfo {
                        id: temp_data.id,
                        column_sequence: temp_data.seq,
                        target_table: temp_data.table,
                        from_column: temp_data.from,
                        to_column: temp_data.to, // Keep as String, handles NULL from get()
                        on_update: on_update_atom,
                        on_delete: on_delete_atom,
                        match_clause: match_clause_atom,
                    });
                }
                Err(rusqlite_err) => {
                    // Propagate rusqlite errors
                    return Err(rusqlite_err.into());
                }
            }
        }

        Ok(final_fks)
    })
}

/// Temporary struct for holding intermediate results during index list parsing.
#[derive(Debug)]
struct TempIndexData {
    // seq: i64, // Sequence number of index, typically not needed by user
    name: String,
    unique: i64,        // PRAGMA returns 0 or 1
    origin_str: String, // PRAGMA returns 'c', 'u', 'pk'
    partial: i64,       // PRAGMA returns 0 or 1
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_indexes(
    handle: ResourceArc<XqliteConn>,
    table_name: String,
) -> Result<Vec<IndexInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        let quoted_table_name = quote_identifier(&table_name);
        let sql = format!("PRAGMA index_list({});", quoted_table_name);
        let mut stmt = conn.prepare(&sql)?;

        // Step 1: Query and map raw data
        let temp_results: Vec<Result<TempIndexData, rusqlite::Error>> = stmt
            .query_map([], |row| {
                // PRAGMA index_list columns: seq(0), name(1), unique(2), origin(3), partial(4)
                Ok(TempIndexData {
                    name: row.get(1)?,
                    unique: row.get(2)?,
                    origin_str: row.get(3)?,
                    partial: row.get(4)?,
                })
            })?
            .collect();

        // Step 2: Process results, convert values, map errors
        let mut final_indexes: Vec<IndexInfo> = Vec::with_capacity(temp_results.len());
        for temp_result in temp_results {
            match temp_result {
                Ok(temp_data) => {
                    // Convert origin string to atom
                    let origin_atom = index_origin_to_atom(&temp_data.origin_str).map_err(
                        |unexpected_val| XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'origin' for index '{}' on table '{}'",
                                temp_data.name, table_name
                            ),
                            error_detail: SchemaErrorDetail::UnexpectedValue(
                                unexpected_val.to_string(),
                            ),
                        },
                    )?;

                    // Convert integer flags to booleans (simple check)
                    let unique_bool = match temp_data.unique {
                        0 => false,
                        1 => true,
                        _ => {
                            return Err(XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'unique' flag for index '{}' on table '{}'",
                                    temp_data.name, table_name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    temp_data.unique.to_string(),
                                ),
                            })
                        }
                    };
                    let partial_bool = match temp_data.partial {
                        0 => false,
                        1 => true,
                        _ => {
                            return Err(XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'partial' flag for index '{}' on table '{}'",
                                    temp_data.name, table_name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    temp_data.partial.to_string(),
                                ),
                            })
                        }
                    };

                    // Construct final struct
                    final_indexes.push(IndexInfo {
                        name: temp_data.name,
                        unique: unique_bool,
                        origin: origin_atom,
                        partial: partial_bool,
                    });
                }
                Err(rusqlite_err) => {
                    // Propagate rusqlite errors
                    return Err(rusqlite_err.into());
                }
            }
        }

        Ok(final_indexes)
    })
}

/// Temporary struct for holding intermediate results during index column parsing.
#[derive(Debug)]
struct TempIndexColumnData {
    seqno: i64,
    cid: i64,             // Column ID in table, often -1 for expressions
    name: Option<String>, // Name is NULL for expressions
    desc: i64,            // Sort order: 0=ASC, 1=DESC
    coll: String,         // Collation sequence name
    key: i64,             // Key column (1) or included column (0)
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_index_columns(
    handle: ResourceArc<XqliteConn>,
    index_name: String,
) -> Result<Vec<IndexColumnInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        let quoted_index_name = quote_identifier(&index_name);
        let sql = format!("PRAGMA index_xinfo({});", quoted_index_name);
        let mut stmt = conn.prepare(&sql)?;

        // Step 1: Query and map raw data
        let temp_results: Vec<Result<TempIndexColumnData, rusqlite::Error>> = stmt
            .query_map([], |row| {
                // PRAGMA index_xinfo columns:
                // seqno(0), cid(1), name(2), desc(3), coll(4), key(5)
                Ok(TempIndexColumnData {
                    seqno: row.get(0)?,
                    cid: row.get(1)?,
                    name: row.get(2)?,
                    desc: row.get(3)?,
                    coll: row.get(4)?,
                    key: row.get(5)?,
                })
            })?
            .collect();

        // Step 2: Process results, convert values, map errors
        let mut final_cols: Vec<IndexColumnInfo> = Vec::with_capacity(temp_results.len());
        for temp_result in temp_results {
            match temp_result {
                Ok(temp_data) => {
                    // Convert sort order flag to atom
                    let sort_order_atom =
                        sort_order_to_atom(temp_data.desc).map_err(|unexpected_val| {
                            XqliteError::SchemaParsingError {
                                context: format!(
                                "Parsing sort order ('desc') for column seq {} in index '{}'",
                                temp_data.seqno, index_name
                            ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    unexpected_val,
                                ),
                            }
                        })?;

                    // Convert key flag to boolean
                    let is_key_bool = match temp_data.key {
                        0 => false, // Included column
                        1 => true,  // Key column
                        _ => {
                            return Err(XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'key' flag for column seq {} in index '{}'",
                                    temp_data.seqno, index_name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    temp_data.key.to_string(),
                                ),
                            })
                        }
                    };

                    // Construct final struct
                    final_cols.push(IndexColumnInfo {
                        index_column_sequence: temp_data.seqno,
                        table_column_id: temp_data.cid,
                        name: temp_data.name,
                        sort_order: sort_order_atom,
                        collation: temp_data.coll,
                        is_key_column: is_key_bool,
                    });
                }
                Err(rusqlite_err) => {
                    return Err(rusqlite_err.into());
                }
            }
        }

        Ok(final_cols)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn get_create_sql(
    handle: ResourceArc<XqliteConn>,
    object_name: String,
) -> Result<Option<String>, XqliteError> {
    with_conn(&handle, |conn| {
        // Prefer sqlite_schema as it includes temporary objects,
        // but sqlite_master is the traditional one. A simple query works.
        // We don't strictly need a fallback mechanism here unless specifically required.
        // Let's use sqlite_schema for modern compatibility.
        let sql = "SELECT sql FROM sqlite_schema WHERE name = ?1 LIMIT 1;";
        let mut stmt = conn.prepare(sql)?;

        // Use query_row to expect exactly zero or one row.
        // Map the result row to Option<String>.
        let result = stmt.query_row([&object_name], |row| row.get::<usize, Option<String>>(0));

        match result {
            // Successfully found the row and got the SQL (which might be NULL in schema, hence Option)
            Ok(sql_string_option) => Ok(sql_string_option),
            // `query_row` returns this specific error if no rows were found
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            // Any other error during query execution or conversion
            Err(e) => Err(e.into()), // Convert rusqlite::Error to XqliteError
        }
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn last_insert_rowid(handle: ResourceArc<XqliteConn>) -> Result<i64, XqliteError> {
    with_conn(&handle, |conn| Ok(conn.last_insert_rowid()))
}

#[rustler::nif(schedule = "DirtyIo")]
fn close(_handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    Ok(true)
}

fn on_load(_env: Env, _info: Term) -> bool {
    true
}

rustler::init!("Elixir.XqliteNIF", load = on_load);
