use crate::connection::{ChildHandle, XqliteConn};
use crate::error::XqliteError;
use crate::util::sqlite_row_to_elixir_terms;
use rusqlite::ffi;
use rusqlite::types::Value;
use rustler::{Env, Resource, ResourceArc, Term};
use std::collections::HashMap;
use std::io::Write;
use std::os::raw::c_int;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

pub(crate) struct XqliteStream {
    // Null means the stream is done/closed/finalized. Shared with the
    // connection's child registry, which finalizes it if the connection is
    // closed first.
    pub(crate) atomic_raw_stmt: Arc<AtomicPtr<ffi::sqlite3_stmt>>,

    // A step error a batch hit after it had already read rows. The rows go
    // back to the caller and this waits for the next fetch. Written and
    // taken with the connection Mutex held; `take_and_finalize_atomic_stmt`
    // empties it before it takes that Mutex, so the two never nest the
    // other way round.
    pending_error: Mutex<Option<XqliteError>>,

    // These are immutable after stream_open completes
    pub(crate) conn_resource_arc: ResourceArc<XqliteConn>,
    pub(crate) column_names: Vec<String>,
}

#[rustler::resource_impl]
impl Resource for XqliteStream {}

impl XqliteStream {
    pub(crate) fn new(
        atomic_raw_stmt: Arc<AtomicPtr<ffi::sqlite3_stmt>>,
        conn_resource_arc: ResourceArc<XqliteConn>,
        column_names: Vec<String>,
    ) -> Self {
        XqliteStream {
            atomic_raw_stmt,
            pending_error: Mutex::new(None),
            conn_resource_arc,
            column_names,
        }
    }

    pub(crate) fn take_and_finalize_atomic_stmt(&self) -> Result<(), XqliteError> {
        // A closed stream answers `:done`, never a leftover error.
        let _ = self.take_pending_error();
        take_and_finalize_raw(&self.atomic_raw_stmt, &self.conn_resource_arc)
    }

    pub(crate) fn take_pending_error(&self) -> Option<XqliteError> {
        self.pending_slot().take()
    }

    pub(crate) fn store_pending_error(&self, error: XqliteError) {
        *self.pending_slot() = Some(error);
    }

    // The slot holds one Option and nothing that can panic runs while it is
    // held, so a poisoned Mutex is recovered rather than reported.
    fn pending_slot(&self) -> MutexGuard<'_, Option<XqliteError>> {
        match self.pending_error.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}

/// Finalizes a raw statement under the connection Mutex and drops it from the
/// connection's child registry. Shared by every resource that owns a raw
/// `sqlite3_stmt` (`XqliteStream`, `XqliteStatement`) — their Drop impls
/// and explicit close/finalize NIFs all funnel here.
///
/// The connection lock comes first and the cell is claimed under it: the
/// connection's own close drains these same cells while holding that lock, so
/// locking first is what keeps a finalize from running against a handle close
/// has already freed. It also keeps any other thread out of `sqlite3_step` on
/// this connection while the statement goes away.
pub(crate) fn take_and_finalize_raw(
    atomic_raw_stmt: &Arc<AtomicPtr<ffi::sqlite3_stmt>>,
    conn_resource_arc: &ResourceArc<XqliteConn>,
) -> Result<(), XqliteError> {
    // A null cell means the statement is already gone — finalized by an
    // earlier call, by the stream's own exhaustion, or by the connection's
    // close — and its registry entry went with it.
    if atomic_raw_stmt.load(Ordering::Acquire).is_null() {
        Ok(())
    } else {
        let _conn_guard = conn_resource_arc
            .conn
            .lock()
            .map_err(|e| XqliteError::LockError(e.to_string()))?;
        let child = ChildHandle::Stmt(Arc::clone(atomic_raw_stmt));
        // SAFETY: the connection Mutex is held for the whole release, so no
        // other thread is inside a `sqlite3_*` call on this connection, and
        // the cell holds a statement prepared on it.
        unsafe { conn_resource_arc.release_child(&child) }
    }
}

