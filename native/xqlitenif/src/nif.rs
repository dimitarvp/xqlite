use crate::atoms;
use crate::blob::{self, XqliteBlob};
use crate::busy_handler::{self, BusyHandlerState};
use crate::cancel::XqliteCancelToken;
use crate::connection::{self, XqliteConn, XqliteQueryResult};
use crate::error::XqliteError;
use crate::explain_analyze::{self, ExplainAnalyze};
use crate::pragma;
use crate::query;
use crate::schema::{
    ColumnInfo, DatabaseInfo, ForeignKeyInfo, IndexColumnInfo, IndexInfo, SchemaObjectInfo,
};
use crate::session::{self, XqliteSession};
use crate::stream::XqliteStream;
use crate::transaction;
use crate::util::singular_ok_or_error_tuple;
use rusqlite::Connection;
use rusqlite::ffi;
use rusqlite::session::ConflictAction;
use rustler::{
    Encoder, Env, ResourceArc, Term, TermType,
    types::{
        atom::{error, ok},
        map::map_new,
    },
};
use std::io::Cursor;
use std::ptr::NonNull;
use std::sync::atomic::{AtomicPtr, Ordering};

// ---------------------------------------------------------------------------
// Connection NIFs
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyIo")]
fn open(path: String) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let result = Connection::open(&path);
    connection::handle_open_result(result, path)
}

#[rustler::nif(schedule = "DirtyIo")]
fn open_in_memory(uri: String) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let result = Connection::open(&uri);
    connection::handle_open_result(result, uri)
}

#[rustler::nif(schedule = "DirtyIo")]
fn open_readonly(path: String) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
        | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
        | rusqlite::OpenFlags::SQLITE_OPEN_URI;
    let result = Connection::open_with_flags(&path, flags);
    connection::handle_open_result(result, path)
}

#[rustler::nif(schedule = "DirtyIo")]
fn open_in_memory_readonly(uri: String) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
        | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX
        | rusqlite::OpenFlags::SQLITE_OPEN_MEMORY
        | rusqlite::OpenFlags::SQLITE_OPEN_URI;
    let result = Connection::open_with_flags(&uri, flags);
    connection::handle_open_result(result, uri)
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

