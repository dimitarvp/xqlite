use crate::atoms;
use crate::error::XqliteError;
use crate::util::quote_identifier;
use rusqlite::Connection;
use rustler::{Atom, NifStruct};

#[derive(Debug, Clone, NifStruct)]
#[module = "Xqlite.Schema.DatabaseInfo"]
pub(crate) struct DatabaseInfo {
    pub name: String,
    pub file: Option<String>,
}

#[derive(Debug, Clone, NifStruct)]
#[module = "Xqlite.Schema.SchemaObjectInfo"]
pub(crate) struct SchemaObjectInfo {
    pub schema: String,
    pub name: String,
    pub object_type: Atom,
    pub column_count: i64,
    pub is_without_rowid: bool,
    pub strict: bool,
}

#[derive(Debug, Clone, NifStruct)]
#[module = "Xqlite.Schema.ColumnInfo"]
pub(crate) struct ColumnInfo {
    pub column_id: i64,
    pub name: String,
    pub type_affinity: Atom,
    pub declared_type: String,
    pub nullable: bool,
    pub default_value: Option<String>,
    pub primary_key_index: u8,
    pub hidden_kind: Atom,
}

#[derive(Debug, Clone, NifStruct)]
#[module = "Xqlite.Schema.ForeignKeyInfo"]
pub(crate) struct ForeignKeyInfo {
    pub id: i64,
    pub column_sequence: i64,
    pub target_table: String,
    pub from_column: String,
    pub to_column: String,
    pub on_update: Atom,
    pub on_delete: Atom,
    pub match_clause: Atom,
}

#[derive(Debug, Clone, NifStruct)]
#[module = "Xqlite.Schema.IndexInfo"]
pub(crate) struct IndexInfo {
    pub name: String,
    pub unique: bool,
    pub origin: Atom,
    pub partial: bool,
}

#[derive(Debug, Clone, NifStruct)]
#[module = "Xqlite.Schema.IndexColumnInfo"]
pub(crate) struct IndexColumnInfo {
    pub index_column_sequence: i64,
    pub table_column_id: i64,
    pub name: Option<String>,
    pub sort_order: Atom,
    pub collation: String,
    pub is_key_column: bool,
}

