use crate::atoms;
use crate::error::XqliteError;
use rusqlite::ffi;
use rusqlite::{Rows, types::Value};
use rustler::{
    Atom, Binary, Decoder, Encoder, Env, Error as RustlerError, Resource, ResourceArc, Term,
    TermType, resource_impl,
    sys::enif_get_list_cell,
    types::{
        atom::{error, false_, nil, ok, true_},
        binary::OwnedBinary,
        elixir_struct::get_ex_struct_name,
    },
};
use std::mem::MaybeUninit;
use std::ops::DerefMut;

#[derive(Debug)]
pub(crate) struct BlobResource(pub(crate) Vec<u8>);
#[resource_impl]
impl Resource for BlobResource {}

/// A text argument as the caller wrote it. Reading the term IS the check: the
/// bytes are validated once, on the way in, and a binary that is no UTF-8 is
/// answered with `:invalid_utf8_in_string` instead of raising. A term that is
/// no binary still raises, the documented kind for a wrong type on a raw stub.
#[derive(Debug)]
pub(crate) struct TextArg(String);

impl TextArg {
    #[inline]
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }

    #[inline]
    pub(crate) fn into_string(self) -> String {
        self.0
    }
}

impl std::ops::Deref for TextArg {
    type Target = str;

    #[inline]
    fn deref(&self) -> &str {
        &self.0
    }
}

/// A text argument the caller may leave out: `nil` is "no text" and anything
/// else is read as text. Rustler's own `Option` decoder turns every refusal of
/// the inner type into a raise, which would hide the UTF-8 answer.
#[derive(Debug)]
pub(crate) struct MaybeTextArg(Option<String>);

impl MaybeTextArg {
    #[inline]
    pub(crate) fn as_deref(&self) -> Option<&str> {
        self.0.as_deref()
    }

    #[inline]
    pub(crate) fn into_option(self) -> Option<String> {
        self.0
    }
}

impl<'a> Decoder<'a> for MaybeTextArg {
    fn decode(term: Term<'a>) -> rustler::NifResult<Self> {
        match term.decode::<Atom>() {
            Ok(atom) if atom == nil() => Ok(MaybeTextArg(None)),
            _not_nil => {
                let text: TextArg = term.decode()?;
                Ok(MaybeTextArg(Some(text.into_string())))
            }
        }
    }
}

/// A name, or the atom `:all` where SQLite reads a NULL name as every schema or
/// every table. `nil` is no name here: it raises like any other term that is
/// no text.
#[derive(Debug)]
pub(crate) struct NameOrAll(Option<String>);

impl NameOrAll {
    #[inline]
    pub(crate) fn as_deref(&self) -> Option<&str> {
        self.0.as_deref()
    }
}

impl<'a> Decoder<'a> for NameOrAll {
    fn decode(term: Term<'a>) -> rustler::NifResult<Self> {
        match term.decode::<Atom>() {
            Ok(atom) if atom == atoms::all() => Ok(NameOrAll(None)),
            _not_all => Ok(NameOrAll(Some(term.decode::<TextArg>()?.into_string()))),
        }
    }
}

impl<'a> Decoder<'a> for TextArg {
    fn decode(term: Term<'a>) -> rustler::NifResult<Self> {
        let bytes: Binary<'a> = term.decode()?;
        match std::str::from_utf8(bytes.as_slice()) {
            Ok(text) => Ok(TextArg(text.to_string())),
            Err(_not_utf8) => Err(RustlerError::Term(Box::new(
                atoms::invalid_utf8_in_string(),
            ))),
        }
    }
}

#[inline]
pub(crate) fn encode_val(
    env: Env<'_>,
    val: rusqlite::types::Value,
) -> Result<Term<'_>, XqliteError> {
    match val {
        Value::Null => Ok(nil().encode(env)),
        Value::Integer(i) => Ok(i.encode(env)),
        Value::Real(f) => Ok(encode_f64(env, f)),
        Value::Text(s) => encode_text(env, s.as_bytes()),
        Value::Blob(owned_vec) => Ok(encode_blob(env, owned_vec)),
    }
}

