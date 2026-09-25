use crate::atoms;
use crate::authorizer;
use crate::blob::{self, XqliteBlob};
use crate::busy_handler;
use crate::cancel::{ProgressHandlerGuard, XqliteCancelToken, cancel_if_signalled};
use crate::connection::{self, ChildHandle, XqliteConn, XqliteQueryResult};
use crate::error::XqliteError;
use crate::explain_analyze::{self, ExplainAnalyze};
use crate::pragma;
use crate::query;
use crate::schema::{
    ColumnInfo, DatabaseInfo, ForeignKeyInfo, IndexColumnInfo, IndexInfo, SchemaObjectInfo,
};
use crate::session::{self, XqliteSession};
use crate::statement::{self, XqliteStatement};
use crate::stream::{XqliteStream, finalize_stream_stmt_locked};
use crate::transaction;
use crate::util::{MaybeTextArg, NameOrAll, TextArg, singular_ok_or_error_tuple};
use rusqlite::Connection;
use rusqlite::ffi;
use rusqlite::session::{ConflictAction, ConflictType};
use rustler::{
    Encoder, Env, ResourceArc, Term,
    types::{
        atom::{error, ok},
        map::map_new,
    },
};
use std::io::Cursor;
use std::ptr::null_mut;
use std::sync::Arc;
use std::sync::atomic::{AtomicPtr, Ordering};

#[rustler::nif(schedule = "DirtyIo")]
fn open(path: TextArg) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let result = Connection::open(path.as_str());
    connection::handle_open_result(result, path.into_string())
}

#[rustler::nif(schedule = "DirtyIo")]
fn open_in_memory(uri: TextArg) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let flags = match uri.as_str() {
        ":memory:" => rusqlite::OpenFlags::default(),
        _ => rusqlite::OpenFlags::default() | rusqlite::OpenFlags::SQLITE_OPEN_MEMORY,
    };
    let result = Connection::open_with_flags(uri.as_str(), flags);
    connection::handle_open_result(result, uri.into_string())
}

#[rustler::nif(schedule = "DirtyIo")]
fn open_readonly(path: TextArg) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
        | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
        | rusqlite::OpenFlags::SQLITE_OPEN_URI;
    let result = Connection::open_with_flags(path.as_str(), flags).and_then(keep_read_only);
    connection::handle_open_result(result, path.into_string())
}

#[rustler::nif(schedule = "DirtyIo")]
fn open_in_memory_readonly(uri: TextArg) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
        | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
        | rusqlite::OpenFlags::SQLITE_OPEN_MEMORY
        | rusqlite::OpenFlags::SQLITE_OPEN_URI;
    let result = Connection::open_with_flags(uri.as_str(), flags).and_then(keep_read_only);
    connection::handle_open_result(result, uri.into_string())
}

