#[macro_use]
extern crate rustler;

use rustler::resource::ResourceArc;
use rustler::schedule::SchedulerFlags;
use rustler::{Encoder, Env, Error, Term};
use std::sync::Mutex;
use std::path::Path;
use rusqlite::{params, Connection, OpenFlags};

mod atoms {
    rustler_atoms! {
        atom ok;
        atom error;
        atom already_closed;
        //atom exec_timeout;
        //atom __true__ = "true";
        //atom __false__ = "false";
    }
}

rustler::rustler_export_nifs! {
    "Elixir.Xqlite.RusqliteNif",
    [
        ("open", 2, open, SchedulerFlags::DirtyIo),
        ("close", 1, close, SchedulerFlags::DirtyIo),
        ("exec", 2, exec, SchedulerFlags::DirtyIo),
    ],
    Some(on_load)
}

struct XqliteConnection {
    conn: Mutex<Option<Connection>>,
}

fn on_load(env: Env, _info: Term) -> bool {
    resource_struct_init!(XqliteConnection, env);
    true
}

fn open<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let db_name: String = args[0].decode()?;
    let path = Path::new(&db_name);
    // let opts: Vec<(Atom, Term)> = args[1].decode()?;

    // for (k, v) in opts.iter() {
    //     println!("key={:?}, value={:?}", k, v);
    // }

    // Ok((db_name, opts).encode(env))

    let flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_CREATE | OpenFlags::SQLITE_OPEN_FULL_MUTEX;
    match Connection::open_with_flags(path, flags) {
        Ok(conn) => {
            let mutex = Mutex::new(Some(conn));
            let xconn = XqliteConnection { conn: mutex };
            let wrapper = ResourceArc::new(xconn);
            let result: Result<_, Term<'a>> = Ok(wrapper);
            Ok(result.encode(env))
        }
        Err(err) => {
            let err: Result<Term<'a>, _> = Err(format!("{:?}", err));
            Ok(err.encode(env))
        }
    }
}

fn close<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    match args[0].decode::<ResourceArc<XqliteConnection>>() {
        Ok(wrapper) => {
            let mut mconn = wrapper.conn.lock().unwrap();
            if !mconn.is_none() {
                // Take out the connection so it becomes None in the resource
                // as it is being closed early
                let conn = mconn.take().unwrap();
                match conn.close() {
                    Ok(()) => Ok(atoms::ok().encode(env)),
                    Err((conn, err)) => {
                        // closing failed, put the connection back in the return value.
                        *mconn = Some(conn);
                        let err: Result<Term<'a>, _> = Err(format!("{:?}", err));
                        Ok(err.encode(env))
                    }
                }
            } else {
                Ok((atoms::error(), atoms::already_closed()).encode(env))
            }
        }
        Err(err) => Err(err),
    }
}

fn exec<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let wrapper = args[0].decode::<ResourceArc<XqliteConnection>>()?;
    let sql = args[1].decode::<String>()?;

    match *wrapper.conn.lock().unwrap() {
        Some(conn) => {
            match conn.execute(&sql, params![]) {
                Ok(affected) => {
                    Ok((atoms::ok(), ResourceArc::new(affected)).encode(env))
                }
                Err(err) => Err(err)
            }
        }
        None => {
            Ok((atoms::error(), atoms::already_closed()).encode(env))
        }
    }
}
