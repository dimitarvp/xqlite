use crate::atoms;
use crate::constraint_parse::{self, ConstraintDetails};
use rusqlite::{Error as RusqliteError, ffi};
use rustler::{
    Atom, Encoder, Env, Term, TermType,
    types::{atom::nil, map::map_new},
};
use std::ffi::CStr;
use std::fmt::{self, Display};
use std::os::raw::c_int;
use std::panic::RefUnwindSafe;

/// The `kind` atom for a constraint failure. Every caller has already
/// matched the primary code as `SQLITE_CONSTRAINT`, so the last arm always
/// answers: a bare 19 (a virtual table's own check, for one) and any
/// extended constraint code this build does not know both land there.
fn constraint_kind_to_atom_extended(extended_code: i32) -> Atom {
    match extended_code {
        ffi::SQLITE_CONSTRAINT_CHECK => atoms::constraint_check(),
        ffi::SQLITE_CONSTRAINT_COMMITHOOK => atoms::constraint_commit_hook(),
        ffi::SQLITE_CONSTRAINT_FOREIGNKEY => atoms::constraint_foreign_key(),
        ffi::SQLITE_CONSTRAINT_FUNCTION => atoms::constraint_function(),
        ffi::SQLITE_CONSTRAINT_NOTNULL => atoms::constraint_not_null(),
        ffi::SQLITE_CONSTRAINT_PRIMARYKEY => atoms::constraint_primary_key(),
        ffi::SQLITE_CONSTRAINT_ROWID => atoms::constraint_rowid(),
        ffi::SQLITE_CONSTRAINT_TRIGGER => atoms::constraint_trigger(),
        ffi::SQLITE_CONSTRAINT_UNIQUE => atoms::constraint_unique(),
        ffi::SQLITE_CONSTRAINT_VTAB => atoms::constraint_vtab(),
        ffi::SQLITE_CONSTRAINT_PINNED => atoms::constraint_pinned(),
        ffi::SQLITE_CONSTRAINT_DATATYPE => atoms::constraint_datatype(),
        _ => atoms::constraint_violation(),
    }
}

/// The text after an ASCII prefix, matched without regard to case. The
/// classifier tests its prefixes on a lowercase copy of the message; the
/// prefixes are ASCII, so the copy and the original agree byte for byte
/// over them and the original's own casing survives here.
#[inline]
fn strip_ascii_prefix<'m>(message: &'m str, prefix: &str) -> Option<&'m str> {
    match message.get(..prefix.len()) {
        Some(head) if head.eq_ignore_ascii_case(prefix) => message.get(prefix.len()..),
        _ => None,
    }
}

/// The name in a `no such table: NAME` / `no such index: NAME` message.
#[inline]
fn name_after(message: &str, prefix: &str) -> String {
    strip_ascii_prefix(message, prefix)
        .unwrap_or(message)
        .to_string()
}

/// The name in a `table NAME already exists` / `index NAME already exists`
/// message.
#[inline]
fn name_between(message: &str, prefix: &str) -> String {
    let rest = strip_ascii_prefix(message, prefix).unwrap_or(message);

    rest.strip_suffix(" already exists")
        .unwrap_or(rest)
        .to_string()
}

fn option_to_term<'a>(env: Env<'a>, value: &Option<String>) -> Term<'a> {
    match value {
        Some(s) => s.as_str().encode(env),
        None => nil().encode(env),
    }
}

// Emits SQLite-vocabulary atoms (:integer, :real, :text, :blob) for constraint
// DATATYPE errors. Kept separate from `sqlite_type_to_atom` — that one is
// BEAM-flavored (:float, :binary) for column-type reporting — so that intent
// at each call site stays obvious.
fn storage_class_to_term<'a>(env: Env<'a>, t: &Option<rusqlite::types::Type>) -> Term<'a> {
    use rusqlite::types::Type;
    match t {
        Some(Type::Integer) => atoms::integer().encode(env),
        Some(Type::Real) => atoms::real().encode(env),
        Some(Type::Text) => atoms::text().encode(env),
        Some(Type::Blob) => atoms::blob().encode(env),
        Some(Type::Null) | None => nil().encode(env),
    }
}

