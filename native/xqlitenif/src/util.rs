use crate::error::XqliteError;
use crate::XqliteConn;
use rusqlite::Connection;
use rusqlite::{types::Value, Rows};
use rustler::types::atom::{false_, nil, true_};
use rustler::{resource_impl, Resource};
use rustler::{
    Atom, Binary, Encoder, Env, Error as RustlerError, ListIterator, ResourceArc, Term,
    TermType,
};
use std::fmt::Debug;
use std::vec::Vec;

#[derive(Debug)]
pub(crate) struct BlobResource(pub(crate) Vec<u8>);
#[resource_impl]
impl Resource for BlobResource {}

pub(crate) fn encode_val(env: Env<'_>, val: rusqlite::types::Value) -> Term<'_> {
    match val {
        Value::Null => nil().encode(env),
        Value::Integer(i) => i.encode(env),
        Value::Real(f) => f.encode(env),
        Value::Text(s) => s.encode(env),
        Value::Blob(owned_vec) => {
            let resource = ResourceArc::new(BlobResource(owned_vec));
            resource
                .make_binary(env, |wrapper: &BlobResource| &wrapper.0)
                .encode(env)
        }
    }
}

pub(crate) fn process_rows<'a, 'rows>(
    env: Env<'a>,
    mut rows: Rows<'rows>, // Takes ownership of `rows`
    column_count: usize,
) -> Result<Vec<Vec<Term<'a>>>, XqliteError> {
    let mut results: Vec<Vec<Term<'a>>> = Vec::new();

    loop {
        match rows.next() {
            Ok(Some(row)) => {
                // Got a row
                let mut row_values: Vec<Term<'a>> = Vec::with_capacity(column_count);
                for i in 0..column_count {
                    // Use `?` here - if row.get fails, it returns rusqlite::Error,
                    // which will be converted via From/Into by the surrounding function's
                    // Result signature (XqliteError) if this closure doesn't map it.
                    // Or map it explicitly if needed (as done below, which is safer).
                    let value: Value = row.get::<usize, Value>(i)?; // This '?' uses the From impl
                    let term = encode_val(env, value);
                    row_values.push(term);
                }
                results.push(row_values);
            }
            Ok(None) => {
                // No more rows
                break;
            }
            Err(e) => {
                // Error fetching next row, map it and return Err
                return Err(XqliteError::CannotFetchRow(e.to_string()));
            }
        }
    }
    Ok(results)
}

fn elixir_term_to_rusqlite_value<'a>(
    env: Env<'a>,
    term: Term<'a>,
) -> Result<Value, XqliteError> {
    let make_convert_error = |term: Term<'a>, err: RustlerError| -> XqliteError {
        XqliteError::CannotConvertToSqliteValue {
            value_str: format!("{:?}", term),
            reason: format!("{:?}", err),
        }
    };
    let term_type = term.get_type();
    match term_type {
        TermType::Atom => {
            if term == nil().to_term(env) {
                Ok(Value::Null)
            } else if term == true_().to_term(env) {
                Ok(Value::Integer(1))
            } else if term == false_().to_term(env) {
                Ok(Value::Integer(0))
            } else {
                Err(XqliteError::UnsupportedAtom {
                    atom_value: term
                        .atom_to_string()
                        .unwrap_or_else(|_| format!("{:?}", term)),
                })
            }
        }
        TermType::Integer => term
            .decode::<i64>()
            .map(Value::Integer)
            .map_err(|e| make_convert_error(term, e)),
        TermType::Float => term
            .decode::<f64>()
            .map(Value::Real)
            .map_err(|e| make_convert_error(term, e)),
        TermType::Binary => match term.decode::<String>() {
            Ok(s) => Ok(Value::Text(s)),
            Err(_string_decode_err) => match term.decode::<Binary>() {
                Ok(bin) => Ok(Value::Blob(bin.as_slice().to_vec())),
                Err(binary_decode_err) => Err(make_convert_error(term, binary_decode_err)),
            },
        },
        _ => Err(XqliteError::UnsupportedDataType { term_type }),
    }
}

