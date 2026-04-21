use crate::error::XqliteError;
use crate::hook_util;
use rustler::sys::{enif_alloc_env, enif_free_env, enif_make_tuple_from_array, enif_send};
use rustler::types::LocalPid;

/// Send `{:xqlite_commit}` to `pid`.
///
/// # Safety
///
/// See `busy_handler::send_busy_to_pid` for the OTP 26.1 NULL-env
/// invariant.
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

/// Install a commit hook on the given connection.
///
/// The hook sends `{:xqlite_commit}` to `pid` immediately before each
/// commit. It never vetoes the commit (always returns `false`).
///
/// SQLite allows the commit hook to abort the transaction by having
/// the callback return non-zero. We deliberately do not expose that:
/// the hook is observation-only. Use triggers or `CHECK` constraints
/// at the schema level if you need synchronous veto semantics.
pub(crate) fn set(conn: &rusqlite::Connection, pid: LocalPid) -> Result<(), XqliteError> {
    conn.commit_hook(Some(move || {
        // SAFETY: see send_commit_to_pid.
        unsafe {
            send_commit_to_pid(&pid);
        }
        false // never veto
    }))?;
    Ok(())
}

/// Remove the commit hook from the given connection.
pub(crate) fn remove(conn: &rusqlite::Connection) -> Result<(), XqliteError> {
    conn.commit_hook(None::<fn() -> bool>)?;
    Ok(())
}
