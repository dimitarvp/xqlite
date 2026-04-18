use crate::atoms;
use crate::error::XqliteError;
use rusqlite::ffi;
use rusqlite::{Rows, types::Value};
use rustler::{
    Atom, Binary, Encoder, Env, Error as RustlerError, ListIterator, Resource, ResourceArc,
    Term, TermType, resource_impl,
    types::{
        atom::{error, false_, nil, ok, true_},
        binary::OwnedBinary,
    },
};
use std::ops::DerefMut;

#[derive(Debug)]
pub(crate) struct BlobResource(pub(crate) Vec<u8>);
#[resource_impl]
impl Resource for BlobResource {}

#[inline]
pub(crate) fn encode_val(env: Env<'_>, val: rusqlite::types::Value) -> Term<'_> {
    match val {
        Value::Null => nil().encode(env),
        Value::Integer(i) => i.encode(env),
        Value::Real(f) => f.encode(env),
        Value::Text(s) => s.encode(env),
        Value::Blob(owned_vec) => {
            // Zero-copy: wrap the owned Vec<u8> in a resource and let the BEAM
            // reference its memory directly. The resource GC keeps it alive.
            // This differs from sqlite_row_to_elixir_terms which must copy from
            // a raw SQLite pointer that becomes invalid after the next step.
            let resource = ResourceArc::new(BlobResource(owned_vec));
            resource
                .make_binary(env, |wrapper: &BlobResource| &wrapper.0)
                .encode(env)
        }
    }
}

#[inline]
pub(crate) fn term_to_tagged_elixir_value<'a>(env: Env<'a>, term: Term<'a>) -> Term<'a> {
    match term.get_type() {
        TermType::Atom => (atoms::atom(), term).encode(env), // e.g., {:atom, :foo}
        TermType::Binary => {
            match term.decode::<String>() {
                Ok(_s_val) => {
                    // If it's a valid Elixir string, tag as :string and pass original term
                    (atoms::string(), term).encode(env) // e.g., {:string, "hello"}
                }
                _ => {
                    // Otherwise, tag as :binary and pass original term
                    (atoms::binary(), term).encode(env) // e.g., {:binary, <<1,2,3>>}
                }
            }
        }
        TermType::Integer => (atoms::integer(), term).encode(env), // e.g., {:integer, 123}
        TermType::Float => (atoms::float(), term).encode(env),     // e.g., {:float, 1.23}
        TermType::List => (atoms::list(), term).encode(env),       // e.g., {:list, [1,2]}
        TermType::Map => (atoms::map(), term).encode(env),         // e.g., {:map, %{a: 1}}
        TermType::Fun => (atoms::function(), term).encode(env), // e.g., {:function, &fun/0} (opaque)
        TermType::Pid => (atoms::pid(), term).encode(env), // e.g., {:pid, #Pid<...>} (opaque)
        TermType::Port => (atoms::port(), term).encode(env), // e.g., {:port, #Port<...>} (opaque)
        TermType::Ref => (atoms::reference(), term).encode(env), // e.g., {:reference, #Reference<...>} (opaque)
        TermType::Tuple => (atoms::tuple(), term).encode(env),   // e.g., {:tuple, {1,2}}
        TermType::Unknown => {
            (atoms::unknown(), format!("Unknown TermType: {term:?}")).encode(env)
        }
    }
}

#[inline]
pub(crate) fn singular_ok_or_error_tuple<'a>(
    env: Env<'a>,
    operation_result: Result<(), XqliteError>,
) -> Term<'a> {
    match operation_result {
        // Returns only `:ok` to Elixir
        Ok(()) => ok().encode(env),
        // Returns `{:error, err}` to Elixir
        Err(err) => (error(), err).encode(env),
    }
}

/// Converts rusqlite Rows to Vec<Vec<Term>> using the safe rusqlite API.
/// Used by core_query/core_execute (single NIF call, Statement lifetime tied to Connection).
/// Streaming uses sqlite_row_to_elixir_terms instead (raw FFI) because the statement
/// outlives the Connection borrow via AtomicPtr — rusqlite's lifetime-bound Rows can't
/// express that.
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
                        Err(e) => return Err(e.into()),
                    };
                }
                results.push(row_values);
            }
            Ok(None) => {
                break; // End of rows
            }
            Err(e) => return Err(e.into()),
        }
    }
    Ok(results)
}