pub(crate) fn decode_exec_keyword_params<'a>(
    env: Env<'a>,
    list_term: Term<'a>,
) -> Result<Vec<(String, Value)>, XqliteError> {
    let iter: ListIterator<'a> =
        list_term
            .decode()
            .map_err(|_| XqliteError::ExpectedKeywordList {
                value_str: format!("{:?}", list_term),
            })?;
    let mut params: Vec<(String, Value)> = Vec::new();
    for term_item in iter {
        let (key_atom, value_term): (Atom, Term<'a>) =
            term_item
                .decode()
                .map_err(|_| XqliteError::ExpectedKeywordTuple {
                    value_str: format!("{:?}", term_item),
                })?;
        let mut key_string: String = key_atom
            .to_term(env)
            .atom_to_string()
            .map_err(|e| XqliteError::CannotConvertAtomToString(format!("{:?}", e)))?;
        key_string.insert(0, ':'); // Prepend ':' as SQLite expects it in named parameters
        let rusqlite_value = elixir_term_to_rusqlite_value(env, value_term)?;
        params.push((key_string, rusqlite_value));
    }
    Ok(params)
}

pub(crate) fn decode_plain_list_params<'a>(
    env: Env<'a>,
    list_term: Term<'a>,
) -> Result<Vec<Value>, XqliteError> {
    let iter: ListIterator<'a> =
        list_term.decode().map_err(|_| XqliteError::ExpectedList {
            value_str: format!("{:?}", list_term),
        })?;
    let mut values = Vec::new();
    for term in iter {
        values.push(elixir_term_to_rusqlite_value(env, term)?);
    }
    Ok(values)
}

pub(crate) fn format_term_for_pragma<'a>(
    env: Env<'a>,
    term: Term<'a>,
) -> Result<String, XqliteError> {
    // Based on elixir_term_to_rusqlite_value, but produces SQL literal strings
    let term_type = term.get_type();
    match term_type {
        TermType::Atom => {
            if term == nil().to_term(env) {
                Ok("NULL".to_string())
            } else if term == true_().to_term(env) {
                Ok("ON".to_string()) // Common PRAGMA boolean values
            } else if term == false_().to_term(env) {
                Ok("OFF".to_string()) // Common PRAGMA boolean values
            } else {
                // Allow other atoms if they represent valid PRAGMA keywords (like WAL, DELETE)
                term.atom_to_string()
                    .map_err(|e| XqliteError::CannotConvertAtomToString(format!("{:?}", e)))
            }
        }
        TermType::Integer => term
            .decode::<i64>()
            .map(|i| i.to_string()) // Convert integer directly to string
            .map_err(|e| XqliteError::CannotConvertToSqliteValue {
                value_str: format!("{:?}", term),
                reason: format!("{:?}", e),
            }),
        // Floats are usually not set via PRAGMA, but handle just in case
        TermType::Float => term.decode::<f64>().map(|f| f.to_string()).map_err(|e| {
            XqliteError::CannotConvertToSqliteValue {
                value_str: format!("{:?}", term),
                reason: format!("{:?}", e),
            }
        }),
        // Binaries interpreted as Strings, need single quotes
        TermType::Binary => term
            .decode::<String>()
            .map(|s| format!("'{}'", s.replace('\'', "''"))) // Single quote and escape
            .map_err(|e| XqliteError::CannotConvertToSqliteValue {
                value_str: format!("{:?}", term),
                reason: format!("Failed to decode binary as string for PRAGMA: {:?}", e),
            }),
        _ => Err(XqliteError::UnsupportedDataType { term_type }),
    }
}

pub(crate) fn is_keyword<'a>(list_term: Term<'a>) -> bool {
    match list_term.decode::<ListIterator<'a>>() {
        Ok(mut iter) => match iter.next() {
            Some(first_el) => first_el.decode::<(Atom, Term<'a>)>().is_ok(),
            None => false,
        },
        Err(_) => false,
    }
}

/// Quotes an identifier (like table name) for safe inclusion in PRAGMA commands
/// where strings are accepted. Uses single quotes for consistency.
#[inline]
pub(crate) fn quote_identifier(name: &str) -> String {
    format!("'{}'", name.replace('\'', "''"))
}

#[inline]
pub(crate) fn quote_savepoint_name(name: &str) -> String {
    format!("'{}'", name.replace('\'', "''"))
}

pub(crate) fn with_conn<F, R>(
    handle: &ResourceArc<XqliteConn>,
    func: F,
) -> Result<R, XqliteError>
where
    F: FnOnce(&Connection) -> Result<R, XqliteError>,
{
    let conn_guard = handle
        .0
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    func(&conn_guard)
}
