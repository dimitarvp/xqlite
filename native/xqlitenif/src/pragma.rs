use crate::atoms;
use crate::error::{self, XqliteError};
use crate::util::{encode_val, format_term_for_pragma};
use rusqlite::types::Value;
use rusqlite::{Connection, Error as RusqliteError};
use rustler::{Encoder, Env, Term};

pub(crate) fn validate_name(name: &str) -> Result<(), XqliteError> {
    if name.is_empty() || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
        return Err(XqliteError::InvalidPragmaName(name.to_string()));
    }
    Ok(())
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
    pragma_name: &str,
) -> Result<Term<'a>, XqliteError> {
    validate_name(pragma_name)?;
    let read_sql = format!("PRAGMA {pragma_name};");
    match conn.query_row(&read_sql, [], |row| row.get::<usize, Value>(0)) {
        Ok(value) => Ok(encode_val(env, value)),
        Err(RusqliteError::QueryReturnedNoRows) => Ok(atoms::no_value().to_term(env)),
        Err(e) => Err(pragma_exec_error(read_sql, e)),
    }
}

pub(crate) fn set<'a>(
    env: Env<'a>,
    conn: &Connection,
    pragma_name: &str,
    value_term: Term<'a>,
) -> Result<Term<'a>, XqliteError> {
    validate_name(pragma_name)?;
    let value_literal = format_term_for_pragma(env, value_term)?;
    let write_sql = format!("PRAGMA {pragma_name} = {value_literal};");
    let mut write_stmt = conn
        .prepare(&write_sql)
        .map_err(|e| pragma_exec_error(write_sql, e))?;
    let mut rows = write_stmt.query([])?;
    match rows.next()? {
        Some(row) => {
            let value: Value = row.get(0)?;
            Ok(encode_val(env, value))
        }
        None => Ok(rustler::types::atom::nil().encode(env)),
    }
}
