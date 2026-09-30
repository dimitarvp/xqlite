use crate::atoms;
use crate::error::XqliteError;
use crate::util::quote_identifier;
use rusqlite::{Connection, ffi};
use rustler::Atom;

#[derive(Debug, Clone, Copy)]
pub(crate) enum TransactionMode {
    Deferred,
    Immediate,
    Exclusive,
}

impl TransactionMode {
    pub(crate) fn from_atom(atom: Atom) -> Result<Self, XqliteError> {
        if atom == atoms::deferred() {
            Ok(Self::Deferred)
        } else if atom == atoms::immediate() {
            Ok(Self::Immediate)
        } else if atom == atoms::exclusive() {
            Ok(Self::Exclusive)
        } else {
            Err(XqliteError::InvalidTransactionMode { mode: atom })
        }
    }

    fn as_sql(self) -> &'static str {
        match self {
            Self::Deferred => "BEGIN DEFERRED;",
            Self::Immediate => "BEGIN IMMEDIATE;",
            Self::Exclusive => "BEGIN EXCLUSIVE;",
        }
    }
}

pub(crate) fn begin(conn: &Connection, mode: TransactionMode) -> Result<(), XqliteError> {
    conn.execute(mode.as_sql(), [])
        .map(|_| ())
        .map_err(XqliteError::from)
}

pub(crate) fn commit(conn: &Connection) -> Result<(), XqliteError> {
    match conn.is_autocommit() {
        true => Err(XqliteError::NoTransaction),
        false => execute_classifying_busy(conn, "COMMIT;"),
    }
}

pub(crate) fn rollback(conn: &Connection) -> Result<(), XqliteError> {
    match conn.is_autocommit() {
        true => Err(XqliteError::NoTransaction),
        false => conn
            .execute("ROLLBACK;", [])
            .map(|_| ())
            .map_err(XqliteError::from),
    }
}

pub(crate) fn savepoint(conn: &Connection, name: &str) -> Result<(), XqliteError> {
    let quoted_name = quote_identifier(name);
    let sql = format!("SAVEPOINT {quoted_name};");
    execute_classifying_busy(conn, &sql)
}

pub(crate) fn rollback_to_savepoint(conn: &Connection, name: &str) -> Result<(), XqliteError> {
    let quoted_name = quote_identifier(name);
    let sql = format!("ROLLBACK TO SAVEPOINT {quoted_name};");
    conn.execute(&sql, [])
        .map(|_| ())
        .map_err(XqliteError::from)
}

pub(crate) fn release_savepoint(conn: &Connection, name: &str) -> Result<(), XqliteError> {
    let quoted_name = quote_identifier(name);
    let sql = format!("RELEASE SAVEPOINT {quoted_name};");
    execute_classifying_busy(conn, &sql)
}

fn execute_classifying_busy(conn: &Connection, sql: &str) -> Result<(), XqliteError> {
    match conn.execute(sql, []).map_err(XqliteError::from) {
        // SQLite tests for a running write, a blob open for writing included,
        // before it tries the lock, so one means the busy answer is the caller's own.
        Err(XqliteError::DatabaseBusyOrLocked { .. }) if write_mid_run(conn) => {
            Err(XqliteError::StatementMidRun)
        }
        other => other.map(|_| ()),
    }
}

fn write_mid_run(conn: &Connection) -> bool {
    // SAFETY: the caller holds the connection Mutex, so `handle()` is the live
    // `sqlite3*` and no other call can change its statement list during the walk.
    unsafe {
        let db = conn.handle();
        let mut stmt = ffi::sqlite3_next_stmt(db, std::ptr::null_mut());
        while !stmt.is_null()
            && (ffi::sqlite3_stmt_busy(stmt) == 0 || ffi::sqlite3_stmt_readonly(stmt) != 0)
        {
            stmt = ffi::sqlite3_next_stmt(db, stmt);
        }
        !stmt.is_null()
    }
}