/// Finalizes a stream's statement with the connection Mutex already held by
/// the caller, and drops it from the child registry. `stream_fetch` uses this
/// when a batch exhausts or fails mid-loop.
///
/// # Safety
///
/// The caller holds the connection's Mutex for the whole call — or holds it
/// poisoned, which keeps every other thread out of SQLite on that connection.
pub(crate) unsafe fn finalize_stream_stmt_locked(
    stream: &XqliteStream,
) -> Result<(), XqliteError> {
    let child = ChildHandle::Stmt(Arc::clone(&stream.atomic_raw_stmt));
    // SAFETY: forwarded from this function's own contract.
    unsafe { stream.conn_resource_arc.release_child(&child) }
}

impl Drop for XqliteStream {
    fn drop(&mut self) {
        if let Err(e) = self.take_and_finalize_atomic_stmt() {
            // Errors from Drop cannot be propagated. Log to stderr —
            // writeln!, never eprintln!: eprintln! panics on a broken
            // stderr (EPIPE), and rustler 0.38 resource destructors have
            // no catch_unwind, so a panic here would unwind into C and
            // kill the VM. A failed finalize here is a potential resource
            // leak if SQLite itself failed to finalize.
            let _ = writeln!(
                std::io::stderr(),
                "[xqlite] Error finalizing SQLite statement during stream resource drop: {e:?}"
            );
        }
    }
}

/// Why a single step produced no row to deliver. The two are not
/// interchangeable: only `Unreadable` leaves a run that can carry on.
pub(crate) enum StepFailure {
    /// `sqlite3_step` returned neither a row nor done — a locked database, an
    /// I/O error, a runtime error in the SQL, a trigger's RAISE, a
    /// cancellation. No row was stepped past and the statement is finished
    /// where SQLite left it.
    Failed(XqliteError),
    /// A row came back and could not be turned into terms. SQLite has already
    /// stepped past it, so the run continues at the row after it.
    Unreadable(XqliteError),
}

impl From<StepFailure> for XqliteError {
    fn from(failure: StepFailure) -> Self {
        match failure {
            StepFailure::Failed(error) => error,
            StepFailure::Unreadable(error) => error,
        }
    }
}

/// Steps a prepared statement once and returns the row data if available.
///
/// The column count is read AFTER the step, not taken from a prepare-time
/// snapshot: sqlite3_step's v2 auto-reprepare after a schema change can
/// legitimately change it (e.g. `SELECT *` re-expansion).
///
/// # Safety
///
/// - `stmt_ptr` must be non-null and point to a valid, prepared `sqlite3_stmt`.
/// - `db_handle_for_error_reporting` must be the `sqlite3*` handle that owns `stmt_ptr`.
/// - The caller must hold the connection mutex for the duration of this call.
#[inline]
pub(crate) unsafe fn process_single_step<'a>(
    env: Env<'a>,
    stmt_ptr: *mut ffi::sqlite3_stmt,
    db_handle_for_error_reporting: *mut ffi::sqlite3,
) -> Result<Option<Vec<Term<'a>>>, StepFailure> {
    // SAFETY: Caller guarantees stmt_ptr and db_handle are valid and exclusively held.
    let step_result = unsafe { ffi::sqlite3_step(stmt_ptr) };

    match step_result {
        ffi::SQLITE_ROW => {
            // SAFETY: stmt_ptr is valid and we just confirmed SQLITE_ROW; the
            // mutex is held, so the post-step column count is stable while we
            // decode this row.
            let column_count = unsafe { ffi::sqlite3_column_count(stmt_ptr) } as usize;
            // SAFETY: stmt_ptr is valid and we just confirmed SQLITE_ROW.
            unsafe { sqlite_row_to_elixir_terms(env, stmt_ptr, column_count) }
                .map(Some)
                .map_err(StepFailure::Unreadable)
        }
        ffi::SQLITE_DONE => Ok(None),
        err_code => {
            // SAFETY: db_handle is valid for the lifetime of the connection mutex hold.
            let specific_message = unsafe {
                let err_msg_ptr = ffi::sqlite3_errmsg(db_handle_for_error_reporting);
                if err_msg_ptr.is_null() {
                    format!("SQLite error {err_code} during step; no specific message.")
                } else {
                    std::ffi::CStr::from_ptr(err_msg_ptr)
                        .to_string_lossy()
                        .into_owned()
                }
            };
            let rusqlite_err = rusqlite::Error::SqliteFailure(
                ffi::Error::new(err_code),
                Some(specific_message),
            );
            Err(StepFailure::Failed(XqliteError::from(rusqlite_err)))
        }
    }
}