/// Byte length at or below which a BEAM binary is a *heap binary* (lives on the
/// process heap, copied on send) rather than an off-heap, reference-counted
/// *refc binary*. `enif_make_resource_binary` ALWAYS produces an off-heap refc
/// binary regardless of size, so wrapping a tiny blob in a `BlobResource` pays
/// full refc + per-resource overhead for a value that would otherwise sit
/// cheaply on the process heap.
const HEAP_BINARY_THRESHOLD: usize = 64;

/// Encodes a BLOB value on the query/execute path, which OWNS the bytes as a
/// `Vec<u8>` (rusqlite already copied them out of SQLite). Size-adaptive so each
/// regime uses its leaner backing:
///
/// * `> HEAP_BINARY_THRESHOLD`: wrap the owned `Vec` in a `BlobResource` and hand
///   back a ZERO-copy resource binary — avoids re-copying large payloads. The
///   stream path, working from a transient SQLite pointer, cannot do this.
/// * otherwise: copy into an `OwnedBinary` so the value lands as a cheap
///   process-heap binary instead of an off-heap resource binary with per-object
///   overhead — matching the stream path's backing for small blobs and removing
///   the measured small-blob memory blow-up (an off-heap resource binary per tiny
///   value was ~1.5-3x heavier than a heap-binary copy).
///
/// On the (OOM-only) allocation failure of the small-blob copy, degrade to the
/// resource-binary wrap rather than panic — the crate's graceful convention.
#[inline]
fn encode_blob(env: Env<'_>, owned_vec: Vec<u8>) -> Term<'_> {
    if owned_vec.len() > HEAP_BINARY_THRESHOLD {
        return wrap_blob_resource(env, owned_vec);
    }
    match OwnedBinary::new(owned_vec.len()) {
        Some(mut bin) => {
            bin.as_mut_slice().copy_from_slice(&owned_vec);
            bin.release(env).encode(env)
        }
        None => wrap_blob_resource(env, owned_vec),
    }
}

/// Wraps an owned `Vec<u8>` in a `BlobResource` and hands the BEAM a zero-copy
/// resource binary referencing it; the resource GC keeps the `Vec` alive.
#[inline]
fn wrap_blob_resource(env: Env<'_>, owned_vec: Vec<u8>) -> Term<'_> {
    let resource = ResourceArc::new(BlobResource(owned_vec));
    resource
        .make_binary(env, |wrapper: &BlobResource| &wrapper.0)
        .encode(env)
}

/// Encodes bytes as a BEAM binary term via a fallible `OwnedBinary` allocation,
/// degrading to a structured error on allocation failure instead of aborting.
///
/// rustler's `str`/`String` `Encoder` allocates the same `OwnedBinary` but
/// `panic!`s when `OwnedBinary::new` returns `None`, so a returned TEXT value
/// is the one outbound value path that aborts under allocation exhaustion
/// rather than surfacing an error the way the BLOB encoders do. This mirrors
/// their graceful convention. The success path is byte-identical to
/// `str::encode`: an `OwnedBinary` holding exactly these bytes.
#[inline]
pub(crate) fn encode_text<'a>(env: Env<'a>, bytes: &[u8]) -> Result<Term<'a>, XqliteError> {
    let mut bin =
        OwnedBinary::new(bytes.len()).ok_or_else(|| XqliteError::InternalEncodingError {
            context: format!(
                "Failed to allocate {}-byte OwnedBinary for TEXT value",
                bytes.len()
            ),
        })?;
    bin.as_mut_slice().copy_from_slice(bytes);
    Ok(bin.release(env).encode(env))
}