fn term_type_to_atom(term_type: TermType) -> Atom {
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

/// The BEAM reports a bitstring as `TermType::Binary`, and the only term the
/// `Binary` decoder refuses is one whose bit size is not a whole number of
/// bytes, so a refusal from that decoder can name the case the shared table
/// cannot.
fn blob_bytes_type_atom(term_type: TermType) -> Atom {
    match term_type {
        TermType::Binary => atoms::bitstring(),
        other => term_type_to_atom(other),
    }
}

fn refusal_atom(refusal: &ListRefusal) -> Atom {
    match refusal {
        ListRefusal::NotAList => atoms::not_a_list(),
        ListRefusal::ImproperTail => atoms::improper_tail(),
        ListRefusal::BadElement { .. } => atoms::bad_element(),
    }
}

fn refusal_text(refusal: &ListRefusal) -> String {
    match refusal {
        ListRefusal::NotAList => "the term is no list".to_string(),
        ListRefusal::ImproperTail => "its tail is no list".to_string(),
        ListRefusal::BadElement { position } => {
            format!("element {position} does not belong in it")
        }
    }
}

fn encode_list_refusal<'a>(
    env: Env<'a>,
    tag: Atom,
    refusal: &ListRefusal,
    value_type: TermType,
) -> Term<'a> {
    let map_result = map_new(env)
        .map_put(atoms::reason(), refusal_atom(refusal))
        .and_then(|map| map.map_put(atoms::value_type(), term_type_to_atom(value_type)))
        .and_then(|map| match refusal {
            ListRefusal::BadElement { position } => map.map_put(atoms::position(), position),
            _no_position => Ok(map),
        });

    match map_result {
        Ok(map) => (tag, map).encode(env),
        Err(_) => {
            let err = XqliteError::InternalEncodingError {
                context: "Failed map create for a list refusal".to_string(),
            };
            err.encode(env)
        }
    }
}

/// The map carries `position` only where the value came out of a list; a
/// PRAGMA value is judged on its own and answers an empty map.
fn encode_integer_out_of_range(env: Env<'_>, position: Option<usize>) -> Term<'_> {
    let map_result = match position {
        Some(position) => map_new(env).map_put(atoms::position(), position),
        None => Ok(map_new(env)),
    };

    match map_result {
        Ok(map) => (atoms::integer_out_of_range(), map).encode(env),
        Err(_) => {
            let err = XqliteError::InternalEncodingError {
                context: "Failed map create for IntegerOutOfRange".to_string(),
            };
            err.encode(env)
        }
    }
}

/// A pragma name is handed back exactly as the caller wrote it, bytes and all,
/// so a name holding something that is no UTF-8 is still the name they used.
fn encode_pragma_name<'a>(env: Env<'a>, name: &[u8]) -> Term<'a> {
    match crate::util::encode_text(env, name) {
        Ok(term) => (atoms::invalid_pragma_name(), term).encode(env),
        Err(err) => err.encode(env),
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

/// Why a term a caller passed is no list this library can read: it is no list
/// at all, its tail stops being one part-way through, or one of its elements
/// is not what the list is for.
#[derive(Debug, Clone, Copy)]
pub(crate) enum ListRefusal {
    NotAList,
    ImproperTail,
    BadElement { position: usize },
}

#[derive(Debug, Clone)]
pub(crate) enum XqliteError {
    // An Elixir integer with no room in SQLite's signed 64 bits. `position`
    // is the value's one-based place in the parameter list, and None where
    // one value was judged on its own, as a PRAGMA value is.
    IntegerOutOfRange {
        position: Option<usize>,
    },
    // A TEXT or BLOB parameter longer than the connection's own length limit
    // (SQLITE_LIMIT_LENGTH), judged before anything is bound.
    ValueTooLarge {
        byte_size: usize,
        limit: usize,
    },
    ToSqlConversionFailure {
        reason: String,
    },
    ExpectedKeywordList {
        refusal: ListRefusal,
        value_type: TermType,
    },
    ExpectedKeywordTuple {
        position: usize,
        value_type: TermType,
    },
    ExpectedList {
        refusal: ListRefusal,
        value_type: TermType,
    },
    InvalidCancelTokens {
        refusal: ListRefusal,
        value_type: TermType,
    },
    UnsupportedAtom {
        atom_value: String,
    },
    UnsupportedDataType {
        term_type: TermType,
    },
    // An `%Xqlite.Blob{}` parameter whose `bytes` field is not a binary.
    // Distinct from UnsupportedDataType because the parameter itself is a
    // supported form and so is the type inside it — only not there.
    InvalidBlobBytes {
        position: usize,
        term_type: TermType,
    },
    BlobWriteOutOfBounds {
        offset: usize,
        byte_size: usize,
        blob_size: usize,
    },
    CannotConvertAtomToString(String),
    InvalidParameterCount {
        provided: usize,
        expected: usize,
    },
    // A statement that takes parameters, stepped before anything set them.
    // SQLite would read every one of them as NULL and run.
    ParametersUnbound {
        expected: usize,
    },
    InvalidParameterName(String),
    // A statement parameter no key of the caller's keyword list named. `name`
    // is SQLite's own spelling of it, and None for a bare `?`, which a keyword
    // list can never name.
    MissingParameter {
        index: usize,
        name: Option<String>,
    },
    DuplicateParameterName(String),
    TooManyNamedParameters {
        count: usize,
        limit: usize,
    },
    InvalidPragmaName(Vec<u8>),
    InvalidPragmaValue {
        pragma: Atom,
        value: u64,
    },
    InvalidTransactionMode {
        mode: Atom,
    },
    InvalidCheckpointMode {
        mode: Atom,
    },
    NotInWalMode,
    InvalidAuthorizerAction {
        action: Atom,
    },
    InvalidHookOption {
        key: Atom,
        value: u32,
    },
    // A limit category naming none of SQLite's thirteen.
    InvalidLimitCategory {
        category: Atom,
    },
    InvalidLimitValue {
        category: Atom,
        value: i64,
    },
    NulErrorInString,
    InvalidUtf8InString,
    MultipleStatements,
    NoStatement,

    CannotOpenDatabase {
        path: String,
        code: i32,
        message: String,
    },
    LockError(String),

    SqlInputError {
        code: i32,
        message: String,
        sql: String,
        offset: i32,
    },
    ExecuteReturnedResults,
    CannotExecute(String),
    CannotExecutePragma {
        pragma: String,
        reason: String,
    },
    DatabaseBusyOrLocked {
        // SQLITE_BUSY / SQLITE_LOCKED — the extended code discriminates
        // BUSY (5) from LOCKED (6) and their sub-codes (BUSY_SNAPSHOT, …).
        extended_code: i32,
        message: String,
    },
    OperationCancelled,

    // `name` is what SQLite printed after the sanctioned message prefix and
    // is what Elixir receives; `message` keeps the whole sentence for
    // `Display`.
    NoSuchTable {
        name: String,
        message: String,
    },
    NoSuchIndex {
        name: String,
        message: String,
    },
    TableExists {
        name: String,
        message: String,
    },
    IndexExists {
        name: String,
        message: String,
    },
    SchemaChanged {
        // SQLITE_SCHEMA
        extended_code: i32,
        message: String,
    },
    ReadOnlyDatabase {
        // SQLITE_READONLY — the extended code names the sub-reason
        // (READONLY_RECOVERY, READONLY_ROLLBACK, READONLY_DBMOVED, …).
        extended_code: i32,
        message: String,
    },
    TooBig {
        // SQLITE_TOOBIG — SQLite met the connection's length limit while it
        // ran: a row, a record it was building, a concatenation or a column
        // read. A parameter over the same limit is refused before the bind,
        // as ValueTooLarge.
        extended_code: i32,
        message: String,
    },
    AuthorizationDenied {
        // SQLITE_AUTH — statement rejected by an installed authorizer
        extended_code: i32,
        message: String,
    },
    BusyTimeoutWriteRefused {
        // SQLITE_AUTH raised by xqlite's own rule: a `busy_timeout` write
        // while the busy slot holds a policy or observers.
        policy: bool,
        observers: usize,
    },

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
        column: usize,
        reason: String,
    },

    ConstraintViolation {
        kind: Atom,
        message: String,
        details: Box<ConstraintDetails>,
    },

    SqliteFailure {
        code: i32,
        extended_code: i32,
        message: Option<String>,
    },

    SchemaParsingError {
        context: String,
        unexpected_value: String,
    },

    InvalidStreamHandle {
        reason: String,
    },

    ConnectionClosed,
    StatementFinalized,
    StatementMidRun,

    InternalEncodingError {
        context: String,
    },
}

