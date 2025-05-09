use crate::cancel::{ProgressHandlerGuard, XqliteCancelToken};
use crate::error::{SchemaErrorDetail, XqliteError};
use crate::schema::{
    fk_action_to_atom, fk_match_to_atom, hidden_int_to_atom, index_origin_to_atom,
    notnull_to_nullable, object_type_to_atom, pk_value_to_index, sort_order_to_atom,
    type_affinity_to_atom, ColumnInfo, DatabaseInfo, ForeignKeyInfo, IndexColumnInfo,
    IndexInfo, SchemaObjectInfo,
};
use crate::util::{
    decode_exec_keyword_params, decode_plain_list_params, encode_val, format_term_for_pragma,
    is_keyword, process_rows, quote_identifier, quote_savepoint_name, with_conn,
};
use crate::{columns, no_value, num_rows, rows};
use rusqlite::{types::Value, Connection, Error as RusqliteError, ToSql};
use rustler::{
    resource_impl,
    types::{
        atom::{error, nil, ok},
        map::map_new,
    },
    Atom, Encoder, Env, Resource, ResourceArc, Term, TermType,
};
use std::sync::atomic::AtomicBool;
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
) -> Result<bool, XqliteError> {
    let _guard = token_bool_opt
        .map(|token_bool| ProgressHandlerGuard::new(conn, token_bool, 8))
        .transpose()?;
    conn.execute_batch(sql_batch)?;
    Ok(true)
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
    handle: ResourceArc<XqliteConn>,
    sql_batch: String,
) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| core_execute_batch(conn, &sql_batch, None))
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
    handle: ResourceArc<XqliteConn>,
    sql_batch: String,
    token: ResourceArc<XqliteCancelToken>,
) -> Result<bool, XqliteError> {
    let token_bool = token.0.clone();

    with_conn(&handle, |conn| {
        core_execute_batch(conn, &sql_batch, Some(token_bool))
    })
}

#[rustler::nif]
fn create_cancel_token() -> Result<ResourceArc<XqliteCancelToken>, XqliteError> {
    Ok(ResourceArc::new(XqliteCancelToken::new()))
}

#[rustler::nif]
fn cancel_operation(token: ResourceArc<XqliteCancelToken>) -> Result<bool, XqliteError> {
    token.cancel();
    Ok(true)
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
            {
                let mut write_stmt = conn.prepare(&write_sql).map_err(|e| {
                    XqliteError::CannotExecutePragma {
                        pragma: write_sql.clone(),
                        reason: e.to_string(),
                    }
                })?;
                let mut rows = write_stmt.query([])?;
                if let Some(row_result) = rows.next()? {
                    let _value_from_pragma_set: Value = row_result.get(0)?;
                }
            }
            Ok(())
        })
    })();

    match execution_result {
        Ok(_) => ok().encode(env),
        Err(err) => (error(), err.encode(env)).encode(env),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn begin(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        conn.execute("BEGIN;", [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn commit(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        conn.execute("COMMIT;", [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn rollback(handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        conn.execute("ROLLBACK;", [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn savepoint(handle: ResourceArc<XqliteConn>, name: String) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        let quoted_name = quote_savepoint_name(&name);
        let sql = format!("SAVEPOINT {};", quoted_name);
        conn.execute(&sql, [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn rollback_to_savepoint(
    handle: ResourceArc<XqliteConn>,
    name: String,
) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        let quoted_name = quote_savepoint_name(&name);
        let sql = format!("ROLLBACK TO SAVEPOINT {};", quoted_name);
        conn.execute(&sql, [])?;
        Ok(true)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn release_savepoint(
    handle: ResourceArc<XqliteConn>,
    name: String,
) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        let quoted_name = quote_savepoint_name(&name);
        let sql = format!("RELEASE SAVEPOINT {};", quoted_name);
        conn.execute(&sql, [])?;
        Ok(true)
    })
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
fn close(env: Env<'_>, _handle: ResourceArc<XqliteConn>) -> Term<'_> {
    ok().encode(env)
}
