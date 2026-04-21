use crate::error::XqliteError;
use crate::hook_util;
use rusqlite::{Connection, ffi};
use rustler::sys::{
    enif_alloc_env, enif_free_env, enif_make_int64, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_void};
use std::sync::atomic::AtomicPtr;

/// State kept alive while a WAL hook is installed on a connection.
///
/// rusqlite 0.39's `Connection::wal_hook` only accepts bare `fn`
/// pointers, so we drop to FFI to capture `pid` via a `Box<State>`
/// stored on `XqliteConn`.
pub(crate) struct WalHookState {
    pid: LocalPid,
}

impl std::fmt::Debug for WalHookState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WalHookState").finish()
    }
}

/// The C callback SQLite invokes after each commit in WAL mode.
///
/// # Safety
///
/// `user_data` must point to a `WalHookState` previously installed via
/// `install` and not yet reclaimed. SQLite guarantees the pointer is
/// exactly what we passed to `sqlite3_wal_hook`.
unsafe extern "C" fn wal_hook_callback(
    user_data: *mut c_void,
    _db: *mut ffi::sqlite3,
    db_name: *const c_char,
    pages: c_int,
) -> c_int {
    // SAFETY: `user_data` is the Box<WalHookState> pointer we leaked in
    // `install`. Valid until `uninstall` (or connection Drop) clears
    // the SQLite-side handler *before* freeing the box.
    let state = unsafe { &*(user_data as *const WalHookState) };

    // SAFETY: SQLite passes a valid null-terminated C string here.
    let db_name_str = if db_name.is_null() {
        ""
    } else {
        unsafe { CStr::from_ptr(db_name) }.to_str().unwrap_or("")
    };

    // SAFETY: see `send_wal_to_pid`. All data is copied into a fresh
    // msg_env; we never retain references across the call.
    unsafe {
        send_wal_to_pid(&state.pid, db_name_str, pages);
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

/// Install a WAL hook on the given connection.
///
/// Callers must hold the connection Mutex — the FFI
/// `sqlite3_wal_hook` mutates connection state.
pub(crate) fn install(
    conn: &Connection,
    slot: &AtomicPtr<WalHookState>,
    state: WalHookState,
) -> Result<(), XqliteError> {
    hook_util::install_hook(slot, state, |new_ptr| {
        // SAFETY: caller holds the connection Mutex. sqlite3_wal_hook
        // returns the previous user_data pointer (or NULL); we ignore
        // it because our atomic slot already tracks ownership, and
        // freeing it twice would be a double-free.
        unsafe {
            ffi::sqlite3_wal_hook(
                conn.handle(),
                Some(wal_hook_callback),
                new_ptr as *mut c_void,
            );
        }
        Ok(())
    })
}

/// Remove the WAL hook from the given connection.
///
/// Safe to call when no hook is installed.
pub(crate) fn uninstall(
    conn: &Connection,
    slot: &AtomicPtr<WalHookState>,
) -> Result<(), XqliteError> {
    hook_util::uninstall_hook(slot, || {
        // SAFETY: caller holds the connection Mutex. Passing
        // None+null clears any registered handler.
        unsafe {
            ffi::sqlite3_wal_hook(conn.handle(), None, std::ptr::null_mut());
        }
        Ok(())
    })
}

impl WalHookState {
    pub(crate) fn new(pid: LocalPid) -> Self {
        Self { pid }
    }
}
