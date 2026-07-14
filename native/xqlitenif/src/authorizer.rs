use crate::atoms;
use crate::error::XqliteError;
use rusqlite::Connection;
use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
use rustler::Atom;
use std::collections::HashSet;

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

/// Build the denied-kind set from user atoms, rejecting any unrecognized atom
/// before an authorizer is touched.
pub(crate) fn parse_denied(actions: Vec<Atom>) -> Result<HashSet<ActionKind>, XqliteError> {
    actions.into_iter().map(ActionKind::from_atom).collect()
}

/// Install a deny-list authorizer, replacing any previous one (single slot).
///
/// The closure owns the denied set and only reads it, so it is `Fn` (hence
/// `FnMut`), `Send`, and `'static` — exactly what rusqlite's safe authorizer
/// API requires. Callers must hold the connection Mutex.
pub(crate) fn set(conn: &Connection, denied: HashSet<ActionKind>) -> Result<(), XqliteError> {
    conn.authorizer(Some(move |ctx: AuthContext<'_>| {
        if denied.contains(&ActionKind::of(&ctx.action)) {
            Authorization::Deny
        } else {
            Authorization::Allow
        }
    }))
    .map_err(XqliteError::from)
}

/// Clear any installed authorizer. Idempotent. Callers must hold the
/// connection Mutex.
pub(crate) fn clear(conn: &Connection) -> Result<(), XqliteError> {
    conn.authorizer(None::<fn(AuthContext<'_>) -> Authorization>)
        .map_err(XqliteError::from)
}
