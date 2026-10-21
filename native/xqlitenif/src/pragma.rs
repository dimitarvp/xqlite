use crate::atoms;
use crate::error::{self, XqliteError};
use crate::util::{encode_val, format_term_for_pragma};
use rusqlite::types::Value;
use rusqlite::{Connection, Error as RusqliteError};
use rustler::{Encoder, Env, Term};

/// A PRAGMA name is written into the statement, so it is read as bytes and
/// judged before it can become text: every byte outside `A-Z`, `a-z`, `0-9`
/// and `_` is refused, which leaves a name that is ASCII and so is UTF-8.
pub(crate) fn validate_name(name: &[u8]) -> Result<&str, XqliteError> {
    let spelled_right =
        !name.is_empty() && name.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'_');

    match spelled_right {
        true => std::str::from_utf8(name).map_err(|_not_utf8| invalid_name(name)),
        false => Err(invalid_name(name)),
    }
}

fn invalid_name(name: &[u8]) -> XqliteError {
    XqliteError::InvalidPragmaName(name.to_vec())
}

// A lock is the caller's to wait for, and an authorizer's denial carries its own variant:
// both keep the error their code makes, never `CannotExecutePragma`'s message text.
fn pragma_exec_error(pragma: String, err: RusqliteError) -> XqliteError {
    if error::is_sqlite_auth(&err) || error::is_sqlite_busy_or_locked(&err) {
        XqliteError::from(err)
    } else {
        XqliteError::CannotExecutePragma {
            pragma,
            reason: err.to_string(),
        }
    }
}

pub(crate) fn get<'a>(
    env: Env<'a>,
    conn: &Connection,
    pragma_name: &[u8],
) -> Result<Term<'a>, XqliteError> {
    let pragma_name = validate_name(pragma_name)?;
    let read_sql = format!("PRAGMA {pragma_name};");
    let exec_error = |e| pragma_exec_error(pragma_name.to_string(), e);
    let mut stmt = conn.prepare(&read_sql).map_err(exec_error)?;
    let valued = stmt.column_count() > 0;
    let writes = !stmt.readonly();
    let mut rows = stmt.query([]).map_err(exec_error)?;
    let first = rows.next().map_err(exec_error)?.filter(|_row| valued);
    let value = first
        .map(|row| row.get::<usize, Value>(0))
        .transpose()
        .map_err(exec_error)?;
    // A PRAGMA that writes, as incremental_vacuum does, commits as it ends.
    while writes && rows.next()?.is_some() {}
    match value {
        Some(value) => encode_val(env, value),
        None => Ok(atoms::no_value().to_term(env)),
    }
}

pub(crate) fn set<'a>(
    env: Env<'a>,
    conn: &Connection,
    pragma_name: &[u8],
    value_term: Term<'a>,
) -> Result<Term<'a>, XqliteError> {
    let pragma_name = validate_name(pragma_name)?;
    let value_literal = format_term_for_pragma(env, value_term)?;
    // SQLite drops a foreign_keys write while autocommit is off, and still answers success.
    if pragma_name.eq_ignore_ascii_case("foreign_keys") && !conn.is_autocommit() {
        return Err(XqliteError::TransactionInProgress);
    }
    let write_sql = format!("PRAGMA {pragma_name} = {value_literal};");
    let mut write_stmt = conn
        .prepare(&write_sql)
        .map_err(|e| pragma_exec_error(pragma_name.to_string(), e))?;
    let valued = write_stmt.column_count() > 0;
    let writes = !write_stmt.readonly();
    let mut rows = write_stmt.query([])?;
    let first = rows.next()?.filter(|_row| valued);
    let value = first.map(|row| row.get::<usize, Value>(0)).transpose()?;
    while writes && rows.next()?.is_some() {}
    match value {
        Some(value) => encode_val(env, value),
        None => Ok(rustler::types::atom::nil().encode(env)),
    }
}