/// Binds one value at one index.
///
/// # Safety
///
/// The caller holds the connection Mutex for the whole call, `raw_stmt_ptr` is
/// a live prepared statement of that connection and `db_handle` is the
/// `sqlite3*` that owns it.
#[inline]
unsafe fn bind_value_to_raw_stmt(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    bind_idx: c_int,
    value: &Value,
    db_handle: *mut ffi::sqlite3,
) -> Result<(), XqliteError> {
    // SAFETY: forwarded from this function's own contract. SQLITE_TRANSIENT
    // tells SQLite to copy the data immediately, so our local slice can be
    // dropped safely.
    let rc = unsafe {
        match value {
            Value::Null => ffi::sqlite3_bind_null(raw_stmt_ptr, bind_idx),
            Value::Integer(val) => ffi::sqlite3_bind_int64(raw_stmt_ptr, bind_idx, *val),
            Value::Real(val) => ffi::sqlite3_bind_double(raw_stmt_ptr, bind_idx, *val),
            // The 64-bit forms take the byte count as it is. Binding with an
            // explicit length rather than a CString is what lets TEXT hold
            // interior NUL bytes, which SQLite stores fine.
            Value::Text(s_val) => ffi::sqlite3_bind_text64(
                raw_stmt_ptr,
                bind_idx,
                s_val.as_ptr() as *const std::os::raw::c_char,
                s_val.len() as u64,
                ffi::SQLITE_TRANSIENT(),
                ffi::SQLITE_UTF8 as u8,
            ),
            Value::Blob(b_val) => ffi::sqlite3_bind_blob64(
                raw_stmt_ptr,
                bind_idx,
                b_val.as_ptr() as *const std::ffi::c_void,
                b_val.len() as u64,
                ffi::SQLITE_TRANSIENT(),
            ),
        }
    };

    if rc != ffi::SQLITE_OK {
        let ffi_err = ffi::Error::new(rc);
        // SAFETY: forwarded from this function's own contract. sqlite3_errmsg
        // returns a pointer to an internal buffer valid until the next API
        // call; we copy immediately.
        let message = unsafe {
            let err_msg_ptr = ffi::sqlite3_errmsg(db_handle);
            if err_msg_ptr.is_null() {
                format!("Parameter binding failed at index {bind_idx} (code {rc})")
            } else {
                std::ffi::CStr::from_ptr(err_msg_ptr)
                    .to_string_lossy()
                    .into_owned()
            }
        };
        let rusqlite_err = rusqlite::Error::SqliteFailure(ffi_err, Some(message));
        return Err(XqliteError::from(rusqlite_err));
    }
    Ok(())
}

/// Refuses a positional parameter list whose length is not the statement's
/// own parameter count, before anything is bound.
///
/// SQLite itself refuses neither shape: a parameter nothing was bound to
/// reads as NULL, so a short list silently writes NULLs, and a long one only
/// fails at the first index past the last parameter. Every raw-FFI door goes
/// through here. The three doors that bind through rusqlite count the list
/// first as well, through `query.rs:require_parameter_count`, so `provided`
/// is the list's own length everywhere and rusqlite's own check — which stops
/// at the first index the statement lacks and reports THAT index — is only
/// the second line behind them.
///
/// # Safety
///
/// The caller holds the connection Mutex for the whole call and
/// `raw_stmt_ptr` is a live prepared statement of that connection.
pub(crate) unsafe fn require_parameter_count(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    provided: usize,
) -> Result<(), XqliteError> {
    // SAFETY: forwarded from this function's own contract.
    let expected = unsafe { ffi::sqlite3_bind_parameter_count(raw_stmt_ptr) } as usize;

    match provided == expected {
        true => Ok(()),
        false => Err(XqliteError::InvalidParameterCount { provided, expected }),
    }
}

