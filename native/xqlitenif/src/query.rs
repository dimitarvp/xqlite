use crate::connection::XqliteQueryResult;
use crate::error::XqliteError;
use crate::util::{
    Params, decode_exec_keyword_params, decode_plain_list_params, process_rows, walk_params,
};
use rusqlite::types::Value;
use rusqlite::{Connection, Statement, ToSql};
use rustler::{Env, Term};
use std::collections::HashMap;

/// Refuses a positional list holding a value over the connection's length
/// limit, before rusqlite binds anything.
///
/// rusqlite reads that limit only behind its `limits` feature, which this
/// crate does not enable, so the read goes straight to the C function on the
/// connection's own handle.
fn require_positional_within_length(
    conn: &Connection,
    params: &[Value],
) -> Result<(), XqliteError> {
    // SAFETY: the caller holds the connection Mutex for the whole call, so no
    // other thread is inside a `sqlite3_*` call on this connection, and
    // `handle()` is the live `sqlite3*` that Mutex guards.
    unsafe { crate::limits::require_positional_within_length(conn.handle(), params) }
}

/// The keyword twin of `require_positional_within_length`.
fn require_named_within_length(
    conn: &Connection,
    params: &[(String, Value)],
) -> Result<(), XqliteError> {
    // SAFETY: as in `require_positional_within_length`.
    unsafe { crate::limits::require_named_within_length(conn.handle(), params) }
}

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
/// `readonly()` is the tell: `sqlite3_stmt_readonly` answers true for a NULL
/// statement, which is the one thing rusqlite's public API reports differently
/// for one. It is true of plenty of real statements too — every SELECT, the
/// transaction-control ones, `SAVEPOINT` and `RELEASE` — so the other three
/// conditions narrow it, and `expanded_sql()` is what tells a NULL statement
/// from `BEGIN`. That last one answers nothing for an expansion longer than
/// the connection's length limit as well, so the read lifts the limit and puts
/// it back: otherwise a caller who lowered it would see `SAVEPOINT` read as no
/// statement.
#[inline]
fn reject_no_statement(conn: &Connection, stmt: &Statement<'_>) -> Result<(), XqliteError> {
    if stmt.column_count() == 0
        && stmt.parameter_count() == 0
        && stmt.readonly()
        && expansion_absent(conn, stmt)
    {
        Err(XqliteError::NoStatement)
    } else {
        Ok(())
    }
}

