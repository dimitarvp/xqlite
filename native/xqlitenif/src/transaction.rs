use crate::atoms;
use crate::error::XqliteError;
use crate::util::quote_identifier;
use rusqlite::Connection;
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
            Err(XqliteError::InvalidTransactionMode)
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
