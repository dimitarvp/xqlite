use rusqlite::params;
use rustler::resource::ResourceArc;
use rustler::{Encoder, Env, Term};

use crate::atoms::{already_closed, cannot_execute, error, ok};
use crate::shared::XqliteConnection;

enum ExecResult {
    Success(usize),
    AlreadyClosed,
    Failure(String),
}

impl<'a> Encoder for ExecResult {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        match self {
            ExecResult::Success(affected) => (ok(), affected).encode(env),
            ExecResult::AlreadyClosed => (error(), already_closed()).encode(env),
            ExecResult::Failure(msg) => (error(), cannot_execute(), msg).encode(env),
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn exec(arc: ResourceArc<XqliteConnection>, sql: String) -> ExecResult {
    let locked = arc.0.lock().unwrap();
    match &*locked {
        Some(conn) => match conn.execute(&sql, params![]) {
            Ok(affected) => ExecResult::Success(affected),
            Err(e) => ExecResult::Failure(e.to_string()),
        },
        None => ExecResult::AlreadyClosed,
    }
}