#[inline]
fn elixir_term_to_rusqlite_value<'a>(
    env: Env<'a>,
    term: Term<'a>,
) -> Result<Value, XqliteError> {
    let make_convert_error = |term: Term<'a>, err: RustlerError| -> XqliteError {
        XqliteError::CannotConvertToSqliteValue {
            value_str: format!("{term:?}"),
            reason: format!("{err:?}"),
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
                        .unwrap_or_else(|_| format!("{term:?}")),
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
                value_str: format!("{list_term:?}"),
            })?;
    let mut params: Vec<(String, Value)> = Vec::new();
    for term_item in iter {
        let (key_atom, value_term): (Atom, Term<'a>) =
            term_item
                .decode()
                .map_err(|_| XqliteError::ExpectedKeywordTuple {
                    value_str: format!("{term_item:?}"),
                })?;
        let mut key_string: String = key_atom
            .to_term(env)
            .atom_to_string()
            .map_err(|e| XqliteError::CannotConvertAtomToString(format!("{e:?}")))?;
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
            value_str: format!("{list_term:?}"),
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
                    .map_err(|e| XqliteError::CannotConvertAtomToString(format!("{e:?}")))
            }
        }
        TermType::Integer => term.decode::<i64>().map(|i| i.to_string()).map_err(|e| {
            XqliteError::CannotConvertToSqliteValue {
                value_str: format!("{term:?}"),
                reason: format!("{e:?}"),
            }
        }),
        // Floats are usually not set via PRAGMA, but handle just in case
        TermType::Float => term.decode::<f64>().map(|f| f.to_string()).map_err(|e| {
            XqliteError::CannotConvertToSqliteValue {
                value_str: format!("{term:?}"),
                reason: format!("{e:?}"),
            }
        }),
        // Binaries interpreted as Strings, need single quotes
        TermType::Binary => term
            .decode::<String>()
            .map(|s| format!("'{}'", s.replace('\'', "''")))
            .map_err(|e| XqliteError::CannotConvertToSqliteValue {
                value_str: format!("{term:?}"),
                reason: format!("Failed to decode binary as string for PRAGMA: {e:?}"),
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
    format!("\"{}\"", name.replace('"', "\"\""))
}

/// Extracts column values from a stepped statement and encodes them as Rustler Terms.
///
/// # Safety
///
/// - `stmt_ptr` must be non-null and point to a valid, prepared `sqlite3_stmt`
///   that has just returned `SQLITE_ROW` from `sqlite3_step`.
/// - `column_count` must match the statement's actual column count.
/// - The caller must hold the connection mutex or otherwise guarantee no concurrent
///   access to the same statement.
#[inline]
pub(crate) unsafe fn sqlite_row_to_elixir_terms(
    env: Env<'_>,
    stmt_ptr: *mut ffi::sqlite3_stmt,
    column_count: usize,
) -> Result<Vec<Term<'_>>, XqliteError> {
    // SAFETY: Caller guarantees stmt_ptr is valid and positioned on a row.
    // All sqlite3_column_* calls are safe given a valid, stepped statement.
    unsafe {
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
                                "SQLite TEXT column pointer was null for column index {i}"
                            ),
                        });
                    }
                    let len = ffi::sqlite3_column_bytes(stmt_ptr, col_idx);
                    let text_slice = std::slice::from_raw_parts(s_ptr, len as usize);
                    match std::str::from_utf8(text_slice) {
                        Ok(s) => s.encode(env),
                        Err(utf8_err) => {
                            return Err(XqliteError::Utf8Error {
                                column: i,
                                reason: utf8_err.to_string(),
                            });
                        }
                    }
                }
                ffi::SQLITE_BLOB => {
                    // Must copy: the raw pointer from sqlite3_column_blob is only
                    // valid until the next sqlite3_step call. Unlike encode_val
                    // (which receives an owned Vec<u8> and can zero-copy via
                    // BlobResource), we must allocate an OwnedBinary and copy.
                    let b_ptr = ffi::sqlite3_column_blob(stmt_ptr, col_idx);
                    let len = ffi::sqlite3_column_bytes(stmt_ptr, col_idx) as usize;
                    if b_ptr.is_null() {
                        if len == 0 {
                            let empty_bin = OwnedBinary::new(0).ok_or_else(|| {
                                XqliteError::InternalEncodingError {
                                    context: "Failed to allocate 0-byte OwnedBinary"
                                        .to_string(),
                                }
                            })?;
                            // For an empty OwnedBinary, no copy is needed after creation.
                            empty_bin.release(env).encode(env)
                        } else {
                            return Err(XqliteError::InternalEncodingError {
                                context: format!(
                                    "SQLite BLOB column pointer was null for non-empty blob (column index {i})"
                                ),
                            });
                        }
                    } else {
                        let data_slice = std::slice::from_raw_parts(b_ptr as *const u8, len);
                        let mut bin = OwnedBinary::new(len).ok_or_else(|| {
                            XqliteError::InternalEncodingError {
                                context: format!(
                                    "Failed to allocate {len}-byte OwnedBinary for blob"
                                ),
                            }
                        })?;
                        // Use deref_mut to get &mut [u8] to copy into.
                        bin.deref_mut().copy_from_slice(data_slice);
                        bin.release(env).encode(env)
                    }
                }
                ffi::SQLITE_NULL => nil().encode(env),
                _ => {
                    return Err(XqliteError::InternalEncodingError {
                        context: format!(
                            "Unknown SQLite column type: {col_type} for column index {i}"
                        ),
                    });
                }
            };
            row_values.push(term);
        }
        Ok(row_values)
    }
}
