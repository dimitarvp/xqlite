//! Multi-subscriber global log hook.
//!
//! SQLite's logging is configured process-wide via `sqlite3_config`. We
//! install a single master callback once (lazily on first register, kept
//! installed thereafter) that walks a `static HookList<LogSubscriber>`
//! and fans events out to every subscriber.

use crate::hook_util::{self, HookList};
use rusqlite::trace;
use rustler::sys::{
    enif_alloc_env, enif_free_env, enif_make_int64, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;
use std::ffi::c_int;
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
/// Serialises `sqlite3_config` calls — that API is itself not
/// thread-safe.
static MASTER_LOCK: Mutex<()> = Mutex::new(());

/// SQLite log callback. Fan-out to all registered subscribers.
fn log_callback(err_code: c_int, msg: &str) {
    // SAFETY: LOG_SUBSCRIBERS is 'static; snapshot iteration is
    // wait-free. The HookList outlives every callback.
    unsafe {
        LOG_SUBSCRIBERS.for_each_snapshot(|entry| {
            send_log_to_pid(&entry.state.pid, err_code, msg);
        });
    }
}

/// # Safety
///
/// See `busy_handler::send_busy_to_pid`.
unsafe fn send_log_to_pid(pid: &LocalPid, err_code: c_int, msg: &str) {
    unsafe {
        let msg_env = enif_alloc_env();

        let tag = hook_util::make_atom(msg_env, b"xqlite_log");
        let code = enif_make_int64(msg_env, i64::from(err_code));
        let message = hook_util::make_binary(msg_env, msg.as_bytes());

        let elements = [tag, code, message];
        let tuple = enif_make_tuple_from_array(msg_env, elements.as_ptr(), 3);

        let _res = enif_send(std::ptr::null_mut(), pid.as_c_arg(), msg_env, tuple);

        enif_free_env(msg_env);
    }
}

/// Add a log subscriber. Installs the master callback on first
/// register; subsequent registers only modify the HookList.
pub(crate) fn register(pid: LocalPid) -> Result<u64, String> {
    let _guard = MASTER_LOCK.lock().map_err(|e| format!("lock error: {e}"))?;

    if !MASTER_INSTALLED.load(Ordering::Acquire) {
        // SAFETY: we hold MASTER_LOCK, so no concurrent config_log.
        // The callback never invokes SQLite (it only sends Erlang
        // messages via raw enif_send).
        unsafe {
            trace::config_log(Some(log_callback))
                .map_err(|e| format!("sqlite3_config failed: {e}"))?;
        }
        MASTER_INSTALLED.store(true, Ordering::Release);
    }

    Ok(LOG_SUBSCRIBERS.register(LogSubscriber::new(pid)))
}

/// Remove a log subscriber by handle. Idempotent. The master callback
/// stays installed even when the subscriber list empties — re-registering
/// later is cheap.
pub(crate) fn unregister(id: u64) -> Result<(), String> {
    let _guard = MASTER_LOCK.lock().map_err(|e| format!("lock error: {e}"))?;
    let _ = LOG_SUBSCRIBERS.unregister(id);
    Ok(())
}
