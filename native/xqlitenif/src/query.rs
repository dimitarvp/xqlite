use crate::connection::XqliteQueryResult;
use crate::error::XqliteError;
use crate::util::{
    decode_exec_keyword_params, decode_plain_list_params, is_keyword, process_rows,
};
use rusqlite::types::Value;
use rusqlite::{Connection, ToSql};
use rustler::types::atom::nil;
use rustler::{Env, Term, TermType};

/// Reject SQL text containing an interior NUL byte before it reaches SQLite.
///
/// rusqlite's `prepare`/`execute_batch` hand SQLite the SQL length-delimited
/// (`as_ptr` + `len`), and SQLite's tokenizer STOPS at the first NUL — every
/// byte after it is silently ignored, which can shorten a statement into
/// something unintended. We refuse with `:null_byte_in_string` instead, so the
/// contract matches the raw-FFI `prepare`/`stream_open`/`explain_analyze`
/// paths (which build a `CString` and reject the same way).
#[inline]
fn reject_interior_nul(sql: &str) -> Result<(), XqliteError> {
    if sql.as_bytes().contains(&0) {
        Err(XqliteError::NulErrorInString)
    } else {
        Ok(())
    }
}

pub(crate) fn core_query<'a>(
    env: Env<'a>,
    conn: &Connection,
    sql: &str,
    params_term: Term<'a>,
) -> Result<XqliteQueryResult<'a>, XqliteError> {
    reject_interior_nul(sql)?;
    let mut stmt = conn.prepare(sql)?;
    let column_names: Vec<String> =
        stmt.column_names().iter().map(|s| s.to_string()).collect();
    let column_count = column_names.len();

    let rows_result = match params_term.get_type() {
        TermType::List => {
            if params_term.is_empty_list() {
                stmt.query([])
            } else if is_keyword(params_term) {
                let named_params_vec = decode_exec_keyword_params(env, params_term)?;
                let params_for_rusqlite: Vec<(&str, &dyn ToSql)> = named_params_vec
                    .iter()
                    .map(|(k, v)| (k.as_str(), v as &dyn ToSql))
                    .collect();
                stmt.query(params_for_rusqlite.as_slice())
            } else {
                let positional_values: Vec<Value> =
                    decode_plain_list_params(env, params_term)?;
                let params_slice: Vec<&dyn ToSql> =
                    positional_values.iter().map(|v| v as &dyn ToSql).collect();
                stmt.query(params_slice.as_slice())
            }
        }
        _ if params_term == nil().to_term(env) => stmt.query([]),
        _ => {
            return Err(XqliteError::ExpectedList {
                value_str: format!("{params_term:?}"),
            });
        }
    };
    let rows = rows_result?;

    let results_vec = process_rows(env, rows, column_count)?;
    let num_rows = results_vec.len();

    Ok(XqliteQueryResult {
        columns: column_names,
        rows: results_vec,
        num_rows,
    })
}

/// Runs a query and reports how many rows THIS statement changed.
///
/// `sqlite3_changes()` is sticky — it keeps the last INSERT/UPDATE/DELETE's
/// count across intervening SELECT/DDL/PRAGMA statements. Detecting "did this
/// statement change rows" by empty columns is wrong twice: an `… RETURNING`
/// DML has columns yet changed rows, and a DDL/PRAGMA has no columns yet must
/// report 0 (not the stale prior count). We instead observe
/// `sqlite3_total_changes()` across the statement: a non-zero delta means this
/// statement (or its triggers) changed rows, so the fresh `sqlite3_changes()`
/// is meaningful; a zero delta means it changed nothing, so we report 0
/// regardless of the sticky counter.
pub(crate) fn core_query_with_changes<'a>(
    env: Env<'a>,
    conn: &Connection,
    sql: &str,
    params_term: Term<'a>,
) -> Result<(XqliteQueryResult<'a>, u64), XqliteError> {
    let before = conn.total_changes();
    let qr = core_query(env, conn, sql, params_term)?;
    let changes = if conn.total_changes() == before {
        0
    } else {
        conn.changes()
    };
    Ok((qr, changes))
}

pub(crate) fn core_execute<'a>(
    env: Env<'a>,
    conn: &Connection,
    sql: &str,
    params_term: Term<'a>,
) -> Result<usize, XqliteError> {
    reject_interior_nul(sql)?;
    let mut stmt = conn.prepare(sql)?;

    let affected_rows = match params_term.get_type() {
        TermType::List => {
            if params_term.is_empty_list() {
                stmt.execute([])
            } else if is_keyword(params_term) {
                let named_params_vec = decode_exec_keyword_params(env, params_term)?;
                let params_for_rusqlite: Vec<(&str, &dyn ToSql)> = named_params_vec
                    .iter()
                    .map(|(k, v)| (k.as_str(), v as &dyn ToSql))
                    .collect();
                stmt.execute(params_for_rusqlite.as_slice())
            } else {
                let positional_values: Vec<Value> =
                    decode_plain_list_params(env, params_term)?;
                let params_slice: Vec<&dyn ToSql> =
                    positional_values.iter().map(|v| v as &dyn ToSql).collect();
                stmt.execute(params_slice.as_slice())
            }
        }
        _ if params_term == nil().to_term(env) => stmt.execute([]),
        _ => {
            return Err(XqliteError::ExpectedList {
                value_str: format!("{params_term:?}"),
            });
        }
    }?;

    Ok(affected_rows)
}

pub(crate) fn core_execute_batch(
    conn: &Connection,
    sql_batch: &str,
) -> Result<(), XqliteError> {
    reject_interior_nul(sql_batch)?;
    conn.execute_batch(sql_batch)?;
    Ok(())
}
