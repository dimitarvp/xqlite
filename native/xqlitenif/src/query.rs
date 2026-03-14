use crate::cancel::ProgressHandlerGuard;
use crate::connection::XqliteQueryResult;
use crate::error::XqliteError;
use crate::util::{
    decode_exec_keyword_params, decode_plain_list_params, is_keyword, process_rows,
};
use rusqlite::types::Value;
use rusqlite::{Connection, ToSql};
use rustler::types::atom::nil;
use rustler::{Env, Term, TermType};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

pub(crate) fn core_query<'a>(
    env: Env<'a>,
    conn: &Connection,
    sql: &str,
    params_term: Term<'a>,
    token_bool_opt: Option<Arc<AtomicBool>>,
) -> Result<XqliteQueryResult<'a>, XqliteError> {
    let _guard = token_bool_opt
        .map(|token_bool| ProgressHandlerGuard::new(conn, token_bool, 8))
        .transpose()?;

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

pub(crate) fn core_execute<'a>(
    env: Env<'a>,
    conn: &Connection,
    sql: &str,
    params_term: Term<'a>,
    token_bool_opt: Option<Arc<AtomicBool>>,
) -> Result<usize, XqliteError> {
    let _guard = token_bool_opt
        .map(|token_bool| ProgressHandlerGuard::new(conn, token_bool, 8))
        .transpose()?;

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
    token_bool_opt: Option<Arc<AtomicBool>>,
) -> Result<(), XqliteError> {
    let _guard = token_bool_opt
        .map(|token_bool| ProgressHandlerGuard::new(conn, token_bool, 8))
        .transpose()?;
    conn.execute_batch(sql_batch)?;
    Ok(())
}
