//! Multi-subscriber global log hook.
//!
//! SQLite's logging is configured process-wide via `sqlite3_config`. We
//! install a single master callback once (lazily on first register, kept
//! installed thereafter) that walks a `static HookList<LogSubscriber>`
//! and fans events out to every subscriber.

use crate::error::XqliteError;
use crate::hook_util::{self, HookList};
use rusqlite::ffi;
use rustler::sys::{
    enif_alloc_env, enif_free_env, enif_make_int64, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;
use std::ffi::{c_char, c_int, c_void};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Clone)]
pub(crate) struct LogSubscriber {
    pub(crate) pid: LocalPid,
}

impl std::fmt::Debug for LogSubscriber {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LogSubscriber").finish()
    }
}

impl LogSubscriber {
    pub(crate) fn new(pid: LocalPid) -> Self {
        Self { pid }
    }
}

static LOG_SUBSCRIBERS: HookList<LogSubscriber> = HookList::new();
static MASTER_INSTALLED: AtomicBool = AtomicBool::new(false);
/// Guards the log callback's one install and the subscriber list (see `fan_out`).
static MASTER_LOCK: Mutex<()> = Mutex::new(());

/// SQLite log callback. Fan-out to all registered subscribers.
///
/// # Safety
///
/// SQLite calls it with `msg` a NUL-terminated string that lives for the call.
unsafe extern "C" fn log_callback(_arg: *mut c_void, err_code: c_int, msg: *const c_char) {
    hook_util::guard_ffi_callback("log_callback", 0, move || {
        // SAFETY: `msg` is valid for this call (fn contract).
        let bytes = unsafe { hook_util::c_bytes(msg) }.unwrap_or_default();
        fan_out(err_code, bytes);
        0
    });
}

fn fan_out(err_code: c_int, msg: &[u8]) {
    // Hold MASTER_LOCK while reading the subscriber list. This hook is
    // PROCESS-GLOBAL (installed via sqlite3_config) and fires from any thread
    // with no connection Mutex held, so — unlike the per-connection hooks —
    // nothing else serialises this read against register/unregister, which
    // free the old subscriber Vec under this same lock. Without it the
    // lock-free read races the free: use-after-free. A plain Mutex (not
    // RwLock) is deliberate — log events are rare, so serialising them costs
    // nothing that matters, and a caller that floods registrations only slows
    // its own log delivery. Ordering is safe: register/unregister take only
    // MASTER_LOCK, so no thread holds it and then waits on a connection Mutex.
    let _guard = match MASTER_LOCK.lock() {
        Ok(g) => g,
        Err(poisoned) => poisoned.into_inner(),
    };
    // SAFETY: LOG_SUBSCRIBERS is 'static; MASTER_LOCK now serialises this
    // snapshot read against the writers that free the list.
    unsafe {
        LOG_SUBSCRIBERS.for_each_snapshot(|entry| {
            send_log_to_pid(&entry.state.pid, err_code, msg);
        });
    }
}

/// # Safety
///
/// See `busy_handler::send_busy_to_pid`.
unsafe fn send_log_to_pid(pid: &LocalPid, err_code: c_int, msg: &[u8]) {
    // SAFETY: every enif_* call operates on a freshly allocated msg_env and no
    // references are retained across the send (see `send_busy_to_pid`).
    unsafe {
        let msg_env = enif_alloc_env();

        let tag = hook_util::make_atom(msg_env, b"xqlite_log");
        let code = enif_make_int64(msg_env, i64::from(err_code));
        let message = hook_util::make_binary(msg_env, msg);

        let elements = [tag, code, message];
        let tuple = enif_make_tuple_from_array(msg_env, elements.as_ptr(), 3);

        let _res = enif_send(std::ptr::null_mut(), pid.as_c_arg(), msg_env, tuple);

        enif_free_env(msg_env);
    }
}

/// Add a log subscriber. Installs the master callback on first
/// register; subsequent registers only modify the HookList.
pub(crate) fn register(pid: LocalPid) -> Result<u64, XqliteError> {
    let _guard = MASTER_LOCK
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;

    if !MASTER_INSTALLED.load(Ordering::Acquire) {
        // SAFETY: SQLite 3.53.2 takes SQLITE_CONFIG_LOG at any time, as two word stores
        // that `sqlite3_log` reads on any thread without a lock; MASTER_INSTALLED makes this
        // the one install, from no callback to ours with a NULL argument, so a reader sees
        // none or ours. The callback calls no SQLite function; it only sends Erlang messages.
        let rc = unsafe {
            ffi::sqlite3_config(
                ffi::SQLITE_CONFIG_LOG,
                log_callback as unsafe extern "C" fn(_, _, _),
                std::ptr::null_mut::<c_void>(),
            )
        };
        if rc != ffi::SQLITE_OK {
            return Err(rusqlite::Error::SqliteFailure(ffi::Error::new(rc), None).into());
        }
        MASTER_INSTALLED.store(true, Ordering::Release);
    }

    Ok(LOG_SUBSCRIBERS.register(LogSubscriber::new(pid)))
}

/// Remove a log subscriber by handle. Idempotent. The master callback
/// stays installed even when the subscriber list empties — re-registering
/// later is cheap.
pub(crate) fn unregister(id: u64) -> Result<(), XqliteError> {
    let _guard = MASTER_LOCK
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    let _ = LOG_SUBSCRIBERS.unregister(id);
    Ok(())
}