/// Maps PRAGMA table_list type string to an atom.
#[inline]
pub(crate) fn object_type_to_atom(s: &str) -> Result<Atom, &str> {
    match s {
        "table" => Ok(atoms::table()),
        "view" => Ok(atoms::view()),
        "shadow" => Ok(atoms::shadow()),
        "virtual" => Ok(atoms::r#virtual()),
        "sequence" => Ok(atoms::sequence()),
        _ => Err(s),
    }
}

/// Maps PRAGMA table_info type affinity string to an atom.
#[inline]
pub(crate) fn type_affinity_to_atom(declared_type_str: &str) -> Atom {
    let upper = declared_type_str.to_uppercase();

    if upper.contains("INT") {
        atoms::integer()
    } else if upper.contains("CHAR") || upper.contains("CLOB") || upper.contains("TEXT") {
        atoms::text()
    } else if upper.contains("BLOB") || upper.is_empty() || upper == "ANY" {
        atoms::binary()
    } else if upper.contains("REAL") || upper.contains("FLOA") || upper.contains("DOUB") {
        atoms::float()
    } else {
        atoms::numeric()
    }
}

/// Maps the integer 'hidden' value from PRAGMA table_xinfo to an atom.
#[inline]
pub(crate) fn hidden_int_to_atom(hidden_val: i64) -> Result<Atom, String> {
    match hidden_val {
        0 => Ok(atoms::normal()),
        1 => Ok(atoms::hidden_alias()),
        2 => Ok(atoms::virtual_generated()),
        3 => Ok(atoms::stored_generated()),
        _ => Err(hidden_val.to_string()),
    }
}

/// Maps PRAGMA foreign_key_list action string to an atom.
#[inline]
pub(crate) fn fk_action_to_atom(s: &str) -> Result<Atom, &str> {
    match s {
        "NO ACTION" => Ok(atoms::no_action()),
        "RESTRICT" => Ok(atoms::restrict()),
        "SET NULL" => Ok(atoms::set_null()),
        "SET DEFAULT" => Ok(atoms::set_default()),
        "CASCADE" => Ok(atoms::cascade()),
        _ => Err(s),
    }
}

/// Maps PRAGMA foreign_key_list match string to an atom.
#[inline]
pub(crate) fn fk_match_to_atom(s: &str) -> Result<Atom, &str> {
    match s {
        "NONE" => Ok(atoms::none()),
        "SIMPLE" => Ok(atoms::simple()),
        "PARTIAL" => Ok(atoms::partial()),
        "FULL" => Ok(atoms::full()),
        _ => Err(s),
    }
}

/// Maps PRAGMA index_list origin char to a descriptive atom.
#[inline]
pub(crate) fn index_origin_to_atom(s: &str) -> Result<Atom, &str> {
    match s {
        "c" => Ok(atoms::create_index()),
        "u" => Ok(atoms::unique_constraint()),
        "pk" => Ok(atoms::primary_key_constraint()),
        _ => Err(s),
    }
}

/// Maps PRAGMA index_xinfo sort order value (0/1) to an atom.
/// Assumes the input 'val' is derived from an integer column.
#[inline]
pub(crate) fn sort_order_to_atom(val: i64) -> Result<Atom, String> {
    match val {
        0 => Ok(atoms::asc()),
        1 => Ok(atoms::desc()),
        _ => Err(val.to_string()),
    }
}

/// Converts the 'notnull' integer flag from PRAGMA table_info to a boolean 'nullable'.
/// Returns Err with the unexpected value as String if input is not 0 or 1.
#[inline]
pub(crate) fn notnull_to_nullable(notnull_flag: i64) -> Result<bool, String> {
    match notnull_flag {
        0 => Ok(true),
        1 => Ok(false),
        _ => Err(notnull_flag.to_string()),
    }
}

/// Converts the 'pk' integer flag from PRAGMA table_info to a u8 index.
/// Returns Err with the unexpected value as String if input is negative or > 255.
#[inline]
pub(crate) fn pk_value_to_index(pk_flag: i64) -> Result<u8, String> {
    u8::try_from(pk_flag).map_err(|_| pk_flag.to_string())
}

/// Converts an integer flag (0/1) to a boolean.
#[inline]
fn int_flag_to_bool(val: i64, context: &str, name: &str) -> Result<bool, XqliteError> {
    match val {
        0 => Ok(false),
        1 => Ok(true),
        _ => Err(XqliteError::SchemaParsingError {
            context: format!("Parsing '{context}' flag for {name}"),
            unexpected_value: val.to_string(),
        }),
    }
}

// ---------------------------------------------------------------------------
// Temporary structs for intermediate parsing results
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct TempObjectInfo {
    schema: String,
    name: String,
    obj_type_atom: Result<Atom, String>,
    column_count: i64,
    wr_flag: i64,
    strict_flag: i64,
}

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

#[derive(Debug)]
struct TempIndexData {
    name: String,
    unique: i64,
    origin_str: String,
    partial: i64,
}

#[derive(Debug)]
struct TempIndexColumnData {
    seqno: i64,
    cid: i64,
    name: Option<String>,
    desc: i64,
    coll: String,
    key: i64,
}

// ---------------------------------------------------------------------------
// Schema logic functions (called from NIF wrappers)
// ---------------------------------------------------------------------------

pub(crate) fn databases(conn: &Connection) -> Result<Vec<DatabaseInfo>, XqliteError> {
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
}

pub(crate) fn list_objects(
    conn: &Connection,
    schema: Option<&str>,
) -> Result<Vec<SchemaObjectInfo>, XqliteError> {
    let sql = "PRAGMA table_list;";
    let mut stmt = conn.prepare(sql)?;

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

    let mut final_objects: Vec<SchemaObjectInfo> = Vec::with_capacity(temp_results.len());
    for temp_result in temp_results {
        match temp_result {
            Ok(temp_info) => {
                if let Some(filter_schema) = schema
                    && temp_info.schema != *filter_schema
                {
                    continue;
                }

                let atom = temp_info.obj_type_atom.map_err(|unexpected_val| {
                    XqliteError::SchemaParsingError {
                        context: format!(
                            "Parsing object type for '{}'.'{}'",
                            temp_info.schema, temp_info.name
                        ),
                        unexpected_value: unexpected_val,
                    }
                })?;
                let obj_desc = format!("object '{}'.'{}'", temp_info.schema, temp_info.name);
                let is_without_rowid = int_flag_to_bool(temp_info.wr_flag, "wr", &obj_desc)?;
                let is_strict = int_flag_to_bool(temp_info.strict_flag, "strict", &obj_desc)?;

                final_objects.push(SchemaObjectInfo {
                    schema: temp_info.schema,
                    name: temp_info.name,
                    object_type: atom,
                    column_count: temp_info.column_count,
                    is_without_rowid,
                    strict: is_strict,
                });
            }
            Err(rusqlite_err) => {
                return Err(rusqlite_err.into());
            }
        }
    }
    Ok(final_objects)
}

pub(crate) fn columns(
    conn: &Connection,
    table_name: &str,
) -> Result<Vec<ColumnInfo>, XqliteError> {
    let quoted_table_name = quote_identifier(table_name);
    let sql = format!("PRAGMA table_xinfo({quoted_table_name});");
    let mut stmt = conn.prepare(&sql)?;

    let temp_results: Vec<Result<TempColumnData, rusqlite::Error>> = stmt
        .query_map([], |row| {
            Ok(TempColumnData {
                cid: row.get(0)?,
                name: row.get(1)?,
                type_str: row.get(2)?,
                notnull_flag: row.get(3)?,
                dflt_value: row.get(4)?,
                pk_flag: row.get(5)?,
                hidden: row.get(6)?,
            })
        })?
        .collect();

    let mut final_columns: Vec<ColumnInfo> = Vec::with_capacity(temp_results.len());
    for temp_result in temp_results {
        match temp_result {
            Ok(temp_data) => {
                let type_affinity_atom = type_affinity_to_atom(&temp_data.type_str);

                let nullable =
                    notnull_to_nullable(temp_data.notnull_flag).map_err(|unexpected_val| {
                        XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'notnull' flag for column '{}' in table '{}'",
                                temp_data.name, table_name
                            ),
                            unexpected_value: unexpected_val,
                        }
                    })?;

                let primary_key_index =
                    pk_value_to_index(temp_data.pk_flag).map_err(|unexpected_val| {
                        XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'pk' flag for column '{}' in table '{}'",
                                temp_data.name, table_name
                            ),
                            unexpected_value: unexpected_val,
                        }
                    })?;

                let hidden_kind_atom =
                    hidden_int_to_atom(temp_data.hidden).map_err(|unexpected_val| {
                        XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'hidden' kind for column '{}' in table '{}'",
                                temp_data.name, table_name
                            ),
                            unexpected_value: unexpected_val,
                        }
                    })?;

                final_columns.push(ColumnInfo {
                    column_id: temp_data.cid,
                    name: temp_data.name,
                    type_affinity: type_affinity_atom,
                    declared_type: temp_data.type_str,
                    nullable,
                    default_value: temp_data.dflt_value,
                    primary_key_index,
                    hidden_kind: hidden_kind_atom,
                });
            }
            Err(rusqlite_err) => {
                return Err(rusqlite_err.into());
            }
        }
    }
    Ok(final_columns)
}

