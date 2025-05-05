use crate::error::SchemaErrorDetail;
use crate::error::XqliteError;
use crate::schema::{
    fk_action_to_atom, fk_match_to_atom, index_origin_to_atom, notnull_to_nullable,
    object_type_to_atom, pk_value_to_index, sort_order_to_atom, type_affinity_to_atom,
    ColumnInfo, DatabaseInfo, ForeignKeyInfo, IndexColumnInfo, IndexInfo, SchemaObjectInfo,
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
        atom::{error, nil},
        map::map_new,
    },
    Atom, Encoder, Env, Resource, ResourceArc, Term, TermType,
};
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
    wr_flag: i64,     // Raw value from PRAGMA 'wr' column (0 or 1)
    strict_flag: i64, // Raw value from PRAGMA 'strict' column (0 or 1)
}

/// Temporary struct for holding intermediate results during column info parsing.
#[derive(Debug)]
struct TempColumnData {
    cid: i64,
    name: String,
    type_str: String, // This holds the original declared type string
    notnull_flag: i64,
    dflt_value: Option<String>,
    pk_flag: i64,
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
    // seq: i64, // Sequence number of index, typically not needed by user
    name: String,
    unique: i64,        // PRAGMA returns 0 or 1
    origin_str: String, // PRAGMA returns 'c', 'u', 'pk'
    partial: i64,       // PRAGMA returns 0 or 1
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
    let sql_for_err = sql.clone();

