use crate::cancel::{ProgressHandlerGuard, XqliteCancelToken};
use crate::error::{SchemaErrorDetail, XqliteError};
use crate::schema::{
    fk_action_to_atom, fk_match_to_atom, hidden_int_to_atom, index_origin_to_atom,
    notnull_to_nullable, object_type_to_atom, pk_value_to_index, sort_order_to_atom,
    type_affinity_to_atom, ColumnInfo, DatabaseInfo, ForeignKeyInfo, IndexColumnInfo,
    IndexInfo, SchemaObjectInfo,
};
use crate::stream::{
    bind_named_params_ffi, bind_positional_params_ffi, process_single_step, XqliteStream,
};
use crate::util::{
    decode_exec_keyword_params, decode_plain_list_params, encode_val, format_term_for_pragma,
    is_keyword, process_rows, quote_identifier, quote_savepoint_name,
    singular_ok_or_error_tuple, term_to_tagged_elixir_value, with_conn,
};
use crate::{columns, done, invalid_batch_size, no_value, num_rows, rows};
use rusqlite::ffi;
use rusqlite::{types::Value, Connection, Error as RusqliteError, ToSql};
use rustler::{
    resource_impl,
    types::{
        atom::{error, nil, ok},
        map::map_new,
    },
    Atom, Encoder, Env, Resource, ResourceArc, Term, TermType,
};
use std::convert::TryFrom;
use std::ptr::NonNull;
use std::sync::atomic::AtomicBool;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Debug)]
pub(crate) struct XqliteConn(pub(crate) Arc<Mutex<Connection>>);
#[resource_impl]
impl Resource for XqliteConn {}

#[derive(Debug)]
pub(crate) struct XqliteQueryResult<'a> {
    pub(crate) columns: Vec<String>,
    pub(crate) rows: Vec<Vec<Term<'a>>>,
    pub(crate) num_rows: usize,
}

impl Encoder for XqliteQueryResult<'_> {
    fn encode<'b>(&self, env: Env<'b>) -> Term<'b> {
        let map_value_result: Result<Term, String> = Ok(map_new(env))
            .and_then(|map| {
                map.map_put(columns(), self.columns.encode(env))
                    .map_err(|_| "Failed to insert :columns key".to_string())
            })
            .and_then(|map| {
                map.map_put(rows(), self.rows.encode(env))
                    .map_err(|_| "Failed to insert :rows key".to_string())
            })
            .and_then(|map| {
                map.map_put(num_rows(), self.num_rows.encode(env))
                    .map_err(|_| "Failed to insert :num_rows key".to_string())
            });

        match map_value_result {
            Ok(final_map) => final_map,
            Err(context) => {
                let err = XqliteError::InternalEncodingError { context };
                (error(), err).encode(env)
            }
        }
    }
}

/// Temporary struct for holding intermediate results during object list parsing.
#[derive(Debug)]
struct TempObjectInfo {
    schema: String,
    name: String,
    obj_type_atom: Result<Atom, String>,
    column_count: i64,
    wr_flag: i64,
    strict_flag: i64,
}

/// Temporary struct for holding intermediate results during column info parsing.
#[derive(Debug)]
struct TempColumnData {
    cid: i64,
    name: String,
    type_str: String,
    notnull_flag: i64,
    dflt_value: Option<String>,
    pk_flag: i64,
    hidden: i64,
}

/// Temporary struct for holding intermediate results during foreign key parsing.
#[derive(Debug)]
struct TempForeignKeyData {
    id: i64,
    seq: i64,
    table: String,
    from: String,
    to: String,
    on_update_str: String,
    on_delete_str: String,
    match_str: String,
}

/// Temporary struct for holding intermediate results during index list parsing.
#[derive(Debug)]
struct TempIndexData {
    // seq: i64,
    name: String,
    unique: i64,
    origin_str: String,
    partial: i64,
}

/// Temporary struct for holding intermediate results during index column parsing.
#[derive(Debug)]
struct TempIndexColumnData {
    seqno: i64,
    cid: i64,             // Column ID in table, often -1 for expressions
    name: Option<String>, // Name is NULL for expressions
    desc: i64,            // Sort order: 0=ASC, 1=DESC
    coll: String,         // Collation sequence name
    key: i64,             // Key column (1) or included column (0)
}

