use crate::error::XqliteError;
use crate::util::quote_identifier;
use rusqlite::Connection;

pub(crate) fn begin(conn: &Connection) -> Result<(), XqliteError> {
    conn.execute("BEGIN;", [])
        .map(|_| ())
        .map_err(XqliteError::from)
}

pub(crate) fn commit(conn: &Connection) -> Result<(), XqliteError> {
    conn.execute("COMMIT;", [])
        .map(|_| ())
        .map_err(XqliteError::from)
}

pub(crate) fn rollback(conn: &Connection) -> Result<(), XqliteError> {
    conn.execute("ROLLBACK;", [])
        .map(|_| ())
        .map_err(XqliteError::from)
}

pub(crate) fn savepoint(conn: &Connection, name: &str) -> Result<(), XqliteError> {
    let quoted_name = quote_identifier(name);
    let sql = format!("SAVEPOINT {quoted_name};");
    conn.execute(&sql, [])
        .map(|_| ())
        .map_err(XqliteError::from)
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
    conn.execute(&sql, [])
        .map(|_| ())
        .map_err(XqliteError::from)
}
