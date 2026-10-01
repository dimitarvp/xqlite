use crate::busy_handler;
use crate::connection::XqliteQueryResult;
use crate::error::XqliteError;
use crate::statement::{self, PreparedStmt};
use crate::stream;
use rusqlite::{Connection, ffi};
use rustler::{Env, Term};
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

/// Reject SQL text containing an interior NUL byte before it reaches SQLite.
///
/// `statement.rs:prepare_one` hands SQLite the SQL length-delimited
/// (`as_ptr` + `len`), and SQLite's tokenizer STOPS at the first NUL — every
/// byte after it is silently ignored, which can shorten a statement into
/// something unintended. We reject it with `:null_byte_in_string` instead.
#[inline]
pub(crate) fn reject_interior_nul(sql: &str) -> Result<(), XqliteError> {
    if sql.as_bytes().contains(&0) {
        Err(XqliteError::NulErrorInString)
    } else {
        Ok(())
    }
}

/// Runs one statement and answers all of its rows. The names are judged
/// before the bind and the first step, because a write with `RETURNING` runs
/// whole in that step.
pub(crate) fn core_query<'a>(
    env: Env<'a>,
    conn: &Connection,
    sql: &str,
    params_term: Term<'a>,
) -> Result<XqliteQueryResult<'a>, XqliteError> {
    // SAFETY: the caller holds the connection Mutex for the whole call, so
    // `handle()` is the live `sqlite3*` it guards, and the holder finalizes
    // the statement on every way out of this block.
    unsafe {
        let db = conn.handle();
        let held = PreparedStmt::new(statement::prepare_one(db, sql)?);
        let columns = statement::column_names(held.as_ptr())?;
        stream::bind_params(env, held.as_ptr(), db, params_term)?;

        let mut rows = Vec::new();
        while let Some(row) =
            stream::step_under_names(env, held.as_ptr(), db, &columns, rows.is_empty())?
        {
            rows.push(row);
        }

        Ok(XqliteQueryResult {
            num_rows: rows.len(),
            columns,
            rows,
        })
    }
}

/// Runs a query and reports how many rows this statement changed.
pub(crate) fn core_query_with_changes<'a>(
    env: Env<'a>,
    conn: &Connection,
    sql: &str,
    params_term: Term<'a>,
) -> Result<(XqliteQueryResult<'a>, u64), XqliteError> {
    let before = conn.total_changes();
    let qr = core_query(env, conn, sql, params_term)?;
    Ok((qr, changes_since(conn, before)))
}

/// The rows the statement just ran changed. `sqlite3_changes()` is sticky: it
/// keeps the last INSERT, UPDATE or DELETE's count across statements that
/// change nothing (DDL, PRAGMA, BEGIN, VACUUM), so it counts only when
/// `sqlite3_total_changes()` moved across the statement.
fn changes_since(conn: &Connection, total_before: u64) -> u64 {
    match conn.total_changes() == total_before {
        true => 0,
        false => conn.changes(),
    }
}

/// Runs one statement to its end and answers the rows it changed. A row the
/// statement returns is stepped past unread, so no value is ever decoded.
pub(crate) fn core_execute<'a>(
    env: Env<'a>,
    conn: &Connection,
    sql: &str,
    params_term: Term<'a>,
) -> Result<u64, XqliteError> {
    let before = conn.total_changes();
    // SAFETY: the caller holds the connection Mutex for the whole call, so
    // `handle()` is the live `sqlite3*` it guards, and the holder finalizes
    // the statement on every way out of this block.
    unsafe {
        let db = conn.handle();
        let held = PreparedStmt::new(statement::prepare_one(db, sql)?);
        stream::bind_params(env, held.as_ptr(), db, params_term)?;

        let mut rc = ffi::sqlite3_step(held.as_ptr());
        while rc == ffi::SQLITE_ROW {
            rc = ffi::sqlite3_step(held.as_ptr());
        }
        match rc {
            ffi::SQLITE_DONE => Ok(changes_since(conn, before)),
            failed => Err(busy_handler::ffi_rc_to_error(conn, "sqlite3_step", failed)),
        }
    }
}

/// Runs a batch, and when it fails or is cancelled inside a transaction it
/// opened itself — autocommit on before the call and off after — rolls that
/// transaction back before answering. A transaction open before the call stays
/// the caller's, and a ROLLBACK that fails leaves the transaction open under
/// the batch's own error.
pub(crate) fn core_execute_batch(
    conn: &Connection,
    sql_batch: &str,
    tokens: &[Arc<AtomicBool>],
) -> Result<(), XqliteError> {
    let autocommit_before = conn.is_autocommit();
    // SAFETY: the caller holds the connection Mutex for the whole call, and
    // `handle()` is the live `sqlite3*` that Mutex guards.
    unsafe {
        let db = conn.handle();
        let result = statement::execute_batch(db, sql_batch, tokens);

        if result.is_err() && autocommit_before && !conn.is_autocommit() {
            let _ = statement::execute_batch(db, "ROLLBACK", &[]);
        }

        result
    }
}
