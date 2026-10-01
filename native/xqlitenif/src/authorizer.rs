use crate::atoms;
use crate::busy_handler::{self, BusySlotFlags};
use crate::connection::XqliteConn;
use crate::error::XqliteError;
use crate::hook_util;
use rusqlite::{Connection, ffi};
use rustler::{Atom, Term};
use std::collections::HashSet;
use std::os::raw::{c_char, c_int, c_void};
use std::sync::Arc;

/// A single authorizer action *kind*, one per SQLite action code.
///
/// v1 granularity is the action kind only — the table / column / trigger /
/// database names SQLite passes with each code are never read, whatever
/// their bytes. `Unknown` is a code this build does not map.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum ActionKind {
    CreateIndex,
    CreateTable,
    CreateTempIndex,
    CreateTempTable,
    CreateTempTrigger,
    CreateTempView,
    CreateTrigger,
    CreateView,
    Delete,
    DropIndex,
    DropTable,
    DropTempIndex,
    DropTempTable,
    DropTempTrigger,
    DropTempView,
    DropTrigger,
    DropView,
    Insert,
    Pragma,
    Read,
    Select,
    Transaction,
    Update,
    Attach,
    Detach,
    AlterTable,
    Reindex,
    Analyze,
    CreateVtable,
    DropVtable,
    Function,
    Savepoint,
    Recursive,
    Unknown,
}

impl ActionKind {
    #[inline]
    fn of(code: c_int) -> Self {
        match code {
            ffi::SQLITE_CREATE_INDEX => Self::CreateIndex,
            ffi::SQLITE_CREATE_TABLE => Self::CreateTable,
            ffi::SQLITE_CREATE_TEMP_INDEX => Self::CreateTempIndex,
            ffi::SQLITE_CREATE_TEMP_TABLE => Self::CreateTempTable,
            ffi::SQLITE_CREATE_TEMP_TRIGGER => Self::CreateTempTrigger,
            ffi::SQLITE_CREATE_TEMP_VIEW => Self::CreateTempView,
            ffi::SQLITE_CREATE_TRIGGER => Self::CreateTrigger,
            ffi::SQLITE_CREATE_VIEW => Self::CreateView,
            ffi::SQLITE_DELETE => Self::Delete,
            ffi::SQLITE_DROP_INDEX => Self::DropIndex,
            ffi::SQLITE_DROP_TABLE => Self::DropTable,
            ffi::SQLITE_DROP_TEMP_INDEX => Self::DropTempIndex,
            ffi::SQLITE_DROP_TEMP_TABLE => Self::DropTempTable,
            ffi::SQLITE_DROP_TEMP_TRIGGER => Self::DropTempTrigger,
            ffi::SQLITE_DROP_TEMP_VIEW => Self::DropTempView,
            ffi::SQLITE_DROP_TRIGGER => Self::DropTrigger,
            ffi::SQLITE_DROP_VIEW => Self::DropView,
            ffi::SQLITE_INSERT => Self::Insert,
            ffi::SQLITE_PRAGMA => Self::Pragma,
            ffi::SQLITE_READ => Self::Read,
            ffi::SQLITE_SELECT => Self::Select,
            ffi::SQLITE_TRANSACTION => Self::Transaction,
            ffi::SQLITE_UPDATE => Self::Update,
            ffi::SQLITE_ATTACH => Self::Attach,
            ffi::SQLITE_DETACH => Self::Detach,
            ffi::SQLITE_ALTER_TABLE => Self::AlterTable,
            ffi::SQLITE_REINDEX => Self::Reindex,
            ffi::SQLITE_ANALYZE => Self::Analyze,
            ffi::SQLITE_CREATE_VTABLE => Self::CreateVtable,
            ffi::SQLITE_DROP_VTABLE => Self::DropVtable,
            ffi::SQLITE_FUNCTION => Self::Function,
            ffi::SQLITE_SAVEPOINT => Self::Savepoint,
            ffi::SQLITE_RECURSIVE => Self::Recursive,
            _ => Self::Unknown,
        }
    }

