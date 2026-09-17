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

// A PRAGMA runs SQL, so an installed authorizer can veto it with SQLITE_AUTH.
// That denial carries its own structured variant; surface it instead of
// flattening it into the generic `CannotExecutePragma` wrapper. Every other
// failure keeps the pragma wrapper (and its exact `reason` text) unchanged.
fn pragma_exec_error(pragma: String, err: RusqliteError) -> XqliteError {
    if error::is_sqlite_auth(&err) {
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
    match conn.query_row(&read_sql, [], |row| row.get::<usize, Value>(0)) {
        Ok(value) => encode_val(env, value),
        Err(RusqliteError::QueryReturnedNoRows) => Ok(atoms::no_value().to_term(env)),
        Err(e) => Err(pragma_exec_error(pragma_name.to_string(), e)),
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
    let write_sql = format!("PRAGMA {pragma_name} = {value_literal};");
    let mut write_stmt = conn
        .prepare(&write_sql)
        .map_err(|e| pragma_exec_error(pragma_name.to_string(), e))?;
    let mut rows = write_stmt.query([])?;
    match rows.next()? {
        Some(row) => {
            let value: Value = row.get(0)?;
            encode_val(env, value)
        }
        None => Ok(rustler::types::atom::nil().encode(env)),
    }
}
