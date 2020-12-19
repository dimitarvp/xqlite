use crate::atoms::{already_closed, cannot_execute, db_name, unsupported_value};
use rusqlite::{Connection, DatabaseName};
use rustler::resource::ResourceArc;
use rustler::types::atom::{error, nil, ok};
use rustler::{Encoder, Env, Term};
use std::sync::Mutex;

pub struct XqliteConnection(pub Mutex<Option<Connection>>);
pub struct XqliteValue(pub rusqlite::types::Value);

pub enum SharedResult<'a, T> {
    Success(T),
    SuccessWithoutValue,
    UnsupportedValue(Term<'a>),
    AlreadyClosed,
    Failure(String),
}

impl<'a, T> Encoder for SharedResult<'_, T>
where
    T: Encoder,
{
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        match self {
            SharedResult::Success(value) => (ok(), value).encode(env),
            SharedResult::SuccessWithoutValue => (ok()).encode(env),
            SharedResult::UnsupportedValue(term) => {
                (error(), unsupported_value(), term).encode(env)
            }
            SharedResult::AlreadyClosed => (error(), already_closed()).encode(env),
            SharedResult::Failure(msg) => (error(), cannot_execute(), msg).encode(env),
        }
    }
}

pub fn use_conn<'a, F, T>(
    container: ResourceArc<XqliteConnection>,
    consume: F,
) -> SharedResult<'a, T>
where
    F: FnOnce(&Connection) -> SharedResult<'a, T>,
    T: Encoder,
{
    let locked = container.0.lock().unwrap();
    match &*locked {
        Some(conn) => consume(conn),
        None => SharedResult::AlreadyClosed,
    }
}

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

pub fn database_name_from_opts<'a>(opts: &'a Vec<Term>) -> DatabaseName<'a> {
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

    database_name
}

// Transforms an Erlang term to rusqlite value, limited to what the pragma updating
// functions are willing to accept.
pub fn term_to_pragma_value<'a>(input: Term<'a>) -> Result<rusqlite::types::Value, Term<'a>> {
    match input.get_type() {
        rustler::TermType::Atom => {
            let decoded: Result<rustler::types::Atom, rustler::error::Error> = input.decode();
            if let Ok(atom_value) = decoded {
                if atom_value == nil() {
                    // Only the `nil` Erlang atom is accepted.
                    return Ok(rusqlite::types::Value::Null);
                }
            }

            // All other atoms except `nil` are rejected.
            Err(input)
        }
        rustler::TermType::Number => {
            // Attempt to decode a 64-bit signed integer or a 64-bit floating point number.
            let decoded_i64: Result<i64, rustler::error::Error> = input.decode();
            if let Ok(an_i64) = decoded_i64 {
                return Ok(rusqlite::types::Value::Integer(an_i64));
            } else {
                let decoded_f64: Result<f64, rustler::error::Error> = input.decode();
                if let Ok(an_f64) = decoded_f64 {
                    return Ok(rusqlite::types::Value::Real(an_f64));
                }
            }

            Err(input)
        }
        rustler::TermType::Binary => {
            // Anything that's a valid string (including e.g. [0, 0, 0, 0]) is going
            // to be decoded into a Rust string.
            // Everything else (f.ex. [255, 255]) is going to be decoded to `&[u8]`
            // (a byte array slice) and then turned into a `Vec<u8>`.
            let decoded_string: Result<String, rustler::error::Error> = input.decode();
            if let Ok(string) = decoded_string {
                return Ok(rusqlite::types::Value::Text(string));
            } else {
                let decoded_blob: Result<rustler::types::Binary, rustler::error::Error> =
                    rustler::types::Binary::from_term(input);
                if let Ok(blob) = decoded_blob {
                    let slice: &'a [u8] = blob.as_slice();
                    return Ok(rusqlite::types::Value::Blob(slice.to_vec()));
                }
            }

            Err(input)
        }
        _ => Err(input),
    }
}