/// Refuses a keyword list that does not name every parameter of the statement
/// exactly once, before anything is bound, and answers the index each key
/// names so the caller binds without resolving them again.
///
/// Three refusals, in this order: a key the statement does not have, two keys
/// that name the same parameter, and a parameter no key named. The last is
/// why the walk exists — SQLite reads a parameter nothing was bound to as
/// NULL, so a list that forgets one writes NULL over that column.
///
/// The twin for the doors that bind through rusqlite is
/// `query.rs:require_named_parameters_covered`.
///
/// # Safety
///
/// The caller holds the connection Mutex for the whole call and
/// `raw_stmt_ptr` is a live prepared statement of that connection.
pub(crate) unsafe fn require_named_parameters_covered(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    params: &[(String, Value)],
) -> Result<Vec<c_int>, XqliteError> {
    // SAFETY: forwarded from this function's own contract.
    let expected = unsafe { ffi::sqlite3_bind_parameter_count(raw_stmt_ptr) };
    let count = expected.max(0) as usize;
    let share = name_walk_share(count);
    // SAFETY: forwarded from this function's own contract.
    let mut resolver = unsafe { name_resolver(raw_stmt_ptr, params.len(), expected) };
    let mut walked: usize = 0;

    // Two structures, because they answer two questions. `indices` keeps the
    // caller's order, which is what the caller zips its values with to bind.
    // `claimed` is one flag per parameter index, so a second key naming the
    // same parameter costs one step instead of a scan of the keys read so
    // far. SQLite caps a statement's parameter count at 32 766, which is what
    // makes the flag vector small whatever the SQL.
    let mut indices: Vec<c_int> = Vec::with_capacity(params.len());
    let mut claimed = vec![false; count + 1];

    for (name, _value) in params {
        // SAFETY: forwarded from this function's own contract.
        let index = unsafe { resolver.index_of(raw_stmt_ptr, name) };

        // Zero is how SQLite says "no such parameter", and no name the map
        // holds is zero either.
        let slot = match usize::try_from(index).ok().filter(|slot| *slot > 0) {
            None => return Err(XqliteError::InvalidParameterName(name.clone())),
            Some(slot) => slot,
        };

        // An index the flag vector has no room for would be SQLite answering
        // outside its own count.
        match claimed.get_mut(slot) {
            None => return Err(XqliteError::InvalidParameterName(name.clone())),
            Some(flag) if *flag => {
                return Err(XqliteError::DuplicateParameterName(name.clone()));
            }
            Some(flag) => {
                *flag = true;
                indices.push(index);
            }
        }

        // A key the statement does not have, and a second key naming one
        // parameter, both end the walk above, so only a key that resolved and
        // was the first to claim its parameter is counted here.
        walked = walked.saturating_add(slot);
        // SAFETY: forwarded from this function's own contract.
        resolver =
            unsafe { map_once_share_spent(resolver, raw_stmt_ptr, expected, walked, share) };
    }

    match (1..=expected).find(|index| !claimed_parameter(&claimed, *index)) {
        None => Ok(indices),
        Some(index) => {
            // SAFETY: forwarded from this function's own contract. SQLite owns
            // the name for the statement's lifetime and it is copied here; a
            // bare `?` has no name and answers a null pointer.
            let name = unsafe {
                let name_ptr = ffi::sqlite3_bind_parameter_name(raw_stmt_ptr, index);

                match name_ptr.is_null() {
                    true => None,
                    false => Some(
                        std::ffi::CStr::from_ptr(name_ptr)
                            .to_string_lossy()
                            .into_owned(),
                    ),
                }
            };

            Err(XqliteError::MissingParameter {
                index: index as usize,
                name,
            })
        }
    }
}

/// How a walk turns a key into the parameter's one-based index.
///
/// The map reads one name per parameter of the statement, so it costs what the
/// statement is long whatever the list holds; a direct lookup walks the same
/// names up to the one it answers, so it costs the position the caller's key
/// named. A keyword list has to name every parameter, so a much shorter one is
/// a list about to be refused, and resolving its keys one at a time keeps that
/// refusal cheap — on a statement of 32 766 parameters the difference is
/// seconds — until the positions add up, which is what `name_walk_share`
/// bounds.
enum NameResolver {
    OneByOne,
    Map(HashMap<String, c_int>),
}

