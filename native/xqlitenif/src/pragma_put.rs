use rustler::resource::ResourceArc;
use rustler::{Encoder, Env, Term};

use crate::atoms::{
    already_closed, error, ok, pragma_put_failed, unsupported_pragma_put_value,
};
use crate::shared::{
    database_name_from_opts, term_to_pragma_value, XqliteConnection, XqliteValue,
};

enum PragmaPutResult<'a> {
    SuccessWithoutValue,
    SuccessWithValue(Vec<Vec<(String, XqliteValue)>>),
    UnsupportedValue(Term<'a>),
    AlreadyClosed,
    Failure(String),
}

impl<'a> Encoder for PragmaPutResult<'_> {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        match self {
            PragmaPutResult::SuccessWithoutValue => (ok()).encode(env),
            PragmaPutResult::SuccessWithValue(result) => (ok(), result).encode(env),
            PragmaPutResult::UnsupportedValue(term) => {
                (error(), unsupported_pragma_put_value(), term).encode(env)
            }
            PragmaPutResult::AlreadyClosed => (error(), already_closed()).encode(env),
            PragmaPutResult::Failure(msg) => (error(), pragma_put_failed(), msg).encode(env),
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn pragma_put<'a>(
    arc: ResourceArc<XqliteConnection>,
    pragma_name: &str,
    pragma_value: Term<'a>,
    opts: Vec<Term>,
) -> PragmaPutResult<'a> {
    let locked = arc.0.lock().unwrap();
    match &*locked {
        Some(conn) => {
            let native_pragma_value: rusqlite::types::Value;

            match term_to_pragma_value(pragma_value) {
                Ok(value) => {
                    native_pragma_value = value;
                }
                Err(term) => return PragmaPutResult::UnsupportedValue(term),
            }

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

            match conn.pragma_update_and_check(
                Some(database_name),
                pragma_name,
                &native_pragma_value,
                gather_pragmas,
            ) {
                Ok(_) => PragmaPutResult::SuccessWithValue(acc),
                Err(err) => match err {
                    rusqlite::Error::QueryReturnedNoRows => {
                        PragmaPutResult::SuccessWithoutValue
                    }
                    _ => {
                        let msg: String = format!("{:?}", err);
                        PragmaPutResult::Failure(msg)
                    }
                },
            }
        }
        None => PragmaPutResult::AlreadyClosed,
    }
}
