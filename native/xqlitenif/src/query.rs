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

/// Reads a caller's list of SQL texts, before the connection is locked.
pub(crate) fn text_list(term: Term<'_>) -> Result<Vec<String>, XqliteError> {
    crate::util::walk_list(term)?
        .into_iter()
        .enumerate()
        .map(|(index, item)| {
            let bytes: rustler::Binary = item
                .decode()
                .map_err(|_not_binary| XqliteError::bad_element(index + 1, item))?;
            std::str::from_utf8(bytes.as_slice())
                .map(str::to_owned)
                .map_err(|_not_utf8| XqliteError::InvalidUtf8InString)
        })
        .collect()
}

/// Runs the STRICT rebuild's statements, each exactly one, in one
/// `BEGIN IMMEDIATE` transaction inside the caller's one hold of the
/// connection Mutex, so no other caller of the connection runs between them.
/// `foreign_keys` goes off before the `BEGIN`, since SQLite drops that write
/// inside a transaction, and `legacy_alter_table` on, or the rename re-parses
/// every view and trigger and fails on one still naming the original; both
/// are written back once the transaction has ended. Each failure becomes its
/// error before the `ROLLBACK` resets the connection's message.
pub(crate) fn strict_rebuild(
    conn: &Connection,
    statements: &[String],
    schema: &str,
    table: &str,
    schema_version: i64,
    stored: &[String],
) -> Result<(), XqliteError> {
    if !conn.is_autocommit() {
        return Err(XqliteError::TransactionInProgress);
    }
    crate::progress_dispatch::require_idle(conn)?;
    crate::schema::require_schema(conn, schema)?;
    let flag = |name: &str| conn.pragma_query_value(None, name, |row| row.get::<_, i64>(0));
    let restore = format!(
        "PRAGMA foreign_keys = {}; PRAGMA legacy_alter_table = {}",
        flag("foreign_keys")?,
        flag("legacy_alter_table")?
    );
    // SAFETY: the caller holds the connection Mutex for the whole call and `db` is its live
    // handle; each statement's error is read before its holder finalizes it.
    unsafe {
        let db = conn.handle();
        let run = |sql: &String| {
            let held = PreparedStmt::new(statement::prepare_one(db, sql)?);
            let mut rc = rusqlite::ffi::sqlite3_step(held.as_ptr());
            while rc == rusqlite::ffi::SQLITE_ROW {
                rc = rusqlite::ffi::sqlite3_step(held.as_ptr());
            }
            match rc {
                rusqlite::ffi::SQLITE_DONE => Ok(()),
                failed => Err(crate::error::prepare_failure(db, failed, sql)),
            }
        };
        let begin =
            "PRAGMA foreign_keys = OFF; PRAGMA legacy_alter_table = ON; BEGIN IMMEDIATE";
        let result = statement::execute_batch(db, begin, &[])
            .and_then(|()| require_unchanged(conn, schema, table, schema_version, stored))
            .and_then(|()| statements.iter().try_for_each(run))
            .and_then(|()| statement::execute_batch(db, "COMMIT", &[]));
        if result.is_err() && !conn.is_autocommit() {
            let _ = statement::execute_batch(db, "ROLLBACK", &[]);
        }
        result.and(statement::execute_batch(db, &restore, &[]))
    }
}

/// Answers `TableChanged` unless the schema's version and the stored texts of
/// the table, its indexes and its triggers, TEMP ones included, in any order,
/// are still the ones the plan was built from.
fn require_unchanged(
    conn: &Connection,
    schema: &str,
    table: &str,
    schema_version: i64,
    stored: &[String],
) -> Result<(), XqliteError> {
    let quoted = crate::util::quote_identifier(schema)?;
    let version: i64 =
        conn.query_row(&format!("PRAGMA {quoted}.schema_version"), [], |row| {
            row.get(0)
        })?;
    let own = format!(
        "SELECT sql FROM {quoted}.sqlite_master WHERE tbl_name = ?1 AND sql IS NOT NULL \
         AND type IN ('table', 'index', 'trigger')"
    );
    let sql = match schema.eq_ignore_ascii_case("temp") {
        true => own,
        false => {
            own + " UNION ALL SELECT sql FROM temp.sqlite_master WHERE tbl_name = ?1 \
               AND sql IS NOT NULL AND type = 'trigger'"
        }
    };
    let mut live = conn
        .prepare(&sql)?
        .query_map([table], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    let mut expected = stored.to_vec();
    live.sort_unstable();
    expected.sort_unstable();
    match version == schema_version && live == expected {
        true => Ok(()),
        false => Err(XqliteError::TableChanged {
            table: table.to_owned(),
        }),
    }
}
