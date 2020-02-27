#[macro_use] extern crate rustler;

use std::sync::Mutex;
use rustler::{Encoder, Env, Error, Term};
use rustler::schedule::SchedulerFlags;
use rustler::resource::ResourceArc;
//use rusqlite::{params, Connection, Result};

mod atoms {
    rustler_atoms! {
        atom ok;
        atom error;
        atom badarg;
        //atom exec_timeout;
        //atom __true__ = "true";
        //atom __false__ = "false";
    }
}

rustler::rustler_export_nifs! {
    "Elixir.Xqlite.RusqliteNif",
    [
        ("add", 2, add),
        ("open", 2, open, SchedulerFlags::DirtyIo),
        ("close", 2, close, SchedulerFlags::DirtyIo)
    ],
    Some(on_load)
}

struct XqliteConnection {
    conn: Mutex<rusqlite::Connection>
}

fn on_load(env: Env, _info: Term) -> bool {
    resource_struct_init!(XqliteConnection, env);
    true
}

fn add<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    let num1: i64 = args[0].decode()?;
    let num2: i64 = args[1].decode()?;

    Ok((atoms::ok(), num1 + num2).encode(env))
}

fn open<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    // let db_name: String = args[0].decode()?;
    // let opts: Vec<(Atom, Term)> = args[1].decode()?;

    // for (k, v) in opts.iter() {
    //     println!("key={:?}, value={:?}", k, v);
    // }

    // Ok((db_name, opts).encode(env))

    match rusqlite::Connection::open_in_memory() {
        Ok(conn) => {
            let mutex = Mutex::new(conn);
            let xconn = XqliteConnection { conn: mutex };
            let wrapper = ResourceArc::new(xconn);
            Ok((atoms::ok(), wrapper).encode(env))
        },
        Err(err) => {
            Ok((atoms::error(), format!("{}", err)).encode(env))
        },
    }
}

fn close<'a>(env: Env<'a>, args: &[Term<'a>]) -> Result<Term<'a>, Error> {
    match args[0].decode::<ResourceArc<XqliteConnection>>() {
        Ok(wrapper) => {
            let conn = wrapper.conn.lock().unwrap();
            match conn.close() {
                Ok(()) => {
                    Ok(atoms::ok().encode(env))
                },
                Err((conn, err)) => {
                    Ok((atoms::error(), wrapper).encode(env))
                }
            }
        }
        Err(err) => {
            unsafe {
                Ok((atoms::error(), err).encode(env))
            }
        }
    }
}
