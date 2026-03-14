use rusqlite::trace;
use rustler::sys::{
    ERL_NIF_TERM, ErlNifEnv, enif_alloc_env, enif_free_env, enif_make_atom_len,
    enif_make_int64, enif_make_new_binary, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;
use std::ffi::c_int;
use std::sync::Mutex;

static LOG_HOOK_PID: Mutex<Option<LocalPid>> = Mutex::new(None);

/// The callback passed to `rusqlite::trace::config_log`.
///
/// Fires on any thread that triggers a SQLite diagnostic. Sends
/// `{:xqlite_log, error_code, message}` to the registered PID
/// using raw `enif_send` — no thread spawn needed.
fn log_callback(err_code: c_int, msg: &str) {
    let pid = {
        let guard = match LOG_HOOK_PID.lock() {
            Ok(g) => g,
            Err(_) => return,
        };
        match guard.as_ref() {
            Some(pid) => *pid,
            None => return,
        }
    };

    // SAFETY: enif_send with NULL caller_env is valid from any thread
    // since OTP 26.1. All data is copied into msg_env before send.
    unsafe {
        let msg_env = enif_alloc_env();

        let tag = make_atom(msg_env, b"xqlite_log");
        let code = enif_make_int64(msg_env, i64::from(err_code));
        let message = make_binary(msg_env, msg.as_bytes());

        let elements = [tag, code, message];
        let tuple = enif_make_tuple_from_array(msg_env, elements.as_ptr(), 3);

        let _res = enif_send(std::ptr::null_mut(), pid.as_c_arg(), msg_env, tuple);

        enif_free_env(msg_env);
    }
}

#[inline]
unsafe fn make_atom(env: *mut ErlNifEnv, name: &[u8]) -> ERL_NIF_TERM {
    // SAFETY: env is a valid NIF environment, name is a valid byte slice.
    unsafe { enif_make_atom_len(env, name.as_ptr().cast(), name.len()) }
}

#[inline]
unsafe fn make_binary(env: *mut ErlNifEnv, data: &[u8]) -> ERL_NIF_TERM {
    // SAFETY: env is valid, enif_make_new_binary returns a buffer of exactly data.len() bytes.
    unsafe {
        let mut term: ERL_NIF_TERM = 0;
        let buf = enif_make_new_binary(env, data.len(), &mut term);
        std::ptr::copy_nonoverlapping(data.as_ptr(), buf, data.len());
        term
    }
}

/// Register a PID to receive log events and install the global callback.
pub(crate) fn set_log_hook(pid: LocalPid) -> Result<(), String> {
    let mut guard = LOG_HOOK_PID
        .lock()
        .map_err(|e| format!("lock error: {e}"))?;
    *guard = Some(pid);

    // SAFETY: no concurrent `config_log` calls (we hold the mutex).
    // The callback must not invoke SQLite calls (it doesn't — it only
    // sends an Erlang message via raw enif_send).
    unsafe {
        trace::config_log(Some(log_callback))
            .map_err(|e| format!("sqlite3_config failed: {e}"))?;
    }
    Ok(())
}

/// Unregister the log hook.
pub(crate) fn remove_log_hook() -> Result<(), String> {
    let mut guard = LOG_HOOK_PID
        .lock()
        .map_err(|e| format!("lock error: {e}"))?;
    *guard = None;

    // SAFETY: same as above.
    unsafe {
        trace::config_log(None).map_err(|e| format!("sqlite3_config failed: {e}"))?;
    }
    Ok(())
}