// ---------------------------------------------------------------------------
// Query / Execute NIFs
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyIo")]
fn query<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: String,
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
    sql: String,
    params_term: Term<'a>,
) -> Result<usize, XqliteError> {
    connection::with_conn(&handle, |conn| {
        query::core_execute(env, conn, &sql, params_term)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute_batch(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    sql_batch: String,
) -> Term<'_> {
    let execution_result =
        connection::with_conn(&handle, |conn| query::core_execute_batch(conn, &sql_batch));
    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn query_with_changes<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: String,
    params_term: Term<'a>,
) -> Term<'a> {
    let result = connection::with_conn(&handle, |conn| {
        let qr = query::core_query(env, conn, &sql, params_term)?;
        let changes = if qr.columns.is_empty() {
            conn.changes()
        } else {
            0
        };
        Ok((qr, changes))
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
    sql: String,
    params_term: Term<'a>,
    tokens: Vec<ResourceArc<XqliteCancelToken>>,
) -> Term<'a> {
    let token_bools: Vec<std::sync::Arc<std::sync::atomic::AtomicBool>> =
        tokens.iter().map(|t| t.0.clone()).collect();
    let result = connection::with_conn(&handle, |conn| {
        let _guard =
            crate::cancel::ProgressHandlerGuard::new(&handle.progress_dispatch, token_bools);
        let qr = query::core_query(env, conn, &sql, params_term)?;
        let changes = if qr.columns.is_empty() {
            conn.changes()
        } else {
            0
        };
        Ok((qr, changes))
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
    sql: String,
    params_term: Term<'a>,
    tokens: Vec<ResourceArc<XqliteCancelToken>>,
) -> Result<XqliteQueryResult<'a>, XqliteError> {
    let token_bools: Vec<std::sync::Arc<std::sync::atomic::AtomicBool>> =
        tokens.iter().map(|t| t.0.clone()).collect();
    connection::with_conn(&handle, |conn| {
        let _guard =
            crate::cancel::ProgressHandlerGuard::new(&handle.progress_dispatch, token_bools);
        query::core_query(env, conn, &sql, params_term)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute_cancellable<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: String,
    params_term: Term<'a>,
    tokens: Vec<ResourceArc<XqliteCancelToken>>,
) -> Result<usize, XqliteError> {
    let token_bools: Vec<std::sync::Arc<std::sync::atomic::AtomicBool>> =
        tokens.iter().map(|t| t.0.clone()).collect();
    connection::with_conn(&handle, |conn| {
        let _guard =
            crate::cancel::ProgressHandlerGuard::new(&handle.progress_dispatch, token_bools);
        query::core_execute(env, conn, &sql, params_term)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute_batch_cancellable(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    sql_batch: String,
    tokens: Vec<ResourceArc<XqliteCancelToken>>,
) -> Term<'_> {
    let token_bools: Vec<std::sync::Arc<std::sync::atomic::AtomicBool>> =
        tokens.iter().map(|t| t.0.clone()).collect();
    let execution_result = connection::with_conn(&handle, |conn| {
        let _guard =
            crate::cancel::ProgressHandlerGuard::new(&handle.progress_dispatch, token_bools);
        query::core_execute_batch(conn, &sql_batch)
    });
    singular_ok_or_error_tuple(env, execution_result)
}

// ---------------------------------------------------------------------------
// EXPLAIN ANALYZE NIF
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyIo")]
fn explain_analyze<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: String,
    params_term: Term<'a>,
) -> Result<ExplainAnalyze, XqliteError> {
    connection::with_conn(&handle, |conn| {
        explain_analyze::core_explain_analyze(env, conn, &sql, params_term)
    })
}

// ---------------------------------------------------------------------------
// Transaction / autocommit introspection
// ---------------------------------------------------------------------------

#[rustler::nif]
fn autocommit(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    connection::with_conn(&handle, |conn| Ok(conn.is_autocommit()))
}

#[rustler::nif]
fn txn_state<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    schema: Option<String>,
) -> Result<Term<'a>, XqliteError> {
    use rusqlite::TransactionState as TS;

    let state = connection::with_conn(&handle, |conn| {
        conn.transaction_state(schema.as_deref())
            .map_err(XqliteError::from)
    })?;

    let atom = match state {
        TS::None => atoms::none(),
        TS::Read => atoms::read(),
        TS::Write => atoms::write(),
        _ => atoms::unknown(),
    };

    Ok(atom.encode(env))
}

// ---------------------------------------------------------------------------
// Busy handler
// ---------------------------------------------------------------------------

#[rustler::nif]
fn set_busy_handler(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    pid: rustler::LocalPid,
    max_retries: u32,
    max_elapsed_ms: u64,
    sleep_ms: u64,
) -> Term<'_> {
    let state = BusyHandlerState::new(pid, max_retries, max_elapsed_ms, sleep_ms);
    let result = connection::with_conn(&handle, |conn| {
        busy_handler::install(conn, &handle.busy_handler, state)
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif]
fn remove_busy_handler(env: Env<'_>, handle: ResourceArc<XqliteConn>) -> Term<'_> {
    let result = connection::with_conn(&handle, |conn| {
        busy_handler::uninstall(conn, &handle.busy_handler)
    });
    singular_ok_or_error_tuple(env, result)
}

// ---------------------------------------------------------------------------
// WAL checkpoint + DB status (observability)
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyIo")]
fn wal_checkpoint<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    mode: rustler::Atom,
    schema: Option<String>,
) -> Result<Term<'a>, XqliteError> {
    let mode_int = match () {
        _ if mode == atoms::passive() => ffi::SQLITE_CHECKPOINT_PASSIVE,
        _ if mode == atoms::full() => ffi::SQLITE_CHECKPOINT_FULL,
        _ if mode == atoms::restart() => ffi::SQLITE_CHECKPOINT_RESTART,
        _ if mode == atoms::truncate() => ffi::SQLITE_CHECKPOINT_TRUNCATE,
        _ => {
            return Err(XqliteError::CannotExecute(format!(
                "invalid wal_checkpoint mode {mode:?}; expected :passive, :full, :restart, or :truncate"
            )));
        }
    };

    connection::with_conn(&handle, |conn| {
        // SAFETY: with_conn holds the connection Mutex. db handle is
        // valid for the duration of the closure. zDb is either null
        // (main schema) or a valid NUL-terminated string whose lifetime
        // spans the FFI call.
        unsafe {
            let db = conn.handle();
            let c_schema = match schema.as_deref() {
                None => None,
                Some(s) => Some(
                    std::ffi::CString::new(s).map_err(|_| XqliteError::NulErrorInString)?,
                ),
            };
            let schema_ptr = c_schema
                .as_ref()
                .map(|c| c.as_ptr())
                .unwrap_or(std::ptr::null());

            let mut log_pages: std::os::raw::c_int = 0;
            let mut ckpt_pages: std::os::raw::c_int = 0;
            let rc = ffi::sqlite3_wal_checkpoint_v2(
                db,
                schema_ptr,
                mode_int,
                &mut log_pages,
                &mut ckpt_pages,
            );

            match rc {
                ffi::SQLITE_OK | ffi::SQLITE_BUSY => {
                    let busy = rc == ffi::SQLITE_BUSY;
                    let map = map_new(env);
                    let map = map
                        .map_put(
                            atoms::log_pages().encode(env),
                            (log_pages as i64).encode(env),
                        )
                        .map_err(|_| {
                            XqliteError::CannotExecute(
                                "wal_checkpoint map_put log_pages failed".into(),
                            )
                        })?;
                    let map = map
                        .map_put(
                            atoms::checkpointed_pages().encode(env),
                            (ckpt_pages as i64).encode(env),
                        )
                        .map_err(|_| {
                            XqliteError::CannotExecute(
                                "wal_checkpoint map_put checkpointed_pages failed".into(),
                            )
                        })?;
                    let map = map
                        .map_put(atoms::busy().encode(env), busy.encode(env))
                        .map_err(|_| {
                            XqliteError::CannotExecute(
                                "wal_checkpoint map_put busy failed".into(),
                            )
                        })?;
                    Ok(map)
                }
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
        // for the closure. Each `sqlite3_db_status` call writes into
        // stack-local ints we own.
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
                let mut current: std::os::raw::c_int = 0;
                let mut highwater: std::os::raw::c_int = 0;
                let rc = ffi::sqlite3_db_status(db, *op, &mut current, &mut highwater, 0);

                if rc != ffi::SQLITE_OK {
                    return Err(XqliteError::CannotExecute(format!(
                        "sqlite3_db_status(op={op}) returned {rc}"
                    )));
                }

                map = map
                    .map_put(atom.encode(env), (current as i64).encode(env))
                    .map_err(|_| {
                        XqliteError::CannotExecute(format!(
                            "connection_stats map_put for op {op} failed"
                        ))
                    })?;
            }

            Ok(map)
        }
    })
}

// ---------------------------------------------------------------------------
// Cancel NIFs
// ---------------------------------------------------------------------------

#[rustler::nif]
fn create_cancel_token() -> Result<ResourceArc<XqliteCancelToken>, XqliteError> {
    Ok(ResourceArc::new(XqliteCancelToken::new()))
}

#[rustler::nif]
fn cancel_operation(env: Env<'_>, token: ResourceArc<XqliteCancelToken>) -> Term<'_> {
    token.cancel();
    ok().encode(env)
}

// ---------------------------------------------------------------------------
// Pragma NIFs
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyIo")]
fn get_pragma(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    pragma_name: String,
) -> Result<Term<'_>, XqliteError> {
    connection::with_conn(&handle, |conn| pragma::get(env, conn, &pragma_name))
}

#[rustler::nif(schedule = "DirtyIo")]
fn set_pragma<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    pragma_name: String,
    value_term: Term<'a>,
) -> Result<Term<'a>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        pragma::set(env, conn, &pragma_name, value_term)
    })
}