    with_conn(&handle, |conn| {
        let mut stmt = conn
            .prepare(sql.as_str())
            .map_err(|e| XqliteError::CannotPrepareStatement(sql_for_err, e.to_string()))?;
        let column_names: Vec<String> =
            stmt.column_names().iter().map(|s| s.to_string()).collect();
        let column_count = column_names.len();

        let rows = match params_term.get_type() {
            TermType::List => {
                if is_keyword(params_term) {
                    let named_params_vec = decode_exec_keyword_params(env, params_term)?;
                    let params_for_rusqlite: Vec<(&str, &dyn ToSql)> = named_params_vec
                        .iter()
                        .map(|(k, v)| (k.as_str(), v as &dyn ToSql))
                        .collect();
                    stmt.query(params_for_rusqlite.as_slice())?
                } else {
                    let positional_values: Vec<Value> =
                        decode_plain_list_params(env, params_term)?;
                    let params_slice: Vec<&dyn ToSql> =
                        positional_values.iter().map(|v| v as &dyn ToSql).collect();
                    stmt.query(params_slice.as_slice())?
                }
            }
            _ if params_term == nil().to_term(env) || params_term.is_empty_list() => {
                stmt.query([])?
            }
            _ => {
                return Err(XqliteError::ExpectedList {
                    value_str: format!("{:?}", params_term),
                });
            }
        };

        let results_vec: Vec<Vec<Term<'a>>> = process_rows(env, rows, column_count)?;
        let num_rows = results_vec.len();

        Ok(XqliteQueryResult {
            columns: column_names,
            rows: results_vec,
            num_rows,
        })
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
        let positional_values: Vec<Value> = decode_plain_list_params(env, params_term)?;
        let params_slice: Vec<&dyn ToSql> =
            positional_values.iter().map(|v| v as &dyn ToSql).collect();
        // Use `?` which will now invoke the refined `From<rusqlite::Error>` impl
        Ok(conn.execute(sql.as_str(), params_slice.as_slice())?)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn execute_batch(
    handle: ResourceArc<XqliteConn>,
    sql_batch: String,
) -> Result<bool, XqliteError> {
    with_conn(&handle, |conn| {
        conn.execute_batch(&sql_batch)?;
        Ok(true)
    })
}

/// Reads the current value of an SQLite PRAGMA.
#[rustler::nif(schedule = "DirtyIo")]
fn get_pragma(
    env: Env<'_>,
    handle: ResourceArc<XqliteConn>,
    pragma_name: String,
) -> Result<Term<'_>, XqliteError> {
    // This function contains the logic previously in Step 2 of pragma_write_and_read
    with_conn(&handle, |conn| {
        // Assuming with_conn is available (e.g., pub(crate) in util.rs)
        let read_sql = format!("PRAGMA {};", pragma_name);
        match conn.query_row(&read_sql, [], |row| row.get::<usize, Value>(0)) {
            Ok(value) => Ok(encode_val(env, value)), // Assuming encode_val is available
            Err(RusqliteError::QueryReturnedNoRows) => Ok(no_value().to_term(env)), // Use atoms module
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
) -> Result<bool, XqliteError> {
    // Returns bool now
    // Convert Elixir term to SQL literal string suitable for PRAGMA value
    let value_literal = format_term_for_pragma(env, value_term)?;

    with_conn(&handle, |conn| {
        // Construct the full SQL command for setting the PRAGMA.
        let write_sql = format!("PRAGMA {} = {};", pragma_name, value_literal);
        {
            // Scope for statement finalization via Drop
            // Prepare the statement. This can fail (e.g., syntax error in pragma name).
            let mut write_stmt =
                conn.prepare(&write_sql)
                    .map_err(|e| XqliteError::CannotExecutePragma {
                        // Use the fully formatted SQL in the error context.
                        pragma: write_sql.clone(),
                        reason: e.to_string(),
                    })?;

            // Execute using query([]), immediately consuming and discarding the Rows iterator.
            // This robustly handles PRAGMA SET commands regardless of whether they
            // internally return rows or not, using only public rusqlite API.
            // The '?' propagates any execution errors (like constraint issues, invalid values).
            let _ = write_stmt.query([])?;

            // If query([]) succeeded, the PRAGMA SET command executed without error.
            // Statement finalized automatically when write_stmt goes out of scope here.
        }
        Ok(true) // Return simple success if no error occurred
    })
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
                // PRAGMA table_list columns: schema(0), name(1), type(2), ncol(3), wr(4), strict(5)
                let obj_schema: String = row.get(0)?;
                let obj_name: String = row.get(1)?;
                let obj_type_str: String = row.get(2)?;
                let column_count: i64 = row.get(3)?;
                let wr_flag: i64 = row.get(4)?;
                let strict_flag: i64 = row.get(5)?;

                let obj_type_atom_result =
                    object_type_to_atom(&obj_type_str).map_err(|s| s.to_string());

                Ok(TempObjectInfo {
                    schema: obj_schema,
                    name: obj_name,
                    obj_type_atom: obj_type_atom_result,
                    column_count,
                    wr_flag,
                    strict_flag,
                })
            })?
            .collect();

        // Step 2: Process results, apply filter, and map errors
        let mut final_objects: Vec<SchemaObjectInfo> = Vec::new();
        for temp_result in temp_results {
            match temp_result {
                Ok(temp_info) => {
                    // Apply schema filter
                    if let Some(filter_schema) = &schema {
                        if temp_info.schema != *filter_schema {
                            continue;
                        }
                    }

                    // Finalize atom conversion
                    let atom = match temp_info.obj_type_atom {
                        Ok(atom) => atom,
                        Err(unexpected_val) => {
                            return Err(XqliteError::SchemaParsingError {
                                context: format!(
                                    "Parsing object type for '{}'.'{}'",
                                    temp_info.schema, temp_info.name
                                ),
                                error_detail: SchemaErrorDetail::UnexpectedValue(
                                    unexpected_val,
                                ),
                            });
                        }
                    };

                    // Convert wr_flag (0/1) to boolean
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

                    // Convert strict_flag (0/1) to boolean
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
fn schema_databases(
    handle: ResourceArc<XqliteConn>,
) -> Result<Vec<DatabaseInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        let mut stmt = conn.prepare("PRAGMA database_list;")?;

        let db_infos: Vec<DatabaseInfo> = stmt
            .query_map([], |row| {
                // PRAGMA database_list columns: seq(0), name(1), file(2)
                let name: String = row.get(1)?;
                let file: Option<String> = row.get(2)?;
                Ok(DatabaseInfo { name, file })
            })? // Propagate errors from query_map (e.g., statement execution)
            .collect::<Result<Vec<_>, _>>()?; // Collect results, propagating row mapping errors

        Ok(db_infos)
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn schema_columns(
    handle: ResourceArc<XqliteConn>,
    table_name: String,
) -> Result<Vec<ColumnInfo>, XqliteError> {
    with_conn(&handle, |conn| {
        // Quote table name for safety in PRAGMA
        let quoted_table_name = quote_identifier(&table_name);
        let sql = format!("PRAGMA table_info({});", quoted_table_name);
        let mut stmt = conn.prepare(&sql)?;

        // Step 1: Query and map raw data, returning Vec<Result<TempColumnData, rusqlite::Error>>
        let temp_results: Vec<Result<TempColumnData, rusqlite::Error>> = stmt
            .query_map([], |row| {
                // Inside query_map, return Result<_, rusqlite::Error>
                Ok(TempColumnData {
                    cid: row.get(0)?,
                    name: row.get(1)?,
                    type_str: row.get(2)?,
                    notnull_flag: row.get(3)?,
                    dflt_value: row.get(4)?,
                    pk_flag: row.get(5)?,
                })
            })? // Handles rusqlite errors from prepare/query
            .collect(); // Collect into Vec<Result<TempColumnData, rusqlite::Error>>

        // Step 2: Process results, validate/convert, and map errors
        let mut final_columns: Vec<ColumnInfo> = Vec::with_capacity(temp_results.len());
        for temp_result in temp_results {
            match temp_result {
                Ok(temp_data) => {
                    // Perform conversions using helpers, mapping errors to SchemaParsingError
                    let type_affinity_atom = type_affinity_to_atom(&temp_data.type_str)
                        .map_err(|unexpected_val| XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing type affinity for column '{}' in table '{}'",
                                temp_data.name, table_name
                            ),
                            error_detail: SchemaErrorDetail::UnexpectedValue(
                                unexpected_val.to_string(),
                            ),
                        })?;

                    let nullable = notnull_to_nullable(temp_data.notnull_flag).map_err(
                        |unexpected_val| XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'notnull' flag for column '{}' in table '{}'",
                                temp_data.name, table_name
                            ),
                            error_detail: SchemaErrorDetail::UnexpectedValue(unexpected_val),
                        },
                    )?;

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

                    // Construct final struct if all conversions succeeded
                    final_columns.push(ColumnInfo {
                        column_id: temp_data.cid,
                        name: temp_data.name,
                        type_affinity: type_affinity_atom,
                        declared_type: temp_data.type_str, // Assign the original type string
                        nullable,
                        default_value: temp_data.dflt_value,
                        primary_key_index,
                    });
                }
                Err(rusqlite_err) => {
                    // Propagate rusqlite errors encountered during row mapping
                    return Err(rusqlite_err.into()); // Use From trait
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
                // PRAGMA foreign_key_list columns:
                // id(0), seq(1), table(2), from(3), to(4), on_update(5), on_delete(6), match(7)
                Ok(TempForeignKeyData {
                    id: row.get(0)?,
                    seq: row.get(1)?,
                    table: row.get(2)?,
                    from: row.get(3)?,
                    to: row.get(4)?, // Column 'to' can be NULL for FKs targeting a UNIQUE constraint not on the PK
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
                    // Perform atom conversions, mapping errors
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

                    // Construct final struct
                    final_fks.push(ForeignKeyInfo {
                        id: temp_data.id,
                        column_sequence: temp_data.seq,
                        target_table: temp_data.table,
                        from_column: temp_data.from,
                        to_column: temp_data.to, // Keep as String, handles NULL from get()
                        on_update: on_update_atom,
                        on_delete: on_delete_atom,
                        match_clause: match_clause_atom,
                    });
                }
                Err(rusqlite_err) => {
                    // Propagate rusqlite errors
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
                // PRAGMA index_list columns: seq(0), name(1), unique(2), origin(3), partial(4)
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
                    // Convert origin string to atom
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

                    // Convert integer flags to booleans (simple check)
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

                    // Construct final struct
                    final_indexes.push(IndexInfo {
                        name: temp_data.name,
                        unique: unique_bool,
                        origin: origin_atom,
                        partial: partial_bool,
                    });
                }
                Err(rusqlite_err) => {
                    // Propagate rusqlite errors
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
                // PRAGMA index_xinfo columns:
                // seqno(0), cid(1), name(2), desc(3), coll(4), key(5)
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
                    // Convert sort order flag to atom
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

                    // Convert key flag to boolean
                    let is_key_bool = match temp_data.key {
                        0 => false, // Included column
                        1 => true,  // Key column
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

                    // Construct final struct
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
        // Prefer sqlite_schema as it includes temporary objects,
        // but sqlite_master is the traditional one. A simple query works.
        // We don't strictly need a fallback mechanism here unless specifically required.
        // Let's use sqlite_schema for modern compatibility.
        let sql = "SELECT sql FROM sqlite_schema WHERE name = ?1 LIMIT 1;";
        let mut stmt = conn.prepare(sql)?;

        // Use query_row to expect exactly zero or one row.
        // Map the result row to Option<String>.
        let result = stmt.query_row([&object_name], |row| row.get::<usize, Option<String>>(0));

        match result {
            // Successfully found the row and got the SQL (which might be NULL in schema, hence Option)
            Ok(sql_string_option) => Ok(sql_string_option),
            // `query_row` returns this specific error if no rows were found
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            // Any other error during query execution or conversion
            Err(e) => Err(e.into()), // Convert rusqlite::Error to XqliteError
        }
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn last_insert_rowid(handle: ResourceArc<XqliteConn>) -> Result<i64, XqliteError> {
    with_conn(&handle, |conn| Ok(conn.last_insert_rowid()))
}

#[rustler::nif(schedule = "DirtyIo")]
fn close(_handle: ResourceArc<XqliteConn>) -> Result<bool, XqliteError> {
    Ok(true)
}