/// Encodes an `f64` column value, mapping the non-finite cases that rustler's
/// `enif_make_double` rejects with a return-time `badarg` onto sentinel terms:
/// `+Inf`/`-Inf` become `:positive_infinity`/`:negative_infinity`, and `NaN`
/// becomes `nil` (SQLite already surfaces NaN through the NULL storage class,
/// so the NaN arm is defensive). Mirrors the schema layer's finiteness guard.
#[inline]
fn encode_f64(env: Env<'_>, f: f64) -> Term<'_> {
    if f.is_finite() {
        f.encode(env)
    } else if f == f64::INFINITY {
        atoms::positive_infinity().encode(env)
    } else if f == f64::NEG_INFINITY {
        atoms::negative_infinity().encode(env)
    } else {
        nil().encode(env)
    }
}

#[inline]
pub(crate) fn singular_ok_or_error_tuple<'a>(
    env: Env<'a>,
    operation_result: Result<(), XqliteError>,
) -> Term<'a> {
    match operation_result {
        Ok(()) => ok().encode(env),
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
                    let val = row.get::<usize, Value>(i)?;
                    let term = encode_val(env, val)?;
                    row_values.push(term);
                }
                results.push(row_values);
            }
            Ok(None) => {
                break;
            }
            Err(e) => return Err(e.into()),
        }
    }
    Ok(results)
}

/// The `bytes` field of an `%Xqlite.Blob{}`, or `None` for any other map.
/// Only that struct forces a BLOB bind; every other map stays an unsupported
/// parameter value.
#[inline]
fn blob_struct_bytes<'a>(term: Term<'a>) -> Option<Term<'a>> {
    match get_ex_struct_name(term) {
        Ok(name) if name == atoms::elixir_xqlite_blob() => term.map_get(atoms::bytes()).ok(),
        _ => None,
    }
}

/// Binds the wrapped bytes as a BLOB whatever they decode to — skipping the
/// UTF-8 test the plain binary arm applies is the whole point of the wrapper.
/// `position` is the parameter's one-based place in the list the caller passed.
#[inline]
fn blob_struct_value(bytes_term: Term<'_>, position: usize) -> Result<Value, XqliteError> {
    match bytes_term.decode::<Binary>() {
        Ok(bin) => Ok(Value::Blob(bin.as_slice().to_vec())),
        Err(_) => Err(XqliteError::InvalidBlobBytes {
            position,
            term_type: bytes_term.get_type(),
        }),
    }
}

#[inline]
fn elixir_term_to_rusqlite_value<'a>(
    env: Env<'a>,
    term: Term<'a>,
    position: usize,
) -> Result<Value, XqliteError> {
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
        // SQLite stores an integer in 64 signed bits and Elixir's have no
        // size, so the decode is the range test.
        TermType::Integer => term
            .decode::<i64>()
            .map(Value::Integer)
            .map_err(|_too_big| XqliteError::IntegerOutOfRange {
                position: Some(position),
            }),
        TermType::Float => term
            .decode::<f64>()
            .map(Value::Real)
            .map_err(|_not_a_float| XqliteError::UnsupportedDataType { term_type }),
        TermType::Binary => match term.decode::<String>() {
            Ok(s) => Ok(Value::Text(s)),
            Err(_string_decode_err) => match term.decode::<Binary>() {
                Ok(bin) => Ok(Value::Blob(bin.as_slice().to_vec())),
                Err(_binary_decode_err) => Err(XqliteError::UnsupportedDataType { term_type }),
            },
        },
        TermType::Map => match blob_struct_bytes(term) {
            Some(bytes_term) => blob_struct_value(bytes_term, position),
            None => Err(XqliteError::UnsupportedDataType { term_type }),
        },
        _ => Err(XqliteError::UnsupportedDataType { term_type }),
    }
}

