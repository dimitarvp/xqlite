use crate::atoms;
use crate::busy_handler::BusySlotFlags;
use crate::connection::XqliteConn;
use crate::error::XqliteError;
use rusqlite::Connection;
use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use rustler::{Atom, Term};
use std::collections::HashSet;
use std::sync::Arc;

/// A single authorizer action *kind*.
///
/// v1 granularity is the action kind only — the table / column / trigger /
/// database arguments rusqlite carries on each `AuthAction` are intentionally
/// discarded. Exhaustive over the rusqlite 0.40 `AuthAction` enum; `Unknown`
/// also absorbs any future (`#[non_exhaustive]`) variant.
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
    /// Kind of an incoming authorizer action (all arguments discarded).
    #[inline]
    fn of(action: &AuthAction<'_>) -> Self {
        match action {
            AuthAction::CreateIndex { .. } => Self::CreateIndex,
            AuthAction::CreateTable { .. } => Self::CreateTable,
            AuthAction::CreateTempIndex { .. } => Self::CreateTempIndex,
            AuthAction::CreateTempTable { .. } => Self::CreateTempTable,
            AuthAction::CreateTempTrigger { .. } => Self::CreateTempTrigger,
            AuthAction::CreateTempView { .. } => Self::CreateTempView,
            AuthAction::CreateTrigger { .. } => Self::CreateTrigger,
            AuthAction::CreateView { .. } => Self::CreateView,
            AuthAction::Delete { .. } => Self::Delete,
            AuthAction::DropIndex { .. } => Self::DropIndex,
            AuthAction::DropTable { .. } => Self::DropTable,
            AuthAction::DropTempIndex { .. } => Self::DropTempIndex,
            AuthAction::DropTempTable { .. } => Self::DropTempTable,
            AuthAction::DropTempTrigger { .. } => Self::DropTempTrigger,
            AuthAction::DropTempView { .. } => Self::DropTempView,
            AuthAction::DropTrigger { .. } => Self::DropTrigger,
            AuthAction::DropView { .. } => Self::DropView,
            AuthAction::Insert { .. } => Self::Insert,
            AuthAction::Pragma { .. } => Self::Pragma,
            AuthAction::Read { .. } => Self::Read,
            AuthAction::Select => Self::Select,
            AuthAction::Transaction { .. } => Self::Transaction,
            AuthAction::Update { .. } => Self::Update,
            AuthAction::Attach { .. } => Self::Attach,
            AuthAction::Detach { .. } => Self::Detach,
            AuthAction::AlterTable { .. } => Self::AlterTable,
            AuthAction::Reindex { .. } => Self::Reindex,
            AuthAction::Analyze { .. } => Self::Analyze,
            AuthAction::CreateVtable { .. } => Self::CreateVtable,
            AuthAction::DropVtable { .. } => Self::DropVtable,
            AuthAction::Function { .. } => Self::Function,
            AuthAction::Savepoint { .. } => Self::Savepoint,
            AuthAction::Recursive => Self::Recursive,
            // `AuthAction::Unknown` and any future non_exhaustive variant.
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
/// carried separately — so the compare is on the bare name and ignores case,
/// and a value is present exactly when the statement writes.
fn busy_timeout_action(action: &AuthAction<'_>) -> Option<BusyTimeout> {
    match action {
        AuthAction::Pragma {
            pragma_name,
            pragma_value,
            ..
        } if pragma_name.eq_ignore_ascii_case("busy_timeout") => match pragma_value {
            Some(_value) => Some(BusyTimeout::Write),
            None => Some(BusyTimeout::Read),
        },
        _ => None,
    }
}

/// `PRAGMA encoding` without a value: the read `deserialize` runs on its target.
fn encoding_read(action: &AuthAction<'_>) -> bool {
    matches!(
        action,
        AuthAction::Pragma { pragma_name, pragma_value: None, .. }
            if pragma_name.eq_ignore_ascii_case("encoding")
    )
}

/// The answer for one action: xqlite's own reads and the busy slot's rules
/// about `busy_timeout` first, then the kinds the caller denied.
fn decide(
    action: &AuthAction<'_>,
    denied: &HashSet<ActionKind>,
    flags: &BusySlotFlags,
) -> Authorization {
    match busy_timeout_action(action) {
        Some(BusyTimeout::Read) if flags.reading_own_pragma() => Authorization::Allow,
        Some(BusyTimeout::Write) if flags.slot_held() => {
            flags.note_write_refused();
            Authorization::Deny
        }
        None if flags.reading_own_pragma() && encoding_read(action) => Authorization::Allow,
        _ => user_decision(action, denied),
    }
}

/// The caller's own deny-list: the only rule that looks at the action kind.
fn user_decision(action: &AuthAction<'_>, denied: &HashSet<ActionKind>) -> Authorization {
    if denied.contains(&ActionKind::of(action)) {
        Authorization::Deny
    } else {
        Authorization::Allow
    }
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
/// neither. Callers must hold the connection Mutex, and must not call this
/// from inside a row-mapping closure of the same connection — rusqlite
/// borrows the connection mutably to install.
pub(crate) fn sync(conn: &Connection, handle: &XqliteConn) -> Result<(), XqliteError> {
    let denied = {
        let guard = handle
            .denied_actions
            .lock()
            .map_err(|e| XqliteError::LockError(e.to_string()))?;
        guard.clone()
    };

    match (denied, handle.busy_flags.slot_held()) {
        (None, false) => clear(conn),
        (user_denied, _) => {
            let flags = Arc::clone(&handle.busy_flags);
            install(conn, user_denied.unwrap_or_default(), flags)
        }
    }
}

/// Install the composed closure. It owns the denied set and a handle on the
/// busy slot's flags, which makes it `FnMut`, `Send` and `'static` — what
/// rusqlite's safe authorizer API requires.
fn install(
    conn: &Connection,
    denied: HashSet<ActionKind>,
    flags: Arc<BusySlotFlags>,
) -> Result<(), XqliteError> {
    conn.authorizer(Some(move |ctx: AuthContext<'_>| {
        decide(&ctx.action, &denied, &flags)
    }))
    .map_err(XqliteError::from)
}

/// Clear any installed authorizer. Idempotent. Callers must hold the
/// connection Mutex.
fn clear(conn: &Connection) -> Result<(), XqliteError> {
    conn.authorizer(None::<fn(AuthContext<'_>) -> Authorization>)
        .map_err(XqliteError::from)
}