impl XqliteError {
    pub(crate) fn not_a_list(term: Term<'_>) -> Self {
        XqliteError::ExpectedList {
            refusal: ListRefusal::NotAList,
            value_type: term.get_type(),
        }
    }

    pub(crate) fn improper_tail(tail: Term<'_>) -> Self {
        XqliteError::ExpectedList {
            refusal: ListRefusal::ImproperTail,
            value_type: tail.get_type(),
        }
    }

    pub(crate) fn bad_element(position: usize, element: Term<'_>) -> Self {
        XqliteError::ExpectedList {
            refusal: ListRefusal::BadElement { position },
            value_type: element.get_type(),
        }
    }

    /// The same refusal, told about the list of cancel tokens it was reading,
    /// so the caller learns which of a call's two lists it is about.
    pub(crate) fn about_cancel_tokens(self) -> Self {
        match self {
            XqliteError::ExpectedList {
                refusal,
                value_type,
            } => XqliteError::InvalidCancelTokens {
                refusal,
                value_type,
            },
            other => other,
        }
    }

    /// The same refusal, told about a list whose first element made it a
    /// keyword list.
    pub(crate) fn about_keyword_list(self) -> Self {
        match self {
            XqliteError::ExpectedList {
                refusal,
                value_type,
            } => XqliteError::ExpectedKeywordList {
                refusal,
                value_type,
            },
            other => other,
        }
    }
}

