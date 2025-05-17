use crate::error::XqliteError;
use crate::nif::XqliteConn;
use rusqlite::ffi;
use rusqlite::{types::Value, Connection, Rows};
use rustler::{
    resource_impl,
    types::{
        atom::{false_, nil, true_},
        binary::OwnedBinary,
    },
    Atom, Binary, Encoder, Env, Error as RustlerError, ListIterator, Resource, ResourceArc,
    Term, TermType,
};
use std::fmt::Debug;
use std::ops::DerefMut;
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
    mut rows: Rows<'rows>,
    column_count: usize,
) -> Result<Vec<Vec<Term<'a>>>, XqliteError> {
    let mut results: Vec<Vec<Term<'a>>> = Vec::new();

    loop {
        let row_option_result = rows.next();

        match row_option_result {
            Ok(Some(row)) => {
                let mut row_values: Vec<Term<'a>> = Vec::with_capacity(column_count);
                for i in 0..column_count {
                    match row.get::<usize, Value>(i) {
                        Ok(val) => {
                            let term = encode_val(env, val);
                            row_values.push(term);
                        }
                        Err(e) => {
                            // Check specifically for interruption *during column fetch*
                            if e.to_string() == "interrupted" {
                                return Err(XqliteError::OperationCancelled);
                            }
                            // Check specifically for Utf8Error
                            if let rusqlite::Error::Utf8Error(utf8_err) = e {
                                return Err(XqliteError::Utf8Error {
                                    reason: utf8_err.to_string(),
                                });
                            }
                            // Otherwise, map to CannotFetchRow
                            return Err(XqliteError::CannotFetchRow(format!(
                                "Error getting value for column {}: {}",
                                i, e
                            )));
                        }
                    };
                }
                results.push(row_values);
            }
            Ok(None) => {
                break; // End of rows
            }
            Err(e) => {
                // Check specifically for interruption *during row iteration*
                if e.to_string() == "interrupted" {
                    return Err(XqliteError::OperationCancelled);
                }
                // Check specifically for Utf8Error during iteration
                if let rusqlite::Error::Utf8Error(utf8_err) = e {
                    return Err(XqliteError::Utf8Error {
                        reason: utf8_err.to_string(),
                    });
                }
                // Otherwise, map other iteration errors to CannotFetchRow
                return Err(XqliteError::CannotFetchRow(format!(
                    "Error advancing row iterator: {}",
                    e
                )));
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
        key_string.insert(0, ':');
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
    let term_type = term.get_type();
    match term_type {
        TermType::Atom => {
            if term == nil().to_term(env) {
                Ok("NULL".to_string())
            } else if term == true_().to_term(env) {
                Ok("ON".to_string())
            } else if term == false_().to_term(env) {
                Ok("OFF".to_string())
            } else {
                term.atom_to_string()
                    .map_err(|e| XqliteError::CannotConvertAtomToString(format!("{:?}", e)))
            }
        }
        TermType::Integer => term.decode::<i64>().map(|i| i.to_string()).map_err(|e| {
            XqliteError::CannotConvertToSqliteValue {
                value_str: format!("{:?}", term),
                reason: format!("{:?}", e),
            }
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
            .map(|s| format!("'{}'", s.replace('\'', "''")))
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

#[inline]
pub(crate) fn quote_identifier(name: &str) -> String {
    format!("'{}'", name.replace('\'', "''"))
}

#[inline]
pub(crate) fn quote_savepoint_name(name: &str) -> String {
    format!("'{}'", name.replace('\'', "''"))
}

// This function is marked unsafe because it dereferences raw pointers (stmt_ptr)
// and calls FFI functions that are inherently unsafe. The caller (stream_fetch)
// must ensure stmt_ptr is valid and points to a statement that has been
// successfully stepped to SQLITE_ROW.
pub(crate) unsafe fn sqlite_row_to_elixir_terms(
    env: Env<'_>,
    stmt_ptr: *mut ffi::sqlite3_stmt,
    column_count: usize,
) -> Result<Vec<Term<'_>>, XqliteError> {
    let mut row_values = Vec::with_capacity(column_count);
    for i in 0..column_count {
        let col_idx = i as std::os::raw::c_int;
        let col_type = ffi::sqlite3_column_type(stmt_ptr, col_idx);
        let term = match col_type {
            ffi::SQLITE_INTEGER => {
                let val = ffi::sqlite3_column_int64(stmt_ptr, col_idx);
                val.encode(env)
            }
            ffi::SQLITE_FLOAT => {
                let val = ffi::sqlite3_column_double(stmt_ptr, col_idx);
                val.encode(env)
            }
            ffi::SQLITE_TEXT => {
                let s_ptr = ffi::sqlite3_column_text(stmt_ptr, col_idx);
                if s_ptr.is_null() {
                    return Err(XqliteError::InternalEncodingError {
                        context: format!(
                            "SQLite TEXT column pointer was null for column index {}",
                            i
                        ),
                    });
                }
                let len = ffi::sqlite3_column_bytes(stmt_ptr, col_idx);
                let text_slice = std::slice::from_raw_parts(s_ptr, len as usize);
                match std::str::from_utf8(text_slice) {
                    Ok(s) => s.encode(env),
                    Err(utf8_err) => {
                        return Err(XqliteError::Utf8Error {
                            reason: format!(
                                "Invalid UTF-8 sequence in TEXT column index {}: {}",
                                i, utf8_err
                            ),
                        });
                    }
                }
            }
            ffi::SQLITE_BLOB => {
                let b_ptr = ffi::sqlite3_column_blob(stmt_ptr, col_idx);
                let len = ffi::sqlite3_column_bytes(stmt_ptr, col_idx) as usize;
                if b_ptr.is_null() {
                    if len == 0 {
                        let empty_bin = OwnedBinary::new(0).ok_or_else(|| {
                            XqliteError::InternalEncodingError {
                                context: "Failed to allocate 0-byte OwnedBinary".to_string(),
                            }
                        })?;
                        // For an empty OwnedBinary, no copy is needed after creation.
                        empty_bin.release(env).encode(env)
                    } else {
                        return Err(XqliteError::InternalEncodingError {
                            context: format!("SQLite BLOB column pointer was null for non-empty blob (column index {})", i),
                        });
                    }
                } else {
                    let data_slice = std::slice::from_raw_parts(b_ptr as *const u8, len);
                    let mut bin = OwnedBinary::new(len).ok_or_else(|| {
                        XqliteError::InternalEncodingError {
                            context: format!(
                                "Failed to allocate {}-byte OwnedBinary for blob",
                                len
                            ),
                        }
                    })?;
                    // Use deref_mut to get &mut [u8] to copy into.
                    bin.deref_mut().copy_from_slice(data_slice);
                    bin.release(env).encode(env)
                }
            }
            ffi::SQLITE_NULL => nil().encode(env), // Corrected
            _ => {
                return Err(XqliteError::InternalEncodingError {
                    context: format!(
                        "Unknown SQLite column type: {} for column index {}",
                        col_type, i
                    ),
                });
            }
        };
        row_values.push(term);
    }
    Ok(row_values)
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