fn core_query<'a>(
    env: Env<'a>,
    conn: &Connection,
    sql: &str,
    params_term: Term<'a>,
    token_bool_opt: Option<Arc<AtomicBool>>,
) -> Result<XqliteQueryResult<'a>, XqliteError> {
    let _guard = token_bool_opt
        .map(|token_bool| ProgressHandlerGuard::new(conn, token_bool, 8))
        .transpose()?;

    let mut stmt = conn
        .prepare(sql)
        .map_err(|e| XqliteError::CannotPrepareStatement(sql.to_string(), e.to_string()))?;
    let column_names: Vec<String> =
        stmt.column_names().iter().map(|s| s.to_string()).collect();
    let column_count = column_names.len();

    let rows_result = match params_term.get_type() {
        TermType::List => {
            if is_keyword(params_term) {
                let named_params_vec = decode_exec_keyword_params(env, params_term)?;
                let params_for_rusqlite: Vec<(&str, &dyn ToSql)> = named_params_vec
                    .iter()
                    .map(|(k, v)| (k.as_str(), v as &dyn ToSql))
                    .collect();
                stmt.query(params_for_rusqlite.as_slice())
            } else {
                let positional_values: Vec<Value> =
                    decode_plain_list_params(env, params_term)?;
                let params_slice: Vec<&dyn ToSql> =
                    positional_values.iter().map(|v| v as &dyn ToSql).collect();
                stmt.query(params_slice.as_slice())
            }
        }
        _ if params_term == nil().to_term(env) || params_term.is_empty_list() => {
            stmt.query([])
        }
        _ => {
            return Err(XqliteError::ExpectedList {
                value_str: format!("{:?}", params_term),
            });
        }
    };
    let rows = rows_result?;

    let results_vec = process_rows(env, rows, column_count)?;
    let num_rows = results_vec.len();

    Ok(XqliteQueryResult {
        columns: column_names,
        rows: results_vec,
        num_rows,
    })
}

fn core_execute<'a>(
    env: Env<'a>,
    conn: &Connection,
    sql: &str,
    params_term: Term<'a>,
    token_bool_opt: Option<Arc<AtomicBool>>,
) -> Result<usize, XqliteError> {
    let _guard = token_bool_opt
        .map(|token_bool| ProgressHandlerGuard::new(conn, token_bool, 8))
        .transpose()?;

    let positional_values: Vec<Value> = decode_plain_list_params(env, params_term)?;
    let params_slice: Vec<&dyn ToSql> =
        positional_values.iter().map(|v| v as &dyn ToSql).collect();
    let affected_rows = conn.execute(sql, params_slice.as_slice())?;
    Ok(affected_rows)
}

fn core_execute_batch(
    conn: &Connection,
    sql_batch: &str,
    token_bool_opt: Option<Arc<AtomicBool>>,
) -> Result<(), XqliteError> {
    let _guard = token_bool_opt
        .map(|token_bool| ProgressHandlerGuard::new(conn, token_bool, 8))
        .transpose()?;
    conn.execute_batch(sql_batch)?;
    Ok(())
}

#[rustler::nif(schedule = "DirtyIo")]
fn open(path: String) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let conn = Connection::open(&path)
        .map_err(|e| XqliteError::CannotOpenDatabase(path, e.to_string()))?;
    let arc_mutex_conn = Arc::new(Mutex::new(conn));
    Ok(ResourceArc::new(XqliteConn(arc_mutex_conn)))
}

#[rustler::nif(schedule = "DirtyIo")]
fn open_in_memory(uri: String) -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let conn = Connection::open(&uri)
        .map_err(|e| XqliteError::CannotOpenDatabase(uri, e.to_string()))?;
    let arc_mutex_conn = Arc::new(Mutex::new(conn));
    Ok(ResourceArc::new(XqliteConn(arc_mutex_conn)))
}

#[rustler::nif(schedule = "DirtyIo")]
fn open_temporary() -> Result<ResourceArc<XqliteConn>, XqliteError> {
    let conn = Connection::open("")
        .map_err(|e| XqliteError::CannotOpenDatabase("".to_string(), e.to_string()))?;
    let arc_mutex_conn = Arc::new(Mutex::new(conn));
    Ok(ResourceArc::new(XqliteConn(arc_mutex_conn)))
}

