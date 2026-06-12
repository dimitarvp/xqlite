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
use std::sync::atomic::{AtomicI32, Ordering};

/// SQLite's compiled-in default WAL autocheckpoint threshold
/// (`SQLITE_DEFAULT_WAL_AUTOCHECKPOINT`); the bundled build does not
/// override it. Our master callback owns the wal_hook slot from open
/// time onward — which disables SQLite's built-in autocheckpoint — so
/// the emulation must start from the same default SQLite would have
/// used.
const DEFAULT_WAL_AUTOCHECKPOINT_PAGES: i32 = 1000;

/// Everything the master WAL callback needs: the subscriber fan-out
/// list plus the autocheckpoint threshold it emulates.
///
/// SQLite's wal_hook and `sqlite3_wal_autocheckpoint` share a single
/// C-level slot — autocheckpointing is *implemented as* a wal_hook, so
/// registering either silently disables the other. Since we hold the
/// slot for the connection's lifetime, our callback must perform the
/// threshold checkpoint itself (mirroring `sqlite3WalDefaultHook`).
#[derive(Debug)]
pub(crate) struct WalDispatch {
    pub(crate) list: HookList<WalSubscriber>,
    pub(crate) autocheckpoint_pages: AtomicI32,
}

impl WalDispatch {
    pub(crate) fn new() -> Self {
        Self {
            list: HookList::new(),
            autocheckpoint_pages: AtomicI32::new(DEFAULT_WAL_AUTOCHECKPOINT_PAGES),
        }
    }
}

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
/// `user_data` is the `*const WalDispatch` passed at open time; it
/// lives as long as the `XqliteConn` (drop order: conn drops first,
/// then the WalDispatch).
unsafe extern "C" fn wal_hook_callback(
    user_data: *mut c_void,
    db: *mut ffi::sqlite3,
    db_name: *const c_char,
    pages: c_int,
) -> c_int {
    // SAFETY: see the doc comment above.
    let dispatch = unsafe { &*(user_data as *const WalDispatch) };

    let db_name_str = if db_name.is_null() {
        ""
    } else {
        // SAFETY: SQLite passes a valid null-terminated C string.
        unsafe { CStr::from_ptr(db_name) }.to_str().unwrap_or("")
    };

    // SAFETY: snapshot borrow is valid while the callback runs (the conn
    // mutex is held; no concurrent unregister can free the snapshot).
    unsafe {
        dispatch.list.for_each_snapshot(|entry| {
            send_wal_to_pid(&entry.state.pid, db_name_str, pages);
        });
    }

    // Emulate SQLite's built-in autocheckpoint (sqlite3WalDefaultHook):
    // holding the wal_hook slot disables it, so we own the behavior.
    // Like SQLite's own hook, the checkpoint result is ignored —
    // SQLITE_BUSY is routine for a passive checkpoint under readers.
    let threshold = dispatch.autocheckpoint_pages.load(Ordering::Relaxed);
    if threshold > 0 && pages >= threshold {
        // SAFETY: SQLite invokes this hook on the thread that is mid-
        // commit on `db`, i.e. the thread already holding the connection
        // Mutex — the raw-handle locking rule is satisfied. `db` and
        // `db_name` are the live pointers SQLite handed us. A PASSIVE
        // checkpoint never invokes the busy handler and does not commit,
        // so it cannot re-enter this hook.
        unsafe {
            ffi::sqlite3_wal_checkpoint_v2(
                db,
                db_name,
                ffi::SQLITE_CHECKPOINT_PASSIVE,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            );
        }
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

/// Register the WAL callback on a SQLite connection. Called once at
/// open, and again whenever the `wal_autocheckpoint` PRAGMA runs via
/// `set_pragma` (the PRAGMA installs SQLite's internal hook in our
/// slot; we take it back). Subscriber register / unregister never
/// touches SQLite.
///
/// # Safety
///
/// `dispatch` must outlive the SQLite Connection (live in the same
/// `XqliteConn`, whose `Mutex<Connection>` field drops first by
/// declaration order). Caller holds the connection Mutex.
pub(crate) unsafe fn install_callback(conn: &Connection, dispatch: &WalDispatch) {
    let user_data = dispatch as *const WalDispatch as *mut c_void;
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
