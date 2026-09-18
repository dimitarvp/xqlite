//! SQLite's per-connection limits (`sqlite3_limit`) and the one check that
//! reads a limit on every bind: a TEXT or BLOB parameter longer than
//! `SQLITE_LIMIT_LENGTH` is refused before anything is bound.

use crate::atoms;
use crate::error::XqliteError;
use rusqlite::Connection;
use rusqlite::ffi;
use rusqlite::types::Value;
use rustler::Atom;
use std::os::raw::c_int;

// The largest value sqlite3_limit accepts; a bigger one is a caller error
// rather than something SQLite clamps.
const MAX_LIMIT_VALUE: i64 = c_int::MAX as i64;

/// Reads, and optionally sets, one of the connection's limits.
///
/// `new_value` of -1 reads without setting, and 0 to 2^31-1 sets; every other
/// negative, and anything above 2^31-1, is refused rather than read. SQLite
/// answers the value in force before the call and silently clamps a new one
/// to its own compile-time ceiling — and, for `:length` alone, up to a floor
/// of 30 — so a caller who needs the value that took effect reads it back.
///
/// Callers must hold the connection Mutex.
pub(crate) fn read_or_set(
    conn: &Connection,
    category: Atom,
    new_value: i64,
) -> Result<i64, XqliteError> {
    let id = category_id(category)?;
    let requested = judge_value(category, new_value)?;

    // SAFETY: the caller holds the connection Mutex for the whole call, so no
    // other thread is inside a `sqlite3_*` call on this connection, and
    // `handle()` is the live `sqlite3*` that Mutex guards.
    let previous = unsafe { ffi::sqlite3_limit(conn.handle(), id, requested) };

    Ok(previous as i64)
}

/// The id `sqlite3_limit` takes for the category a caller named.
fn category_id(category: Atom) -> Result<c_int, XqliteError> {
    let table = [
        (atoms::length(), ffi::SQLITE_LIMIT_LENGTH),
        (atoms::sql_length(), ffi::SQLITE_LIMIT_SQL_LENGTH),
        (atoms::column(), ffi::SQLITE_LIMIT_COLUMN),
        (atoms::expr_depth(), ffi::SQLITE_LIMIT_EXPR_DEPTH),
        (atoms::compound_select(), ffi::SQLITE_LIMIT_COMPOUND_SELECT),
        (atoms::vdbe_op(), ffi::SQLITE_LIMIT_VDBE_OP),
        (atoms::function_arg(), ffi::SQLITE_LIMIT_FUNCTION_ARG),
        (atoms::attached(), ffi::SQLITE_LIMIT_ATTACHED),
        (
            atoms::like_pattern_length(),
            ffi::SQLITE_LIMIT_LIKE_PATTERN_LENGTH,
        ),
        (atoms::variable_number(), ffi::SQLITE_LIMIT_VARIABLE_NUMBER),
        (atoms::trigger_depth(), ffi::SQLITE_LIMIT_TRIGGER_DEPTH),
        (atoms::worker_threads(), ffi::SQLITE_LIMIT_WORKER_THREADS),
        (atoms::parser_depth(), ffi::SQLITE_LIMIT_PARSER_DEPTH),
    ];

    table
        .into_iter()
        .find_map(|(name, id)| (name == category).then_some(id))
        .ok_or(XqliteError::InvalidLimitCategory { category })
}

/// The `c_int` SQLite takes for the value a caller asked for. The argument is
/// decoded as a 64-bit integer so that a number past `c_int`'s top is answered
/// with an error rather than raised at the decoder.
fn judge_value(category: Atom, value: i64) -> Result<c_int, XqliteError> {
    let in_range = value == -1 || (0..=MAX_LIMIT_VALUE).contains(&value);

    match in_range.then(|| c_int::try_from(value)) {
        Some(Ok(requested)) => Ok(requested),
        _outside => Err(XqliteError::InvalidLimitValue { category, value }),
    }
}

/// The bytes a TEXT or BLOB parameter may hold on this connection.
///
/// # Safety
///
/// The caller holds the connection Mutex for the whole call and `db_handle`
/// is the live `sqlite3*` that Mutex guards.
#[inline]
pub(crate) unsafe fn length_limit(db_handle: *mut ffi::sqlite3) -> usize {
    // SAFETY: forwarded from this function's own contract.
    let limit = unsafe { ffi::sqlite3_limit(db_handle, ffi::SQLITE_LIMIT_LENGTH, -1) };

    limit.max(0) as usize
}

