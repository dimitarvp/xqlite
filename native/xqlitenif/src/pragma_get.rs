use rustler::resource::ResourceArc;
use rustler::{Encoder, Env, Term};

use crate::atoms::{already_closed, error, ok, pragma_get_failed};
use crate::shared::{database_name_from_opts, XqliteConnection, XqliteValue};

enum PragmaGetResult {
    Success(Vec<Vec<(String, XqliteValue)>>),
    AlreadyClosed,
    Failure(String),
}

impl<'a> Encoder for PragmaGetResult {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        match self {
            PragmaGetResult::Success(results) => (ok(), results).encode(env),
            PragmaGetResult::AlreadyClosed => (error(), already_closed()).encode(env),
            PragmaGetResult::Failure(msg) => (error(), pragma_get_failed(), msg).encode(env),
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn pragma_get0(
    arc: ResourceArc<XqliteConnection>,
    pragma_name: &str,
    opts: Vec<Term>,
) -> PragmaGetResult {
    let locked = arc.0.lock().unwrap();
    match &*locked {
        Some(conn) => {
            let database_name = database_name_from_opts(&opts);

            let mut acc: Vec<Vec<(String, XqliteValue)>> = Vec::new();
            let gather_pragmas = |row: &rusqlite::Row| -> rusqlite::Result<()> {
                let column_count = row.column_count();
                let mut fields: Vec<(String, XqliteValue)> = Vec::with_capacity(column_count);
                for i in 0..column_count {
                    if let Ok(name) = row.column_name(i) {
                        if let Ok(value) = row.get(i) {
                            fields.push((String::from(name), XqliteValue(value)));
                        }
                    }
                }

                acc.push(fields);
                Ok(())
            };

            match conn.pragma_query(Some(database_name), pragma_name, gather_pragmas) {
                Ok(_) => PragmaGetResult::Success(acc),
                Err(err) => {
                    let msg: String = format!("{:?}", err);
                    PragmaGetResult::Failure(msg)
                }
            }
        }
        None => PragmaGetResult::AlreadyClosed,
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn pragma_get1(
    arc: ResourceArc<XqliteConnection>,
    pragma_name: &str,
    param: &str,
    opts: Vec<Term>,
) -> PragmaGetResult {
    let locked = arc.0.lock().unwrap();
    match &*locked {
        Some(conn) => {
            let database_name = database_name_from_opts(&opts);

            let mut acc: Vec<Vec<(String, XqliteValue)>> = Vec::new();
            let gather_pragmas = |row: &rusqlite::Row| -> rusqlite::Result<()> {
                let column_count = row.column_count();
                let mut fields: Vec<(String, XqliteValue)> = Vec::with_capacity(column_count);
                for i in 0..column_count {
                    if let Ok(name) = row.column_name(i) {
                        if let Ok(value) = row.get(i) {
                            fields.push((String::from(name), XqliteValue(value)));
                        }
                    }
                }

                acc.push(fields);
                Ok(())
            };

            match conn.pragma(
                Some(database_name),
                pragma_name,
                &String::from(param),
                gather_pragmas,
            ) {
                Ok(_) => PragmaGetResult::Success(acc),
                Err(err) => {
                    let msg: String = format!("{:?}", err);
                    PragmaGetResult::Failure(msg)
                }
            }
        }
        None => PragmaGetResult::AlreadyClosed,
    }
}
