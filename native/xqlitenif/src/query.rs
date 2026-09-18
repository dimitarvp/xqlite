use crate::connection::XqliteQueryResult;
use crate::error::XqliteError;
use crate::util::{
    Params, decode_exec_keyword_params, decode_plain_list_params, process_rows, walk_params,
};
use rusqlite::types::Value;
use rusqlite::{Connection, Statement, ToSql};
use rustler::{Env, Term};

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

/// SQLite answers whitespace- or comment-only SQL with SQLITE_OK and a NULL
/// statement — no columns, no parameters, no SQL text — which rusqlite hands
/// back as a `Statement` that steps straight into SQLITE_MISUSE.
///
/// `expanded_sql()` is NULL for that case and for two others: an expansion
/// longer than SQLITE_LIMIT_LENGTH, and an allocation failure. The first
/// cannot happen here. A statement with zero parameters expands to its own
/// text, whose length `sqlite3_prepare` already checked against
/// SQLITE_LIMIT_SQL_LENGTH; both limits sit at the same compiled default
/// (one billion bytes) because nothing in this crate calls `sqlite3_limit`
/// to lower either. That leaves an allocation failure, which fails the call
/// whichever way it is reported.
#[inline]
fn reject_no_statement(stmt: &Statement<'_>) -> Result<(), XqliteError> {
    if stmt.column_count() == 0 && stmt.parameter_count() == 0 && stmt.expanded_sql().is_none()
    {
        Err(XqliteError::CannotExecute(
            "SQL contains no statement".to_string(),
        ))
    } else {
        Ok(())
    }
}

/// Refuse a positional parameter list whose length is not the statement's own
/// parameter count, before a single value is bound.
///
/// rusqlite's checked binding refuses the same lists a step later, but it stops
/// at the first index the statement does not have and reports THAT index: a
/// statement taking one parameter given three values would answer `provided:
/// 2`. Counting the list here makes `provided` the list's own length, the same
/// number the raw-FFI doors report (`stream.rs:require_parameter_count`).
#[inline]
fn require_parameter_count(stmt: &Statement<'_>, provided: usize) -> Result<(), XqliteError> {
    let expected = stmt.parameter_count();

    match provided == expected {
        true => Ok(()),
        false => Err(XqliteError::InvalidParameterCount { provided, expected }),
    }
}

/// Refuses a keyword list that does not name every parameter of the statement
/// exactly once, before anything is bound.
///
/// Three refusals, in this order: a key the statement does not have, two keys
/// that name the same parameter, and a parameter no key named. The last is
/// why the walk exists — SQLite reads a parameter nothing was bound to as
/// NULL, so a list that forgets one writes NULL over that column.
///
/// The twin for the raw-FFI doors is
/// `stream.rs:require_named_parameters_covered`.
fn require_named_parameters_covered(
    stmt: &Statement<'_>,
    params: &[(String, Value)],
) -> Result<(), XqliteError> {
    let mut claimed: Vec<usize> = Vec::with_capacity(params.len());

    for (name, _value) in params {
        let index = named_parameter_index(stmt, name)?;

        match claimed.contains(&index) {
            true => return Err(XqliteError::DuplicateParameterName(name.clone())),
            false => claimed.push(index),
        }
    }

    match (1..=stmt.parameter_count()).find(|index| !claimed.contains(index)) {
        None => Ok(()),
        Some(index) => Err(XqliteError::MissingParameter {
            index,
            name: stmt.parameter_name(index).map(str::to_string),
        }),
    }
}

/// The one-based place of the parameter a key names. A name the statement
/// does not have, and one rusqlite cannot even look up (a NUL byte inside
/// it), are the same refusal a raw-FFI door gives.
#[inline]
fn named_parameter_index(stmt: &Statement<'_>, name: &str) -> Result<usize, XqliteError> {
    match stmt.parameter_index(name) {
        Ok(Some(index)) => Ok(index),
        Ok(None) => Err(XqliteError::InvalidParameterName(name.to_string())),
        Err(e) => Err(XqliteError::from(e)),
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
    reject_no_statement(&stmt)?;
    let column_names: Vec<String> =
        stmt.column_names().iter().map(|s| s.to_string()).collect();
    let column_count = column_names.len();

    let rows_result = match walk_params(params_term)? {
        Params::Empty => {
            require_parameter_count(&stmt, 0)?;
            stmt.query([])
        }
        Params::Named(items) => {
            let named_params_vec = decode_exec_keyword_params(env, &items)?;
            require_named_parameters_covered(&stmt, &named_params_vec)?;
            let params_for_rusqlite: Vec<(&str, &dyn ToSql)> = named_params_vec
                .iter()
                .map(|(k, v)| (k.as_str(), v as &dyn ToSql))
                .collect();
            stmt.query(params_for_rusqlite.as_slice())
        }
        Params::Positional(items) => {
            let positional_values: Vec<Value> = decode_plain_list_params(env, &items)?;
            require_parameter_count(&stmt, positional_values.len())?;
            let params_slice: Vec<&dyn ToSql> =
                positional_values.iter().map(|v| v as &dyn ToSql).collect();
            stmt.query(params_slice.as_slice())
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
    reject_no_statement(&stmt)?;

    let affected_rows = match walk_params(params_term)? {
        Params::Empty => {
            require_parameter_count(&stmt, 0)?;
            stmt.execute([])
        }
        Params::Named(items) => {
            let named_params_vec = decode_exec_keyword_params(env, &items)?;
            require_named_parameters_covered(&stmt, &named_params_vec)?;
            let params_for_rusqlite: Vec<(&str, &dyn ToSql)> = named_params_vec
                .iter()
                .map(|(k, v)| (k.as_str(), v as &dyn ToSql))
                .collect();
            stmt.execute(params_for_rusqlite.as_slice())
        }
        Params::Positional(items) => {
            let positional_values: Vec<Value> = decode_plain_list_params(env, &items)?;
            require_parameter_count(&stmt, positional_values.len())?;
            let params_slice: Vec<&dyn ToSql> =
                positional_values.iter().map(|v| v as &dyn ToSql).collect();
            stmt.execute(params_slice.as_slice())
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
