//! Parses SQLite constraint error message text into structured components.
//!
//! SQLite does not expose constraint metadata (column names, constraint names,
//! index names) as structured fields in its error reporting — only as text
//! returned by `sqlite3_errmsg`. This module parses that text ONCE at the
//! lowest layer so structured data can flow upward to Elixir and callers
//! never need to touch the raw message string for classification.

use rusqlite::ffi;
use rusqlite::types::Type;

/// Parses a SQLite storage-class token as it appears in DATATYPE error messages.
///
/// SQLite emits the short form ("INT") for a value's storage class and the
/// declared form ("INTEGER") for a column's type. STRICT `ANY` columns never
/// produce SQLITE_CONSTRAINT_DATATYPE (see stricttables.html), so no `Any`
/// variant is needed.
fn parse_storage_class(s: &str) -> Option<Type> {
    match s {
        "INT" | "INTEGER" => Some(Type::Integer),
        "REAL" => Some(Type::Real),
        "TEXT" => Some(Type::Text),
        "BLOB" => Some(Type::Blob),
        "NULL" => Some(Type::Null),
        _ => None,
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct ConstraintDetails {
    pub table: Option<String>,
    pub columns: Vec<String>,
    pub index_name: Option<String>,
    pub constraint_name: Option<String>,
    pub source_type: Option<Type>,
    pub target_type: Option<Type>,
}

pub(crate) fn parse_details(extended_code: i32, message: &str) -> ConstraintDetails {
    match extended_code {
        ffi::SQLITE_CONSTRAINT_UNIQUE => parse_unique(message),
        ffi::SQLITE_CONSTRAINT_PRIMARYKEY => {
            // SQLite emits "UNIQUE constraint failed: ..." for PK violations on
            // rowid tables and "PRIMARY KEY constraint failed: ..." for WITHOUT
            // ROWID tables. Try the PRIMARY KEY form first, fall back to UNIQUE.
            let d = parse_primary_key(message);
            if d == ConstraintDetails::default() {
                parse_unique(message)
            } else {
                d
            }
        }
        ffi::SQLITE_CONSTRAINT_NOTNULL => parse_not_null(message),
        ffi::SQLITE_CONSTRAINT_CHECK => parse_check(message),
        ffi::SQLITE_CONSTRAINT_DATATYPE => parse_datatype(message),
        _ => ConstraintDetails::default(),
    }
}

fn parse_unique(message: &str) -> ConstraintDetails {
    let Some(rest) = message.strip_prefix("UNIQUE constraint failed: ") else {
        return ConstraintDetails::default();
    };
    if let Some(inner) = rest
        .strip_prefix("index '")
        .and_then(|s| s.strip_suffix('\''))
    {
        return ConstraintDetails {
            index_name: Some(inner.to_string()),
            ..Default::default()
        };
    }
    parse_table_columns(rest)
}

fn parse_primary_key(message: &str) -> ConstraintDetails {
    let Some(rest) = message.strip_prefix("PRIMARY KEY constraint failed: ") else {
        return ConstraintDetails::default();
    };
    parse_table_columns(rest)
}

fn parse_not_null(message: &str) -> ConstraintDetails {
    let Some(rest) = message.strip_prefix("NOT NULL constraint failed: ") else {
        return ConstraintDetails::default();
    };
    parse_table_columns(rest)
}

fn parse_check(message: &str) -> ConstraintDetails {
    let Some(rest) = message.strip_prefix("CHECK constraint failed: ") else {
        return ConstraintDetails::default();
    };
    ConstraintDetails {
        constraint_name: Some(rest.to_string()),
        ..Default::default()
    }
}

fn parse_datatype(message: &str) -> ConstraintDetails {
    // Empirically verified STRICT-table format:
    //   "cannot store SRC value in TGT column TABLE.COLUMN"
    //
    // SRC uses SQLite's short storage-class name (INT, REAL, TEXT, BLOB, NULL)
    // while TGT uses the column's declared type (INTEGER, REAL, TEXT, BLOB, ANY).
    let Some(rest) = message.strip_prefix("cannot store ") else {
        return ConstraintDetails::default();
    };
    let Some((src, rest)) = rest.split_once(" value in ") else {
        return ConstraintDetails::default();
    };
    let Some((tgt, rest)) = rest.split_once(" column ") else {
        return ConstraintDetails::default();
    };
    let (table, columns) = match rest.split_once('.') {
        Some((t, c)) => (Some(t.to_string()), vec![c.to_string()]),
        None => (None, vec![rest.to_string()]),
    };
    ConstraintDetails {
        table,
        columns,
        source_type: parse_storage_class(src),
        target_type: parse_storage_class(tgt),
        ..Default::default()
    }
}

fn parse_table_columns(rest: &str) -> ConstraintDetails {
    let mut table: Option<String> = None;
    let mut columns: Vec<String> = Vec::new();
    for part in rest.split(", ") {
        match part.split_once('.') {
            Some((t, c)) => {
                if table.is_none() {
                    table = Some(t.to_string());
                }
                columns.push(c.to_string());
            }
            None => columns.push(part.to_string()),
        }
    }
    ConstraintDetails {
        table,
        columns,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unique_single_column_qualified() {
        let d = parse_unique("UNIQUE constraint failed: users.email");
        assert_eq!(d.table.as_deref(), Some("users"));
        assert_eq!(d.columns, vec!["email".to_string()]);
        assert!(d.index_name.is_none());
    }

    #[test]
    fn unique_composite_columns() {
        let d = parse_unique("UNIQUE constraint failed: users.first, users.last");
        assert_eq!(d.table.as_deref(), Some("users"));
        assert_eq!(d.columns, vec!["first".to_string(), "last".to_string()]);
    }

    #[test]
    fn unique_by_index_name() {
        let d = parse_unique("UNIQUE constraint failed: index 'unique_email_ci'");
        assert_eq!(d.index_name.as_deref(), Some("unique_email_ci"));
        assert!(d.table.is_none());
        assert!(d.columns.is_empty());
    }

    #[test]
    fn unique_unknown_prefix_returns_empty() {
        assert_eq!(
            parse_unique("something unexpected"),
            ConstraintDetails::default()
        );
    }

    #[test]
    fn not_null_qualified() {
        let d = parse_not_null("NOT NULL constraint failed: users.email");
        assert_eq!(d.table.as_deref(), Some("users"));
        assert_eq!(d.columns, vec!["email".to_string()]);
    }

    #[test]
    fn check_named() {
        let d = parse_check("CHECK constraint failed: positive_age");
        assert_eq!(d.constraint_name.as_deref(), Some("positive_age"));
    }

    #[test]
    fn check_anonymous_expression_is_returned_verbatim() {
        let d = parse_check("CHECK constraint failed: age > 0");
        assert_eq!(d.constraint_name.as_deref(), Some("age > 0"));
    }

    #[test]
    fn primary_key_composite() {
        let d = parse_primary_key("PRIMARY KEY constraint failed: users.a, users.b");
        assert_eq!(d.table.as_deref(), Some("users"));
        assert_eq!(d.columns, vec!["a".to_string(), "b".to_string()]);
    }

    #[test]
    fn parse_details_falls_back_to_unique_for_rowid_primary_key() {
        let d = parse_details(
            ffi::SQLITE_CONSTRAINT_PRIMARYKEY,
            "UNIQUE constraint failed: t.id",
        );
        assert_eq!(d.table.as_deref(), Some("t"));
        assert_eq!(d.columns, vec!["id".to_string()]);
    }

    #[test]
    fn parse_details_foreign_key_yields_empty() {
        let d = parse_details(
            ffi::SQLITE_CONSTRAINT_FOREIGNKEY,
            "FOREIGN KEY constraint failed",
        );
        assert_eq!(d, ConstraintDetails::default());
    }

    #[test]
    fn datatype_text_into_integer_column() {
        let d = parse_datatype("cannot store TEXT value in INTEGER column t1.v");
        assert_eq!(d.table.as_deref(), Some("t1"));
        assert_eq!(d.columns, vec!["v".to_string()]);
        assert_eq!(d.source_type, Some(Type::Text));
        assert_eq!(d.target_type, Some(Type::Integer));
    }

    #[test]
    fn datatype_int_source_normalises_to_integer() {
        let d = parse_datatype("cannot store INT value in BLOB column t8.v");
        assert_eq!(d.source_type, Some(Type::Integer));
        assert_eq!(d.target_type, Some(Type::Blob));
    }

    #[test]
    fn datatype_real_source() {
        let d = parse_datatype("cannot store REAL value in BLOB column t9.v");
        assert_eq!(d.source_type, Some(Type::Real));
        assert_eq!(d.target_type, Some(Type::Blob));
    }

    #[test]
    fn datatype_any_target_is_unreachable_but_returns_nil_types() {
        // STRICT ANY columns never produce SQLITE_CONSTRAINT_DATATYPE, so this
        // string isn't seen in practice. We still document the behaviour:
        // unknown tokens fall through to None rather than matching ANY.
        let d = parse_datatype("cannot store BLOB value in ANY column t.v");
        assert_eq!(d.source_type, Some(Type::Blob));
        assert_eq!(d.target_type, None);
    }

    #[test]
    fn datatype_column_without_qualifier_leaves_table_nil() {
        let d = parse_datatype("cannot store TEXT value in INTEGER column v");
        assert!(d.table.is_none());
        assert_eq!(d.columns, vec!["v".to_string()]);
    }

    #[test]
    fn datatype_unknown_prefix_returns_empty() {
        assert_eq!(
            parse_datatype("something unexpected"),
            ConstraintDetails::default()
        );
    }

    #[test]
    fn parse_details_datatype_routes_through_parser() {
        let d = parse_details(
            ffi::SQLITE_CONSTRAINT_DATATYPE,
            "cannot store TEXT value in INTEGER column mc.a",
        );
        assert_eq!(d.table.as_deref(), Some("mc"));
        assert_eq!(d.source_type, Some(Type::Text));
        assert_eq!(d.target_type, Some(Type::Integer));
    }
}
