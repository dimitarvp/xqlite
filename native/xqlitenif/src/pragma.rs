use crate::atoms;
use crate::error::XqliteError;
use crate::util::{encode_val, format_term_for_pragma};
use rusqlite::types::Value;
use rusqlite::{Connection, Error as RusqliteError};
use rustler::{Env, Term};

pub(crate) fn validate_name(name: &str) -> Result<(), XqliteError> {
    if name.is_empty() || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
        return Err(XqliteError::InvalidPragmaName(name.to_string()));
    }
    Ok(())
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
        Err(e) => Err(XqliteError::CannotExecutePragma {
            pragma: read_sql,
            reason: e.to_string(),
        }),
    }
}

pub(crate) fn set<'a>(
    env: Env<'a>,
    conn: &Connection,
    pragma_name: &str,
    value_term: Term<'a>,
) -> Result<(), XqliteError> {
    validate_name(pragma_name)?;
    let value_literal = format_term_for_pragma(env, value_term)?;
    let write_sql = format!("PRAGMA {pragma_name} = {value_literal};");
    let mut write_stmt =
        conn.prepare(&write_sql)
            .map_err(|e| XqliteError::CannotExecutePragma {
                pragma: write_sql,
                reason: e.to_string(),
            })?;
    let mut rows = write_stmt.query([])?;
    if let Some(row_result) = rows.next()? {
        let _value_from_pragma_set: Value = row_result.get(0)?;
    }
    Ok(())
}