/// Runs `read` with the connection's length limit lifted to SQLite's own
/// ceiling, and puts the caller's limit back before it answers.
///
/// `sqlite3_expanded_sql` builds its answer under that limit and hands back
/// nothing when the expansion does not fit — the same answer it gives for a
/// statement that is not there at all. Lifting the limit for the read tells
/// the two apart whatever the caller set.
///
/// # Safety
///
/// The caller holds the connection Mutex for the whole call and `db_handle`
/// is the live `sqlite3*` that Mutex guards.
pub(crate) unsafe fn with_length_limit_lifted<T>(
    db_handle: *mut ffi::sqlite3,
    read: impl FnOnce() -> T,
) -> T {
    // SAFETY: forwarded from this function's own contract.
    let previous =
        unsafe { ffi::sqlite3_limit(db_handle, ffi::SQLITE_LIMIT_LENGTH, c_int::MAX) };
    let answer = read();
    // SAFETY: forwarded from this function's own contract.
    unsafe { ffi::sqlite3_limit(db_handle, ffi::SQLITE_LIMIT_LENGTH, previous) };

    answer
}

/// Refuses a name a door binds as a parameter by the limit every bound value
/// is judged against, before the bind, so the refusal leaves the statement
/// untouched. Its one caller is `schema.rs:create_sql`, behind
/// `XqliteNIF.get_create_sql/2`. The four PRAGMA-based schema doors build the
/// name into the SQL text instead and never come here: they answer SQLite's
/// `:too_big` only when the text they built passes `SQLITE_LIMIT_SQL_LENGTH`,
/// which a 5 000-byte name does not at that limit's default.
///
/// # Safety
///
/// The caller holds the connection Mutex for the whole call and `db_handle`
/// is the live `sqlite3*` that Mutex guards.
pub(crate) unsafe fn require_text_within_length(
    db_handle: *mut ffi::sqlite3,
    text: &str,
) -> Result<(), XqliteError> {
    // SAFETY: forwarded from this function's own contract.
    let limit = unsafe { length_limit(db_handle) };

    require_byte_size(limit, text.len())
}

/// Refuses a positional list holding a value over the connection's length
/// limit, before a single value is bound.
///
/// # Safety
///
/// The caller holds the connection Mutex for the whole call and `db_handle`
/// is the live `sqlite3*` that Mutex guards.
pub(crate) unsafe fn require_positional_within_length(
    db_handle: *mut ffi::sqlite3,
    params: &[Value],
) -> Result<(), XqliteError> {
    // SAFETY: forwarded from this function's own contract.
    let limit = unsafe { length_limit(db_handle) };

    params
        .iter()
        .try_for_each(|value| require_within_length(limit, value))
}

/// Refuses a keyword list holding a value over the connection's length limit,
/// before a single value is bound.
///
/// # Safety
///
/// The caller holds the connection Mutex for the whole call and `db_handle`
/// is the live `sqlite3*` that Mutex guards.
pub(crate) unsafe fn require_named_within_length(
    db_handle: *mut ffi::sqlite3,
    params: &[(String, Value)],
) -> Result<(), XqliteError> {
    // SAFETY: forwarded from this function's own contract.
    let limit = unsafe { length_limit(db_handle) };

    params
        .iter()
        .try_for_each(|(_name, value)| require_within_length(limit, value))
}

/// SQLite refuses a TEXT or BLOB longer than the connection's length limit,
/// and it refuses it half-way through the list, leaving the values before it
/// bound. Judging every value first is what makes a refused bind bind nothing.
#[inline]
fn require_within_length(limit: usize, value: &Value) -> Result<(), XqliteError> {
    let byte_size = match value {
        Value::Text(text) => text.len(),
        Value::Blob(bytes) => bytes.len(),
        Value::Null | Value::Integer(_) | Value::Real(_) => 0,
    };

    require_byte_size(limit, byte_size)
}

#[inline]
fn require_byte_size(limit: usize, byte_size: usize) -> Result<(), XqliteError> {
    match byte_size > limit {
        true => Err(XqliteError::ValueTooLarge { byte_size, limit }),
        false => Ok(()),
    }
}
