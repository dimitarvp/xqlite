use crate::error::XqliteError;
use crate::hook_util;
use rusqlite::hooks::Action;
use rustler::sys::{
    enif_alloc_env, enif_free_env, enif_make_int64, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;

/// Send `{:xqlite_update, action, db_name, table, rowid}` to `pid`
/// using raw `enif_send` — no thread spawn needed.
///
/// # Safety
///
/// Since OTP 26.1, `enif_send` with NULL `caller_env` is valid from
/// scheduler threads. We target OTP 26+. All data is copied into
/// `msg_env` before send; the `&str` borrows are not held past this call.
unsafe fn send_update_to_pid(
    pid: &LocalPid,
    action_name: &[u8],
    db_name: &str,
    table_name: &str,
    rowid: i64,
) {
    // SAFETY: all enif_* calls operate on a freshly allocated msg_env.
    // enif_send with NULL caller_env is valid from any thread since OTP 26.1.
    // After enif_send, msg_env is invalidated but still allocated — freed below.
    unsafe {
        let msg_env = enif_alloc_env();

        let tag = hook_util::make_atom(msg_env, b"xqlite_update");
        let action = hook_util::make_atom(msg_env, action_name);
        let db = hook_util::make_binary(msg_env, db_name.as_bytes());
        let table = hook_util::make_binary(msg_env, table_name.as_bytes());
        let rid = enif_make_int64(msg_env, rowid);

        let elements = [tag, action, db, table, rid];
        let msg = enif_make_tuple_from_array(msg_env, elements.as_ptr(), 5);

        let _res = enif_send(std::ptr::null_mut(), pid.as_c_arg(), msg_env, msg);

        enif_free_env(msg_env);
    }
}

/// Install an update hook on the given connection.
///
/// The hook sends `{:xqlite_update, action, db_name, table, rowid}` to `pid`
/// for every INSERT, UPDATE, or DELETE on this connection.
pub(crate) fn set(conn: &rusqlite::Connection, pid: LocalPid) -> Result<(), XqliteError> {
    conn.update_hook(Some(
        move |action: Action, db: &str, table: &str, rowid: i64| {
            let action_name: &[u8] = match action {
                Action::SQLITE_INSERT => b"insert",
                Action::SQLITE_UPDATE => b"update",
                Action::SQLITE_DELETE => b"delete",
                _ => b"unknown",
            };

            // SAFETY: see send_update_to_pid doc comment.
            unsafe {
                send_update_to_pid(&pid, action_name, db, table, rowid);
            }
        },
    ))?;
    Ok(())
}

/// Remove the update hook from the given connection.
pub(crate) fn remove(conn: &rusqlite::Connection) -> Result<(), XqliteError> {
    conn.update_hook(None::<fn(Action, &str, &str, i64)>)?;
    Ok(())
}
