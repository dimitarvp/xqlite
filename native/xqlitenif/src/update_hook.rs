//! Multi-subscriber dispatch for SQLite's update hook.
//!
//! rusqlite 0.39's `Connection::update_hook` accepts a `FnMut + Send +
//! 'static` closure, so we install one master closure per connection at
//! open time. The closure captures `Arc<HookList<UpdateSubscriber>>`
//! and fans out each event to every subscriber. Register / unregister
//! NIFs only modify the HookList; they never touch rusqlite.

use crate::error::XqliteError;
use crate::hook_util::{self, HookList};
use rusqlite::hooks::Action;
use rustler::sys::{
    enif_alloc_env, enif_free_env, enif_make_int64, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct UpdateSubscriber {
    pub(crate) pid: LocalPid,
}

impl std::fmt::Debug for UpdateSubscriber {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("UpdateSubscriber").finish()
    }
}

impl UpdateSubscriber {
    pub(crate) fn new(pid: LocalPid) -> Self {
        Self { pid }
    }
}

/// Install the master update-hook closure on a freshly opened
/// connection. The closure captures `list` so subscriber-level
/// register / unregister stays cheap (modifies the HookList only).
pub(crate) fn install_callback(
    conn: &rusqlite::Connection,
    list: Arc<HookList<UpdateSubscriber>>,
) -> Result<(), XqliteError> {
    conn.update_hook(Some(
        move |action: Action, db: &str, table: &str, rowid: i64| {
            let action_name: &[u8] = match action {
                Action::SQLITE_INSERT => b"insert",
                Action::SQLITE_UPDATE => b"update",
                Action::SQLITE_DELETE => b"delete",
                _ => b"unknown",
            };

            // SAFETY: the closure captures Arc<HookList>, so the list
            // outlives every callback. Snapshot iteration is wait-free.
            unsafe {
                list.for_each_snapshot(|entry| {
                    send_update_to_pid(&entry.state.pid, action_name, db, table, rowid);
                });
            }
        },
    ))?;
    Ok(())
}

/// Send `{:xqlite_update, action, db, table, rowid}` to `pid`.
///
/// # Safety
///
/// See `busy_handler::send_busy_to_pid` for the OTP 26.1 NULL-env
/// invariant. All data is copied into a fresh msg_env; no references
/// retained across the call.
unsafe fn send_update_to_pid(
    pid: &LocalPid,
    action_name: &[u8],
    db_name: &str,
    table_name: &str,
    rowid: i64,
) {
    // SAFETY: see fn doc.
    unsafe {
        let msg_env = enif_alloc_env();

        let tag = hook_util::make_atom(msg_env, b"xqlite_update");
        let action = hook_util::make_atom(msg_env, action_name);
        let db = hook_util::make_binary(msg_env, db_name.as_bytes());
        let table = hook_util::make_binary(msg_env, table_name.as_bytes());
        let rid = enif_make_int64(msg_env, rowid);

        let elements = [tag, action, db, table, rid];
        let msg = enif_make_tuple_from_array(msg_env, elements.as_ptr(), 5);

        let _res = enif_send(std::ptr::null_mut(), pid.as_c_arg(), msg_env, msg);

        enif_free_env(msg_env);
    }
}

/// Add an update subscriber.
pub(crate) fn register(
    list: &HookList<UpdateSubscriber>,
    pid: LocalPid,
) -> Result<u64, XqliteError> {
    Ok(list.register(UpdateSubscriber::new(pid)))
}

/// Remove an update subscriber. Idempotent.
pub(crate) fn unregister(list: &HookList<UpdateSubscriber>, id: u64) {
    let _ = list.unregister(id);
}