    /// Parse a user-supplied action atom into its kind. An unrecognized atom
    /// is a structured error so the whole list can be rejected atomically
    /// before any authorizer is installed.
    fn from_atom(atom: Atom) -> Result<Self, XqliteError> {
        let table: [(Atom, Self); 34] = [
            (atoms::create_index(), Self::CreateIndex),
            (atoms::create_table(), Self::CreateTable),
            (atoms::create_temp_index(), Self::CreateTempIndex),
            (atoms::create_temp_table(), Self::CreateTempTable),
            (atoms::create_temp_trigger(), Self::CreateTempTrigger),
            (atoms::create_temp_view(), Self::CreateTempView),
            (atoms::create_trigger(), Self::CreateTrigger),
            (atoms::create_view(), Self::CreateView),
            (atoms::delete(), Self::Delete),
            (atoms::drop_index(), Self::DropIndex),
            (atoms::drop_table(), Self::DropTable),
            (atoms::drop_temp_index(), Self::DropTempIndex),
            (atoms::drop_temp_table(), Self::DropTempTable),
            (atoms::drop_temp_trigger(), Self::DropTempTrigger),
            (atoms::drop_temp_view(), Self::DropTempView),
            (atoms::drop_trigger(), Self::DropTrigger),
            (atoms::drop_view(), Self::DropView),
            (atoms::insert(), Self::Insert),
            (atoms::pragma(), Self::Pragma),
            (atoms::read(), Self::Read),
            (atoms::select(), Self::Select),
            (atoms::transaction(), Self::Transaction),
            (atoms::update(), Self::Update),
            (atoms::attach(), Self::Attach),
            (atoms::detach(), Self::Detach),
            (atoms::alter_table(), Self::AlterTable),
            (atoms::reindex(), Self::Reindex),
            (atoms::analyze(), Self::Analyze),
            (atoms::create_vtable(), Self::CreateVtable),
            (atoms::drop_vtable(), Self::DropVtable),
            (atoms::function(), Self::Function),
            (atoms::savepoint(), Self::Savepoint),
            (atoms::recursive(), Self::Recursive),
            (atoms::unknown(), Self::Unknown),
        ];
        table
            .into_iter()
            .find_map(|(a, kind)| (a == atom).then_some(kind))
            .ok_or(XqliteError::InvalidAuthorizerAction { action: atom })
    }
}

/// Build the denied-kind set from the caller's list, rejecting an element that
/// is no atom, and an atom that names no action, before an authorizer is
/// touched. The list is walked by hand, so a broken tail is refused too.
pub(crate) fn parse_denied(actions: Term<'_>) -> Result<HashSet<ActionKind>, XqliteError> {
    let items = crate::util::walk_list(actions)?;
    let mut denied = HashSet::new();

    for (index, item) in items.iter().enumerate() {
        let action: Atom = item
            .decode()
            .map_err(|_not_an_atom| XqliteError::bad_element(index + 1, *item))?;
        denied.insert(ActionKind::from_atom(action)?);
    }

    Ok(denied)
}

/// A `PRAGMA busy_timeout` statement, and whether it carries a value.
enum BusyTimeout {
    Read,
    Write,
}

/// Recognise `PRAGMA busy_timeout` however it was typed. SQLite hands the
/// callback the name as written, quotes removed, with any schema prefix
/// carried separately — so the compare is on the bare name's bytes and ignores
/// ASCII case, and a value is present exactly when the statement writes.
fn busy_timeout_action(pragma: Option<(&[u8], Option<&[u8]>)>) -> Option<BusyTimeout> {
    match pragma {
        Some((name, value)) if name.eq_ignore_ascii_case(b"busy_timeout") => match value {
            Some(_value) => Some(BusyTimeout::Write),
            None => Some(BusyTimeout::Read),
        },
        _ => None,
    }
}

/// The PRAGMAs the image functions run on their target: `encoding` without a
/// value and `writable_schema = RESET` in `deserialize`, and `page_count`
/// without a value in `serialize`, by xqlite and again by `sqlite3_serialize`.
fn image_pragma(pragma: Option<(&[u8], Option<&[u8]>)>) -> bool {
    match pragma {
        Some((name, None)) => {
            name.eq_ignore_ascii_case(b"encoding") || name.eq_ignore_ascii_case(b"page_count")
        }
        Some((name, Some(value))) => {
            name.eq_ignore_ascii_case(b"writable_schema")
                && value.eq_ignore_ascii_case(b"reset")
        }
        None => false,
    }
}

/// The answer for one action code, `pragma` holding a PRAGMA's name and value:
/// xqlite's own reads and the busy slot's rules about `busy_timeout` first,
/// then the kinds the caller denied.
fn decide(
    code: c_int,
    pragma: Option<(&[u8], Option<&[u8]>)>,
    denied: &HashSet<ActionKind>,
    flags: &BusySlotFlags,
) -> c_int {
    match busy_timeout_action(pragma) {
        Some(BusyTimeout::Read) if flags.reading_own_pragma() => ffi::SQLITE_OK,
        Some(BusyTimeout::Write) if flags.slot_held() => {
            flags.note_write_refused();
            ffi::SQLITE_DENY
        }
        None if flags.reading_own_pragma() && image_pragma(pragma) => ffi::SQLITE_OK,
        _ => user_decision(code, denied),
    }
}

/// The caller's own deny-list: the only rule that looks at the action kind.
fn user_decision(code: c_int, denied: &HashSet<ActionKind>) -> c_int {
    if denied.contains(&ActionKind::of(code)) {
        ffi::SQLITE_DENY
    } else {
        ffi::SQLITE_OK
    }
}