// ---------------------------------------------------------------------------
// Transaction NIFs
// ---------------------------------------------------------------------------

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
fn savepoint(env: Env<'_>, handle: ResourceArc<XqliteConn>, name: String) -> Term<'_> {
    let execution_result =
        connection::with_conn(&handle, |conn| transaction::savepoint(conn, &name));
    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn rollback_to_savepoint(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    name: String,
) -> Term<'_> {
    let execution_result = connection::with_conn(&handle, |conn| {
        transaction::rollback_to_savepoint(conn, &name)
    });
    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn release_savepoint(env: Env<'_>, handle: ResourceArc<XqliteConn>, name: String) -> Term<'_> {
    let execution_result =
        connection::with_conn(&handle, |conn| transaction::release_savepoint(conn, &name));
    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn transaction_status(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    connection::with_conn(&handle, |conn| Ok(!conn.is_autocommit()))
}

// ---------------------------------------------------------------------------
// Schema NIFs
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyIo")]
fn schema_databases(
    handle: ResourceArc<XqliteConn>,
) -> Result<Vec<DatabaseInfo>, XqliteError> {
    connection::with_conn(&handle, crate::schema::databases)
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_list_objects(
    handle: ResourceArc<XqliteConn>,
    schema: Option<String>,
) -> Result<Vec<SchemaObjectInfo>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        crate::schema::list_objects(conn, schema.as_deref())
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_columns(
    handle: ResourceArc<XqliteConn>,
    table_name: String,
) -> Result<Vec<ColumnInfo>, XqliteError> {
    connection::with_conn(&handle, |conn| crate::schema::columns(conn, &table_name))
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_foreign_keys(
    handle: ResourceArc<XqliteConn>,
    table_name: String,
) -> Result<Vec<ForeignKeyInfo>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        crate::schema::foreign_keys(conn, &table_name)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_indexes(
    handle: ResourceArc<XqliteConn>,
    table_name: String,
) -> Result<Vec<IndexInfo>, XqliteError> {
    connection::with_conn(&handle, |conn| crate::schema::indexes(conn, &table_name))
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_index_columns(
    handle: ResourceArc<XqliteConn>,
    index_name: String,
) -> Result<Vec<IndexColumnInfo>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        crate::schema::index_columns(conn, &index_name)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn get_create_sql(
    handle: ResourceArc<XqliteConn>,
    object_name: String,
) -> Result<Option<String>, XqliteError> {
    connection::with_conn(&handle, |conn| {
        crate::schema::create_sql(conn, &object_name)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn last_insert_rowid(handle: ResourceArc<XqliteConn>) -> Result<i64, XqliteError> {
    connection::with_conn(&handle, |conn| Ok(conn.last_insert_rowid()))
}

#[rustler::nif]
fn changes(handle: ResourceArc<XqliteConn>) -> Result<u64, XqliteError> {
    connection::with_conn(&handle, |conn| Ok(conn.changes()))
}

#[rustler::nif]
fn total_changes(handle: ResourceArc<XqliteConn>) -> Result<u64, XqliteError> {
    connection::with_conn(&handle, |conn| Ok(conn.total_changes()))
}

// ---------------------------------------------------------------------------
// Stream NIFs
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyIo")]
fn stream_open<'a>(
    env: Env<'a>,
    conn_handle: ResourceArc<XqliteConn>,
    sql: String,
    params_term: Term<'a>,
    _reserved_future_opts: Term<'a>,
) -> Result<ResourceArc<XqliteStream>, XqliteError> {
    use crate::stream::{bind_named_params_ffi, bind_positional_params_ffi};
    use crate::util::{decode_exec_keyword_params, decode_plain_list_params, is_keyword};

    let conn_resource_arc_clone = conn_handle.clone();

    connection::with_conn(&conn_handle, |conn| {
        // SAFETY: with_conn holds the connection mutex for the duration of
        // this closure. All FFI calls below operate on the db_handle and
        // raw_stmt_ptr owned by this connection. Statement ownership is
        // transferred to XqliteStream's AtomicPtr on success, or finalized
        // on error before returning.
        unsafe {
            let db_handle = conn.handle();
            let mut raw_stmt_ptr: *mut ffi::sqlite3_stmt = std::ptr::null_mut();
            let c_sql = std::ffi::CString::new(sql.as_str())
                .map_err(|_| XqliteError::NulErrorInString)?;

            let prepare_rc = ffi::sqlite3_prepare_v2(
                db_handle,
                c_sql.as_ptr(),
                std::os::raw::c_int::try_from(c_sql.as_bytes().len()).map_err(|_| {
                    XqliteError::CannotExecute(
                        "SQL string length exceeds c_int range".to_string(),
                    )
                })?,
                &mut raw_stmt_ptr,
                std::ptr::null_mut(),
            );

            if prepare_rc != ffi::SQLITE_OK {
                let error_message = {
                    let err_msg_ptr = ffi::sqlite3_errmsg(db_handle);
                    if err_msg_ptr.is_null() {
                        format!("SQLite preparation error (code {prepare_rc}) but no message available. SQL: {sql}")
                    } else {
                        std::ffi::CStr::from_ptr(err_msg_ptr)
                            .to_string_lossy()
                            .into_owned()
                    }
                };
                let ffi_err = ffi::Error::new(prepare_rc);
                let rusqlite_err =
                    rusqlite::Error::SqliteFailure(ffi_err, Some(error_message));
                return Err(XqliteError::from(rusqlite_err));
            }

            // SAFETY: raw_stmt_ptr was just returned by sqlite3_prepare_v2
            // which succeeded (prepare_rc == SQLITE_OK). A null return with
            // SQLITE_OK means the input was whitespace/comments only.
            let non_null_raw_stmt = match NonNull::new(raw_stmt_ptr) {
                Some(ptr) => ptr,
                None => {
                    return Ok(XqliteStream {
                        atomic_raw_stmt: AtomicPtr::new(std::ptr::null_mut()),
                        conn_resource_arc: conn_resource_arc_clone,
                        column_names: Vec::new(),
                        column_count: 0,
                    });
                }
            };

            let bind_result: Result<(), XqliteError> = match params_term.get_type() {
                TermType::List => {
                    if params_term.is_empty_list() {
                        Ok(())
                    } else if is_keyword(params_term) {
                        let named_params_vec =
                            decode_exec_keyword_params(env, params_term)?;
                        bind_named_params_ffi(
                            non_null_raw_stmt.as_ptr(),
                            &named_params_vec,
                            db_handle,
                        )
                    } else {
                        let positional_params_vec =
                            decode_plain_list_params(env, params_term)?;
                        bind_positional_params_ffi(
                            non_null_raw_stmt.as_ptr(),
                            &positional_params_vec,
                            db_handle,
                        )
                    }
                }
                _ if params_term == rustler::types::atom::nil().to_term(env) => Ok(()),
                _ => Err(XqliteError::ExpectedList {
                    value_str: format!(
                        "Parameters term was not a list: {params_term:?}"
                    ),
                }),
            };

            if let Err(e) = bind_result {
                ffi::sqlite3_finalize(non_null_raw_stmt.as_ptr());
                return Err(e);
            }

            let column_count =
                ffi::sqlite3_column_count(non_null_raw_stmt.as_ptr()) as usize;
            let mut column_names = Vec::with_capacity(column_count);

            if column_count > 0 {
                for i in 0..column_count {
                    let name_ptr = ffi::sqlite3_column_name(
                        non_null_raw_stmt.as_ptr(),
                        i as std::os::raw::c_int,
                    );
                    if name_ptr.is_null() {
                        ffi::sqlite3_finalize(non_null_raw_stmt.as_ptr());
                        return Err(XqliteError::InternalEncodingError {
                            context: format!(
                                "SQLite returned null column name for index {i} during stream open"
                            ),
                        });
                    }
                    let name_c_str = std::ffi::CStr::from_ptr(name_ptr);
                    column_names.push(name_c_str.to_string_lossy().into_owned());
                }
            }

            Ok(XqliteStream {
                atomic_raw_stmt: AtomicPtr::new(non_null_raw_stmt.as_ptr()),
                conn_resource_arc: conn_resource_arc_clone,
                column_names,
                column_count,
            })
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
    use crate::stream::process_single_step;
    use crate::util::term_to_tagged_elixir_value;

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

    let batch_size_i64: i64 = match batch_size_term.decode::<i64>() {
        Ok(val) if val >= 1 => val,
        Ok(val) => {
            let original_term_as_term = val.encode(env);
            let tagged_provided_term = term_to_tagged_elixir_value(env, original_term_as_term);
            return create_and_encode_error(env, tagged_provided_term);
        }
        Err(_) => {
            let tagged_provided_term = term_to_tagged_elixir_value(env, batch_size_term);
            return create_and_encode_error(env, tagged_provided_term);
        }
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

    let mut current_stmt_ptr = stream_handle.atomic_raw_stmt.load(Ordering::Acquire);
    if current_stmt_ptr.is_null() {
        return atoms::done().encode(env);
    }

    let mut fetched_rows: Vec<Vec<Term<'a>>> = Vec::with_capacity(batch_size);
    let mut an_error_occurred: Option<XqliteError> = None;
    let mut stream_definitively_exhausted = false;

    let conn_lock_guard = match stream_handle.conn_resource_arc.conn.lock() {
        Ok(guard) => guard,
        Err(p_err_conn) => {
            let old_ptr = stream_handle
                .atomic_raw_stmt
                .swap(std::ptr::null_mut(), Ordering::AcqRel);
            if !old_ptr.is_null() {
                // SAFETY: old_ptr was obtained via atomic swap, guaranteeing exclusive
                // ownership. The mutex is poisoned so no other thread can use the connection.
                unsafe {
                    ffi::sqlite3_finalize(old_ptr);
                }
            }
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
    // SAFETY: conn_ref is valid (checked above). The handle is used only
    // for sqlite3_errmsg within process_single_step.
    let db_handle_for_errors = unsafe { conn_ref.handle() };

    for _ in 0..batch_size {
        current_stmt_ptr = stream_handle.atomic_raw_stmt.load(Ordering::Acquire);
        if current_stmt_ptr.is_null() {
            stream_definitively_exhausted = true;
            break;
        }

        // SAFETY: current_stmt_ptr was loaded non-null from the AtomicPtr above.
        // conn_lock_guard is held, so the db_handle is valid for error reporting.
        // column_count was set at prepare time and is immutable.
        match unsafe {
            process_single_step(
                env,
                current_stmt_ptr,
                stream_handle.column_count,
                db_handle_for_errors,
            )
        } {
            Ok(Some(row_terms)) => {
                fetched_rows.push(row_terms);
            }
            Ok(None) => {
                stream_definitively_exhausted = true;
                let ptr_to_finalize = stream_handle
                    .atomic_raw_stmt
                    .swap(std::ptr::null_mut(), Ordering::AcqRel);
                if !ptr_to_finalize.is_null() {
                    // SAFETY: Atomic swap guarantees exclusive ownership of the pointer.
                    unsafe {
                        ffi::sqlite3_finalize(ptr_to_finalize);
                    }
                }
                break;
            }
            Err(e) => {
                stream_definitively_exhausted = true;
                let ptr_to_finalize = stream_handle
                    .atomic_raw_stmt
                    .swap(std::ptr::null_mut(), Ordering::AcqRel);
                if !ptr_to_finalize.is_null() {
                    // SAFETY: Atomic swap guarantees exclusive ownership of the pointer.
                    unsafe {
                        ffi::sqlite3_finalize(ptr_to_finalize);
                    }
                }
                an_error_occurred = Some(e);
                break;
            }
        }
    }

    if let Some(err) = an_error_occurred {
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

// ---------------------------------------------------------------------------
// Utility NIFs
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Log Hook NIFs (global, multi-subscriber)
// ---------------------------------------------------------------------------

#[rustler::nif]
fn register_log_hook(env: Env<'_>, pid: rustler::LocalPid) -> Term<'_> {
    match crate::log_hook::register(pid) {
        Ok(id) => (ok(), id).encode(env),
        Err(msg) => {
            let err = XqliteError::CannotExecute(msg);
            (error(), err).encode(env)
        }
    }
}

#[rustler::nif]
fn unregister_log_hook(env: Env<'_>, id: u64) -> Term<'_> {
    match crate::log_hook::unregister(id) {
        Ok(()) => ok().encode(env),
        Err(msg) => {
            let err = XqliteError::CannotExecute(msg);
            (error(), err).encode(env)
        }
    }
}

// ---------------------------------------------------------------------------
// Per-connection multi-subscriber hooks
// ---------------------------------------------------------------------------

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
        crate::wal_hook::register(&handle.wal_hook, pid)
    });
    match result {
        Ok(id) => (ok(), id).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn unregister_wal_hook(env: Env<'_>, handle: ResourceArc<XqliteConn>, id: u64) -> Term<'_> {
    let result = connection::with_conn(&handle, |_conn| {
        crate::wal_hook::unregister(&handle.wal_hook, id);
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

// ---------------------------------------------------------------------------
// Progress hook NIFs (multi-subscriber on the progress_dispatch slot)
// ---------------------------------------------------------------------------

#[rustler::nif]
fn register_progress_hook(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    pid: rustler::LocalPid,
    every_n: u32,
    tag: Option<String>,
) -> Term<'_> {
    if every_n == 0 {
        let err = XqliteError::CannotExecute(
            "register_progress_hook: every_n must be >= 1".to_string(),
        );
        return (error(), err).encode(env);
    }

    let result = connection::with_conn(&handle, |_conn| {
        let tag_bytes = tag.map(|s| s.into_bytes());
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

#[rustler::nif]
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

// ---------------------------------------------------------------------------
// Serialize / Deserialize NIFs
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyIo")]
fn serialize<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    schema: String,
) -> Result<rustler::Binary<'a>, XqliteError> {
    connection::with_conn(&handle, |conn| {
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
    schema: String,
    data: rustler::Binary<'a>,
    read_only: bool,
) -> Term<'a> {
    let result = connection::with_conn_mut(&handle, |conn| {
        let bytes = data.as_slice();
        let cursor = Cursor::new(bytes);
        conn.deserialize_read_exact(schema.as_str(), cursor, bytes.len(), read_only)?;
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

// ---------------------------------------------------------------------------
// Extension Loading NIFs
// ---------------------------------------------------------------------------

#[rustler::nif]
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
    path: String,
    entry_point: Option<String>,
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

// ---------------------------------------------------------------------------
// Online Backup NIFs
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyIo")]
fn backup<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    schema: String,
    dest_path: String,
) -> Term<'a> {
    let result = connection::with_conn(&handle, |conn| {
        conn.backup(schema.as_str(), dest_path.as_str(), None)?;
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn restore<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    schema: String,
    src_path: String,
) -> Term<'a> {
    let result = connection::with_conn_mut(&handle, |conn| {
        conn.restore(
            schema.as_str(),
            src_path.as_str(),
            None::<fn(rusqlite::backup::Progress)>,
        )?;
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn backup_with_progress<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    schema: String,
    dest_path: String,
    pid: rustler::types::LocalPid,
    pages_per_step: i32,
    cancel_tokens: Vec<ResourceArc<XqliteCancelToken>>,
) -> Term<'a> {
    let result = connection::with_conn(&handle, |conn| {
        let mut dst = rusqlite::Connection::open(dest_path.as_str())?;
        let backup =
            rusqlite::backup::Backup::new_with_names(conn, schema.as_str(), &mut dst, "main")?;

        loop {
            // OR-semantics: any signalled token cancels the backup.
            let cancelled = cancel_tokens.iter().any(|t| t.0.load(Ordering::Acquire));
            if cancelled {
                return Err(XqliteError::OperationCancelled);
            }

            let step_result = backup.step(pages_per_step)?;
            let progress = backup.progress();

            // SAFETY: enif_send with NULL caller_env is valid from dirty
            // scheduler threads (OTP 26.1+). All data is copied into msg_env.
            unsafe {
                send_backup_progress(&pid, progress.remaining, progress.pagecount);
            }

            match step_result {
                rusqlite::backup::StepResult::Done => return Ok(()),
                rusqlite::backup::StepResult::More => continue,
                rusqlite::backup::StepResult::Busy | rusqlite::backup::StepResult::Locked => {
                    std::thread::sleep(std::time::Duration::from_millis(100));
                    continue;
                }
                _ => continue,
            }
        }
    });
    singular_ok_or_error_tuple(env, result)
}

/// Send `{:xqlite_backup_progress, remaining, pagecount}` to `pid`.
///
/// # Safety
///
/// Must be called from a dirty scheduler thread. Uses `enif_send` with
/// NULL caller_env, valid since OTP 26.1.
unsafe fn send_backup_progress(
    pid: &rustler::types::LocalPid,
    remaining: std::ffi::c_int,
    pagecount: std::ffi::c_int,
) {
    use rustler::sys::{
        enif_alloc_env, enif_free_env, enif_make_atom_len, enif_make_int64,
        enif_make_tuple_from_array, enif_send,
    };

    // SAFETY: All enif_* calls operate on a freshly allocated msg_env.
    unsafe {
        let msg_env = enif_alloc_env();

        let tag = enif_make_atom_len(
            msg_env,
            b"xqlite_backup_progress".as_ptr().cast(),
            b"xqlite_backup_progress".len(),
        );
        let remaining_term = enif_make_int64(msg_env, remaining as i64);
        let pagecount_term = enif_make_int64(msg_env, pagecount as i64);

        let elements = [tag, remaining_term, pagecount_term];
        let tuple = enif_make_tuple_from_array(msg_env, elements.as_ptr(), 3);

        let sent = enif_send(std::ptr::null_mut(), pid.as_c_arg(), msg_env, tuple);

        if sent == 0 {
            enif_free_env(msg_env);
        }
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

// ---------------------------------------------------------------------------
// Session Extension NIFs
// ---------------------------------------------------------------------------

#[rustler::nif]
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

#[rustler::nif]
fn session_attach<'a>(
    env: Env<'a>,
    session_handle: ResourceArc<XqliteSession>,
    table: Option<String>,
) -> Term<'a> {
    let result = session::with_session_mut(&session_handle, |s| {
        match &table {
            Some(name) => s.attach(Some(name.as_str()))?,
            None => s.attach(None::<&str>)?,
        }
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif]
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

#[rustler::nif]
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

#[rustler::nif]
fn session_is_empty(session_handle: ResourceArc<XqliteSession>) -> Result<bool, XqliteError> {
    session::with_session(&session_handle, |s| Ok(s.is_empty()))
}

#[rustler::nif]
fn session_delete<'a>(env: Env<'a>, session_handle: ResourceArc<XqliteSession>) -> Term<'a> {
    let result = (|| -> Result<(), XqliteError> {
        let mut guard = session_handle
            .session
            .lock()
            .map_err(|e| XqliteError::LockError(e.to_string()))?;
        guard.take();
        Ok(())
    })();
    singular_ok_or_error_tuple(env, result)
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
        return (atoms::error(), atoms::invalid_conflict_strategy()).encode(env);
    };

    let result = connection::with_conn(&handle, |conn| {
        let bytes = changeset_binary.as_slice();
        let mut cursor = Cursor::new(bytes);
        let strategy_code = strategy as i32;
        conn.apply_strm(
            &mut cursor,
            None::<fn(&str) -> bool>,
            move |_conflict_type, _item| match strategy_code {
                x if x == ConflictAction::SQLITE_CHANGESET_REPLACE as i32 => {
                    ConflictAction::SQLITE_CHANGESET_REPLACE
                }
                x if x == ConflictAction::SQLITE_CHANGESET_ABORT as i32 => {
                    ConflictAction::SQLITE_CHANGESET_ABORT
                }
                _ => ConflictAction::SQLITE_CHANGESET_OMIT,
            },
        )?;
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif]
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

#[rustler::nif]
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

// ---------------------------------------------------------------------------
// Incremental Blob I/O NIFs
// ---------------------------------------------------------------------------

#[rustler::nif]
fn blob_open<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    db: String,
    table: String,
    column: String,
    row_id: i64,
    read_only: bool,
) -> Term<'a> {
    let result = connection::with_conn(&handle, |conn| {
        let b = conn.blob_open(
            db.as_str(),
            table.as_str(),
            column.as_str(),
            row_id,
            read_only,
        )?;
        // SAFETY: We erase the connection lifetime. This is safe because
        // conn_resource_arc (stored in XqliteBlob) prevents the connection
        // from being dropped while the blob handle exists.
        let static_blob: rusqlite::blob::Blob<'static> = unsafe { std::mem::transmute(b) };
        Ok(ResourceArc::new(XqliteBlob {
            blob: std::sync::Mutex::new(Some(static_blob)),
            conn_resource_arc: handle.clone(),
        }))
    });
    match result {
        Ok(resource) => (ok(), resource).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif]
fn blob_read<'a>(
    env: Env<'a>,
    blob_handle: ResourceArc<XqliteBlob>,
    offset: usize,
    length: usize,
) -> Term<'a> {
    let result = blob::with_blob(&blob_handle, |b| {
        let blob_size = b.len();
        if offset >= blob_size {
            return Ok(rustler::OwnedBinary::new(0).unwrap());
        }
        let actual_len = std::cmp::min(length, blob_size - offset);
        let mut buf = vec![0u8; actual_len];
        b.read_at_exact(&mut buf, offset)?;
        session::to_owned_binary(&buf, "blob read")
    });
    match result {
        Ok(binary) => (ok(), binary.release(env)).encode(env),
        Err(err) => (error(), err).encode(env),
    }
}

#[rustler::nif]
fn blob_write<'a>(
    env: Env<'a>,
    blob_handle: ResourceArc<XqliteBlob>,
    offset: usize,
    data: rustler::Binary<'a>,
) -> Term<'a> {
    let result = blob::with_blob_mut(&blob_handle, |b| {
        b.write_all_at(data.as_slice(), offset)?;
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif]
fn blob_size(blob_handle: ResourceArc<XqliteBlob>) -> Result<usize, XqliteError> {
    blob::with_blob(&blob_handle, |b| Ok(b.len()))
}

#[rustler::nif]
fn blob_reopen<'a>(
    env: Env<'a>,
    blob_handle: ResourceArc<XqliteBlob>,
    row_id: i64,
) -> Term<'a> {
    let result = blob::with_blob_mut(&blob_handle, |b| {
        b.reopen(row_id)?;
        Ok(())
    });
    singular_ok_or_error_tuple(env, result)
}

#[rustler::nif]
fn blob_close<'a>(env: Env<'a>, blob_handle: ResourceArc<XqliteBlob>) -> Term<'a> {
    let result = (|| -> Result<(), XqliteError> {
        let mut guard = blob_handle
            .blob
            .lock()
            .map_err(|e| XqliteError::LockError(e.to_string()))?;
        // Drop the blob (its Drop impl calls sqlite3_blob_close)
        guard.take();
        Ok(())
    })();
    singular_ok_or_error_tuple(env, result)
}
