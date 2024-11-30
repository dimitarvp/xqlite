use crate::atoms::{error, ok};
use crate::shared::XqliteConnection;
use rusqlite::{Connection, OpenFlags};
use rustler::ResourceArc;
use rustler::{Encoder, Env, Term};
use std::path::Path;
use std::sync::Mutex;

enum OpenResult {
    Success(ResourceArc<XqliteConnection>),
    Failure(String),
}

impl Encoder for OpenResult {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        match self {
            OpenResult::Success(arc) => (ok(), arc).encode(env),
            OpenResult::Failure(msg) => (error(), msg).encode(env),
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn open(db_name: String, _opts: Vec<Term>) -> OpenResult {
    let path = Path::new(&db_name);

    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE
        | OpenFlags::SQLITE_OPEN_CREATE
        | OpenFlags::SQLITE_OPEN_FULL_MUTEX;

    match Connection::open_with_flags(path, flags) {
        Ok(conn) => {
            let mutex = Mutex::new(Some(conn));
            let xconn = XqliteConnection(mutex);
            let wrapper = ResourceArc::new(xconn);
            OpenResult::Success(wrapper)
        }
        Err(e) => OpenResult::Failure(e.to_string()),
    }
}
