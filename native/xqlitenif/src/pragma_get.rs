use crate::shared::{
    database_name_from_opts, use_conn, SharedResult, XqliteConnection, XqliteValue,
};
use rustler::resource::ResourceArc;
use rustler::Term;

type PragmaGetResults = Vec<Vec<(String, XqliteValue)>>;

#[rustler::nif(schedule = "DirtyIo")]
fn pragma_get0<'a>(
    container: ResourceArc<XqliteConnection>,
    pragma_name: &str,
    opts: Vec<Term>,
) -> SharedResult<'a, PragmaGetResults> {
    use_conn(container, |conn| {
        let database_name = database_name_from_opts(&opts);

        let mut acc: Vec<Vec<(String, XqliteValue)>> = Vec::new();
        let gather_pragmas = |row: &rusqlite::Row| -> rusqlite::Result<()> {
            let column_count = row.column_count();
            let mut fields: Vec<(String, XqliteValue)> = Vec::with_capacity(column_count);
            for i in 0..column_count {
                if let Ok(name) = row.column_name(i) {
                    if let Ok(value) = row.get(i) {
                        fields.push((String::from(name), XqliteValue(value)));
                    }
                }
            }

            acc.push(fields);
            Ok(())
        };

        match conn.pragma_query(Some(database_name), pragma_name, gather_pragmas) {
            Ok(_) => SharedResult::Success(acc),
            Err(e) => SharedResult::Failure(e.to_string()),
        }
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn pragma_get1<'a>(
    container: ResourceArc<XqliteConnection>,
    pragma_name: &str,
    param: &str,
    opts: Vec<Term>,
) -> SharedResult<'a, PragmaGetResults> {
    use_conn(container, |conn| {
        let database_name = database_name_from_opts(&opts);

        let mut acc: Vec<Vec<(String, XqliteValue)>> = Vec::new();
        let gather_pragmas = |row: &rusqlite::Row| -> rusqlite::Result<()> {
            let column_count = row.column_count();
            let mut fields: Vec<(String, XqliteValue)> = Vec::with_capacity(column_count);
            for i in 0..column_count {
                if let Ok(name) = row.column_name(i) {
                    if let Ok(value) = row.get(i) {
                        fields.push((String::from(name), XqliteValue(value)));
                    }
                }
            }

            acc.push(fields);
            Ok(())
        };

        match conn.pragma(
            Some(database_name),
            pragma_name,
            &String::from(param),
            gather_pragmas,
        ) {
            Ok(_) => SharedResult::Success(acc),
            Err(e) => SharedResult::Failure(e.to_string()),
        }
    })
}