#[rustler::nif(schedule = "DirtyIo")]
fn query<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: String,
    params_term: Term<'a>,
) -> Result<XqliteQueryResult<'a>, XqliteError> {
    with_conn(&handle, |conn| {
        core_query(env, conn, &sql, params_term, None)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    sql: String,
    params_term: Term<'a>,
) -> Result<usize, XqliteError> {
    with_conn(&handle, |conn| {
        core_execute(env, conn, &sql, params_term, None)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute_batch(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    sql_batch: String,
) -> Term<'_> {
    let execution_result =
        with_conn(&handle, |conn| core_execute_batch(conn, &sql_batch, None));

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
    with_conn(&handle, |conn| {
        core_query(env, conn, &sql, params_term, Some(token_bool))
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
    with_conn(&handle, |conn| {
        core_execute(env, conn, &sql, params_term, Some(token_bool))
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
    let execution_result = with_conn(&handle, |conn| {
        core_execute_batch(conn, &sql_batch, Some(token_bool))
    });

    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif]
fn create_cancel_token() -> Result<ResourceArc<XqliteCancelToken>, XqliteError> {
    Ok(ResourceArc::new(XqliteCancelToken::new()))
}

#[rustler::nif]
fn cancel_operation(env: Env<'_>, token: ResourceArc<XqliteCancelToken>) -> Term<'_> {
    token.cancel();
    ok().encode(env)
}

/// Reads the current value of an SQLite PRAGMA.
#[rustler::nif(schedule = "DirtyIo")]
fn get_pragma(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    pragma_name: String,
) -> Result<Term<'_>, XqliteError> {
    with_conn(&handle, |conn| {
        let read_sql = format!("PRAGMA {};", pragma_name);
        match conn.query_row(&read_sql, [], |row| row.get::<usize, Value>(0)) {
            Ok(value) => Ok(encode_val(env, value)),
            Err(RusqliteError::QueryReturnedNoRows) => Ok(no_value().to_term(env)),
            Err(e) => Err(XqliteError::CannotExecutePragma {
                pragma: read_sql,
                reason: e.to_string(),
            }),
        }
    })
}

/// Sets an SQLite PRAGMA to a specific value.
/// Returns {:ok, true} on success, or {:error, reason} on failure.
/// Does NOT return the new value; call get_pragma separately if needed for verification.
#[rustler::nif(schedule = "DirtyIo")]
fn set_pragma<'a>(
    env: Env<'a>,
    handle: ResourceArc<XqliteConn>,
    pragma_name: String,
    value_term: Term<'a>,
) -> Term<'a> {
    let execution_result: Result<(), XqliteError> = (|| {
        let value_literal = format_term_for_pragma(env, value_term)?;

        with_conn(&handle, |conn| {
            let write_sql = format!("PRAGMA {} = {};", pragma_name, value_literal);
            // The block for executing the PRAGMA and consuming potential results remains.
            // rusqlite's `execute` is for non-query statements, but PRAGMA assignments
            // can sometimes return a row (e.g., the new value).
            // Using prepare/query here is safer if the PRAGMA might return something,
            // even if we discard the result.
            {
                let mut write_stmt = conn.prepare(&write_sql).map_err(|e| {
                    XqliteError::CannotExecutePragma {
                        pragma: write_sql.clone(),
                        reason: e.to_string(),
                    }
                })?;
                // Consume any potential rows returned by the PRAGMA statement.
                // Some PRAGMAs when set (e.g. journal_mode) can return the new value.
                // We don't use this returned value for the :ok contract of set_pragma,
                // but we should consume it to properly finalize the statement.
                let mut rows = write_stmt.query([])?;
                if let Some(row_result) = rows.next()? {
                    // We don't need the value, but calling .get() ensures the row is processed.
                    let _value_from_pragma_set: Value = row_result.get(0)?;
                }
            }
            Ok(())
        })
    })();

    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn begin(env: Env<'_>, handle: ResourceArc<XqliteConn>) -> Term<'_> {
    let execution_result = with_conn(&handle, |conn| {
        // conn.execute() returns Result<usize, rusqlite::Error>
        // We want Result<(), XqliteError> for the helper.
        // So, map Ok(usize) to Ok(()), and map Err to XqliteError.
        conn.execute("BEGIN;", [])
            .map(|_affected_rows| ()) // Discard affected_rows, map to Ok(())
            .map_err(XqliteError::from)
    });

    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn commit(env: Env<'_>, handle: ResourceArc<XqliteConn>) -> Term<'_> {
    let execution_result = with_conn(&handle, |conn| {
        conn.execute("COMMIT;", [])
            .map(|_affected_rows| ()) // Discard affected_rows, map to Ok(())
            .map_err(XqliteError::from)
    });

    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn rollback(env: Env<'_>, handle: ResourceArc<XqliteConn>) -> Term<'_> {
    let execution_result = with_conn(&handle, |conn| {
        conn.execute("ROLLBACK;", [])
            .map(|_affected_rows| ())
            .map_err(XqliteError::from)
    });

    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn savepoint(env: Env<'_>, handle: ResourceArc<XqliteConn>, name: String) -> Term<'_> {
    let execution_result = with_conn(&handle, |conn| {
        let quoted_name = quote_savepoint_name(&name);
        let sql = format!("SAVEPOINT {};", quoted_name);
        conn.execute(&sql, [])
            .map(|_affected_rows| ())
            .map_err(XqliteError::from)
    });

    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn rollback_to_savepoint(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    name: String,
) -> Term<'_> {
    let execution_result = with_conn(&handle, |conn| {
        let quoted_name = quote_savepoint_name(&name);
        let sql = format!("ROLLBACK TO SAVEPOINT {};", quoted_name);
        conn.execute(&sql, [])
            .map(|_affected_rows| ())
            .map_err(XqliteError::from)
    });

    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn release_savepoint(env: Env<'_>, handle: ResourceArc<XqliteConn>, name: String) -> Term<'_> {
    let execution_result = with_conn(&handle, |conn| {
        let quoted_name = quote_savepoint_name(&name);
        let sql = format!("RELEASE SAVEPOINT {};", quoted_name);
        conn.execute(&sql, [])
            .map(|_affected_rows| ())
            .map_err(XqliteError::from)
    });

    singular_ok_or_error_tuple(env, execution_result)
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_databases(
    handle: ResourceArc<XqliteConn>,
) -> Result<Vec<DatabaseInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        let mut stmt = conn.prepare("PRAGMA database_list;")?;
        let db_infos: Vec<DatabaseInfo> = stmt
            .query_map([], |row| {
                Ok(DatabaseInfo {
                    name: row.get(1)?,
                    file: row.get(2)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(db_infos)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_list_objects(
    handle: ResourceArc<XqliteConn>,
    schema: Option<String>,
) -> Result<Vec<SchemaObjectInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        let sql = "PRAGMA table_list;";
        let mut stmt = conn.prepare(sql)?;

        // Step 1: Query and map, returning Vec<Result<TempObjectInfo, rusqlite::Error>>
        let temp_results: Vec<Result<TempObjectInfo, rusqlite::Error>> = stmt
            .query_map([], |row| {
                Ok(TempObjectInfo {
                    schema: row.get(0)?,
                    name: row.get(1)?,
                    obj_type_atom: object_type_to_atom(&row.get::<_, String>(2)?)
                        .map_err(|s| s.to_string()),
                    column_count: row.get(3)?,
                    wr_flag: row.get(4)?,
                    strict_flag: row.get(5)?,
                })
            })?
            .collect();

        // Step 2: Process results, apply filter, and map errors
        let mut final_objects: Vec<SchemaObjectInfo> = Vec::new();
        for temp_result in temp_results {
            match temp_result {
                Ok(temp_info) => {
                    if let Some(filter_schema) = &schema {
                        if temp_info.schema != *filter_schema {
                            continue;
                        }
                    }

                    let schema_name_for_error = temp_info.schema.clone();
                    let object_name_for_error = temp_info.name.clone();
                    let atom = temp_info.obj_type_atom.map_err(|unexpected_val| {
                        XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing object type for '{}'.'{}'",
                                schema_name_for_error,
                                object_name_for_error // Use the extracted values
                            ),
                            error_detail: SchemaErrorDetail::UnexpectedValue(unexpected_val),
                        }
                    })?;
                    let is_writable = match temp_info.wr_flag {
                        0 => false,
                        1 => true,
                        _ => {
                            return Err(XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'wr' flag for object '{}'.'{}'",
                                    temp_info.schema, temp_info.name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    temp_info.wr_flag.to_string(),
                                ),
                            })
                        }
                    };

                    let is_strict = match temp_info.strict_flag {
                        0 => false,
                        1 => true,
                        _ => {
                            return Err(XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'strict' flag for object '{}'.'{}'",
                                    temp_info.schema, temp_info.name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    temp_info.strict_flag.to_string(),
                                ),
                            })
                        }
                    };

                    final_objects.push(SchemaObjectInfo {
                        schema: temp_info.schema,
                        name: temp_info.name,
                        object_type: atom,
                        column_count: temp_info.column_count,
                        is_writable,
                        strict: is_strict,
                    });
                }
                Err(rusqlite_err) => {
                    return Err(rusqlite_err.into());
                }
            }
        }
        Ok(final_objects)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_columns(
    handle: ResourceArc<XqliteConn>,
    table_name: String,
) -> Result<Vec<ColumnInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        let quoted_table_name = quote_identifier(&table_name);
        // Using PRAGMA table_xinfo as it provides the 'hidden' column
        let sql = format!("PRAGMA table_xinfo({});", quoted_table_name);
        let mut stmt = conn.prepare(&sql)?;

        // Step 1: Query and map raw data from PRAGMA table_xinfo
        let temp_results: Vec<Result<TempColumnData, rusqlite::Error>> = stmt
            .query_map([], |row| {
                // PRAGMA table_xinfo columns:
                // cid(0), name(1), type(2), notnull(3), dflt_value(4), pk(5), hidden(6)
                Ok(TempColumnData {
                    cid: row.get(0)?,
                    name: row.get(1)?,
                    type_str: row.get(2)?, // This is the declared column type string
                    notnull_flag: row.get(3)?,
                    dflt_value: row.get(4)?, // Will be None for generated columns from this PRAGMA
                    pk_flag: row.get(5)?,
                    hidden: row.get(6)?, // Value indicating if/how column is hidden/generated
                })
            })?
            .collect();

        // Step 2: Process results, validate/convert, and map to the Elixir-facing ColumnInfo struct
        let mut final_columns: Vec<ColumnInfo> = Vec::with_capacity(temp_results.len());
        for temp_result in temp_results {
            match temp_result {
                Ok(temp_data) => {
                    let type_affinity_atom = type_affinity_to_atom(&temp_data.type_str)
                        .map_err(|unexpected_val| XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing type affinity for column '{}' in table '{}'",
                                temp_data.name, table_name
                            ),
                            error_detail: SchemaErrorDetail::UnexpectedValue(
                                unexpected_val.to_string(), // Pass the problematic string
                            ),
                        })?;

                    // Convert 'notnull' flag (0/1) to boolean 'nullable'
                    let nullable = notnull_to_nullable(temp_data.notnull_flag).map_err(
                        |unexpected_val| XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'notnull' flag for column '{}' in table '{}'",
                                temp_data.name, table_name
                            ),
                            error_detail: SchemaErrorDetail::UnexpectedValue(unexpected_val),
                        },
                    )?;

                    // Convert 'pk' flag (0 or 1-based index) to u8
                    let primary_key_index =
                        pk_value_to_index(temp_data.pk_flag).map_err(|unexpected_val| {
                            XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'pk' flag for column '{}' in table '{}'",
                                    temp_data.name, table_name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    unexpected_val,
                                ),
                            }
                        })?;

                    // Convert the integer 'hidden' value to a descriptive atom
                    let hidden_kind_atom =
                        hidden_int_to_atom(temp_data.hidden).map_err(|unexpected_val| {
                            XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'hidden' kind for column '{}' in table '{}'",
                                    temp_data.name, table_name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    unexpected_val,
                                ),
                            }
                        })?;

                    final_columns.push(ColumnInfo {
                        column_id: temp_data.cid,
                        name: temp_data.name,
                        type_affinity: type_affinity_atom,
                        declared_type: temp_data.type_str, // Store the original declared type
                        nullable,
                        default_value: temp_data.dflt_value, // Still None for generated cols from this PRAGMA
                        primary_key_index,
                        hidden_kind: hidden_kind_atom, // Set the new field
                    });
                }
                Err(rusqlite_err) => {
                    // Propagate errors from the .get() calls within query_map
                    return Err(rusqlite_err.into());
                }
            }
        }
        Ok(final_columns)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_foreign_keys(
    handle: ResourceArc<XqliteConn>,
    table_name: String,
) -> Result<Vec<ForeignKeyInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        let quoted_table_name = quote_identifier(&table_name);
        let sql = format!("PRAGMA foreign_key_list({});", quoted_table_name);
        let mut stmt = conn.prepare(&sql)?;

        // Step 1: Query and map raw data
        let temp_results: Vec<Result<TempForeignKeyData, rusqlite::Error>> = stmt
            .query_map([], |row| {
                Ok(TempForeignKeyData {
                    id: row.get(0)?,
                    seq: row.get(1)?,
                    table: row.get(2)?,
                    from: row.get(3)?,
                    to: row.get(4)?,
                    on_update_str: row.get(5)?,
                    on_delete_str: row.get(6)?,
                    match_str: row.get(7)?,
                })
            })?
            .collect();

        // Step 2: Process results, convert strings to atoms, map errors
        let mut final_fks: Vec<ForeignKeyInfo> = Vec::with_capacity(temp_results.len());
        for temp_result in temp_results {
            match temp_result {
                Ok(temp_data) => {
                    let on_update_atom = fk_action_to_atom(&temp_data.on_update_str).map_err(
                        |unexpected_val| XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'on_update' action for FK id {} on table '{}'",
                                temp_data.id, table_name
                            ),
                            error_detail: SchemaErrorDetail::UnexpectedValue(
                                unexpected_val.to_string(),
                            ),
                        },
                    )?;

                    let on_delete_atom = fk_action_to_atom(&temp_data.on_delete_str).map_err(
                        |unexpected_val| XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'on_delete' action for FK id {} on table '{}'",
                                temp_data.id, table_name
                            ),
                            error_detail: SchemaErrorDetail::UnexpectedValue(
                                unexpected_val.to_string(),
                            ),
                        },
                    )?;

                    let match_clause_atom =
                        fk_match_to_atom(&temp_data.match_str).map_err(|unexpected_val| {
                            XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'match' clause for FK id {} on table '{}'",
                                    temp_data.id, table_name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    unexpected_val.to_string(),
                                ),
                            }
                        })?;

                    final_fks.push(ForeignKeyInfo {
                        id: temp_data.id,
                        column_sequence: temp_data.seq,
                        target_table: temp_data.table,
                        from_column: temp_data.from,
                        to_column: temp_data.to,
                        on_update: on_update_atom,
                        on_delete: on_delete_atom,
                        match_clause: match_clause_atom,
                    });
                }
                Err(rusqlite_err) => {
                    return Err(rusqlite_err.into());
                }
            }
        }
        Ok(final_fks)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_indexes(
    handle: ResourceArc<XqliteConn>,
    table_name: String,
) -> Result<Vec<IndexInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        let quoted_table_name = quote_identifier(&table_name);
        let sql = format!("PRAGMA index_list({});", quoted_table_name);
        let mut stmt = conn.prepare(&sql)?;

        // Step 1: Query and map raw data
        let temp_results: Vec<Result<TempIndexData, rusqlite::Error>> = stmt
            .query_map([], |row| {
                Ok(TempIndexData {
                    name: row.get(1)?,
                    unique: row.get(2)?,
                    origin_str: row.get(3)?,
                    partial: row.get(4)?,
                })
            })?
            .collect();

        // Step 2: Process results, convert values, map errors
        let mut final_indexes: Vec<IndexInfo> = Vec::with_capacity(temp_results.len());
        for temp_result in temp_results {
            match temp_result {
                Ok(temp_data) => {
                    let origin_atom = index_origin_to_atom(&temp_data.origin_str).map_err(
                        |unexpected_val| XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'origin' for index '{}' on table '{}'",
                                temp_data.name, table_name
                            ),
                            error_detail: SchemaErrorDetail::UnexpectedValue(
                                unexpected_val.to_string(),
                            ),
                        },
                    )?;

                    let unique_bool = match temp_data.unique {
                        0 => false,
                        1 => true,
                        _ => {
                            return Err(XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'unique' flag for index '{}' on table '{}'",
                                    temp_data.name, table_name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    temp_data.unique.to_string(),
                                ),
                            })
                        }
                    };
                    let partial_bool = match temp_data.partial {
                        0 => false,
                        1 => true,
                        _ => {
                            return Err(XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'partial' flag for index '{}' on table '{}'",
                                    temp_data.name, table_name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    temp_data.partial.to_string(),
                                ),
                            })
                        }
                    };

                    final_indexes.push(IndexInfo {
                        name: temp_data.name,
                        unique: unique_bool,
                        origin: origin_atom,
                        partial: partial_bool,
                    });
                }
                Err(rusqlite_err) => {
                    return Err(rusqlite_err.into());
                }
            }
        }

        Ok(final_indexes)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_index_columns(
    handle: ResourceArc<XqliteConn>,
    index_name: String,
) -> Result<Vec<IndexColumnInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        let quoted_index_name = quote_identifier(&index_name);
        let sql = format!("PRAGMA index_xinfo({});", quoted_index_name);
        let mut stmt = conn.prepare(&sql)?;

        // Step 1: Query and map raw data
        let temp_results: Vec<Result<TempIndexColumnData, rusqlite::Error>> = stmt
            .query_map([], |row| {
                Ok(TempIndexColumnData {
                    seqno: row.get(0)?,
                    cid: row.get(1)?,
                    name: row.get(2)?,
                    desc: row.get(3)?,
                    coll: row.get(4)?,
                    key: row.get(5)?,
                })
            })?
            .collect();

        // Step 2: Process results, convert values, map errors
        let mut final_cols: Vec<IndexColumnInfo> = Vec::with_capacity(temp_results.len());
        for temp_result in temp_results {
            match temp_result {
                Ok(temp_data) => {
                    let sort_order_atom =
                        sort_order_to_atom(temp_data.desc).map_err(|unexpected_val| {
                            XqliteError::SchemaParsingError {
                                context: format!(
                                "Parsing sort order ('desc') for column seq {} in index '{}'",
                                temp_data.seqno, index_name
                            ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    unexpected_val,
                                ),
                            }
                        })?;

                    let is_key_bool = match temp_data.key {
                        0 => false,
                        1 => true,
                        _ => {
                            return Err(XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing 'key' flag for column seq {} in index '{}'",
                                    temp_data.seqno, index_name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    temp_data.key.to_string(),
                                ),
                            })
                        }
                    };

                    final_cols.push(IndexColumnInfo {
                        index_column_sequence: temp_data.seqno,
                        table_column_id: temp_data.cid,
                        name: temp_data.name,
                        sort_order: sort_order_atom,
                        collation: temp_data.coll,
                        is_key_column: is_key_bool,
                    });
                }
                Err(rusqlite_err) => {
                    return Err(rusqlite_err.into());
                }
            }
        }

        Ok(final_cols)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn get_create_sql(
    handle: ResourceArc<XqliteConn>,
    object_name: String,
) -> Result<Option<String>, XqliteError> {
    with_conn(&handle, |conn| {
        let sql = "SELECT sql FROM sqlite_schema WHERE name = ?1 LIMIT 1;";
        let mut stmt = conn.prepare(sql)?;
        let result = stmt.query_row([&object_name], |row| row.get::<usize, Option<String>>(0));

        match result {
            Ok(sql_string_option) => Ok(sql_string_option),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e.into()),
        }
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn last_insert_rowid(handle: ResourceArc<XqliteConn>) -> Result<i64, XqliteError> {
    with_conn(&handle, |conn| Ok(conn.last_insert_rowid()))
}

#[rustler::nif(schedule = "DirtyIo")]
pub(crate) fn stream_open<'a>(
    env: Env<'a>,
    conn_handle: ResourceArc<XqliteConn>,
    sql: String,
    params_term: Term<'a>,
    _opts_term: Term<'a>, // Opts not used initially
) -> Result<ResourceArc<XqliteStream>, XqliteError> {
    let conn_resource_arc_clone = conn_handle.clone();

    with_conn(&conn_handle, |conn| {
        // This entire block performs FFI calls and needs to be unsafe
        unsafe {
            let db_handle = conn.handle();
            let mut raw_stmt_ptr: *mut ffi::sqlite3_stmt = std::ptr::null_mut();
            let c_sql = std::ffi::CString::new(sql.as_str())
                .map_err(|_| XqliteError::NulErrorInString)?;

            let prepare_rc = ffi::sqlite3_prepare_v2(
                db_handle,
                c_sql.as_ptr(),
                c_sql.as_bytes().len() as std::os::raw::c_int,
                &mut raw_stmt_ptr,
                std::ptr::null_mut(),
            );

            if prepare_rc != ffi::SQLITE_OK {
                let error_message = {
                    let err_msg_ptr = ffi::sqlite3_errmsg(db_handle);
                    if err_msg_ptr.is_null() {
                        format!("SQLite preparation error (code {}) but no message available. SQL: {}", prepare_rc, sql)
                    } else {
                        std::ffi::CStr::from_ptr(err_msg_ptr).to_string_lossy().into_owned()
                    }
                };
                let ffi_err = ffi::Error::new(prepare_rc);
                let rusqlite_err = rusqlite::Error::SqliteFailure(ffi_err, Some(error_message));
                return Err(XqliteError::from(rusqlite_err));
            }

            // If SQL was empty/comments, raw_stmt_ptr will be null.
            // Initialize with a null AtomicPtr, signifying an immediately "done" stream.
            if raw_stmt_ptr.is_null() {
                return Ok(XqliteStream {
                    atomic_raw_stmt: AtomicPtr::new(std::ptr::null_mut()),
                    conn_resource_arc: conn_resource_arc_clone,
                    column_names: Vec::new(),
                    column_count: 0,
                });
            }
            // This unwrap is safe due to the .is_null() check above.
            let non_null_raw_stmt = NonNull::new_unchecked(raw_stmt_ptr);

            // Bind parameters
            let bind_result: Result<(), XqliteError> = match params_term.get_type() {
                TermType::List => {
                    if params_term.is_empty_list() { Ok(()) }
                    else if is_keyword(params_term) {
                        let named_params_vec = decode_exec_keyword_params(env, params_term)?;
                        // Ensure bind_named_params_ffi is correctly imported or defined if it moved from stream.rs
                        bind_named_params_ffi(non_null_raw_stmt.as_ptr(), &named_params_vec, db_handle)
                    } else {
                        let positional_params_vec = decode_plain_list_params(env, params_term)?;
                        // Ensure bind_positional_params_ffi is correctly imported or defined
                        bind_positional_params_ffi(non_null_raw_stmt.as_ptr(), &positional_params_vec, db_handle)
                    }
                }
                _ => Err(XqliteError::ExpectedList {
                    value_str: format!("Parameters term was not a list: {:?}", params_term)
                }),
            };

            if let Err(e) = bind_result {
                ffi::sqlite3_finalize(non_null_raw_stmt.as_ptr());
                return Err(e);
            }

            // Get column names and count
            let column_count = ffi::sqlite3_column_count(non_null_raw_stmt.as_ptr()) as usize;
            let mut column_names = Vec::with_capacity(column_count);

            if column_count > 0 {
                for i in 0..column_count {
                    let name_ptr = ffi::sqlite3_column_name(non_null_raw_stmt.as_ptr(), i as std::os::raw::c_int);
                    if name_ptr.is_null() {
                        ffi::sqlite3_finalize(non_null_raw_stmt.as_ptr());
                        return Err(XqliteError::InternalEncodingError {
                            context: format!("SQLite returned null column name for index {} during stream open", i),
                        });
                    }
                    let name_c_str = std::ffi::CStr::from_ptr(name_ptr);
                    column_names.push(name_c_str.to_string_lossy().into_owned());
                }
            }

            Ok(XqliteStream {
                atomic_raw_stmt: AtomicPtr::new(non_null_raw_stmt.as_ptr()), // Store the prepared stmt_ptr
                conn_resource_arc: conn_resource_arc_clone,
                column_names,
                column_count,
            })
        }
    })
    .map(ResourceArc::new)
}

#[rustler::nif(schedule = "DirtyIo")] // DirtyIo because it reads from a resource that interacts with C
pub(crate) fn stream_get_columns(
    stream_handle: ResourceArc<XqliteStream>,
) -> Result<Vec<String>, XqliteError> {
    // The column_names field is populated during stream_open and is immutable afterwards.
    // `stream_open` guarantees `column_names` is populated (it might be empty if the
    // query yields no columns, e.g., an empty SQL string or a DDL statement,
    // in which case an empty Vec<String> is correctly returned).
    // Accessing it directly is safe as long as stream_handle is a valid resource.
    Ok(stream_handle.column_names.clone())
}

#[rustler::nif(schedule = "DirtyIo")]
pub(crate) fn stream_close<'a>(env: Env<'a>, stream_handle_term: Term<'a>) -> Term<'a> {
    match stream_handle_term.decode::<ResourceArc<XqliteStream>>() {
        Ok(stream_arc) => {
            // Use the method on XqliteStream to handle atomic swap and finalization.
            // Pass Some(&stream_arc.conn_resource_arc) for better error reporting from finalize.
            match stream_arc.take_and_finalize_atomic_stmt() {
                Ok(_) => ok().encode(env),
                Err(xqlite_err) => {
                    // Error from finalization itself
                    (error(), xqlite_err.encode(env)).encode(env)
                }
            }
        }
        Err(decode_err) => {
            let xql_err = XqliteError::InvalidStreamHandle {
                reason: format!("Expected a valid stream handle resource: {:?}", decode_err),
            };
            (error(), xql_err.encode(env)).encode(env)
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
pub(crate) fn stream_fetch<'a>(
    env: Env<'a>,
    stream_handle: ResourceArc<XqliteStream>,
    batch_size_term: Term<'a>,
) -> Term<'a> {
    // Helper lambda (or inline block) to produce the final error term
    let create_and_encode_error = |env_closure: Env<'a>,
                                   final_provided_term: Term<'a>|
     -> Term<'a> {
        match map_new(env_closure)
            .map_put(crate::provided(), final_provided_term)
            .and_then(|map| map.map_put(crate::minimum(), 1_usize.encode(env_closure)))
        {
            Ok(details_map) => {
                (error(), (invalid_batch_size(), details_map)).encode(env_closure)
            }
            Err(_map_create_err) => {
                let xql_err = XqliteError::InternalEncodingError {
                    context: "Failed to create details map for InvalidBatchSize".to_string(),
                };
                // This path uses the generic XqliteError Encoder which produces {:error, {:internal_encoding_error, ...}}
                (error(), xql_err).encode(env_closure)
            }
        }
    };

    // Decode and validate batch size
    let batch_size_i64: i64 = match batch_size_term.decode::<i64>() {
        Ok(val) if val >= 1 => val,
        Ok(val) => {
            // Decoded as i64, but val < 1
            let original_term_as_term = val.encode(env);
            let tagged_provided_term = term_to_tagged_elixir_value(env, original_term_as_term);
            return create_and_encode_error(env, tagged_provided_term);
        }
        Err(_) => {
            // Did not decode as i64
            let tagged_provided_term = term_to_tagged_elixir_value(env, batch_size_term);
            return create_and_encode_error(env, tagged_provided_term);
        }
    };

    let batch_size = match usize::try_from(batch_size_i64) {
        Ok(val) => val,
        Err(_) => {
            let xql_err = XqliteError::InternalEncodingError {
                context: format!(
                    "Failed to convert valid i64 batch_size ({}) to usize",
                    batch_size_i64
                ),
            };
            return (error(), xql_err.encode(env)).encode(env);
        }
    };

    // --- Initial State Check (using atomic_raw_stmt) ---
    let mut current_stmt_ptr = stream_handle.atomic_raw_stmt.load(Ordering::Acquire);
    if current_stmt_ptr.is_null() {
        return done().encode(env);
    }

    // --- Main Fetching Logic ---
    let mut fetched_rows: Vec<Vec<Term<'a>>> = Vec::with_capacity(batch_size);
    let mut an_error_occurred: Option<XqliteError> = None;
    let mut stream_definitively_exhausted = false; // True if SQLITE_DONE or error from helper

    // db_handle is needed for process_single_step's error reporting.
    let db_handle_for_errors = match stream_handle.conn_resource_arc.0.lock() {
        Ok(conn_lock_guard) => unsafe { conn_lock_guard.handle() },
        Err(p_err_conn) => {
            // If we can't get the db_handle, we can't safely call process_single_step.
            // Mark stream as done by nullifying atomic_raw_stmt.
            let old_ptr = stream_handle
                .atomic_raw_stmt
                .swap(std::ptr::null_mut(), Ordering::AcqRel);
            if !old_ptr.is_null() {
                unsafe {
                    ffi::sqlite3_finalize(old_ptr);
                }
            } // Finalize if it wasn't null
            return (
                error(),
                XqliteError::LockError(format!(
                    "XqliteConn Mutex poisoned for db_handle: {:?}",
                    p_err_conn
                ))
                .encode(env),
            )
                .encode(env);
        }
    };

    for _ in 0..batch_size {
        // Re-check pointer before each step in case it was concurrently finalized (e.g., by stream_close)
        current_stmt_ptr = stream_handle.atomic_raw_stmt.load(Ordering::Acquire);
        if current_stmt_ptr.is_null() {
            stream_definitively_exhausted = true; // Another thread/call finalized it
            break;
        }

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
                // SQLITE_DONE signaled by process_single_step
                stream_definitively_exhausted = true;
                let ptr_to_finalize = stream_handle
                    .atomic_raw_stmt
                    .swap(std::ptr::null_mut(), Ordering::AcqRel);
                if !ptr_to_finalize.is_null() {
                    unsafe {
                        ffi::sqlite3_finalize(ptr_to_finalize);
                    }
                }
                break;
            }
            Err(e) => {
                // Error from process_single_step
                stream_definitively_exhausted = true;
                let ptr_to_finalize = stream_handle
                    .atomic_raw_stmt
                    .swap(std::ptr::null_mut(), Ordering::AcqRel);
                if !ptr_to_finalize.is_null() {
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
        return (error(), err.encode(env)).encode(env);
    }

    if !fetched_rows.is_empty() {
        match map_new(env).map_put(rows().encode(env), fetched_rows.encode(env)) {
            Ok(result_map) => (ok(), result_map).encode(env),
            Err(_) => (
                error(),
                XqliteError::InternalEncodingError {
                    context: "map_new fail for fetched rows".into(),
                }
                .encode(env),
            )
                .encode(env),
        }
    } else if stream_definitively_exhausted {
        done().encode(env)
    } else {
        // No rows fetched, and stream did not become definitively exhausted in this call.
        // This means batch_size limit was met before any rows, or query yielded no rows from start.
        match map_new(env).map_put(rows().encode(env), Vec::<Vec<Term<'a>>>::new().encode(env))
        {
            Ok(result_map) => (ok(), result_map).encode(env),
            Err(_) => (
                error(),
                XqliteError::InternalEncodingError {
                    context: "map_new fail for empty non-done".into(),
                }
                .encode(env),
            )
                .encode(env),
        }
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn close(env: Env<'_>, _handle: ResourceArc<XqliteConn>) -> Term<'_> {
    ok().encode(env)
}
