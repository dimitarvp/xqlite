//! Multi-subscriber dispatch for SQLite's WAL hook.
//!
//! Same shape as `progress_dispatch`: one C callback registered at
//! connection open, walks a `HookList<WalSubscriber>` per fire. rusqlite
//! 0.39's `Connection::wal_hook` accepts a bare `fn` (no closure
//! capture), so we drop to FFI.

use crate::error::XqliteError;
use crate::hook_util::{self, HookList};
use rusqlite::{Connection, ffi};
use rustler::sys::{
    enif_alloc_env, enif_free_env, enif_make_int64, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_void};

#[derive(Clone)]
pub(crate) struct WalSubscriber {
    pub(crate) pid: LocalPid,
}

impl std::fmt::Debug for WalSubscriber {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WalSubscriber").finish()
    }
}

impl WalSubscriber {
    pub(crate) fn new(pid: LocalPid) -> Self {
        Self { pid }
    }
}

/// C callback invoked after each commit in WAL mode.
///
/// # Safety
///
/// `user_data` is the `*const HookList<WalSubscriber>` passed at open
/// time; it lives as long as the `XqliteConn` (drop order: conn drops
/// first, then the HookList).
unsafe extern "C" fn wal_hook_callback(
    user_data: *mut c_void,
    _db: *mut ffi::sqlite3,
    db_name: *const c_char,
    pages: c_int,
) -> c_int {
    // SAFETY: see the doc comment above.
    let list = unsafe { &*(user_data as *const HookList<WalSubscriber>) };

    let db_name_str = if db_name.is_null() {
        ""
    } else {
        // SAFETY: SQLite passes a valid null-terminated C string.
        unsafe { CStr::from_ptr(db_name) }.to_str().unwrap_or("")
    };

    // SAFETY: snapshot borrow is valid while the callback runs (the conn
    // mutex is held; no concurrent unregister can free the snapshot).
    unsafe {
        list.for_each_snapshot(|entry| {
            send_wal_to_pid(&entry.state.pid, db_name_str, pages);
        });
    }

    ffi::SQLITE_OK
}

/// Send `{:xqlite_wal, db_name, pages}` to `pid`. Fire-and-forget.
///
/// # Safety
///
/// See `busy_handler::send_busy_to_pid` for the OTP 26.1 NULL-env
/// invariant.
unsafe fn send_wal_to_pid(pid: &LocalPid, db_name: &str, pages: c_int) {
    // SAFETY: all enif_* calls operate on a freshly allocated msg_env.
    unsafe {
        let msg_env = enif_alloc_env();

        let tag = hook_util::make_atom(msg_env, b"xqlite_wal");
        let db_term = hook_util::make_binary(msg_env, db_name.as_bytes());
        let pages_term = enif_make_int64(msg_env, pages as i64);

        let elements = [tag, db_term, pages_term];
        let msg = enif_make_tuple_from_array(msg_env, elements.as_ptr(), 3);

        let _res = enif_send(std::ptr::null_mut(), pid.as_c_arg(), msg_env, msg);

        enif_free_env(msg_env);
    }
}

/// Register the WAL callback on a freshly opened SQLite connection. The
/// callback stays installed for the connection's lifetime; subscriber
/// register / unregister never touches SQLite again.
///
/// # Safety
///
/// `list` must outlive the SQLite Connection (live in the same
/// `XqliteConn`, whose `Mutex<Connection>` field drops first by
/// declaration order). Caller holds the connection Mutex.
pub(crate) unsafe fn install_callback(conn: &Connection, list: &HookList<WalSubscriber>) {
    let user_data = list as *const HookList<WalSubscriber> as *mut c_void;
    // SAFETY: see the doc comment.
    unsafe {
        ffi::sqlite3_wal_hook(conn.handle(), Some(wal_hook_callback), user_data);
    }
}

/// Add a WAL subscriber. Returns the handle the caller passes to
/// `unregister` to remove it.
pub(crate) fn register(
    list: &HookList<WalSubscriber>,
    pid: LocalPid,
) -> Result<u64, XqliteError> {
    Ok(list.register(WalSubscriber::new(pid)))
}

/// Remove a WAL subscriber. Idempotent — unknown handles are no-ops.
pub(crate) fn unregister(list: &HookList<WalSubscriber>, id: u64) {
    let _ = list.unregister(id);
}
