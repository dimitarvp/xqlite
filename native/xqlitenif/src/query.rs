use rusqlite::NO_PARAMS;
use rustler::resource::ResourceArc;
use rustler::{Encoder, Env, Term};

use crate::atoms::{already_closed, cannot_execute, error, ok};
use crate::shared::{XqliteConnection, XqliteValue};

type QueryResults = Vec<Vec<XqliteValue>>;

enum QueryResult {
    Success(QueryResults),
    AlreadyClosed,
    Failure(String),
}

impl Encoder for QueryResult {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        match self {
            QueryResult::Success(affected) => (ok(), affected).encode(env),
            QueryResult::AlreadyClosed => (error(), already_closed()).encode(env),
            QueryResult::Failure(msg) => (error(), cannot_execute(), msg).encode(env),
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn query(arc: ResourceArc<XqliteConnection>, sql: String) -> QueryResult {
    let locked = arc.0.lock().unwrap();
    match &*locked {
        Some(conn) => {
            // Prepare SQL statement.
            let mut stmt = match conn.prepare(&sql) {
                Ok(x) => x,
                Err(e) => return QueryResult::Failure(e.to_string()),
            };

            // Execute query.
            let mut rows = match stmt.query(NO_PARAMS) {
                Ok(x) => x,
                Err(e) => return QueryResult::Failure(e.to_string()),
            };

            let mut records = Vec::new();

            // Populate and return results.
            loop {
                match rows.next() {
                    Err(e) => return QueryResult::Failure(e.to_string()),
                    Ok(None) => break,
                    Ok(Some(row)) => {
                        let column_count = row.column_count();
                        let mut record = Vec::with_capacity(column_count);
                        for i in 0..column_count {
                            match row.get(i) {
                                Ok(val) => record.push(XqliteValue(val)),
                                // If any record's column value fetching fails,
                                // then we fail the entire query.
                                Err(e) => return QueryResult::Failure(e.to_string()),
                            }
                        }
                        records.push(record);
                    }
                };
            }

            QueryResult::Success(records)
        }
        None => QueryResult::AlreadyClosed,
    }
}
