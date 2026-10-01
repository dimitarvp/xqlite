//! Multi-subscriber dispatch for SQLite's update hook.
//!
//! One raw C callback, registered with `sqlite3_update_hook` at open, fans
//! each write out to a `HookList<UpdateSubscriber>` and reads the database
//! and table names as bytes. rusqlite's wrapper is not used: it panics on a
//! name that is not UTF-8 and drops the event. Register / unregister NIFs
//! only modify the HookList; they never touch SQLite.

use crate::error::XqliteError;
use crate::hook_util::{self, HookList};
use rusqlite::{Connection, ffi};
use rustler::sys::{
    enif_alloc_env, enif_free_env, enif_make_int64, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;
use std::os::raw::{c_char, c_int, c_void};

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

/// The update hook SQLite calls for each row a statement writes.
///
/// # Safety
///
/// `user_data` is the update `HookList` inside the connection's resource,
/// registered once at open. The `conn` field is declared first and drops
/// first, and rusqlite's close clears the update hook before `sqlite3_close`,
/// so the list outlives every call. The two names are NUL-terminated strings
/// SQLite keeps valid for the call; `make_binary` copies them into the
/// message environment before the send.
unsafe extern "C" fn update_callback(
    user_data: *mut c_void,
    code: c_int,
    db_name: *const c_char,
    table_name: *const c_char,
    rowid: ffi::sqlite3_int64,
) {
    hook_util::guard_ffi_callback("update_callback", 0, move || {
        let action_name: &[u8] = match code {
            ffi::SQLITE_INSERT => b"insert",
            ffi::SQLITE_UPDATE => b"update",
            ffi::SQLITE_DELETE => b"delete",
            _ => b"unknown",
        };

        // SAFETY: see the doc comment above.
        unsafe {
            let list = &*(user_data as *const HookList<UpdateSubscriber>);
            let db = hook_util::c_bytes(db_name).unwrap_or_default();
            let table = hook_util::c_bytes(table_name).unwrap_or_default();
            list.for_each_snapshot(|entry| {
                send_update_to_pid(&entry.state.pid, action_name, db, table, rowid);
            });
        }
        0
    });
}

/// Register the update callback on a freshly opened connection, once;
/// subscriber register / unregister never touches SQLite.
///
/// # Safety
///
/// `list` must outlive the SQLite Connection (live in the same
/// `XqliteConn`, whose `Mutex<Connection>` field drops first by
/// declaration order). Caller holds the connection Mutex.
pub(crate) unsafe fn install_callback(conn: &Connection, list: &HookList<UpdateSubscriber>) {
    let user_data = list as *const HookList<UpdateSubscriber> as *mut c_void;
    // SAFETY: see the doc comment.
    unsafe {
        ffi::sqlite3_update_hook(conn.handle(), Some(update_callback), user_data);
    }
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
    db_name: &[u8],
    table_name: &[u8],
    rowid: i64,
) {
    // SAFETY: see fn doc.
    unsafe {
        let msg_env = enif_alloc_env();

        let tag = hook_util::make_atom(msg_env, b"xqlite_update");
        let action = hook_util::make_atom(msg_env, action_name);
        let db = hook_util::make_binary(msg_env, db_name);
        let table = hook_util::make_binary(msg_env, table_name);
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
