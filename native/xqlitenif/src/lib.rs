use rusqlite::{params, Connection, DatabaseName, OpenFlags};
use rustler::resource::ResourceArc;
use rustler::{Encoder, Env, Term};
use std::path::Path;
use std::sync::Mutex;

rustler::atoms! {
    already_closed,
    cannot_close,
    cannot_decode,
    cannot_execute,
    db_name,
    error,
    nil,
    ok
}

struct XqliteConnection(Mutex<Option<Connection>>);
struct XqliteValue(rusqlite::types::Value);

impl<'a> Encoder for XqliteValue {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        match &self.0 {
            rusqlite::types::Value::Null => nil().encode(env),
            rusqlite::types::Value::Integer(i) => i.encode(env),
            rusqlite::types::Value::Real(f) => f.encode(env),
            rusqlite::types::Value::Text(s) => s.encode(env),
            rusqlite::types::Value::Blob(b) => b.encode(env),
        }
    }
}

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
    Failure(String),
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

#[rustler::nif(schedule = "DirtyIo")]
fn exec(arc: ResourceArc<XqliteConnection>, sql: String) -> ExecResult {
    let locked = arc.0.lock().unwrap();
    match &*locked {
        Some(conn) => match conn.execute(&sql, params![]) {
            Ok(affected) => ExecResult::Success(affected),
            Err(err) => {
                let msg: String = format!("{:?}", err);
                ExecResult::Failure(msg)
            }
        },
        None => ExecResult::AlreadyClosed,
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn pragma_get<'a>(
    env: Env<'a>,
    arc: ResourceArc<XqliteConnection>,
    pragma_name: &str,
    opts: Vec<Term>,
) -> Term<'a> {
    let locked = arc.0.lock().unwrap();
    match &*locked {
        Some(conn) => {
            let mut database_name = DatabaseName::Main;

            // Scan for options that need to be mapped to stricter Rust types.
            for opt in opts.iter() {
                if let rustler::TermType::Tuple = opt.get_type() {
                    let result: Result<(rustler::types::Atom, &str), rustler::error::Error> =
                        opt.decode();
                    if let Ok((key, value)) = result {
                        if key == db_name() {
                            // Provide mapping from string to a proper rusqlite enum.
                            database_name = match value {
                                "main" => DatabaseName::Main,
                                "temp" => DatabaseName::Temp,
                                string => DatabaseName::Attached(string),
                            }
                        }
                    }
                }
            }

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
                Ok(_) => (ok(), acc).encode(env),
                Err(err) => {
                    let msg: String = format!("{:?}", err);
                    (error(), msg).encode(env)
                }
            }
        }
        None => (error(), already_closed()).encode(env),
    }
}

rustler::init!(
    "Elixir.XqliteNIF",
    [open, close, exec, pragma_get],
    load = on_load
);
