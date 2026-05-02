//! Multi-subscriber dispatch for SQLite's commit hook.
//!
//! Master closure installed once via `Connection::commit_hook`; fans
//! out each commit event to a `HookList<CommitSubscriber>`. The hook
//! is observation-only — the master closure always returns `false`
//! (never vetoes). Multi-subscriber composition for a policy callback
//! has no clean rule (see `project_busy_handler_observer_split`); for
//! commit, observation is the only sensible semantics.

use crate::error::XqliteError;
use crate::hook_util::{self, HookList};
use rustler::sys::{enif_alloc_env, enif_free_env, enif_make_tuple_from_array, enif_send};
use rustler::types::LocalPid;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct CommitSubscriber {
    pub(crate) pid: LocalPid,
}

impl std::fmt::Debug for CommitSubscriber {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CommitSubscriber").finish()
    }
}

impl CommitSubscriber {
    pub(crate) fn new(pid: LocalPid) -> Self {
        Self { pid }
    }
}

pub(crate) fn install_callback(
    conn: &rusqlite::Connection,
    list: Arc<HookList<CommitSubscriber>>,
) -> Result<(), XqliteError> {
    conn.commit_hook(Some(move || {
        // SAFETY: closure-captured Arc keeps the list alive across calls.
        unsafe {
            list.for_each_snapshot(|entry| {
                send_commit_to_pid(&entry.state.pid);
            });
        }
        false // never veto — observation only
    }))?;
    Ok(())
}

/// # Safety
///
/// See `busy_handler::send_busy_to_pid`.
unsafe fn send_commit_to_pid(pid: &LocalPid) {
    unsafe {
        let msg_env = enif_alloc_env();

        let tag = hook_util::make_atom(msg_env, b"xqlite_commit");
        let elements = [tag];
        let msg = enif_make_tuple_from_array(msg_env, elements.as_ptr(), 1);

        let _res = enif_send(std::ptr::null_mut(), pid.as_c_arg(), msg_env, msg);

        enif_free_env(msg_env);
    }
}

pub(crate) fn register(
    list: &HookList<CommitSubscriber>,
    pid: LocalPid,
) -> Result<u64, XqliteError> {
    Ok(list.register(CommitSubscriber::new(pid)))
}

pub(crate) fn unregister(list: &HookList<CommitSubscriber>, id: u64) {
    let _ = list.unregister(id);
}
