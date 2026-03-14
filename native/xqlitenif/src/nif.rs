use crate::atoms;
use crate::cancel::XqliteCancelToken;
use crate::connection::{self, XqliteConn, XqliteQueryResult};
use crate::error::XqliteError;
use crate::pragma;
use crate::query;
use crate::schema::{
    ColumnInfo, DatabaseInfo, ForeignKeyInfo, IndexColumnInfo, IndexInfo, SchemaObjectInfo,
};
use crate::stream::XqliteStream;
use crate::transaction;
use crate::util::singular_ok_or_error_tuple;
use rusqlite::Connection;
use rusqlite::ffi;
use rustler::{
    Encoder, Env, ResourceArc, Term, TermType,
    types::{
        atom::{error, ok},
        map::map_new,
    },
};
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
        query::core_query(env, conn, &sql, params_term, None)
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
        query::core_execute(env, conn, &sql, params_term, None)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute_batch(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    sql_batch: String,
) -> Term<'_> {
    let execution_result = connection::with_conn(&handle, |conn| {
        query::core_execute_batch(conn, &sql_batch, None)
    });
    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn query_cancellable<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: String,
    params_term: Term<'a>,
    token: ResourceArc<XqliteCancelToken>,
) -> Result<XqliteQueryResult<'a>, XqliteError> {
    let token_bool = token.0.clone();
    connection::with_conn(&handle, |conn| {
        query::core_query(env, conn, &sql, params_term, Some(token_bool))
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute_cancellable<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: String,
    params_term: Term<'a>,
    token: ResourceArc<XqliteCancelToken>,
) -> Result<usize, XqliteError> {
    let token_bool = token.0.clone();
    connection::with_conn(&handle, |conn| {
        query::core_execute(env, conn, &sql, params_term, Some(token_bool))
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute_batch_cancellable(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    sql_batch: String,
    token: ResourceArc<XqliteCancelToken>,
) -> Term<'_> {
    let token_bool = token.0.clone();
    let execution_result = connection::with_conn(&handle, |conn| {
        query::core_execute_batch(conn, &sql_batch, Some(token_bool))
    });
    singular_ok_or_error_tuple(env, execution_result)
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
