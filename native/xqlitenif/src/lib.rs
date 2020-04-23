use rusqlite::{Connection, OpenFlags};
use rustler::resource::ResourceArc;
use rustler::{atoms, Encoder, Env, Term};
use std::path::Path;
use std::sync::Mutex;

atoms!(ok, error, already_closed);

struct XqliteConnection(Mutex<Connection>);

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
            let mutex = Mutex::new(conn);
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

rustler::init!("Elixir.XqliteNIF", [open], load = on_load);