impl NameResolver {
    /// The parameter's one-based index, or 0 for a name the statement does not
    /// have — SQLite's own answer for one.
    ///
    /// # Safety
    ///
    /// The caller holds the connection Mutex for the whole call and
    /// `raw_stmt_ptr` is a live prepared statement of that connection.
    unsafe fn index_of(&self, raw_stmt_ptr: *mut ffi::sqlite3_stmt, name: &str) -> c_int {
        match self {
            NameResolver::Map(by_name) => match by_name.get(name) {
                None => 0,
                Some(index) => *index,
            },
            // A name holding a NUL byte is no parameter name SQLite can be
            // asked about, and is answered like any other it does not have.
            NameResolver::OneByOne => match std::ffi::CString::new(name) {
                Err(_interior_nul) => 0,
                // SAFETY: forwarded from this function's own contract. The
                // CString owns the buffer for the length of the call.
                Ok(c_name) => unsafe {
                    ffi::sqlite3_bind_parameter_index(raw_stmt_ptr, c_name.as_ptr())
                },
            },
        }
    }
}

/// Where a list's keys start being resolved: one holding half the statement's
/// parameters' worth of keys or more reads every name into the map at once,
/// being about to read most of them anyway; a shorter one starts a key at a
/// time and gives that up part-way if the walking costs too much
/// (`name_walk_share`).
///
/// # Safety
///
/// The caller holds the connection Mutex for the whole call and
/// `raw_stmt_ptr` is a live prepared statement of that connection.
unsafe fn name_resolver(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    keys: usize,
    expected: c_int,
) -> NameResolver {
    match keys.saturating_mul(2) < expected.max(0) as usize {
        true => NameResolver::OneByOne,
        false => {
            // SAFETY: forwarded from this function's own contract.
            let by_name = unsafe { parameter_indices_by_name(raw_stmt_ptr, expected) };

            NameResolver::Map(by_name)
        }
    }
}

/// How many names resolving keys one at a time may walk before the map is
/// built for the keys that are left: `count * count / 32`, never less than
/// `count`. That share measures about a sixth of a map read at SQLite's limit
/// of 32 766 parameters, so no key shape costs more than about 1.2 map reads
/// however far into the statement the caller's keys reach. The floor keeps
/// the share from rounding to nothing on a short statement, where it means
/// the map is built after a key or two and nothing measurable is spent.
///
/// The twin for the doors that bind through rusqlite is
/// `query.rs:name_walk_share`.
const NAME_WALK_SHARE_DIVISOR: usize = 32;

#[inline]
fn name_walk_share(count: usize) -> usize {
    let share = count.saturating_mul(count) / NAME_WALK_SHARE_DIVISOR;

    share.max(count)
}

/// The map, built for the keys still to come once the one-by-one walk has
/// spent its share. The keys resolved before it keep their answers, so no key
/// is resolved twice, and the check runs after every key, so the walk
/// overshoots the share by one key's worth at most.
///
/// # Safety
///
/// The caller holds the connection Mutex for the whole call and
/// `raw_stmt_ptr` is a live prepared statement of that connection.
unsafe fn map_once_share_spent(
    resolver: NameResolver,
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    expected: c_int,
    walked: usize,
    share: usize,
) -> NameResolver {
    match resolver {
        NameResolver::OneByOne if walked > share => {
            // SAFETY: forwarded from this function's own contract.
            let by_name = unsafe { parameter_indices_by_name(raw_stmt_ptr, expected) };

            NameResolver::Map(by_name)
        }
        kept => kept,
    }
}

/// SQLite's own spelling of every named parameter, against its one-based
/// index, so that each key costs one hash lookup instead of a call to
/// `sqlite3_bind_parameter_index`, which walks the statement's whole name list
/// with one string comparison per name. Reading one name is a walk of the same
/// list (`sqlite3VListNumToName`), so building the map is not free either — it
/// is about 2.4 times cheaper per name, measured at SQLite's cap of 32 766
/// parameters, and it is the most the C interface allows. A bare `?` has no
/// name and is left out.
///
/// # Safety
///
/// The caller holds the connection Mutex for the whole call and
/// `raw_stmt_ptr` is a live prepared statement of that connection.
unsafe fn parameter_indices_by_name(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    expected: c_int,
) -> HashMap<String, c_int> {
    let mut by_name = HashMap::with_capacity(expected.max(0) as usize);

    for index in 1..=expected {
        // SAFETY: forwarded from this function's own contract. SQLite owns
        // the name for the statement's lifetime and it is copied here; a
        // bare `?` has no name and answers a null pointer.
        let name = unsafe {
            let name_ptr = ffi::sqlite3_bind_parameter_name(raw_stmt_ptr, index);

            match name_ptr.is_null() {
                true => None,
                false => Some(
                    std::ffi::CStr::from_ptr(name_ptr)
                        .to_string_lossy()
                        .into_owned(),
                ),
            }
        };

        if let Some(name) = name {
            by_name.insert(name, index);
        }
    }

    by_name
}

