//! Multi-subscriber dispatch for SQLite's rollback hook.
//!
//! Master closure installed once via `Connection::rollback_hook`;
//! fans out each rollback event to a `HookList<RollbackSubscriber>`.

use crate::error::XqliteError;
use crate::hook_util::{self, HookList};
use rustler::sys::{enif_alloc_env, enif_free_env, enif_make_tuple_from_array, enif_send};
use rustler::types::LocalPid;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct RollbackSubscriber {
    pub(crate) pid: LocalPid,
}

impl std::fmt::Debug for RollbackSubscriber {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RollbackSubscriber").finish()
    }
}

impl RollbackSubscriber {
    pub(crate) fn new(pid: LocalPid) -> Self {
        Self { pid }
    }
}

pub(crate) fn install_callback(
    conn: &rusqlite::Connection,
    list: Arc<HookList<RollbackSubscriber>>,
) -> Result<(), XqliteError> {
    conn.rollback_hook(Some(move || {
        // SAFETY: closure-captured Arc keeps the list alive across calls.
        unsafe {
            list.for_each_snapshot(|entry| {
                send_rollback_to_pid(&entry.state.pid);
            });
        }
    }))?;
    Ok(())
}

/// # Safety
///
/// See `busy_handler::send_busy_to_pid`.
unsafe fn send_rollback_to_pid(pid: &LocalPid) {
    unsafe {
        let msg_env = enif_alloc_env();

        let tag = hook_util::make_atom(msg_env, b"xqlite_rollback");
        let elements = [tag];
        let msg = enif_make_tuple_from_array(msg_env, elements.as_ptr(), 1);

        let _res = enif_send(std::ptr::null_mut(), pid.as_c_arg(), msg_env, msg);

        enif_free_env(msg_env);
    }
}

pub(crate) fn register(
    list: &HookList<RollbackSubscriber>,
    pid: LocalPid,
) -> Result<u64, XqliteError> {
    Ok(list.register(RollbackSubscriber::new(pid)))
}

pub(crate) fn unregister(list: &HookList<RollbackSubscriber>, id: u64) {
    let _ = list.unregister(id);
}