impl Display for XqliteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            XqliteError::IntegerOutOfRange { position } => match position {
                Some(position) => write!(
                    f,
                    "parameter {position} is an integer outside SQLite's 64-bit range"
                ),
                None => write!(f, "the value is an integer outside SQLite's 64-bit range"),
            },
            XqliteError::ValueTooLarge { byte_size, limit } => write!(
                f,
                "a value of {byte_size} bytes is longer than this connection's limit of {limit}"
            ),
            XqliteError::ToSqlConversionFailure { reason } => {
                write!(f, "Cannot convert Rust value to SQLite type: {reason}")
            }
            XqliteError::ExpectedKeywordList {
                refusal,
                value_type,
            } => write!(
                f,
                "Expected a keyword list for named parameters: {} ({value_type:?})",
                refusal_text(refusal)
            ),
            XqliteError::ExpectedKeywordTuple {
                position,
                value_type,
            } => write!(
                f,
                "element {position} of the keyword list is not an {{atom, value}} pair (a {value_type:?})"
            ),
            XqliteError::ExpectedList {
                refusal,
                value_type,
            } => write!(
                f,
                "Expected a list: {} ({value_type:?})",
                refusal_text(refusal)
            ),
            XqliteError::InvalidCancelTokens {
                refusal,
                value_type,
            } => write!(
                f,
                "Expected a list of cancel tokens: {} ({value_type:?})",
                refusal_text(refusal)
            ),
            XqliteError::UnsupportedAtom { atom_value } => write!(
                f,
                "Unsupported atom value '{atom_value}'. Allowed values: nil, true, false"
            ),
            XqliteError::UnsupportedDataType { term_type } => {
                let name = match term_type {
                    TermType::Atom => "atom",
                    TermType::Binary => "bitstring",
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
                };
                write!(
                    f,
                    "Unsupported data type {name}. Allowed types: atom, integer, float, binary"
                )
            }
            XqliteError::InvalidBlobBytes {
                position,
                term_type,
            } => match term_type {
                TermType::Binary => write!(
                    f,
                    "Blob parameter at position {position} holds a bitstring instead of a binary"
                ),
                other => write!(
                    f,
                    "Blob parameter at position {position} holds {other:?} instead of a binary"
                ),
            },
            XqliteError::BlobWriteOutOfBounds {
                offset,
                byte_size,
                blob_size,
            } => write!(
                f,
                "A write of {byte_size} bytes at offset {offset} runs past the end of a {blob_size}-byte blob"
            ),
            XqliteError::CannotExecute(reason) => {
                write!(f, "Cannot execute query/statement: {reason}")
            }
            XqliteError::CannotExecutePragma { pragma, reason } => {
                write!(f, "Cannot execute PRAGMA '{pragma}': {reason}")
            }
            XqliteError::DatabaseBusyOrLocked {
                extended_code: _,
                message,
            } => {
                write!(f, "Database busy or locked: {message}")
            }
            XqliteError::OperationCancelled => {
                write!(f, "Database operation was cancelled")
            }
            XqliteError::NoSuchTable { name: _, message } => {
                write!(f, "No such table: {message}")
            }
            XqliteError::NoSuchIndex { name: _, message } => {
                write!(f, "No such index: {message}")
            }
            XqliteError::TableExists { name: _, message } => {
                write!(f, "Table already exists: {message}")
            }
            XqliteError::IndexExists { name: _, message } => {
                write!(f, "Index already exists: {message}")
            }
            XqliteError::SchemaChanged {
                extended_code: _,
                message,
            } => {
                write!(f, "Database schema changed: {message}")
            }
            XqliteError::ReadOnlyDatabase {
                extended_code: _,
                message,
            } => {
                write!(f, "Database is read-only: {message}")
            }
            XqliteError::TooBig {
                extended_code: _,
                message,
            } => {
                write!(f, "Past the connection's length limit: {message}")
            }
            XqliteError::AuthorizationDenied {
                extended_code: _,
                message,
            } => {
                write!(f, "Authorization denied: {message}")
            }
            XqliteError::BusyTimeoutWriteRefused { policy, observers } => {
                write!(
                    f,
                    "busy_timeout write rejected: the busy slot is held (policy: {policy}, observers: {observers})"
                )
            }
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
            XqliteError::StatementFinalized => {
                write!(f, "Statement is already finalized")
            }
            XqliteError::StatementMidRun => {
                write!(
                    f,
                    "Statement is mid-run: reset it before binding or clearing its parameters"
                )
            }
            XqliteError::InternalEncodingError { context } => {
                write!(f, "Internal error during result encoding: {context}")
            }
            XqliteError::InvalidParameterCount { provided, expected } => write!(
                f,
                "Invalid parameter count: provided {provided}, expected {expected}"
            ),
            XqliteError::ParametersUnbound { expected } => write!(
                f,
                "the statement takes {expected} parameter(s) and nothing has bound them"
            ),
            XqliteError::InvalidParameterName(name) => {
                write!(f, "Invalid parameter name: '{name}'")
            }
            XqliteError::MissingParameter { index, name } => match name {
                Some(name) => write!(f, "Parameter {index} ('{name}') was not given a value"),
                None => write!(f, "Parameter {index} was not given a value"),
            },
            XqliteError::DuplicateParameterName(name) => {
                write!(f, "Parameter '{name}' was named twice")
            }
            XqliteError::InvalidPragmaName(name) => {
                write!(
                    f,
                    "Invalid pragma name: '{}'",
                    String::from_utf8_lossy(name)
                )
            }
            XqliteError::InvalidPragmaValue { pragma: _, value } => {
                write!(f, "Invalid pragma value {value}")
            }
            XqliteError::InvalidTransactionMode { mode: _ } => {
                write!(
                    f,
                    "Invalid transaction mode. Allowed: :deferred, :immediate, :exclusive"
                )
            }
            XqliteError::InvalidCheckpointMode { mode: _ } => write!(
                f,
                "Invalid checkpoint mode. Allowed: :passive, :full, :restart, :truncate"
            ),
            XqliteError::NotInWalMode => write!(f, "The database is not in WAL mode"),
            XqliteError::InvalidAuthorizerAction { action: _ } => {
                write!(f, "Invalid authorizer action atom")
            }
            XqliteError::InvalidHookOption { key: _, value } => {
                write!(f, "Invalid hook option value {value}")
            }
            XqliteError::InvalidLimitCategory { category: _ } => {
                write!(f, "Invalid connection limit category")
            }
            XqliteError::InvalidLimitValue { category: _, value } => {
                write!(f, "a limit of {value} is outside 0 to {}", i32::MAX)
            }
            XqliteError::TooManyNamedParameters { count, limit } => write!(
                f,
                "a keyword list is refused on a statement of {count} parameters; the most is {limit}"
            ),
            XqliteError::NulErrorInString => {
                write!(f, "Input string contains embedded null byte")
            }
            XqliteError::InvalidUtf8InString => {
                write!(f, "Input string contains bytes that are not UTF-8")
            }
            XqliteError::MultipleStatements => {
                write!(f, "Provided SQL string contains multiple statements")
            }
            XqliteError::NoStatement => write!(f, "Provided SQL string contains no statement"),
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
            XqliteError::Utf8Error { column, reason } => {
                write!(f, "UTF-8 decoding error at column {column}: {reason}")
            }
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
            XqliteError::ConstraintViolation {
                kind: _,
                message,
                details: _,
            } => write!(f, "Constraint violation: {message}"),
            XqliteError::SchemaParsingError {
                context,
                unexpected_value,
            } => {
                write!(f, "Schema parsing error ({context})")?;
                write!(f, ": Unexpected value '{unexpected_value}'")
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
            XqliteError::IntegerOutOfRange { position } => {
                encode_integer_out_of_range(env, *position)
            }
            XqliteError::ValueTooLarge { byte_size, limit } => {
                let map_result = map_new(env)
                    .map_put(atoms::byte_size(), byte_size)
                    .and_then(|map| map.map_put(atoms::limit(), limit));
                match map_result {
                    Ok(map) => (atoms::value_too_large(), map).encode(env),
                    Err(_) => {
                        let err = XqliteError::InternalEncodingError {
                            context: "Failed map create for ValueTooLarge".to_string(),
                        };
                        err.encode(env)
                    }
                }
            }
            XqliteError::ToSqlConversionFailure { reason } => {
                (atoms::to_sql_conversion_failure(), reason).encode(env)
            }
            XqliteError::ExpectedKeywordList {
                refusal,
                value_type,
            } => {
                encode_list_refusal(env, atoms::expected_keyword_list(), refusal, *value_type)
            }
            XqliteError::ExpectedKeywordTuple {
                position,
                value_type,
            } => encode_list_refusal(
                env,
                atoms::expected_keyword_tuple(),
                &ListRefusal::BadElement {
                    position: *position,
                },
                *value_type,
            ),
            XqliteError::ExpectedList {
                refusal,
                value_type,
            } => encode_list_refusal(env, atoms::expected_list(), refusal, *value_type),
            XqliteError::InvalidCancelTokens {
                refusal,
                value_type,
            } => {
                encode_list_refusal(env, atoms::invalid_cancel_tokens(), refusal, *value_type)
            }
            XqliteError::UnsupportedAtom { atom_value } => {
                (atoms::unsupported_atom(), atom_value).encode(env)
            }
            XqliteError::UnsupportedDataType { term_type } => (
                atoms::unsupported_data_type(),
                blob_bytes_type_atom(*term_type),
            )
                .encode(env),
            XqliteError::CannotExecute(reason) => {
                (atoms::cannot_execute(), reason).encode(env)
            }
            XqliteError::CannotExecutePragma { pragma, reason } => {
                (atoms::cannot_execute_pragma(), pragma, reason).encode(env)
            }
            XqliteError::DatabaseBusyOrLocked {
                extended_code,
                message,
            } => (atoms::database_busy_or_locked(), extended_code, message).encode(env),
            XqliteError::OperationCancelled => atoms::operation_cancelled().encode(env),
            XqliteError::NoSuchTable { name, message: _ } => {
                (atoms::no_such_table(), name).encode(env)
            }
            XqliteError::NoSuchIndex { name, message: _ } => {
                (atoms::no_such_index(), name).encode(env)
            }
            XqliteError::TableExists { name, message: _ } => {
                (atoms::table_exists(), name).encode(env)
            }
            XqliteError::IndexExists { name, message: _ } => {
                (atoms::index_exists(), name).encode(env)
            }
            XqliteError::SchemaChanged {
                extended_code,
                message,
            } => (atoms::schema_changed(), extended_code, message).encode(env),
            XqliteError::ReadOnlyDatabase {
                extended_code,
                message,
            } => (atoms::read_only_database(), extended_code, message).encode(env),
            XqliteError::TooBig {
                extended_code,
                message,
            } => (atoms::too_big(), extended_code, message).encode(env),
            XqliteError::AuthorizationDenied {
                extended_code,
                message,
            } => (atoms::authorization_denied(), extended_code, message).encode(env),
            XqliteError::BusyTimeoutWriteRefused { policy, observers } => {
                let map_result = map_new(env)
                    .map_put(atoms::policy(), policy)
                    .and_then(|map| map.map_put(atoms::observers(), observers));
                match map_result {
                    Ok(map) => (atoms::busy_timeout_write_refused(), map).encode(env),
                    Err(_) => {
                        let err = XqliteError::InternalEncodingError {
                            context: "Failed map create for BusyTimeoutWriteRefused"
                                .to_string(),
                        };
                        err.encode(env)
                    }
                }
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
            XqliteError::StatementFinalized => atoms::statement_finalized().encode(env),
            XqliteError::StatementMidRun => atoms::statement_mid_run().encode(env),
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
                        err.encode(env)
                    }
                }
            }
            XqliteError::ParametersUnbound { expected } => {
                match map_new(env).map_put(atoms::expected(), expected) {
                    Ok(map) => (atoms::parameters_unbound(), map).encode(env),
                    Err(_) => {
                        let err = XqliteError::InternalEncodingError {
                            context: "Failed map create for ParametersUnbound".to_string(),
                        };
                        err.encode(env)
                    }
                }
            }
            XqliteError::InvalidBlobBytes {
                position,
                term_type,
            } => {
                let map_result =
                    map_new(env)
                        .map_put(atoms::position(), position)
                        .and_then(|map| {
                            map.map_put(atoms::r#type(), blob_bytes_type_atom(*term_type))
                        });
                match map_result {
                    Ok(map) => (atoms::invalid_blob_bytes(), map).encode(env),
                    Err(_) => {
                        let err = XqliteError::InternalEncodingError {
                            context: "Failed map create for InvalidBlobBytes".to_string(),
                        };
                        err.encode(env)
                    }
                }
            }
            XqliteError::BlobWriteOutOfBounds {
                offset,
                byte_size,
                blob_size,
            } => {
                let map_result = map_new(env)
                    .map_put(atoms::offset(), offset)
                    .and_then(|map| map.map_put(atoms::byte_size(), byte_size))
                    .and_then(|map| map.map_put(atoms::blob_size(), blob_size));
                match map_result {
                    Ok(map) => (atoms::blob_write_out_of_bounds(), map).encode(env),
                    Err(_) => {
                        let err = XqliteError::InternalEncodingError {
                            context: "Failed map create for BlobWriteOutOfBounds".to_string(),
                        };
                        err.encode(env)
                    }
                }
            }
            XqliteError::InvalidParameterName(name) => {
                (atoms::invalid_parameter_name(), name).encode(env)
            }
            XqliteError::MissingParameter { index, name } => {
                let map_result = map_new(env)
                    .map_put(atoms::index(), index)
                    .and_then(|map| map.map_put(atoms::name(), name.encode(env)));
                match map_result {
                    Ok(map) => (atoms::missing_parameter(), map).encode(env),
                    Err(_) => {
                        let err = XqliteError::InternalEncodingError {
                            context: "Failed map create for MissingParameter".to_string(),
                        };
                        err.encode(env)
                    }
                }
            }
            XqliteError::DuplicateParameterName(name) => {
                (atoms::duplicate_parameter_name(), name).encode(env)
            }
            XqliteError::TooManyNamedParameters { count, limit } => {
                let map_result = map_new(env)
                    .map_put(atoms::count(), count)
                    .and_then(|map| map.map_put(atoms::limit(), limit));
                match map_result {
                    Ok(map) => (atoms::too_many_named_parameters(), map).encode(env),
                    Err(_) => {
                        let err = XqliteError::InternalEncodingError {
                            context: "Failed map create for TooManyNamedParameters"
                                .to_string(),
                        };
                        err.encode(env)
                    }
                }
            }
            XqliteError::InvalidPragmaName(name) => encode_pragma_name(env, name),
            XqliteError::InvalidPragmaValue { pragma, value } => {
                let map_result = map_new(env)
                    .map_put(atoms::pragma(), *pragma)
                    .and_then(|map| map.map_put(atoms::value(), value));
                match map_result {
                    Ok(map) => (atoms::invalid_pragma_value(), map).encode(env),
                    Err(_) => {
                        let err = XqliteError::InternalEncodingError {
                            context: "Failed map create for InvalidPragmaValue".to_string(),
                        };
                        err.encode(env)
                    }
                }
            }
            XqliteError::InvalidTransactionMode { mode } => {
                (atoms::invalid_transaction_mode(), *mode).encode(env)
            }
            XqliteError::InvalidCheckpointMode { mode } => {
                (atoms::invalid_checkpoint_mode(), *mode).encode(env)
            }
            XqliteError::NotInWalMode => atoms::not_in_wal_mode().encode(env),
            XqliteError::InvalidAuthorizerAction { action } => {
                (atoms::invalid_authorizer_action(), *action).encode(env)
            }
            XqliteError::InvalidHookOption { key, value } => {
                let map_result = map_new(env)
                    .map_put(atoms::key(), *key)
                    .and_then(|map| map.map_put(atoms::value(), value))
                    .and_then(|map| map.map_put(atoms::reason(), atoms::invalid_value()));
                match map_result {
                    Ok(map) => (atoms::invalid_hook_option(), map).encode(env),
                    Err(_) => {
                        let err = XqliteError::InternalEncodingError {
                            context: "Failed map create for InvalidHookOption".to_string(),
                        };
                        err.encode(env)
                    }
                }
            }
            XqliteError::InvalidLimitCategory { category } => {
                (atoms::invalid_limit_category(), *category).encode(env)
            }
            XqliteError::InvalidLimitValue { category, value } => {
                let map_result = map_new(env)
                    .map_put(atoms::category(), *category)
                    .and_then(|map| map.map_put(atoms::value(), value));
                match map_result {
                    Ok(map) => (atoms::invalid_limit_value(), map).encode(env),
                    Err(_) => {
                        let err = XqliteError::InternalEncodingError {
                            context: "Failed map create for InvalidLimitValue".to_string(),
                        };
                        err.encode(env)
                    }
                }
            }
            XqliteError::NulErrorInString => atoms::null_byte_in_string().encode(env),
            XqliteError::InvalidUtf8InString => atoms::invalid_utf8_in_string().encode(env),
            XqliteError::MultipleStatements => atoms::multiple_statements().encode(env),
            XqliteError::NoStatement => atoms::no_statement().encode(env),
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
            XqliteError::Utf8Error { column, reason } => {
                (atoms::utf8_error(), column, reason).encode(env)
            }
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
                        err.encode(env)
                    }
                }
            }
            XqliteError::ConstraintViolation {
                kind,
                message,
                details,
            } => {
                let columns_list: Vec<&str> =
                    details.columns.iter().map(String::as_str).collect();
                let map_result = map_new(env)
                    .map_put(atoms::message(), message.as_str())
                    .and_then(|m| {
                        m.map_put(atoms::table(), option_to_term(env, &details.table))
                    })
                    .and_then(|m| m.map_put(atoms::columns(), columns_list))
                    .and_then(|m| {
                        m.map_put(
                            atoms::index_name(),
                            option_to_term(env, &details.index_name),
                        )
                    })
                    .and_then(|m| {
                        m.map_put(
                            atoms::constraint_name(),
                            option_to_term(env, &details.constraint_name),
                        )
                    })
                    .and_then(|m| {
                        m.map_put(
                            atoms::source_type(),
                            storage_class_to_term(env, &details.source_type),
                        )
                    })
                    .and_then(|m| {
                        m.map_put(
                            atoms::target_type(),
                            storage_class_to_term(env, &details.target_type),
                        )
                    });
                match map_result {
                    Ok(map) => (atoms::constraint_violation(), *kind, map).encode(env),
                    Err(_) => {
                        let err = XqliteError::InternalEncodingError {
                            context: "Failed map create for ConstraintViolation".to_string(),
                        };
                        err.encode(env)
                    }
                }
            }
            XqliteError::SchemaParsingError {
                context,
                unexpected_value,
            } => {
                let detail_term = (atoms::unexpected_value(), unexpected_value).encode(env);
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

/// True when a rusqlite error is a SQLITE_AUTH (authorizer) denial. Lets
/// callers that would otherwise flatten errors into a generic variant (e.g.
/// the PRAGMA layer) surface the dedicated `AuthorizationDenied` instead.
pub(crate) fn is_sqlite_auth(err: &RusqliteError) -> bool {
    let extended_code = match err {
        RusqliteError::SqliteFailure(ffi_err, _) => ffi_err.extended_code,
        RusqliteError::SqlInputError { error, .. } => error.extended_code,
        _ => return false,
    };
    (extended_code & 0xFF) == ffi::SQLITE_AUTH
}

/// True when SQLite answered a misuse of the C API. The bind path asks,
/// because that is the one refusal SQLite makes before it touches a parameter.
pub(crate) fn is_misuse(error: &XqliteError) -> bool {
    match error {
        XqliteError::SqliteFailure { extended_code, .. } => {
            (extended_code & 0xFF) == ffi::SQLITE_MISUSE
        }
        _other => false,
    }
}

/// Classify a failed `sqlite3_prepare_v2` the way rusqlite's own `prepare`
/// does, so the raw-FFI prepare sites and `query`/`execute` agree on one SQL
/// string.
///
/// # Safety
/// The caller must hold the connection Mutex, and `db` must be the live handle
/// the failing `sqlite3_prepare_v2` ran on.
pub(crate) unsafe fn prepare_failure(
    db: *mut ffi::sqlite3,
    rc: c_int,
    sql: &str,
) -> XqliteError {
    // SAFETY: `db` is a live handle and the Mutex is held (fn contract).
    let msg_ptr = unsafe { ffi::sqlite3_errmsg(db) };
    let msg = if msg_ptr.is_null() {
        format!("SQLite preparation error (code {rc}) but no message available. SQL: {sql}")
    } else {
        // SAFETY: non-null here, and SQLite's error string stays valid while
        // the Mutex is held.
        unsafe { CStr::from_ptr(msg_ptr) }
            .to_string_lossy()
            .into_owned()
    };

    let error = ffi::Error::new(rc);

    // SQLite reports a byte offset into the SQL only for a plain SQLITE_ERROR.
    if rc & 0xFF == ffi::SQLITE_ERROR {
        // SAFETY: `db` is a live handle and the Mutex is held (fn contract).
        let offset = unsafe { ffi::sqlite3_error_offset(db) };
        if offset >= 0 {
            return XqliteError::from(RusqliteError::SqlInputError {
                error,
                msg,
                sql: sql.to_owned(),
                offset,
            });
        }
    }

    XqliteError::from(RusqliteError::SqliteFailure(error, Some(msg)))
}

fn classify_sqlite_error(ffi_err: ffi::Error, message_string: String) -> XqliteError {
    let lower_msg = message_string.to_lowercase();
    let primary_code = ffi_err.extended_code & 0xFF;

    match primary_code {
        ffi::SQLITE_READONLY => XqliteError::ReadOnlyDatabase {
            extended_code: ffi_err.extended_code,
            message: message_string,
        },
        ffi::SQLITE_TOOBIG => XqliteError::TooBig {
            extended_code: ffi_err.extended_code,
            message: message_string,
        },
        ffi::SQLITE_INTERRUPT => XqliteError::OperationCancelled,
        ffi::SQLITE_BUSY | ffi::SQLITE_LOCKED => XqliteError::DatabaseBusyOrLocked {
            extended_code: ffi_err.extended_code,
            message: message_string,
        },
        ffi::SQLITE_SCHEMA => XqliteError::SchemaChanged {
            extended_code: ffi_err.extended_code,
            message: message_string,
        },
        ffi::SQLITE_AUTH => XqliteError::AuthorizationDenied {
            extended_code: ffi_err.extended_code,
            message: message_string,
        },
        ffi::SQLITE_CONSTRAINT => {
            let kind = constraint_kind_to_atom_extended(ffi_err.extended_code);
            let details =
                constraint_parse::parse_details(ffi_err.extended_code, &message_string);
            XqliteError::ConstraintViolation {
                kind,
                message: message_string,
                details: Box::new(details),
            }
        }
        // Text-based classification (the only place we do it outside
        // `constraint_parse.rs`). These four conditions all surface as the
        // primary `SQLITE_ERROR` (1) with NO distinguishing extended code — see
        // the SQLite result-code list: "no such table"/"no such index"/"table …
        // already exists"/"index … already exists" share code 1 with dozens of
        // unrelated errors. SQLite gives us no other signal, so the (stable,
        // English) message prefix is the only discriminator, exactly like
        // `constraint_parse.rs` parses constraint metadata out of `errmsg` text.
        // Consequence, accepted deliberately: a message reword/localization
        // downgrades these to the generic `SqliteFailure` fallback — graceful (no
        // wrong result, no crash), never a misclassification. This is also why
        // these four variants carry no `extended_code` field (unlike the
        // SQLITE_BUSY/READONLY/SCHEMA/AUTH variants above): their extended
        // code is invariantly 1, so it would carry no information. What they
        // do carry is the object name SQLite printed after the prefix, so a
        // caller gets the name without re-parsing the sentence.
        _ if lower_msg.starts_with("no such table") => XqliteError::NoSuchTable {
            name: name_after(&message_string, "no such table: "),
            message: message_string,
        },
        _ if lower_msg.starts_with("no such index") => XqliteError::NoSuchIndex {
            name: name_after(&message_string, "no such index: "),
            message: message_string,
        },
        _ if lower_msg.starts_with("table") && lower_msg.contains("already exists") => {
            XqliteError::TableExists {
                name: name_between(&message_string, "table "),
                message: message_string,
            }
        }
        _ if lower_msg.starts_with("index") && lower_msg.contains("already exists") => {
            XqliteError::IndexExists {
                name: name_between(&message_string, "index "),
                message: message_string,
            }
        }
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

            RusqliteError::ExecuteReturnedResults => XqliteError::ExecuteReturnedResults,
            RusqliteError::InvalidParameterCount(p, e) => XqliteError::InvalidParameterCount {
                provided: p,
                expected: e,
            },
            RusqliteError::InvalidParameterName(name) => {
                XqliteError::InvalidParameterName(name)
            }
            RusqliteError::NulError(_) => XqliteError::NulErrorInString,
            RusqliteError::Utf8Error(col, e) => XqliteError::Utf8Error {
                column: col,
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

            // Only NON-`SqliteFailure`/`SqlInputError` rusqlite errors reach here
            // (both are matched above and routed through `classify_sqlite_error`).
            // A SQLite interrupt is ALWAYS a `SqliteFailure` carrying extended code
            // `SQLITE_INTERRUPT` (9), classified by code — never by message text.
            other_err => XqliteError::CannotExecute(other_err.to_string()),
        }
    }
}