/// What the authorizer callback decides with: the caller's denied kinds and a
/// handle on the busy slot's flags, in the box the authorizer slot holds.
pub(crate) struct AuthorizerState {
    denied: HashSet<ActionKind>,
    flags: Arc<BusySlotFlags>,
}

/// The authorizer SQLite calls for each action of a statement it compiles. It
/// reads the action code and, for a PRAGMA only, the PRAGMA's name and value
/// as bytes; no other name is read.
///
/// # Safety
///
/// `user_data` is the `AuthorizerState` box the authorizer slot holds. SQLite
/// runs the authorizer only while it compiles SQL inside a `sqlite3_*` call
/// the library makes under the connection Mutex. `install` hands SQLite the
/// new box before it frees the old one, and `clear` takes the pointer back
/// from SQLite before it frees the box, both under that Mutex, so the box
/// lives for the whole call. The text arguments are NULL or NUL-terminated
/// strings SQLite keeps valid for the call, and nothing built from them
/// outlives it.
unsafe extern "C" fn authorizer_callback(
    user_data: *mut c_void,
    code: c_int,
    arg1: *const c_char,
    arg2: *const c_char,
    _db_name: *const c_char,
    _accessor: *const c_char,
) -> c_int {
    hook_util::guard_ffi_callback("authorizer_callback", ffi::SQLITE_DENY, move || {
        // SAFETY: see the doc comment above.
        let state = unsafe { &*(user_data as *const AuthorizerState) };
        let pragma = match code {
            ffi::SQLITE_PRAGMA => {
                // SAFETY: see the doc comment above; for a PRAGMA they are its name and value.
                let (name, value) =
                    unsafe { (hook_util::c_bytes(arg1), hook_util::c_bytes(arg2)) };
                name.map(|name| (name, value))
            }
            _ => None,
        };
        decide(code, pragma, &state.denied, &state.flags)
    })
}

/// Record the action kinds the caller denies and make the connection's
/// authorizer match. Callers must hold the connection Mutex.
pub(crate) fn set(
    conn: &Connection,
    handle: &XqliteConn,
    denied: HashSet<ActionKind>,
) -> Result<(), XqliteError> {
    store_denied(handle, Some(denied))?;
    sync(conn, handle)
}

/// Forget the caller's action kinds; the busy slot's own rules stay.
/// Callers must hold the connection Mutex.
pub(crate) fn remove(conn: &Connection, handle: &XqliteConn) -> Result<(), XqliteError> {
    store_denied(handle, None)?;
    sync(conn, handle)
}

fn store_denied(
    handle: &XqliteConn,
    denied: Option<HashSet<ActionKind>>,
) -> Result<(), XqliteError> {
    let mut guard = handle
        .denied_actions
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    *guard = denied;
    Ok(())
}

/// Install or clear the connection's single authorizer so it carries what is
/// asked of it now: the caller's denied kinds, the busy slot's rules, or
/// neither. Callers must hold the connection Mutex.
pub(crate) fn sync(conn: &Connection, handle: &XqliteConn) -> Result<(), XqliteError> {
    let denied = {
        let guard = handle
            .denied_actions
            .lock()
            .map_err(|e| XqliteError::LockError(e.to_string()))?;
        guard.clone()
    };

    match (denied, handle.busy_flags.slot_held()) {
        (None, false) => clear(conn, handle),
        (user_denied, _) => install(conn, handle, user_denied.unwrap_or_default()),
    }
}

fn install(
    conn: &Connection,
    handle: &XqliteConn,
    denied: HashSet<ActionKind>,
) -> Result<(), XqliteError> {
    let flags = Arc::clone(&handle.busy_flags);
    hook_util::install_hook(
        &handle.callback_boxes.authorizer,
        AuthorizerState { denied, flags },
        |state| register(conn, state),
    )
}

/// Clear any installed authorizer and free its box. Idempotent. SQLite expires
/// every prepared statement on this call even with nothing installed, which
/// `deserialize` relies on after a load. Callers must hold the connection Mutex.
fn clear(conn: &Connection, handle: &XqliteConn) -> Result<(), XqliteError> {
    hook_util::uninstall_hook(&handle.callback_boxes.authorizer, || {
        register(conn, std::ptr::null_mut())
    })
}

/// Point SQLite's authorizer at `state`, or clear it for a null `state`, and
/// answer its code. Callers must hold the connection Mutex.
fn register(conn: &Connection, state: *mut AuthorizerState) -> Result<(), XqliteError> {
    let callback = (!state.is_null()).then_some(authorizer_callback as _);
    // SAFETY: the caller holds the connection Mutex, so `conn.handle()` is the live handle.
    let rc = unsafe { ffi::sqlite3_set_authorizer(conn.handle(), callback, state.cast()) };
    if rc == ffi::SQLITE_OK {
        Ok(())
    } else {
        Err(busy_handler::ffi_rc_to_error(
            conn,
            "sqlite3_set_authorizer",
            rc,
        ))
    }
}
