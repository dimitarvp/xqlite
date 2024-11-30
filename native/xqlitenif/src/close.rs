use rusqlite::Connection;
use rustler::ResourceArc;
use rustler::{Encoder, Env, Term};

use crate::atoms::{already_closed, cannot_close, error, ok};
use crate::shared::XqliteConnection;

enum CloseResult {
    Success,
    AlreadyClosed,
    Failure(String),
}

impl Encoder for CloseResult {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        match self {
            CloseResult::Success => (ok()).encode(env),
            CloseResult::AlreadyClosed => (error(), already_closed()).encode(env),
            CloseResult::Failure(msg) => (error(), cannot_close(), msg).encode(env),
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn close(container: ResourceArc<XqliteConnection>) -> CloseResult {
    let mut mconn = container.0.lock().unwrap();
    if !mconn.is_none() {
        // Take out the connection so it becomes None in the resource
        // as it is being closed early.
        let conn: Connection = mconn.take().unwrap();
        match conn.close() {
            Ok(()) => CloseResult::Success,
            Err((conn, e)) => {
                // Closing failed, put the connection back in the original container.
                *mconn = Some(conn);
                CloseResult::Failure(e.to_string())
            }
        }
    } else {
        CloseResult::AlreadyClosed
    }
}