/// Whether SQLite has no expansion for this statement, judged with the
/// connection's length limit out of the way. The three cheap conditions come
/// first, so a statement with columns or parameters pays no C call for this.
fn expansion_absent(conn: &Connection, stmt: &Statement<'_>) -> bool {
    // SAFETY: the caller holds the connection Mutex for the whole call, so no
    // other thread is inside a `sqlite3_*` call on this connection, and
    // `handle()` is the live `sqlite3*` that Mutex guards.
    unsafe {
        crate::limits::with_length_limit_lifted(conn.handle(), || {
            stmt.expanded_sql().is_none()
        })
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
) -> Result<Vec<usize>, XqliteError> {
    let count = stmt.parameter_count();
    let by_name = parameter_indices_by_name(stmt);
    let mut indices: Vec<usize> = Vec::with_capacity(params.len());
    let mut claimed = vec![false; count + 1];

    for (name, _value) in params {
        let index = match by_name.get(name.as_str()) {
            None => return Err(XqliteError::InvalidParameterName(name.clone())),
            Some(index) => *index,
        };

        // An index the flag vector has no room for would be SQLite answering
        // outside its own parameter count.
        match claimed.get_mut(index) {
            None => return Err(XqliteError::InvalidParameterName(name.clone())),
            Some(flag) if *flag => {
                return Err(XqliteError::DuplicateParameterName(name.clone()));
            }
            Some(flag) => {
                *flag = true;
                indices.push(index);
            }
        }
    }

    match (1..=count).find(|index| claimed.get(*index) != Some(&true)) {
        None => Ok(indices),
        Some(index) => Err(XqliteError::MissingParameter {
            index,
            name: stmt.parameter_name(index).map(str::to_string),
        }),
    }
}

/// SQLite's own spelling of every named parameter, against its one-based
/// index, so that each key costs one hash lookup instead of a call to
/// `Statement::parameter_index`, which walks the statement's whole name list
/// with one string comparison per name. A bare `?` has no name and is left
/// out.
///
/// The twin for the raw-FFI doors is `stream.rs:parameter_indices_by_name`.
fn parameter_indices_by_name<'a>(stmt: &'a Statement<'a>) -> HashMap<&'a str, usize> {
    (1..=stmt.parameter_count())
        .filter_map(|index| stmt.parameter_name(index).map(|name| (name, index)))
        .collect()
}

/// Binds each value at the index the coverage walk resolved its key to, so
/// no name is looked up twice. rusqlite's own named binding would resolve
/// every name again through its parameter cache, which this walk no longer
/// fills.
fn bind_named_by_index(
    stmt: &mut Statement<'_>,
    params: &[(String, Value)],
    indices: &[usize],
) -> Result<(), XqliteError> {
    params
        .iter()
        .zip(indices)
        .try_for_each(|((_name, value), index)| {
            stmt.raw_bind_parameter(*index, value)
                .map_err(XqliteError::from)
        })
}

pub(crate) fn core_query<'a>(
    env: Env<'a>,
    conn: &Connection,
    sql: &str,
    params_term: Term<'a>,
) -> Result<XqliteQueryResult<'a>, XqliteError> {
    reject_interior_nul(sql)?;
    let mut stmt = conn.prepare(sql)?;
    reject_no_statement(conn, &stmt)?;
    let column_names: Vec<String> =
        stmt.column_names().iter().map(|s| s.to_string()).collect();
    let column_count = column_names.len();

    let rows = match walk_params(params_term)? {
        Params::Empty => {
            require_parameter_count(&stmt, 0)?;
            stmt.query([])?
        }
        Params::Named(items) => {
            let named_params_vec =
                decode_exec_keyword_params(env, &items, stmt.parameter_count())?;
            let indices = require_named_parameters_covered(&stmt, &named_params_vec)?;
            require_named_within_length(conn, &named_params_vec)?;
            bind_named_by_index(&mut stmt, &named_params_vec, &indices)?;
            stmt.raw_query()
        }
        Params::Positional(items) => {
            let positional_values: Vec<Value> = decode_plain_list_params(env, &items)?;
            require_parameter_count(&stmt, positional_values.len())?;
            require_positional_within_length(conn, &positional_values)?;
            let params_slice: Vec<&dyn ToSql> =
                positional_values.iter().map(|v| v as &dyn ToSql).collect();
            stmt.query(params_slice.as_slice())?
        }
    };

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
    reject_no_statement(conn, &stmt)?;

    let affected_rows = match walk_params(params_term)? {
        Params::Empty => {
            require_parameter_count(&stmt, 0)?;
            stmt.execute([])?
        }
        Params::Named(items) => {
            let named_params_vec =
                decode_exec_keyword_params(env, &items, stmt.parameter_count())?;
            let indices = require_named_parameters_covered(&stmt, &named_params_vec)?;
            require_named_within_length(conn, &named_params_vec)?;
            bind_named_by_index(&mut stmt, &named_params_vec, &indices)?;
            stmt.raw_execute()?
        }
        Params::Positional(items) => {
            let positional_values: Vec<Value> = decode_plain_list_params(env, &items)?;
            require_parameter_count(&stmt, positional_values.len())?;
            require_positional_within_length(conn, &positional_values)?;
            let params_slice: Vec<&dyn ToSql> =
                positional_values.iter().map(|v| v as &dyn ToSql).collect();
            stmt.execute(params_slice.as_slice())?
        }
    };

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