/// One cons cell of a caller's list, read by hand.
///
/// rustler's `ListIterator` panics when a tail is not a list, and a panic
/// inside a NIF that holds the connection Mutex leaves that connection
/// unusable for the rest of the process — so no rustler list decoder is ever
/// handed a caller's term.
#[inline]
fn list_cell<'a>(term: Term<'a>) -> Option<(Term<'a>, Term<'a>)> {
    let env = term.get_env();
    let mut head = MaybeUninit::uninit();
    let mut tail = MaybeUninit::uninit();

    // SAFETY: `enif_get_list_cell` reads `term` in the environment that term
    // belongs to, and writes `head` and `tail` only when it answers 1; both
    // are then terms of that same environment, which is what `'a` names.
    unsafe {
        let found = enif_get_list_cell(
            env.as_c_arg(),
            term.as_c_arg(),
            head.as_mut_ptr(),
            tail.as_mut_ptr(),
        );

        match found {
            1 => Some((
                Term::new(env, head.assume_init()),
                Term::new(env, tail.assume_init()),
            )),
            _no_cell => None,
        }
    }
}

/// Walks a caller's list and answers its elements, refusing a term that is no
/// list and one whose tail stops being a list part-way through.
pub(crate) fn walk_list<'a>(term: Term<'a>) -> Result<Vec<Term<'a>>, XqliteError> {
    let mut items: Vec<Term<'a>> = Vec::new();
    let mut cursor = term;

    loop {
        match list_cell(cursor) {
            Some((head, tail)) => {
                items.push(head);
                cursor = tail;
            }
            None if cursor.is_empty_list() => break Ok(items),
            None if items.is_empty() => break Err(XqliteError::not_a_list(term)),
            None => break Err(XqliteError::improper_tail(cursor)),
        }
    }
}

/// A caller's parameter list after one walk. The first element decides how the
/// list is read, and the elements it collected feed the decode, so the list is
/// never walked twice.
pub(crate) enum Params<'a> {
    Empty,
    Named(Vec<Term<'a>>),
    Positional(Vec<Term<'a>>),
}

/// A parameter term of `nil` means no parameters, on every door that takes
/// them: the one producer answers for it, so the doors cannot disagree.
pub(crate) fn walk_params<'a>(term: Term<'a>) -> Result<Params<'a>, XqliteError> {
    if term == nil().to_term(term.get_env()) {
        return Ok(Params::Empty);
    }

    let keyword = is_keyword(term);

    match walk_list(term) {
        Ok(items) if items.is_empty() => Ok(Params::Empty),
        Ok(items) if keyword => Ok(Params::Named(items)),
        Ok(items) => Ok(Params::Positional(items)),
        Err(e) if keyword => Err(e.about_keyword_list()),
        Err(e) => Err(e),
    }
}

/// The most parameters a statement may have for a keyword list to bind it.
/// The names are resolved through a map of every parameter name, and SQLite
/// reads the name at one index by walking its list up to it, so the map's cost
/// grows about with the square of the count: 7 ms at 2 048, 26 ms at 4 096.
const MAX_NAMED_PARAMETERS: usize = 2048;

