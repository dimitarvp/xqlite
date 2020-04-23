use rusqlite::{Connection, OpenFlags};
use rustler::resource::ResourceArc;
use rustler::{atoms, Encoder, Env, Term};
use std::path::Path;
use std::sync::Mutex;

atoms!(ok, error, cannot_close, already_closed);

struct XqliteConnection(Mutex<Option<Connection>>);

enum OpenResult {
    Success(ResourceArc<XqliteConnection>),
    Failure(String),
}

impl<'a> Encoder for OpenResult {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        match self {
            OpenResult::Success(arc) => (ok(), arc).encode(env),
            OpenResult::Failure(msg) => (error(), msg).encode(env),
        }
    }
}

enum CloseResult {
    Success,
    AlreadyClosed,
    Failure(String)
}

impl<'a> Encoder for CloseResult {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        match self {
            CloseResult::Success => (ok()).encode(env),
            CloseResult::AlreadyClosed => (error(), already_closed()).encode(env),
            CloseResult::Failure(msg) => (error(), cannot_close(), msg).encode(env),
        }
    }
}

fn on_load(env: Env, _info: Term) -> bool {
    rustler::resource!(XqliteConnection, env);
    true
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
        Err(err) => {
            let msg: String = format!("{:?}", err);
            OpenResult::Failure(msg)
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn close(arc: ResourceArc<XqliteConnection>) -> CloseResult {
    let mut mconn = arc.0.lock().unwrap();
    if !mconn.is_none() {
        // Take out the connection so it becomes None in the resource
        // as it is being closed early.
        let conn: Connection = mconn.take().unwrap();
        match conn.close() {
            Ok(()) => CloseResult::Success,
            Err((conn, err)) => {
                // Closing failed, put the connection back in the original container.
                *mconn = Some(conn);
                let msg: String = format!("{:?}", err);
                CloseResult::Failure(msg)
            }
        }
    } else {
        CloseResult::AlreadyClosed
    }
}

rustler::init!("Elixir.XqliteNIF", [open, close], load = on_load);