pub(crate) fn foreign_keys(
    conn: &Connection,
    table_name: &str,
) -> Result<Vec<ForeignKeyInfo>, XqliteError> {
    let quoted_table_name = quote_identifier(table_name);
    let sql = format!("PRAGMA foreign_key_list({quoted_table_name});");
    let mut stmt = conn.prepare(&sql)?;

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

    let mut final_fks: Vec<ForeignKeyInfo> = Vec::with_capacity(temp_results.len());
    for temp_result in temp_results {
        match temp_result {
            Ok(temp_data) => {
                let on_update_atom =
                    fk_action_to_atom(&temp_data.on_update_str).map_err(|unexpected_val| {
                        XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'on_update' action for FK id {} on table '{}'",
                                temp_data.id, table_name
                            ),
                            unexpected_value: unexpected_val.to_string(),
                        }
                    })?;

                let on_delete_atom =
                    fk_action_to_atom(&temp_data.on_delete_str).map_err(|unexpected_val| {
                        XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'on_delete' action for FK id {} on table '{}'",
                                temp_data.id, table_name
                            ),
                            unexpected_value: unexpected_val.to_string(),
                        }
                    })?;

                let match_clause_atom =
                    fk_match_to_atom(&temp_data.match_str).map_err(|unexpected_val| {
                        XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'match' clause for FK id {} on table '{}'",
                                temp_data.id, table_name
                            ),
                            unexpected_value: unexpected_val.to_string(),
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
}

pub(crate) fn indexes(
    conn: &Connection,
    table_name: &str,
) -> Result<Vec<IndexInfo>, XqliteError> {
    let quoted_table_name = quote_identifier(table_name);
    let sql = format!("PRAGMA index_list({quoted_table_name});");
    let mut stmt = conn.prepare(&sql)?;

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

    let mut final_indexes: Vec<IndexInfo> = Vec::with_capacity(temp_results.len());
    for temp_result in temp_results {
        match temp_result {
            Ok(temp_data) => {
                let origin_atom =
                    index_origin_to_atom(&temp_data.origin_str).map_err(|unexpected_val| {
                        XqliteError::SchemaParsingError {
                            context: format!(
                                "Parsing 'origin' for index '{}' on table '{}'",
                                temp_data.name, table_name
                            ),
                            unexpected_value: unexpected_val.to_string(),
                        }
                    })?;

                let idx_desc = format!("index '{}' on table '{}'", temp_data.name, table_name);
                let unique_bool = int_flag_to_bool(temp_data.unique, "unique", &idx_desc)?;
                let partial_bool = int_flag_to_bool(temp_data.partial, "partial", &idx_desc)?;

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
}

pub(crate) fn index_columns(
    conn: &Connection,
    index_name: &str,
) -> Result<Vec<IndexColumnInfo>, XqliteError> {
    let quoted_index_name = quote_identifier(index_name);
    let sql = format!("PRAGMA index_xinfo({quoted_index_name});");
    let mut stmt = conn.prepare(&sql)?;

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
                            unexpected_value: unexpected_val,
                        }
                    })?;

                let col_desc =
                    format!("column seq {} in index '{}'", temp_data.seqno, index_name);
                let is_key_bool = int_flag_to_bool(temp_data.key, "key", &col_desc)?;

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
}

pub(crate) fn create_sql(
    conn: &Connection,
    object_name: &str,
) -> Result<Option<String>, XqliteError> {
    let sql = "SELECT sql FROM sqlite_schema WHERE name = ?1 LIMIT 1;";
    let mut stmt = conn.prepare(sql)?;
    let result = stmt.query_row([object_name], |row| row.get::<usize, Option<String>>(0));

    match result {
        Ok(sql_string_option) => Ok(sql_string_option),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(e) => Err(e.into()),
    }
}