/// Decodes a keyword list for a statement of `parameter_count` parameters,
/// refusing a statement over `MAX_NAMED_PARAMETERS` before any value is read.
pub(crate) fn decode_exec_keyword_params<'a>(
    env: Env<'a>,
    items: &[Term<'a>],
    parameter_count: usize,
) -> Result<Vec<(String, Value)>, XqliteError> {
    require_named_parameter_room(parameter_count)?;

    let mut params: Vec<(String, Value)> = Vec::new();
    for (index, term_item) in items.iter().enumerate() {
        let (key_atom, value_term): (Atom, Term<'a>) =
            term_item
                .decode()
                .map_err(|_| XqliteError::ExpectedKeywordTuple {
                    position: index + 1,
                    value_type: term_item.get_type(),
                })?;
        let key_string: String = key_atom
            .to_term(env)
            .atom_to_string()
            .map_err(|e| XqliteError::CannotConvertAtomToString(format!("{e:?}")))?;
        let rusqlite_value = elixir_term_to_rusqlite_value(env, value_term, index + 1)?;
        params.push((parameter_name_of(key_string), rusqlite_value));
    }
    Ok(params)
}

#[inline]
fn require_named_parameter_room(count: usize) -> Result<(), XqliteError> {
    match count > MAX_NAMED_PARAMETERS {
        true => Err(XqliteError::TooManyNamedParameters {
            count,
            limit: MAX_NAMED_PARAMETERS,
        }),
        false => Ok(()),
    }
}

/// The parameter a keyword key names. SQLite spells a name with one of three
/// prefixes (`:a`, `@a`, `$a`), so a key that already carries one is used as
/// written and every other key gets the `:` one — `[a: 1]` names `:a` and
/// `[{:"@a", 1}]` names `@a`. SQLite does name a `?NNN` parameter, as `?NNN`,
/// and only a bare `?` has no name at all; no key reaches either, because a
/// key always comes out with one of the three prefixes — `[{:"?1", 1}]` asks
/// for `:?1`.
#[inline]
fn parameter_name_of(key: String) -> String {
    match key.as_bytes().first() {
        Some(b':' | b'@' | b'$') => key,
        _no_prefix => format!(":{key}"),
    }
}

pub(crate) fn decode_plain_list_params<'a>(
    env: Env<'a>,
    items: &[Term<'a>],
) -> Result<Vec<Value>, XqliteError> {
    let mut values = Vec::with_capacity(items.len());
    for (index, term) in items.iter().enumerate() {
        values.push(elixir_term_to_rusqlite_value(env, *term, index + 1)?);
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
        // One value, no list around it, so there is no position to report.
        TermType::Integer => term
            .decode::<i64>()
            .map(|i| i.to_string())
            .map_err(|_too_big| XqliteError::IntegerOutOfRange { position: None }),
        TermType::Float => term
            .decode::<f64>()
            .map(|f| f.to_string())
            .map_err(|_not_a_float| XqliteError::UnsupportedDataType { term_type }),
        TermType::Binary => pragma_text(term),
        _ => Err(XqliteError::UnsupportedDataType { term_type }),
    }
}

/// A PRAGMA value is written into the statement, so it has to be text. Three
/// ways a term of the BEAM's one binary type is not: a bit size that is no
/// whole number of bytes, bytes that are no UTF-8, and a NUL byte, where
/// SQLite's tokenizer would stop and read a shorter statement than we built.
fn pragma_text(term: Term<'_>) -> Result<String, XqliteError> {
    match term.decode::<String>() {
        Ok(text) if text.contains('\0') => Err(XqliteError::NulErrorInString),
        Ok(text) => Ok(format!("'{}'", text.replace('\'', "''"))),
        Err(_not_text) => Err(non_text_pragma_value(term)),
    }
}

fn non_text_pragma_value(term: Term<'_>) -> XqliteError {
    match term.decode::<Binary>() {
        Ok(_bytes) => XqliteError::InvalidUtf8InString,
        Err(_not_bytes) => XqliteError::UnsupportedDataType {
            term_type: TermType::Binary,
        },
    }
}

/// A parameter list is read as a keyword list exactly when its first element
/// is a `{atom, value}` tuple. Only the first cell is read, and by hand.
pub(crate) fn is_keyword<'a>(list_term: Term<'a>) -> bool {
    match list_cell(list_term) {
        Some((first_el, _tail)) => first_el.decode::<(Atom, Term<'a>)>().is_ok(),
        None => false,
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
                    encode_f64(env, val)
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
                        Ok(s) => encode_text(env, s.as_bytes())?,
                        Err(utf8_err) => {
                            return Err(XqliteError::Utf8Error {
                                column: i,
                                reason: utf8_err.to_string(),
                            });
                        }
                    }
                }
                ffi::SQLITE_BLOB => {
                    // Must copy: sqlite3_column_blob's pointer is only valid
                    // until the next sqlite3_step.
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