/// Whether a key has claimed the parameter at `index`. An index the flag
/// vector has no room for cannot happen, the vector being sized from the
/// statement's own parameter count, and reads as unclaimed.
#[inline]
fn claimed_parameter(claimed: &[bool], index: c_int) -> bool {
    match usize::try_from(index) {
        Ok(slot) => claimed.get(slot) == Some(&true),
        Err(_negative) => false,
    }
}

/// Why a bind did not happen, and whether SQLite had taken a value by then.
///
/// The library's own refusals — the count, the names, a value it cannot
/// convert, a value over the connection's length limit — all come before the
/// first `sqlite3_bind_*` call, so the statement is untouched. So does one
/// refusal of SQLite's own: a bind on a statement that is mid-run, answered
/// with a misuse before the first parameter is released. Every other failure
/// has taken at least one value, leaving the ones before it bound and the
/// failing parameter NULL.
pub(crate) enum BindFailure {
    NothingBound(XqliteError),
    PartlyBound(XqliteError),
}

/// Which tag a failed bind carries. `vdbeUnbind` answers a misuse for a
/// statement that is mid-run and returns before it releases the parameter, so
/// a misuse on the first value of the list took nothing; every other failure
/// has already replaced that parameter with NULL.
#[inline]
fn bind_failure(position: usize, error: XqliteError) -> BindFailure {
    match position == 0 && crate::error::is_misuse(&error) {
        true => BindFailure::NothingBound(error),
        false => BindFailure::PartlyBound(error),
    }
}

impl BindFailure {
    pub(crate) fn into_error(self) -> XqliteError {
        match self {
            BindFailure::NothingBound(error) => error,
            BindFailure::PartlyBound(error) => error,
        }
    }
}

/// # Safety
///
/// The caller holds the connection Mutex for the whole call, `raw_stmt_ptr` is
/// a live prepared statement of that connection and `db_handle` is the
/// `sqlite3*` that owns it.
pub(crate) unsafe fn bind_positional_params_ffi(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    params: &[Value],
    db_handle: *mut ffi::sqlite3,
) -> Result<(), BindFailure> {
    // SAFETY: forwarded from this function's own contract.
    unsafe { require_parameter_count(raw_stmt_ptr, params.len()) }
        .map_err(BindFailure::NothingBound)?;
    // SAFETY: forwarded from this function's own contract.
    unsafe { crate::limits::require_positional_within_length(db_handle, params) }
        .map_err(BindFailure::NothingBound)?;

    for (i, value) in params.iter().enumerate() {
        // SQLite bind indices are 1-based
        // SAFETY: forwarded from this function's own contract.
        unsafe { bind_value_to_raw_stmt(raw_stmt_ptr, (i + 1) as c_int, value, db_handle) }
            .map_err(|error| bind_failure(i, error))?;
    }
    Ok(())
}

/// # Safety
///
/// The caller holds the connection Mutex for the whole call, `raw_stmt_ptr` is
/// a live prepared statement of that connection and `db_handle` is the
/// `sqlite3*` that owns it.
pub(crate) unsafe fn bind_named_params_ffi(
    raw_stmt_ptr: *mut ffi::sqlite3_stmt,
    params: &[(String, Value)],
    db_handle: *mut ffi::sqlite3,
) -> Result<(), BindFailure> {
    // SAFETY: forwarded from this function's own contract.
    let indices = unsafe { require_named_parameters_covered(raw_stmt_ptr, params) }
        .map_err(BindFailure::NothingBound)?;
    // SAFETY: forwarded from this function's own contract.
    unsafe { crate::limits::require_named_within_length(db_handle, params) }
        .map_err(BindFailure::NothingBound)?;

    for (position, ((_name, value), bind_idx)) in params.iter().zip(indices).enumerate() {
        // SAFETY: forwarded from this function's own contract.
        unsafe { bind_value_to_raw_stmt(raw_stmt_ptr, bind_idx, value, db_handle) }
            .map_err(|error| bind_failure(position, error))?;
    }
    Ok(())
}