/// Sets `query_only` on a read-only open whose main database SQLite still
/// reports writable: a shared cache another connection opened read-write, or a
/// URI whose `mode=memory` replaced the read-only flag. A private read-only
/// connection keeps its TEMP tables.
fn keep_read_only(conn: Connection) -> rusqlite::Result<Connection> {
    match conn.is_readonly(rusqlite::MAIN_DB)? {
        true => Ok(conn),
        false => conn.pragma_update(None, "query_only", 1).map(|()| conn),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn open_temporary() -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let result = Connection::open("");
    connection::handle_open_result(result, "".to_string())
}

#[rustler::nif(schedule = "DirtyIo")]
fn close(env: Env<'_>, handle: ResourceArc<XqliteConn>) -> Term<'_> {
    let result = connection::close_connection(&handle);
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn db_path(handle: ResourceArc<XqliteConn>) -> Result<Option<String>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        // SQLite reports an empty filename for in-memory and temporary
        // databases; normalize that to None so Elixir sees nil.
        Ok(conn.path().filter(|p| !p.is_empty()).map(String::from))
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn query<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: TextArg,
    params_term: Term<'a>,
) -> Result<XqliteQueryResult<'a>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        query::core_query(env, conn, &sql, params_term)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: TextArg,
    params_term: Term<'a>,
) -> Result<u64, XqliteError> {
    connection::with_conn(&handle, |conn| {
        query::core_execute(env, conn, &sql, params_term)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute_batch(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    sql_batch: TextArg,
) -> Term<'_> {
    let execution_result =
        connection::with_conn(&handle, |conn| query::core_execute_batch(conn, &sql_batch));
    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn query_with_changes<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: TextArg,
    params_term: Term<'a>,
) -> Term<'a> {
    let result = connection::with_conn(&handle, |conn| {
        query::core_query_with_changes(env, conn, &sql, params_term)
    });

    match result {
        Ok((qr, changes)) => encode_query_result_with_changes(env, &qr, changes),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn query_with_changes_cancellable<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: TextArg,
    params_term: Term<'a>,
    tokens_term: Term<'a>,
) -> Term<'a> {
    let token_bools = match crate::cancel::decode_tokens(tokens_term) {
        Ok(flags) => flags,
        Err(e) => return (error(), e).encode(env),
    };
    let result = connection::with_conn(&handle, |conn| {
        cancel_if_signalled(&token_bools)?;
        let _guard =
            ProgressHandlerGuard::new(&handle.progress_dispatch, null_mut(), token_bools);
        query::core_query_with_changes(env, conn, &sql, params_term)
    });

    match result {
        Ok((qr, changes)) => encode_query_result_with_changes(env, &qr, changes),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn query_cancellable<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: TextArg,
    params_term: Term<'a>,
    tokens_term: Term<'a>,
) -> Result<XqliteQueryResult<'a>, XqliteError> {
    let token_bools = crate::cancel::decode_tokens(tokens_term)?;
    connection::with_conn(&handle, |conn| {
        cancel_if_signalled(&token_bools)?;
        let _guard =
            ProgressHandlerGuard::new(&handle.progress_dispatch, null_mut(), token_bools);
        query::core_query(env, conn, &sql, params_term)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute_cancellable<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: TextArg,
    params_term: Term<'a>,
    tokens_term: Term<'a>,
) -> Result<u64, XqliteError> {
    let token_bools = crate::cancel::decode_tokens(tokens_term)?;
    connection::with_conn(&handle, |conn| {
        cancel_if_signalled(&token_bools)?;
        let _guard =
            ProgressHandlerGuard::new(&handle.progress_dispatch, null_mut(), token_bools);
        query::core_execute(env, conn, &sql, params_term)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute_batch_cancellable<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql_batch: TextArg,
    tokens_term: Term<'a>,
) -> Term<'a> {
    let token_bools = match crate::cancel::decode_tokens(tokens_term) {
        Ok(flags) => flags,
        Err(e) => return (error(), e).encode(env),
    };
    let execution_result = connection::with_conn(&handle, |conn| {
        cancel_if_signalled(&token_bools)?;
        let _guard =
            ProgressHandlerGuard::new(&handle.progress_dispatch, null_mut(), token_bools);
        query::core_execute_batch(conn, &sql_batch)
    });
    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn explain_analyze<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: TextArg,
    params_term: Term<'a>,
) -> Result<ExplainAnalyze, XqliteError> {
    connection::with_conn(&handle, |conn| {
        explain_analyze::core_explain_analyze(env, conn, &sql, params_term)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn autocommit(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    connection::with_conn(&handle, |conn| Ok(conn.is_autocommit()))
}

#[rustler::nif(schedule = "DirtyIo")]
fn get_limit(
    handle: ResourceArc<XqliteConn>,
    category: rustler::Atom,
) -> Result<std::os::raw::c_int, XqliteError> {
    connection::with_conn(&handle, |conn| crate::limits::read(conn, category))
}

#[rustler::nif(schedule = "DirtyIo")]
fn put_limit(
    handle: ResourceArc<XqliteConn>,
    category: rustler::Atom,
    value: i64,
) -> Result<std::os::raw::c_int, XqliteError> {
    connection::with_conn(&handle, |conn| crate::limits::write(conn, category, value))
}

#[rustler::nif(schedule = "DirtyIo")]
fn txn_state<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    schema: NameOrAll,
) -> Result<Term<'a>, XqliteError> {
    let state = connection::with_conn(&handle, |conn| match schema.as_deref() {
        Some(name) => crate::schema::require_schema(conn, name),
        // SAFETY: with_conn holds the connection Mutex, so `handle()` is the
        // live `sqlite3*`; a NULL name asks for the highest state over every
        // attached database.
        None => Ok(unsafe { ffi::sqlite3_txn_state(conn.handle(), std::ptr::null()) }),
    })?;

    let atom = match state {
        ffi::SQLITE_TXN_NONE => atoms::none(),
        ffi::SQLITE_TXN_READ => atoms::read(),
        ffi::SQLITE_TXN_WRITE => atoms::write(),
        _ => atoms::unknown(),
    };

    Ok(atom.encode(env))
}

#[rustler::nif(schedule = "DirtyIo")]
fn set_busy_policy(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    max_retries: u32,
    max_elapsed_ms: u64,
    sleep_ms: u64,
) -> Term<'_> {
    let policy = busy_handler::BusyPolicy {
        max_retries,
        max_elapsed_ms,
        sleep_ms,
    };
    let result = connection::with_conn(&handle, |conn| {
        busy_handler::set_policy(conn, &handle, policy)
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn remove_busy_policy(env: Env<'_>, handle: ResourceArc<XqliteConn>) -> Term<'_> {
    let result =
        connection::with_conn(&handle, |conn| busy_handler::remove_policy(conn, &handle));
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn register_busy_observer(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    pid: rustler::LocalPid,
) -> Term<'_> {
    let result = connection::with_conn(&handle, |conn| {
        busy_handler::register_observer(conn, &handle, pid)
    });
    match result {
        Ok(id) => (ok(), id).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn unregister_busy_observer(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    observer_handle: u64,
) -> Term<'_> {
    let result = connection::with_conn(&handle, |conn| {
        busy_handler::unregister_observer(conn, &handle, observer_handle)
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn set_busy_timeout(env: Env<'_>, handle: ResourceArc<XqliteConn>, ms: u64) -> Term<'_> {
    let result =
        connection::with_conn(&handle, |conn| busy_handler::set_timeout(conn, &handle, ms));
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn set_authorizer<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    denied_actions: Term<'a>,
) -> Term<'a> {
    // Validate the whole list before touching the connection, so an
    // unrecognized atom installs nothing.
    let denied = match authorizer::parse_denied(denied_actions) {
        Ok(set) => set,
        Err(e) => return (error(), e).encode(env),
    };
    let result = connection::with_conn(&handle, |conn| authorizer::set(conn, &handle, denied));
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn remove_authorizer(env: Env<'_>, handle: ResourceArc<XqliteConn>) -> Term<'_> {
    let result = connection::with_conn(&handle, |conn| authorizer::remove(conn, &handle));
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn wal_checkpoint<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    mode: rustler::Atom,
    schema: TextArg,
) -> Result<Term<'a>, XqliteError> {
    let mode_int = match () {
        _ if mode == atoms::passive() => ffi::SQLITE_CHECKPOINT_PASSIVE,
        _ if mode == atoms::full() => ffi::SQLITE_CHECKPOINT_FULL,
        _ if mode == atoms::restart() => ffi::SQLITE_CHECKPOINT_RESTART,
        _ if mode == atoms::truncate() => ffi::SQLITE_CHECKPOINT_TRUNCATE,
        _ => return Err(XqliteError::InvalidCheckpointMode { mode }),
    };

    connection::with_conn(&handle, |conn| {
        crate::schema::require_schema(conn, &schema)?;
        let c_schema = std::ffi::CString::new(schema.as_str())
            .map_err(|_| XqliteError::NulErrorInString)?;
        // SAFETY: with_conn holds the connection Mutex. db handle is
        // valid for the duration of the closure. zDb is a valid
        // NUL-terminated string whose lifetime spans the FFI call.
        unsafe {
            let db = conn.handle();
            let mut log_pages: std::os::raw::c_int = 0;
            let mut ckpt_pages: std::os::raw::c_int = 0;
            let rc = ffi::sqlite3_wal_checkpoint_v2(
                db,
                c_schema.as_ptr(),
                mode_int,
                &mut log_pages,
                &mut ckpt_pages,
            );

            // SQLite leaves both counts at -1 for a database whose WAL it did
            // not checkpoint: one not in WAL mode as this connection sees it
            // (SQLITE_OK), or one whose checkpoint lock another connection
            // holds (SQLITE_BUSY).
            let counts_unwritten = log_pages == -1 && ckpt_pages == -1;

            match rc {
                ffi::SQLITE_OK if counts_unwritten => Err(XqliteError::NotInWalMode),
                ffi::SQLITE_OK | ffi::SQLITE_BUSY if !counts_unwritten => map_new(env)
                    .map_put(atoms::log_pages(), log_pages as i64)
                    .and_then(|map| {
                        map.map_put(atoms::checkpointed_pages(), ckpt_pages as i64)
                    })
                    .and_then(|map| map.map_put(atoms::busy(), rc == ffi::SQLITE_BUSY))
                    .map_err(|_| XqliteError::InternalEncodingError {
                        context: "Failed map create for wal_checkpoint".to_string(),
                    }),
                _ => {
                    let ffi_err = ffi::Error::new(rc);
                    let err_msg_ptr = ffi::sqlite3_errmsg(db);
                    let message = if err_msg_ptr.is_null() {
                        format!("sqlite3_wal_checkpoint_v2 failed (code {rc})")
                    } else {
                        std::ffi::CStr::from_ptr(err_msg_ptr)
                            .to_string_lossy()
                            .into_owned()
                    };
                    Err(XqliteError::from(rusqlite::Error::SqliteFailure(
                        ffi_err,
                        Some(message),
                    )))
                }
            }
        }
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn connection_stats<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
) -> Result<Term<'a>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        // SAFETY: with_conn holds the connection Mutex; db handle valid
        // for the closure. Each `sqlite3_db_status64` call writes into
        // stack-local integers we own.
        unsafe {
            let db = conn.handle();

            let ops: &[(rustler::Atom, i32)] = &[
                (atoms::lookaside_used(), ffi::SQLITE_DBSTATUS_LOOKASIDE_USED),
                (atoms::cache_used(), ffi::SQLITE_DBSTATUS_CACHE_USED),
                (atoms::schema_used(), ffi::SQLITE_DBSTATUS_SCHEMA_USED),
                (atoms::stmt_used(), ffi::SQLITE_DBSTATUS_STMT_USED),
                (atoms::lookaside_hit(), ffi::SQLITE_DBSTATUS_LOOKASIDE_HIT),
                (
                    atoms::lookaside_miss_size(),
                    ffi::SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE,
                ),
                (
                    atoms::lookaside_miss_full(),
                    ffi::SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL,
                ),
                (atoms::cache_hit(), ffi::SQLITE_DBSTATUS_CACHE_HIT),
                (atoms::cache_miss(), ffi::SQLITE_DBSTATUS_CACHE_MISS),
                (atoms::cache_write(), ffi::SQLITE_DBSTATUS_CACHE_WRITE),
                (atoms::deferred_fks(), ffi::SQLITE_DBSTATUS_DEFERRED_FKS),
                (
                    atoms::cache_used_shared(),
                    ffi::SQLITE_DBSTATUS_CACHE_USED_SHARED,
                ),
                (atoms::cache_spill(), ffi::SQLITE_DBSTATUS_CACHE_SPILL),
                (atoms::tempbuf_spill(), ffi::SQLITE_DBSTATUS_TEMPBUF_SPILL),
            ];

            let mut map = map_new(env);
            for (atom, op) in ops {
                let mut current: i64 = 0;
                let mut highwater: i64 = 0;
                let rc = ffi::sqlite3_db_status64(db, *op, &mut current, &mut highwater, 0);

                if rc != ffi::SQLITE_OK {
                    return Err(XqliteError::SqliteFailure {
                        code: rc & 0xFF,
                        extended_code: rc,
                        message: None,
                    });
                }

                // SQLite defines only the high-water half of the three lookaside
                // counts, reporting current as 0, and DEFERRED_FKS is a 0/1 flag.
                let value = match *op {
                    ffi::SQLITE_DBSTATUS_LOOKASIDE_HIT
                    | ffi::SQLITE_DBSTATUS_LOOKASIDE_MISS_SIZE
                    | ffi::SQLITE_DBSTATUS_LOOKASIDE_MISS_FULL => highwater.encode(env),
                    ffi::SQLITE_DBSTATUS_DEFERRED_FKS => (current != 0).encode(env),
                    _ => current.encode(env),
                };

                map = map.map_put(atom.encode(env), value).map_err(|_| {
                    XqliteError::InternalEncodingError {
                        context: format!("connection_stats map_put for op {op} failed"),
                    }
                })?;
            }

            Ok(map)
        }
    })
}

#[rustler::nif]
fn create_cancel_token() -> Result<ResourceArc<XqliteCancelToken>, XqliteError> {
    Ok(ResourceArc::new(XqliteCancelToken::new()))
}

// Takes the term undecoded: a cancel token is a reference and so is every
// other resource handle, so only the resource decode can tell them apart, and
// a typed argument would raise instead of answering.
#[rustler::nif]
fn is_cancel_token(term: Term<'_>) -> bool {
    term.decode::<ResourceArc<XqliteCancelToken>>().is_ok()
}

#[rustler::nif]
fn cancel_operation(env: Env<'_>, token: ResourceArc<XqliteCancelToken>) -> Term<'_> {
    token.cancel();
    ok().encode(env)
}

#[rustler::nif(schedule = "DirtyIo")]
fn get_pragma<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    pragma_name: rustler::Binary<'a>,
) -> Result<Term<'a>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        // SQLite reads both as 0 while our own callback holds the slot the
        // setting belongs to: wal_autocheckpoint while the master WAL hook
        // emulates the autocheckpoint, busy_timeout while the busy slot is
        // held. Report the value the slot keeps instead.
        let name = pragma_name.as_slice();
        if name.eq_ignore_ascii_case(b"wal_autocheckpoint") {
            let pages = handle.wal_hook.autocheckpoint_pages.load(Ordering::Relaxed);
            Ok((pages as i64).encode(env))
        } else if name.eq_ignore_ascii_case(b"busy_timeout")
            && let Some(ms) = busy_handler::kept_timeout(&handle)
        {
            Ok(ms.encode(env))
        } else {
            pragma::get(env, conn, name)
        }
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn set_pragma<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    pragma_name: rustler::Binary<'a>,
    value_term: Term<'a>,
) -> Result<Term<'a>, XqliteError> {
    // SQLite reads a busy_timeout past c_int::MAX as 0 and drops the wait.
    if pragma_name.as_slice().eq_ignore_ascii_case(b"busy_timeout")
        && let Ok(ms) = value_term.decode::<u64>()
    {
        busy_handler::busy_timeout_c_int(ms)?;
    }

    connection::with_conn(&handle, |conn| {
        let result = pragma::set(env, conn, pragma_name.as_slice(), value_term)?;

        // `PRAGMA wal_autocheckpoint` installs SQLite's internal
        // autocheckpoint wal_hook, evicting our master callback from
        // the shared slot. Take the slot back and mirror the threshold
        // SQLite reports, so our callback both notifies subscribers and
        // emulates the autocheckpoint the caller just configured. Raw
        // SQL (`query`/`execute_batch` "PRAGMA ...") bypasses this
        // repair — documented limitation.
        if pragma_name
            .as_slice()
            .eq_ignore_ascii_case(b"wal_autocheckpoint")
        {
            if let Ok(pages) = result.decode::<i64>() {
                let clamped = pages.clamp(i32::MIN as i64, i32::MAX as i64) as i32;
                handle
                    .wal_hook
                    .autocheckpoint_pages
                    .store(clamped, Ordering::Relaxed);
            }
            // SAFETY: with_conn holds the connection Mutex for the
            // duration of this closure; the WalDispatch lives in the
            // same XqliteConn as `conn` (drop-order safe).
            unsafe { crate::wal_hook::install_callback(conn, &handle.wal_hook) };
        }

        Ok(result)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn begin(env: Env<'_>, handle: ResourceArc<XqliteConn>, mode: rustler::Atom) -> Term<'_> {
    let mode = match transaction::TransactionMode::from_atom(mode) {
        Ok(m) => m,
        Err(e) => return (error(), e).encode(env),
    };
    let execution_result =
        connection::with_conn(&handle, |conn| transaction::begin(conn, mode));
    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn commit(env: Env<'_>, handle: ResourceArc<XqliteConn>) -> Term<'_> {
    let execution_result = connection::with_conn(&handle, transaction::commit);
    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn rollback(env: Env<'_>, handle: ResourceArc<XqliteConn>) -> Term<'_> {
    let execution_result = connection::with_conn(&handle, transaction::rollback);
    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn savepoint(env: Env<'_>, handle: ResourceArc<XqliteConn>, name: TextArg) -> Term<'_> {
    let execution_result =
        connection::with_conn(&handle, |conn| transaction::savepoint(conn, &name));
    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn rollback_to_savepoint(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    name: TextArg,
) -> Term<'_> {
    let execution_result = connection::with_conn(&handle, |conn| {
        transaction::rollback_to_savepoint(conn, &name)
    });
    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn release_savepoint(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    name: TextArg,
) -> Term<'_> {
    let execution_result =
        connection::with_conn(&handle, |conn| transaction::release_savepoint(conn, &name));
    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn transaction_status(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    connection::with_conn(&handle, |conn| Ok(!conn.is_autocommit()))
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_databases(
    handle: ResourceArc<XqliteConn>,
) -> Result<Vec<DatabaseInfo>, XqliteError> {
    connection::with_conn(&handle, crate::schema::databases)
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_list_objects(
    handle: ResourceArc<XqliteConn>,
    schema: NameOrAll,
) -> Result<Vec<SchemaObjectInfo>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        crate::schema::list_objects(conn, schema.as_deref())
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_columns(
    handle: ResourceArc<XqliteConn>,
    table_name: TextArg,
) -> Result<Vec<ColumnInfo>, XqliteError> {
    connection::with_conn(&handle, |conn| crate::schema::columns(conn, &table_name))
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_foreign_keys(
    handle: ResourceArc<XqliteConn>,
    table_name: TextArg,
) -> Result<Vec<ForeignKeyInfo>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        crate::schema::foreign_keys(conn, &table_name)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_indexes(
    handle: ResourceArc<XqliteConn>,
    table_name: TextArg,
) -> Result<Vec<IndexInfo>, XqliteError> {
    connection::with_conn(&handle, |conn| crate::schema::indexes(conn, &table_name))
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_index_columns(
    handle: ResourceArc<XqliteConn>,
    index_name: TextArg,
) -> Result<Vec<IndexColumnInfo>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        crate::schema::index_columns(conn, &index_name)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn get_create_sql(
    handle: ResourceArc<XqliteConn>,
    object_name: TextArg,
) -> Result<Option<String>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        crate::schema::create_sql(conn, &object_name)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn last_insert_rowid(handle: ResourceArc<XqliteConn>) -> Result<i64, XqliteError> {
    connection::with_conn(&handle, |conn| Ok(conn.last_insert_rowid()))
}

#[rustler::nif(schedule = "DirtyIo")]
fn changes(handle: ResourceArc<XqliteConn>) -> Result<u64, XqliteError> {
    connection::with_conn(&handle, |conn| Ok(conn.changes()))
}

#[rustler::nif(schedule = "DirtyIo")]
fn total_changes(handle: ResourceArc<XqliteConn>) -> Result<u64, XqliteError> {
    connection::with_conn(&handle, |conn| Ok(conn.total_changes()))
}

#[rustler::nif(schedule = "DirtyIo")]
fn stmt_prepare(
    conn_handle: ResourceArc<XqliteConn>,
    sql: TextArg,
) -> Result<ResourceArc<XqliteStatement>, XqliteError> {
    let conn_resource_arc_clone = conn_handle.clone();

    connection::with_conn(&conn_handle, |conn| {
        // SAFETY: with_conn holds the connection mutex for the duration of
        // this closure. The raw statement is transferred into the
        // XqliteStatement's AtomicPtr on success, or finalized on every
        // error path before returning.
        unsafe {
            let db_handle = conn.handle();
            let non_null_raw_stmt = statement::prepare_one(db_handle, &sql)?;

            let column_count =
                ffi::sqlite3_column_count(non_null_raw_stmt.as_ptr()) as usize;
            let parameter_count = ffi::sqlite3_bind_parameter_count(non_null_raw_stmt.as_ptr())
                .max(0) as usize;
            let mut column_names = Vec::with_capacity(column_count);
            for i in 0..column_count {
                let name_ptr = ffi::sqlite3_column_name(
                    non_null_raw_stmt.as_ptr(),
                    i as std::os::raw::c_int,
                );
                if name_ptr.is_null() {
                    ffi::sqlite3_finalize(non_null_raw_stmt.as_ptr());
                    return Err(XqliteError::InternalEncodingError {
                        context: format!(
                            "SQLite returned null column name for index {i} during statement prepare"
                        ),
                    });
                }
                let name_c_str = std::ffi::CStr::from_ptr(name_ptr);
                column_names.push(name_c_str.to_string_lossy().into_owned());
            }

            let cell = Arc::new(AtomicPtr::new(non_null_raw_stmt.as_ptr()));
            let registration =
                conn_resource_arc_clone.register_child(ChildHandle::Stmt(Arc::clone(&cell)));
            if let Err(e) = registration {
                ffi::sqlite3_finalize(non_null_raw_stmt.as_ptr());
                return Err(e);
            }

            Ok(XqliteStatement::new(
                cell,
                conn_resource_arc_clone,
                column_names,
                parameter_count,
            ))
        }
    })
    .map(ResourceArc::new)
}

#[rustler::nif(schedule = "DirtyIo")]
fn stmt_bind<'a>(
    env: Env<'a>,
    stmt_handle: ResourceArc<XqliteStatement>,
    params_term: Term<'a>,
) -> Term<'a> {
    use crate::stream::{
        BindFailure, bind_named_params_ffi, bind_positional_params_ffi,
        require_parameter_count,
    };
    use crate::util::{Params, decode_exec_keyword_params, decode_plain_list_params};

    let result = stmt_handle.with_live_stmt(|stmt_ptr, db_handle| {
        // Each call below: with_live_stmt holds the connection Mutex for the
        // whole closure and proved stmt_ptr a live statement of it.
        // SAFETY: the lock and the statement, as stated above.
        let mid_run = unsafe { ffi::sqlite3_stmt_busy(stmt_ptr) } != 0;

        if mid_run && stmt_handle.takes_parameters() {
            return Err(XqliteError::StatementMidRun);
        }

        // SQLite refuses a bind on a statement whose run has ended, though its
        // next step would reset that statement unasked; resetting here lets
        // the bind land. The return code repeats the last step's error.
        if !mid_run {
            // SAFETY: the lock and the statement, as stated above.
            unsafe { ffi::sqlite3_reset(stmt_ptr) };
        }

        let bound = match crate::util::walk_params(params_term)? {
            // SAFETY: the lock and the statement, as stated above.
            Params::Empty => unsafe { require_parameter_count(stmt_ptr, 0) }
                .map_err(BindFailure::NothingBound),
            Params::Named(items) => {
                // SAFETY: the lock and the statement, as stated above.
                let count = unsafe { ffi::sqlite3_bind_parameter_count(stmt_ptr) };
                let named = decode_exec_keyword_params(env, &items, count.max(0) as usize)?;
                // SAFETY: the lock and the statement, as stated above.
                unsafe { bind_named_params_ffi(stmt_ptr, &named, db_handle) }
            }
            Params::Positional(items) => {
                let positional = decode_plain_list_params(env, &items)?;
                // SAFETY: the lock and the statement, as stated above.
                unsafe { bind_positional_params_ffi(stmt_ptr, &positional, db_handle) }
            }
        };

        // The flag moves under the same lock as the bind, so a step that took
        // the lock straight after a bind answered `:ok` never reads it unset.
        match bound {
            Ok(()) => {
                stmt_handle.mark_parameters_set();
                Ok(())
            }
            Err(BindFailure::NothingBound(e)) => Err(e),
            Err(BindFailure::PartlyBound(e)) => {
                stmt_handle.clear_parameters_set();
                Err(e)
            }
        }
    });

    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn stmt_step<'a>(env: Env<'a>, stmt_handle: ResourceArc<XqliteStatement>) -> Term<'a> {
    use crate::stream::process_single_step;

    let result = stmt_handle.with_live_stmt(|stmt_ptr, db_handle| {
        // Behind the liveness check the lock did: a finalized statement, and
        // one whose connection is closed, are answered as such whether or
        // not anything ever bound their parameters.
        stmt_handle.require_parameters_set()?;

        // An earlier batch read a row it could not decode after it had handed
        // back the rows it already had. Every door that reads a row answers
        // that error first and empties the slot; the statement itself carries
        // on at the row after the one SQLite stepped past.
        match stmt_handle.take_pending_error() {
            Some(pending) => Err(pending),
            // SAFETY: with_live_stmt holds the connection mutex and proved
            // stmt_ptr live.
            None => unsafe { process_single_step(env, stmt_ptr, db_handle) }
                .map_err(XqliteError::from),
        }
    });

    match result {
        Ok(Some(row_terms)) => (atoms::row(), row_terms).encode(env),
        Ok(None) => atoms::done().encode(env),
        Err(e) => (error(), e).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn stmt_multi_step<'a>(
    env: Env<'a>,
    stmt_handle: ResourceArc<XqliteStatement>,
    batch_size: i64,
) -> Term<'a> {
    stmt_multi_step_impl(env, stmt_handle, batch_size, Vec::new())
}

#[rustler::nif(schedule = "DirtyIo")]
fn stmt_multi_step_cancellable<'a>(
    env: Env<'a>,
    stmt_handle: ResourceArc<XqliteStatement>,
    batch_size: i64,
    tokens_term: Term<'a>,
) -> Term<'a> {
    match crate::cancel::decode_tokens(tokens_term) {
        Ok(token_bools) => stmt_multi_step_impl(env, stmt_handle, batch_size, token_bools),
        Err(e) => (error(), e).encode(env),
    }
}

fn stmt_multi_step_impl<'a>(
    env: Env<'a>,
    stmt_handle: ResourceArc<XqliteStatement>,
    batch_size: i64,
    token_bools: Vec<std::sync::Arc<std::sync::atomic::AtomicBool>>,
) -> Term<'a> {
    use crate::stream::{StepFailure, process_single_step};

    if batch_size < 1 {
        let details = map_new(env)
            .map_put(atoms::provided(), batch_size)
            .and_then(|m| m.map_put(atoms::minimum(), 1_usize));
        return match details {
            Ok(details_map) => {
                (error(), (atoms::invalid_batch_size(), details_map)).encode(env)
            }
            Err(_) => {
                let e = XqliteError::InternalEncodingError {
                    context: "Failed to create details map for InvalidBatchSize".to_string(),
                };
                (error(), e).encode(env)
            }
        };
    }

    let mut rows: Vec<Vec<Term<'a>>> = Vec::new();
    let mut done = false;

    let result = stmt_handle.with_live_stmt(|stmt_ptr, db_handle| {
        // Behind the liveness check the lock did, exactly as in `stmt_step`.
        stmt_handle.require_parameters_set()?;

        // An earlier batch ended on a row it could not decode after it had
        // handed back the rows it already had. Answer that error now and
        // empty the slot: the statement itself carries on at the row after
        // the one SQLite stepped past.
        if let Some(pending) = stmt_handle.take_pending_error() {
            return Err(pending);
        }

        // SAFETY: with_live_stmt holds the connection mutex and proved
        // stmt_ptr live.
        if unsafe { ffi::sqlite3_stmt_busy(stmt_ptr) } == 0 {
            cancel_if_signalled(&token_bools)?;
        }

        // with_live_stmt holds the connection Mutex, satisfying the guard's
        // contract.
        let _guard = ProgressHandlerGuard::new(
            &stmt_handle.conn_resource_arc.progress_dispatch,
            stmt_ptr,
            token_bools,
        );

        for _ in 0..batch_size {
            // SAFETY: with_live_stmt holds the connection mutex and proved
            // stmt_ptr live.
            match unsafe { process_single_step(env, stmt_ptr, db_handle) } {
                Ok(Some(row_terms)) => rows.push(row_terms),
                Ok(None) => {
                    done = true;
                    break;
                }
                // The step itself failed, so no row was stepped past and the run
                // is over, save a busy lock SQLite keeps for a retry: answer now
                // and discard the batch's rows, exactly as a cancellation does.
                Err(StepFailure::Failed(e)) => return Err(e),
                Err(StepFailure::Unreadable(e)) => {
                    // The row is lost either way. Hand back the rows this
                    // batch had already read and hold the error for the next
                    // call that reads a row — unless there are none, when it
                    // is answered now.
                    if rows.is_empty() {
                        return Err(e);
                    }

                    stmt_handle.store_pending_error(e);
                    break;
                }
            }
        }
        Ok(())
    });

    match result {
        Ok(()) => {
            let map = map_new(env)
                .map_put(atoms::rows(), &rows)
                .and_then(|m| m.map_put(atoms::done(), done));
            match map {
                Ok(result_map) => (ok(), result_map).encode(env),
                Err(_) => {
                    let e = XqliteError::InternalEncodingError {
                        context: "Failed to create result map for stmt_multi_step".to_string(),
                    };
                    (error(), e).encode(env)
                }
            }
        }
        Err(e) => (error(), e).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn stmt_reset(env: Env<'_>, stmt_handle: ResourceArc<XqliteStatement>) -> Term<'_> {
    let result = stmt_handle.with_live_stmt(|stmt_ptr, _db_handle| {
        // The statement starts from the top, so an error held back from an
        // earlier batch belongs to a run that is over.
        let _ = stmt_handle.take_pending_error();

        // SAFETY: with_live_stmt holds the connection mutex and proved
        // stmt_ptr live. sqlite3_reset's return code echoes the most recent
        // step error rather than reporting the reset itself — resetting a
        // stepped-to-error statement is legal — so it is deliberately not
        // treated as a failure here.
        unsafe { ffi::sqlite3_reset(stmt_ptr) };
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn stmt_clear_bindings(env: Env<'_>, stmt_handle: ResourceArc<XqliteStatement>) -> Term<'_> {
    let result = stmt_handle.with_live_stmt(|stmt_ptr, _db_handle| {
        // `sqlite3_clear_bindings` has no mid-run check where every
        // `sqlite3_bind_*` answers SQLITE_MISUSE, so a clear between two rows
        // releases the values in place and every row left in the run reads
        // NULL. The tell is read and answered under the same lock as the
        // clear, so the statement is in one state for both.
        //
        // SAFETY: with_live_stmt holds the connection mutex and proved
        // stmt_ptr live.
        let mid_run = unsafe { ffi::sqlite3_stmt_busy(stmt_ptr) } != 0;

        match mid_run && stmt_handle.takes_parameters() {
            true => Err(XqliteError::StatementMidRun),
            false => {
                // SAFETY: with_live_stmt holds the connection mutex and proved
                // stmt_ptr live. sqlite3_clear_bindings always returns
                // SQLITE_OK.
                unsafe { ffi::sqlite3_clear_bindings(stmt_ptr) };
                stmt_handle.mark_parameters_set();
                Ok(())
            }
        }
    });

    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn stmt_column_names(
    stmt_handle: ResourceArc<XqliteStatement>,
) -> Result<Vec<String>, XqliteError> {
    let live = stmt_handle.with_live_stmt(|stmt_ptr, _db_handle| {
        // SAFETY: with_live_stmt holds the connection mutex and proved
        // stmt_ptr live. Live reads reflect v2 auto-reprepare after schema
        // changes (e.g. SELECT * re-expansion), which the prepare-time
        // snapshot cannot.
        unsafe {
            let count = ffi::sqlite3_column_count(stmt_ptr) as usize;
            let mut names = Vec::with_capacity(count);
            for i in 0..count {
                let name_ptr = ffi::sqlite3_column_name(stmt_ptr, i as std::os::raw::c_int);
                if name_ptr.is_null() {
                    return Err(XqliteError::InternalEncodingError {
                        context: format!("SQLite returned null column name for index {i}"),
                    });
                }
                names.push(
                    std::ffi::CStr::from_ptr(name_ptr)
                        .to_string_lossy()
                        .into_owned(),
                );
            }
            Ok(names)
        }
    });

    match live {
        Ok(names) => Ok(names),
        // When live reading is impossible for lifecycle reasons — statement
        // finalized or connection closed — callers still get the
        // prepare-time snapshot.
        Err(XqliteError::StatementFinalized) | Err(XqliteError::ConnectionClosed) => {
            Ok(stmt_handle.column_names.clone())
        }
        Err(e) => Err(e),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn stmt_finalize(env: Env<'_>, stmt_handle: ResourceArc<XqliteStatement>) -> Term<'_> {
    singular_ok_or_error_tuple(env, stmt_handle.take_and_finalize())
}

/// Binds a stream's parameters onto a statement that is already prepared.
///
/// # Safety
///
/// The caller holds the connection Mutex for the whole call, `stmt_ptr` is a
/// live prepared statement of that connection and `db_handle` is the
/// `sqlite3*` that owns it.
unsafe fn bind_stream_params<'a>(
    env: Env<'a>,
    stmt_ptr: *mut ffi::sqlite3_stmt,
    db_handle: *mut ffi::sqlite3,
    params_term: Term<'a>,
) -> Result<(), XqliteError> {
    use crate::stream::{
        bind_named_params_ffi, bind_positional_params_ffi, require_parameter_count,
    };
    use crate::util::{Params, decode_exec_keyword_params, decode_plain_list_params};

    match crate::util::walk_params(params_term)? {
        // SAFETY: forwarded from this function's own contract.
        Params::Empty => unsafe { require_parameter_count(stmt_ptr, 0) },
        Params::Named(items) => {
            // SAFETY: forwarded from this function's own contract.
            let count = unsafe { ffi::sqlite3_bind_parameter_count(stmt_ptr) };
            let named_params_vec =
                decode_exec_keyword_params(env, &items, count.max(0) as usize)?;
            // SAFETY: forwarded from this function's own contract.
            unsafe { bind_named_params_ffi(stmt_ptr, &named_params_vec, db_handle) }
                .map_err(crate::stream::BindFailure::into_error)
        }
        Params::Positional(items) => {
            let positional_params_vec = decode_plain_list_params(env, &items)?;
            // SAFETY: forwarded from this function's own contract.
            unsafe { bind_positional_params_ffi(stmt_ptr, &positional_params_vec, db_handle) }
                .map_err(crate::stream::BindFailure::into_error)
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn stream_open<'a>(
    env: Env<'a>,
    conn_handle: ResourceArc<XqliteConn>,
    sql: TextArg,
    params_term: Term<'a>,
) -> Result<ResourceArc<XqliteStream>, XqliteError> {
    use crate::statement::PreparedStmt;

    let conn_resource_arc_clone = conn_handle.clone();

    connection::with_conn(&conn_handle, |conn| {
        // SAFETY: with_conn holds the connection mutex for the duration of
        // this closure. All FFI calls below operate on the db_handle and
        // the statement prepare_one returned, both owned by this connection.
        // The statement is owned by a holder that finalizes it on every path
        // out of this closure, until the stream takes it over.
        unsafe {
            let db_handle = conn.handle();
            let held = PreparedStmt::new(statement::prepare_one(db_handle, &sql)?);

            bind_stream_params(env, held.as_ptr(), db_handle, params_term)?;

            let column_count = ffi::sqlite3_column_count(held.as_ptr()) as usize;
            let mut column_names = Vec::with_capacity(column_count);

            for i in 0..column_count {
                let name_ptr =
                    ffi::sqlite3_column_name(held.as_ptr(), i as std::os::raw::c_int);
                if name_ptr.is_null() {
                    return Err(XqliteError::InternalEncodingError {
                        context: format!(
                            "SQLite returned null column name for index {i} during stream open"
                        ),
                    });
                }
                let name_c_str = std::ffi::CStr::from_ptr(name_ptr);
                column_names.push(name_c_str.to_string_lossy().into_owned());
            }

            let cell = Arc::new(AtomicPtr::new(held.as_ptr()));
            conn_resource_arc_clone.register_child(ChildHandle::Stmt(Arc::clone(&cell)))?;
            held.release();

            Ok(XqliteStream::new(
                cell,
                conn_resource_arc_clone,
                column_names,
            ))
        }
    })
    .map(ResourceArc::new)
}

#[rustler::nif(schedule = "DirtyIo")]
fn stream_get_columns(
    stream_handle: ResourceArc<XqliteStream>,
) -> Result<Vec<String>, XqliteError> {
    Ok(stream_handle.column_names.clone())
}

#[rustler::nif(schedule = "DirtyIo")]
fn stream_close<'a>(env: Env<'a>, stream_handle_term: Term<'a>) -> Term<'a> {
    match stream_handle_term.decode::<ResourceArc<XqliteStream>>() {
        Ok(stream_arc) => {
            let finalization_result = stream_arc.take_and_finalize_atomic_stmt();
            singular_ok_or_error_tuple(env, finalization_result)
        }
        Err(decode_err) => {
            let xql_err = XqliteError::InvalidStreamHandle {
                reason: format!("Expected a valid stream handle resource: {decode_err:?}"),
            };
            (error(), xql_err).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn stream_fetch<'a>(
    env: Env<'a>,
    stream_handle: ResourceArc<XqliteStream>,
    batch_size_term: Term<'a>,
) -> Term<'a> {
    stream_fetch_impl(env, stream_handle, batch_size_term, Vec::new())
}

#[rustler::nif(schedule = "DirtyIo")]
fn stream_fetch_cancellable<'a>(
    env: Env<'a>,
    stream_handle: ResourceArc<XqliteStream>,
    batch_size_term: Term<'a>,
    tokens_term: Term<'a>,
) -> Term<'a> {
    match crate::cancel::decode_tokens(tokens_term) {
        Ok(token_bools) => stream_fetch_impl(env, stream_handle, batch_size_term, token_bools),
        Err(e) => (error(), e).encode(env),
    }
}

fn stream_fetch_impl<'a>(
    env: Env<'a>,
    stream_handle: ResourceArc<XqliteStream>,
    batch_size_term: Term<'a>,
    token_bools: Vec<std::sync::Arc<std::sync::atomic::AtomicBool>>,
) -> Term<'a> {
    use crate::stream::process_single_step;

    let create_and_encode_error = |env_closure: Env<'a>,
                                   final_provided_term: Term<'a>|
     -> Term<'a> {
        match map_new(env_closure)
            .map_put(atoms::provided(), final_provided_term)
            .and_then(|map| map.map_put(atoms::minimum(), 1_usize))
        {
            Ok(details_map) => {
                (error(), (atoms::invalid_batch_size(), details_map)).encode(env_closure)
            }
            Err(_map_create_err) => {
                let xql_err = XqliteError::InternalEncodingError {
                    context: "Failed to create details map for InvalidBatchSize".to_string(),
                };
                (error(), xql_err).encode(env_closure)
            }
        }
    };

    // `provided` is the caller's own term, whatever it was: this door takes it
    // and judges it, where the statement door's `i64` argument makes rustler
    // refuse a wrong type before the function runs.
    let batch_size_i64: i64 = match batch_size_term.decode::<i64>() {
        Ok(val) if val >= 1 => val,
        Ok(_) | Err(_) => return create_and_encode_error(env, batch_size_term),
    };

    let batch_size = match usize::try_from(batch_size_i64) {
        Ok(val) => val,
        Err(_) => {
            let xql_err = XqliteError::InternalEncodingError {
                context: format!(
                    "Failed to convert valid i64 batch_size ({batch_size_i64}) to usize"
                ),
            };
            return (error(), xql_err).encode(env);
        }
    };

    // The connection is proven open before the statement pointer is read: a
    // connection that was closed finalized this stream on its way out, so a
    // null pointer alone can no longer tell an exhausted stream from a closed
    // connection, and the caller must still hear `:connection_closed`.
    //
    // Do NOT pre-size to `batch_size`: it is an unvalidated user integer, and
    // `Vec::with_capacity(huge)` aborts the VM via `handle_alloc_error` before a
    // single row is read (a pathological value requests petabytes up front).
    // Grow on demand instead, exactly like `stmt_multi_step_impl`.
    let mut fetched_rows: Vec<Vec<Term<'a>>> = Vec::new();
    let mut stream_definitively_exhausted = false;

    let conn_lock_guard = match stream_handle.conn_resource_arc.conn.lock() {
        Ok(guard) => guard,
        Err(p_err_conn) => {
            // SAFETY: the Mutex is poisoned, so no other thread can enter
            // SQLite on this connection. The registry result is dropped: the
            // poisoning is what the caller has to hear about.
            let _ = unsafe { finalize_stream_stmt_locked(&stream_handle) };
            return (
                error(),
                XqliteError::LockError(format!(
                    "XqliteConn Mutex poisoned for db_handle: {p_err_conn:?}"
                )),
            )
                .encode(env);
        }
    };
    let conn_ref = match conn_lock_guard.as_ref() {
        Some(conn) => conn,
        None => return (error(), XqliteError::ConnectionClosed).encode(env),
    };

    // An earlier batch ended on a step error after handing back the rows it
    // had read. Answer that error now, before the loop: the statement is
    // already finalized, so its null pointer would otherwise report `:done`
    // and the stream would look complete.
    if let Some(pending) = stream_handle.take_pending_error() {
        return (error(), pending).encode(env);
    }

    // SAFETY: conn_ref is valid (checked above). The handle is used only
    // for sqlite3_errmsg within process_single_step.
    let db_handle_for_errors = unsafe { conn_ref.handle() };

    let stmt_ptr = stream_handle.atomic_raw_stmt.load(Ordering::Acquire);
    // SAFETY: conn_lock_guard is held, and a non-null pointer is this stream's
    // live statement.
    let fresh = !stmt_ptr.is_null() && unsafe { ffi::sqlite3_stmt_busy(stmt_ptr) } == 0;
    if fresh && let Err(cancelled) = cancel_if_signalled(&token_bools) {
        // SAFETY: conn_lock_guard is held. The registry result is dropped: a
        // cancelled fetch closes the stream, as a cancelled step does below.
        let _ = unsafe { finalize_stream_stmt_locked(&stream_handle) };
        return (error(), cancelled).encode(env);
    }

    // SAFETY: the declaration order is load-bearing. Rust drops locals in
    // reverse declaration order, so declaring the guard after conn_lock_guard
    // drops it while the connection Mutex is still held, which is the guard's
    // contract: HookList frees the old subscriber vector right after its
    // atomic swap, while the C progress callback reads that vector without a
    // lock. Unregistering with the Mutex released would be a use-after-free
    // inside the callback.
    let _progress_guard = ProgressHandlerGuard::new(
        &stream_handle.conn_resource_arc.progress_dispatch,
        stmt_ptr,
        token_bools,
    );

    let fetch_outcome =
        connection::with_busy_timeout_rule(&stream_handle.conn_resource_arc, || {
            for _ in 0..batch_size {
                let current_stmt_ptr = stream_handle.atomic_raw_stmt.load(Ordering::Acquire);
                if current_stmt_ptr.is_null() {
                    stream_definitively_exhausted = true;
                    break;
                }

                // SAFETY: current_stmt_ptr was loaded non-null from the AtomicPtr
                // above. conn_lock_guard is held, so the db_handle is valid for
                // error reporting.
                match unsafe {
                    process_single_step(env, current_stmt_ptr, db_handle_for_errors)
                } {
                    Ok(Some(row_terms)) => {
                        fetched_rows.push(row_terms);
                    }
                    Ok(None) => {
                        stream_definitively_exhausted = true;
                        // SAFETY: conn_lock_guard is held for the whole loop. The
                        // registry result is dropped: the caller is being told the
                        // stream is done, which is the answer that matters here.
                        let _ = unsafe { finalize_stream_stmt_locked(&stream_handle) };
                        break;
                    }
                    // The stream finalizes its statement on every error, so a
                    // failed step and a row that cannot be read are both held
                    // back the same way: there is nothing left to carry on
                    // with, and the rows already read still belong to the
                    // caller. A cancellation is the exception below — it is
                    // answered at once and its batch's rows go with it.
                    Err(failure) => {
                        let e = XqliteError::from(failure);
                        stream_definitively_exhausted = true;
                        // SAFETY: conn_lock_guard is held for the whole loop. The
                        // registry result is dropped in favour of the step error.
                        let _ = unsafe { finalize_stream_stmt_locked(&stream_handle) };

                        // A cancellation discards the batch, as the stream's
                        // contract says. Any other error hands back the rows
                        // this batch had already read and waits for the next
                        // fetch — unless there are none, when it answers now.
                        if fetched_rows.is_empty()
                            || matches!(e, XqliteError::OperationCancelled)
                        {
                            return Err(e);
                        }

                        stream_handle.store_pending_error(e);
                        break;
                    }
                }
            }

            Ok(())
        });

    if let Err(err) = fetch_outcome {
        return (error(), err).encode(env);
    }

    if !fetched_rows.is_empty() {
        match map_new(env).map_put(atoms::rows(), fetched_rows) {
            Ok(result_map) => (ok(), result_map).encode(env),
            Err(_) => (
                error(),
                XqliteError::InternalEncodingError {
                    context: "map_new fail for fetched rows".into(),
                },
            )
                .encode(env),
        }
    } else if stream_definitively_exhausted {
        atoms::done().encode(env)
    } else {
        match map_new(env).map_put(atoms::rows(), Vec::<Vec<Term<'a>>>::new()) {
            Ok(result_map) => (ok(), result_map).encode(env),
            Err(_) => (
                error(),
                XqliteError::InternalEncodingError {
                    context: "map_new fail for empty non-done".into(),
                },
            )
                .encode(env),
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn compile_options(handle: ResourceArc<XqliteConn>) -> Result<Vec<String>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        let mut stmt = conn.prepare("PRAGMA compile_options;")?;
        let opts: Vec<String> = stmt
            .query_map([], |row| row.get(0))?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(opts)
    })
}

#[rustler::nif]
fn sqlite_version() -> Result<String, XqliteError> {
    // SAFETY: sqlite3_libversion() is thread-safe, requires no setup, and returns
    // a pointer to a static string compiled into SQLite. Never null in practice,
    // but we check defensively.
    let version_ptr = unsafe { rusqlite::ffi::sqlite3_libversion() };
    if version_ptr.is_null() {
        return Err(XqliteError::InternalEncodingError {
            context: "sqlite3_libversion returned a null pointer".to_string(),
        });
    }
    // SAFETY: version_ptr is non-null (checked above) and points to a valid,
    // null-terminated, static C string.
    let version_cstr = unsafe { std::ffi::CStr::from_ptr(version_ptr) };
    Ok(version_cstr.to_string_lossy().into_owned())
}

#[rustler::nif]
fn register_log_hook(env: Env<'_>, pid: rustler::LocalPid) -> Term<'_> {
    match crate::log_hook::register(pid) {
        Ok(id) => (ok(), id).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif]
fn unregister_log_hook(env: Env<'_>, id: u64) -> Term<'_> {
    singular_ok_or_error_tuple(env, crate::log_hook::unregister(id))
}

#[rustler::nif(schedule = "DirtyIo")]
fn register_update_hook(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    pid: rustler::LocalPid,
) -> Term<'_> {
    let result = connection::with_conn(&handle, |_conn| {
        crate::update_hook::register(&handle.update_hook, pid)
    });
    match result {
        Ok(id) => (ok(), id).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn unregister_update_hook(env: Env<'_>, handle: ResourceArc<XqliteConn>, id: u64) -> Term<'_> {
    let result = connection::with_conn(&handle, |_conn| {
        crate::update_hook::unregister(&handle.update_hook, id);
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn register_wal_hook(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    pid: rustler::LocalPid,
) -> Term<'_> {
    let result = connection::with_conn(&handle, |_conn| {
        crate::wal_hook::register(&handle.wal_hook.list, pid)
    });
    match result {
        Ok(id) => (ok(), id).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn unregister_wal_hook(env: Env<'_>, handle: ResourceArc<XqliteConn>, id: u64) -> Term<'_> {
    let result = connection::with_conn(&handle, |_conn| {
        crate::wal_hook::unregister(&handle.wal_hook.list, id);
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn register_commit_hook(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    pid: rustler::LocalPid,
) -> Term<'_> {
    let result = connection::with_conn(&handle, |_conn| {
        crate::commit_hook::register(&handle.commit_hook, pid)
    });
    match result {
        Ok(id) => (ok(), id).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn unregister_commit_hook(env: Env<'_>, handle: ResourceArc<XqliteConn>, id: u64) -> Term<'_> {
    let result = connection::with_conn(&handle, |_conn| {
        crate::commit_hook::unregister(&handle.commit_hook, id);
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn register_rollback_hook(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    pid: rustler::LocalPid,
) -> Term<'_> {
    let result = connection::with_conn(&handle, |_conn| {
        crate::rollback_hook::register(&handle.rollback_hook, pid)
    });
    match result {
        Ok(id) => (ok(), id).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn unregister_rollback_hook(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    id: u64,
) -> Term<'_> {
    let result = connection::with_conn(&handle, |_conn| {
        crate::rollback_hook::unregister(&handle.rollback_hook, id);
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn register_progress_hook(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    pid: rustler::LocalPid,
    every_n: u32,
    tag: MaybeTextArg,
) -> Term<'_> {
    if every_n == 0 {
        let err = XqliteError::InvalidOption {
            key: atoms::every_n(),
            value: every_n,
        };
        return (error(), err).encode(env);
    }

    let result = connection::with_conn(&handle, |_conn| {
        let tag_bytes = tag.into_option().map(|text| text.into_bytes());
        let subscriber =
            crate::progress_dispatch::TickSubscriber::new(pid, every_n, tag_bytes);
        let id = handle.progress_dispatch.ticks.register(subscriber);
        Ok(id)
    });

    match result {
        Ok(id) => (ok(), id).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn unregister_progress_hook(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    id: u64,
) -> Term<'_> {
    let result = connection::with_conn(&handle, |_conn| {
        // Idempotent — true if removed, false if no matching id; both
        // are :ok at the API layer (the user shouldn't have to track
        // whether a particular handle is still live).
        let _ = handle.progress_dispatch.ticks.unregister(id);
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn serialize<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    schema: TextArg,
) -> Result<rustler::Binary<'a>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        crate::schema::require_schema(conn, &schema)?;
        let data = conn.serialize(schema.as_str())?;
        let bytes: &[u8] = &data;
        let mut binary = rustler::OwnedBinary::new(bytes.len()).ok_or_else(|| {
            XqliteError::InternalEncodingError {
                context: "failed to allocate binary for serialized database".to_string(),
            }
        })?;
        binary.as_mut_slice().copy_from_slice(bytes);
        Ok(binary.release(env))
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn deserialize<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    schema: TextArg,
    data: rustler::Binary<'a>,
    read_only: bool,
) -> Term<'a> {
    let result = connection::with_conn_mut(&handle, |conn| {
        crate::schema::require_schema(conn, &schema)?;
        let bytes = data.as_slice();
        judge_image(bytes)?;
        judge_image_encoding(conn, &handle.busy_flags, &schema, bytes)?;
        let image = rollback_image(bytes);
        conn.deserialize_read_exact(schema.as_str(), image, bytes.len(), read_only)?;
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

/// Rejects an image before it replaces anything: bytes without SQLite's
/// 16-byte header, the empty binary included, and an image whose header and
/// schema SQLite cannot read on a scratch in-memory connection. Running out of
/// memory there says nothing about the image and keeps its own error.
fn judge_image(bytes: &[u8]) -> Result<(), XqliteError> {
    if !bytes.starts_with(b"SQLite format 3\0") {
        return Err(XqliteError::InvalidImage {
            reason: atoms::not_a_database(),
            code: ffi::SQLITE_NOTADB,
        });
    }
    let mut scratch = Connection::open_in_memory()?;
    scratch
        .deserialize_read_exact("main", rollback_image(bytes), bytes.len(), true)
        .and_then(|()| scratch.query_row("SELECT count(*) FROM sqlite_schema", [], |_| Ok(())))
        .map_err(|err| match err {
            rusqlite::Error::SqliteFailure(failure, _)
                if failure.code != ffi::ErrorCode::OutOfMemory =>
            {
                XqliteError::InvalidImage {
                    reason: match failure.code {
                        ffi::ErrorCode::DatabaseCorrupt => atoms::malformed(),
                        _ => atoms::not_a_database(),
                    },
                    code: failure.extended_code,
                }
            }
            other => XqliteError::from(other),
        })
}

/// Rejects an image whose text encoding, header bytes 56 to 59, is not the
/// connection's. SQLite checks an attached schema against it, and a loaded
/// `main` resets it while the connection's other schemas keep theirs, so
/// `main` takes only a UTF-8 image on a UTF-8 connection, the one pairing
/// that loads safely on every connection. A zero field, which SQLite leaves
/// unchecked, counts as the UTF-8 the scratch read checked the image in.
fn judge_image_encoding(
    conn: &Connection,
    flags: &busy_handler::BusySlotFlags,
    schema: &str,
    bytes: &[u8],
) -> Result<(), XqliteError> {
    let field = bytes
        .get(56..60)
        .and_then(|field| field.try_into().ok())
        .map_or(0, u32::from_be_bytes);
    let image = match (field, field & 3) {
        (0, _) | (_, 1) => Some("UTF-8"),
        (_, 2) => Some("UTF-16le"),
        (_, 3) => Some("UTF-16be"),
        _ => None,
    };
    let connection: String =
        flags.own_read(|| conn.pragma_query_value(None, "encoding", |row| row.get(0)))?;
    let main = schema.eq_ignore_ascii_case("main");
    match image == Some(connection.as_str()) && (!main || connection == "UTF-8") {
        true => Ok(()),
        false => Err(XqliteError::InvalidImage {
            reason: atoms::encoding_mismatch(),
            code: ffi::SQLITE_ERROR,
        }),
    }
}

/// The image as SQLite gets it: header bytes 18 and 19 set to 1 where they
/// read 2. A WAL database's image carries 2, which SQLite's memory storage
/// cannot open, and SQLite documents this change before a deserialize.
fn rollback_image(bytes: &[u8]) -> impl std::io::Read + '_ {
    use std::io::Read;
    let (head, rest) = bytes.split_at(bytes.len().min(18));
    let (versions, tail) = rest.split_at(rest.len().min(2));
    let versions: Vec<u8> = versions
        .iter()
        .map(|&version| if version == 2 { 1 } else { version })
        .collect();
    head.chain(Cursor::new(versions)).chain(tail)
}

#[rustler::nif(schedule = "DirtyIo")]
fn enable_load_extension<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    enabled: bool,
) -> Term<'a> {
    let result = connection::with_conn(&handle, |conn| {
        if enabled {
            // SAFETY: Caller has opted in to loading extensions. The risk of
            // arbitrary code execution is accepted by the user.
            unsafe { conn.load_extension_enable()? };
        } else {
            conn.load_extension_disable()?;
        }
        handle.extensions_enabled.store(enabled, Ordering::Release);
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn load_extension<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    path: TextArg,
    entry_point: MaybeTextArg,
) -> Term<'a> {
    if !handle.extensions_enabled.load(Ordering::Acquire) {
        return (atoms::error(), atoms::extension_loading_disabled()).encode(env);
    }
    let result = connection::with_conn(&handle, |conn| {
        // SAFETY: Extension loading was explicitly enabled by the caller via
        // enable_load_extension. The path points to a user-provided shared
        // library — the user accepts the trust boundary.
        unsafe {
            conn.load_extension(path.as_str(), entry_point.as_deref())?;
        }
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn backup<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    schema: TextArg,
    dest_path: TextArg,
) -> Term<'a> {
    let result = connection::with_conn(&handle, |conn| {
        crate::schema::require_schema(conn, &schema)?;
        conn.backup(schema.as_str(), dest_path.as_str(), None)?;
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn restore<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    schema: TextArg,
    src_path: TextArg,
) -> Term<'a> {
    let result = connection::with_conn_mut(&handle, |conn| {
        crate::schema::require_schema(conn, &schema)?;
        restore_from(conn, &schema, &src_path)
    });
    singular_ok_or_error_tuple(env, result)
}

/// Copies the main database of the file at `src_path` over `schema`. The file
/// is opened read-only and never created, and a source SQLite reports no file
/// name for — `""`, `:memory:` or another in-memory name, which it opens as a
/// new empty database — is rejected like a missing file, before anything is
/// copied. A busy step is retried twice, 100 ms apart, and a locked one is an
/// error, as rusqlite's own restore does.
fn restore_from(
    conn: &mut Connection,
    schema: &str,
    src_path: &str,
) -> Result<(), XqliteError> {
    use rusqlite::backup::{Backup, StepResult};

    let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
        | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
        | rusqlite::OpenFlags::SQLITE_OPEN_URI;
    let src = Connection::open_with_flags(src_path, flags).map_err(|err| match err {
        rusqlite::Error::SqliteFailure(ffi_err, message) => XqliteError::CannotOpenDatabase {
            path: src_path.to_string(),
            code: ffi_err.extended_code,
            message: message.unwrap_or_else(|| ffi_err.to_string()),
        },
        other => XqliteError::from(other),
    })?;
    if src.path().is_none_or(str::is_empty) {
        return Err(XqliteError::CannotOpenDatabase {
            path: src_path.to_string(),
            code: ffi::SQLITE_CANTOPEN,
            message: format!("no database file at {src_path:?}"),
        });
    }
    let restore = Backup::new_with_names(&src, "main", conn, schema)?;
    let mut busy_steps = 0;
    loop {
        let code = match restore.step(100)? {
            StepResult::Done => return Ok(()),
            StepResult::More => continue,
            StepResult::Busy if busy_steps < 2 => {
                busy_steps += 1;
                std::thread::sleep(std::time::Duration::from_millis(100));
                continue;
            }
            StepResult::Busy => ffi::SQLITE_BUSY,
            _locked => ffi::SQLITE_LOCKED,
        };
        return Err(rusqlite::Error::SqliteFailure(ffi::Error::new(code), None).into());
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn backup_with_progress<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    schema: TextArg,
    dest_path: TextArg,
    pid: rustler::types::LocalPid,
    pages_per_step: i32,
    cancel_tokens_term: Term<'a>,
) -> Term<'a> {
    // A non-positive step count is out of the documented `pos_integer()`
    // contract: `sqlite3_backup_step(0)` copies nothing yet reports "more", so
    // the loop would spin forever — pinning the connection Mutex and flooding
    // `pid` with progress messages.
    if pages_per_step < 1 {
        return (
            atoms::error(),
            (atoms::invalid_pages_per_step(), pages_per_step),
        )
            .encode(env);
    }

    let cancel_flags = match crate::cancel::decode_tokens(cancel_tokens_term) {
        Ok(flags) => flags,
        Err(e) => return (error(), e).encode(env),
    };

    let result = connection::with_conn(&handle, |conn| {
        crate::schema::require_schema(conn, &schema)?;
        let mut dst = rusqlite::Connection::open(dest_path.as_str())?;
        let backup =
            rusqlite::backup::Backup::new_with_names(conn, schema.as_str(), &mut dst, "main")?;
        let mut counts = None;

        loop {
            let cancelled = cancel_flags.iter().any(|t| t.load(Ordering::Acquire));
            if cancelled {
                return Err(XqliteError::OperationCancelled);
            }

            let step_result = backup.step(pages_per_step)?;
            if matches!(
                step_result,
                rusqlite::backup::StepResult::Done | rusqlite::backup::StepResult::More
            ) {
                let progress = backup.progress();
                counts = Some((progress.remaining, progress.pagecount));
            }
            let send = |status: &[u8]| {
                // SAFETY: enif_send with NULL caller_env is valid from dirty
                // scheduler threads (OTP 26.1+). All data is copied into msg_env.
                unsafe { send_backup_progress(&pid, counts, status) }
            };

            match step_result {
                rusqlite::backup::StepResult::Done => {
                    send(b"copied");
                    return Ok(());
                }
                rusqlite::backup::StepResult::More => send(b"copied"),
                rusqlite::backup::StepResult::Busy => {
                    send(b"busy");
                    return Err(rejected_step(ffi::SQLITE_BUSY));
                }
                rusqlite::backup::StepResult::Locked => {
                    send(b"busy");
                    return Err(rejected_step(ffi::SQLITE_LOCKED));
                }
                _ => continue,
            }
        }
    });
    singular_ok_or_error_tuple(env, result)
}

/// The error `Connection::backup` answers for a step SQLite rejected with `code`.
fn rejected_step(code: std::ffi::c_int) -> XqliteError {
    // SAFETY: sqlite3_errstr reads no connection; it answers a pointer to a
    // static string, or NULL for a code it has no text for.
    let text = unsafe { ffi::sqlite3_errstr(code) };
    let message = (!text.is_null()).then(|| {
        // SAFETY: a non-NULL answer points to a static NUL-terminated string.
        unsafe { std::ffi::CStr::from_ptr(text) }
            .to_string_lossy()
            .into_owned()
    });
    XqliteError::from(rusqlite::Error::SqliteFailure(
        ffi::Error::new(code),
        message,
    ))
}

/// `counts` are the last copied step's `(remaining, total)`, `None` before a
/// step has copied pages, when SQLite has no counts yet; `nil` goes out then.
///
/// # Safety
///
/// Sends with a NULL `caller_env`, which `hook_util`'s module doc covers.
unsafe fn send_backup_progress(
    pid: &rustler::types::LocalPid,
    counts: Option<(std::ffi::c_int, std::ffi::c_int)>,
    status: &[u8],
) {
    use crate::hook_util::make_atom;
    use rustler::sys::{
        ERL_NIF_TERM, enif_alloc_env, enif_free_env, enif_make_int64,
        enif_make_map_from_arrays, enif_make_tuple_from_array, enif_send,
    };

    // SAFETY: All enif_* calls operate on a freshly allocated msg_env.
    unsafe {
        let msg_env = enif_alloc_env();

        let keys = [
            make_atom(msg_env, b"remaining"),
            make_atom(msg_env, b"total"),
            make_atom(msg_env, b"status"),
        ];
        let count = |value: Option<std::ffi::c_int>| match value {
            Some(value) => enif_make_int64(msg_env, i64::from(value)),
            None => make_atom(msg_env, b"nil"),
        };
        let values = [
            count(counts.map(|(remaining, _)| remaining)),
            count(counts.map(|(_, total)| total)),
            make_atom(msg_env, status),
        ];
        let mut map: ERL_NIF_TERM = 0;
        // Only duplicate keys make the map fail, and these three are distinct.
        let made = enif_make_map_from_arrays(
            msg_env,
            keys.as_ptr(),
            values.as_ptr(),
            keys.len(),
            &mut map,
        );

        if made != 0 {
            let elements = [make_atom(msg_env, b"xqlite_backup_progress"), map];
            let tuple = enif_make_tuple_from_array(msg_env, elements.as_ptr(), 2);
            let _ = enif_send(std::ptr::null_mut(), pid.as_c_arg(), msg_env, tuple);
        }

        // enif_send never takes ownership of msg_env; free it unconditionally.
        enif_free_env(msg_env);
    }
}

/// Encodes a query result with an additional `changes` key.
#[inline]
fn encode_query_result_with_changes<'a>(
    env: Env<'a>,
    qr: &XqliteQueryResult<'a>,
    changes: u64,
) -> Term<'a> {
    let result: Result<Term, String> = Ok(map_new(env))
        .and_then(|map| {
            map.map_put(atoms::columns(), &qr.columns)
                .map_err(|_| "Failed to insert :columns key".to_string())
        })
        .and_then(|map| {
            map.map_put(atoms::rows(), &qr.rows)
                .map_err(|_| "Failed to insert :rows key".to_string())
        })
        .and_then(|map| {
            map.map_put(atoms::num_rows(), qr.num_rows)
                .map_err(|_| "Failed to insert :num_rows key".to_string())
        })
        .and_then(|map| {
            map.map_put(atoms::changes(), changes)
                .map_err(|_| "Failed to insert :changes key".to_string())
        });

    match result {
        Ok(map) => (ok(), map).encode(env),
        Err(context) => {
            let err = XqliteError::InternalEncodingError { context };
            (error(), err).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn session_new<'a>(env: Env<'a>, handle: ResourceArc<XqliteConn>) -> Term<'a> {
    let result = connection::with_conn(&handle, |conn| {
        let s = rusqlite::session::Session::new(conn)?;
        // SAFETY: We erase the connection lifetime. This is safe because
        // conn_resource_arc (stored in XqliteSession) prevents the connection
        // from being dropped while the session exists.
        let static_session: rusqlite::session::Session<'static> =
            unsafe { std::mem::transmute(s) };
        Ok(ResourceArc::new(XqliteSession {
            session: std::sync::Mutex::new(Some(static_session)),
            conn_resource_arc: handle.clone(),
        }))
    });
    match result {
        Ok(resource) => (ok(), resource).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn session_attach<'a>(
    env: Env<'a>,
    session_handle: ResourceArc<XqliteSession>,
    table: NameOrAll,
) -> Term<'a> {
    let result = session::with_session_mut(&session_handle, |s| {
        match table.as_deref() {
            Some(name) => s.attach(Some(name))?,
            None => s.attach(None::<&str>)?,
        }
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn session_changeset<'a>(
    env: Env<'a>,
    session_handle: ResourceArc<XqliteSession>,
) -> Term<'a> {
    let result = session::with_session_mut(&session_handle, |s| {
        let mut output = Vec::new();
        s.changeset_strm(&mut output)?;
        session::to_owned_binary(&output, "changeset")
    });
    match result {
        Ok(binary) => (ok(), binary.release(env)).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn session_patchset<'a>(env: Env<'a>, session_handle: ResourceArc<XqliteSession>) -> Term<'a> {
    let result = session::with_session_mut(&session_handle, |s| {
        let mut output = Vec::new();
        s.patchset_strm(&mut output)?;
        session::to_owned_binary(&output, "patchset")
    });
    match result {
        Ok(binary) => (ok(), binary.release(env)).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn session_is_empty(session_handle: ResourceArc<XqliteSession>) -> Result<bool, XqliteError> {
    session::with_session(&session_handle, |s| Ok(s.is_empty()))
}

#[rustler::nif(schedule = "DirtyIo")]
fn session_delete<'a>(env: Env<'a>, session_handle: ResourceArc<XqliteSession>) -> Term<'a> {
    singular_ok_or_error_tuple(env, session::close(&session_handle))
}

#[rustler::nif(schedule = "DirtyIo")]
fn changeset_apply<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    changeset_binary: rustler::Binary<'a>,
    conflict_strategy: rustler::Atom,
) -> Term<'a> {
    let strategy = if conflict_strategy == atoms::omit() {
        ConflictAction::SQLITE_CHANGESET_OMIT
    } else if conflict_strategy == atoms::replace() {
        ConflictAction::SQLITE_CHANGESET_REPLACE
    } else if conflict_strategy == atoms::abort() {
        ConflictAction::SQLITE_CHANGESET_ABORT
    } else {
        return (
            atoms::error(),
            (atoms::invalid_conflict_strategy(), conflict_strategy),
        )
            .encode(env);
    };

    let result = connection::with_conn(&handle, |conn| {
        let bytes = changeset_binary.as_slice();
        let mut cursor = Cursor::new(bytes);
        let strategy_code = strategy as i32;
        conn.apply_strm(
            &mut cursor,
            None::<fn(&str) -> bool>,
            move |conflict_type, _item| {
                if strategy_code == ConflictAction::SQLITE_CHANGESET_ABORT as i32 {
                    ConflictAction::SQLITE_CHANGESET_ABORT
                } else if strategy_code == ConflictAction::SQLITE_CHANGESET_REPLACE as i32 {
                    // SQLITE_CHANGESET_REPLACE is a legal return ONLY for DATA
                    // and CONFLICT conflicts; returning it for NOTFOUND /
                    // CONSTRAINT / FOREIGN_KEY makes sqlite3changeset_apply fail
                    // with SQLITE_MISUSE. A `:replace` request cannot overwrite
                    // in those cases, so abort the whole apply cleanly (rolled
                    // back) rather than surface an opaque misuse error.
                    match conflict_type {
                        ConflictType::SQLITE_CHANGESET_DATA
                        | ConflictType::SQLITE_CHANGESET_CONFLICT => {
                            ConflictAction::SQLITE_CHANGESET_REPLACE
                        }
                        _ => ConflictAction::SQLITE_CHANGESET_ABORT,
                    }
                } else {
                    ConflictAction::SQLITE_CHANGESET_OMIT
                }
            },
        )?;
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn changeset_invert<'a>(env: Env<'a>, changeset_binary: rustler::Binary<'a>) -> Term<'a> {
    let result = (|| -> Result<rustler::OwnedBinary, XqliteError> {
        let bytes = changeset_binary.as_slice();
        let mut input = Cursor::new(bytes);
        let mut output = Vec::new();
        rusqlite::session::invert_strm(&mut input, &mut output)?;
        session::to_owned_binary(&output, "inverted changeset")
    })();
    match result {
        Ok(binary) => (ok(), binary.release(env)).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn changeset_concat<'a>(
    env: Env<'a>,
    a_binary: rustler::Binary<'a>,
    b_binary: rustler::Binary<'a>,
) -> Term<'a> {
    let result = (|| -> Result<rustler::OwnedBinary, XqliteError> {
        let mut input_a = Cursor::new(a_binary.as_slice());
        let mut input_b = Cursor::new(b_binary.as_slice());
        let mut output = Vec::new();
        rusqlite::session::concat_strm(&mut input_a, &mut input_b, &mut output)?;
        session::to_owned_binary(&output, "concatenated changeset")
    })();
    match result {
        Ok(binary) => (ok(), binary.release(env)).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn blob_open<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    db: TextArg,
    table: TextArg,
    column: TextArg,
    row_id: i64,
    read_only: bool,
) -> Term<'a> {
    match blob::open(&handle, &db, &table, &column, row_id, read_only) {
        Ok(resource) => (ok(), resource).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn blob_read<'a>(
    env: Env<'a>,
    blob_handle: ResourceArc<XqliteBlob>,
    offset: usize,
    length: usize,
) -> Term<'a> {
    match blob::read(&blob_handle, offset, length) {
        Ok(binary) => (ok(), binary.release(env)).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn blob_write<'a>(
    env: Env<'a>,
    blob_handle: ResourceArc<XqliteBlob>,
    offset: usize,
    data: rustler::Binary<'a>,
) -> Term<'a> {
    singular_ok_or_error_tuple(env, blob::write(&blob_handle, offset, data.as_slice()))
}

#[rustler::nif(schedule = "DirtyIo")]
fn blob_size(blob_handle: ResourceArc<XqliteBlob>) -> Result<usize, XqliteError> {
    blob::size(&blob_handle)
}

#[rustler::nif(schedule = "DirtyIo")]
fn blob_reopen<'a>(
    env: Env<'a>,
    blob_handle: ResourceArc<XqliteBlob>,
    row_id: i64,
) -> Term<'a> {
    singular_ok_or_error_tuple(env, blob::reopen(&blob_handle, row_id))
}

#[rustler::nif(schedule = "DirtyIo")]
fn blob_close<'a>(env: Env<'a>, blob_handle: ResourceArc<XqliteBlob>) -> Term<'a> {
    singular_ok_or_error_tuple(env, blob::close(&blob_handle))
}
