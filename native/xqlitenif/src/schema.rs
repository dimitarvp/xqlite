use crate::{
    asc, binary, cascade, create_index, desc, float, full, integer, no_action, none, numeric,
    partial, primary_key_constraint, r#virtual, restrict, sequence, set_default, set_null,
    shadow, simple, table, text, unique_constraint, view,
};
use rustler::{Atom, NifStruct};
use std::convert::TryFrom;

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
    pub is_writable: bool,
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
        "table" => Ok(table()),
        "view" => Ok(view()),
        "shadow" => Ok(shadow()),
        "virtual" => Ok(r#virtual()),
        "sequence" => Ok(sequence()),
        _ => Err(s),
    }
}

/// Maps PRAGMA table_info type affinity string to an atom.
#[inline]
pub(crate) fn type_affinity_to_atom(s: &str) -> Result<Atom, &str> {
    match s {
        "TEXT" => Ok(text()),
        "NUMERIC" => Ok(numeric()),
        "INTEGER" => Ok(integer()),
        "REAL" => Ok(float()),
        "BLOB" => Ok(binary()),
        _ => Err(s),
    }
}

/// Maps PRAGMA foreign_key_list action string to an atom.
#[inline]
pub(crate) fn fk_action_to_atom(s: &str) -> Result<Atom, &str> {
    match s {
        "NO ACTION" => Ok(no_action()),
        "RESTRICT" => Ok(restrict()),
        "SET NULL" => Ok(set_null()),
        "SET DEFAULT" => Ok(set_default()),
        "CASCADE" => Ok(cascade()),
        _ => Err(s),
    }
}

/// Maps PRAGMA foreign_key_list match string to an atom.
#[inline]
pub(crate) fn fk_match_to_atom(s: &str) -> Result<Atom, &str> {
    match s {
        "NONE" => Ok(none()),
        "SIMPLE" => Ok(simple()),
        "PARTIAL" => Ok(partial()),
        "FULL" => Ok(full()),
        _ => Err(s),
    }
}

/// Maps PRAGMA index_list origin char to a descriptive atom.
#[inline]
pub(crate) fn index_origin_to_atom(s: &str) -> Result<Atom, &str> {
    match s {
        "c" => Ok(create_index()),
        "u" => Ok(unique_constraint()),
        "pk" => Ok(primary_key_constraint()),
        _ => Err(s),
    }
}

/// Maps PRAGMA index_xinfo sort order value (0/1) to an atom.
/// Assumes the input 'val' is derived from an integer column.
#[inline]
pub(crate) fn sort_order_to_atom(val: i64) -> Result<Atom, String> {
    match val {
        0 => Ok(asc()),
        1 => Ok(desc()),
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
