use crate::shared::{
    database_name_from_opts, use_conn, SharedResult, XqliteConnection, XqliteValue,
};
use rustler::ResourceArc;
use rustler::Term;

type PragmaGetResults = Vec<Vec<XqliteValue>>;

#[rustler::nif(schedule = "DirtyIo")]
fn pragma_get0<'a>(
    container: ResourceArc<XqliteConnection>,
    pragma_name: &str,
    opts: Vec<Term>,
) -> SharedResult<'a, PragmaGetResults> {
    use_conn(container, |conn| {
        let database_name = database_name_from_opts(&opts);

        let mut acc: Vec<Vec<XqliteValue>> = Vec::new();
        let gather_pragmas = |row: &rusqlite::Row| -> rusqlite::Result<()> {
            let mut i: usize = 0;

            // Pragmas don't return a lot of results, so 4 is adequate.
            let mut fields: Vec<XqliteValue> = Vec::with_capacity(4);

            while let Ok(value) = row.get(i) {
                fields.push(XqliteValue(value));
                i += 1;
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

        let mut acc: Vec<Vec<XqliteValue>> = Vec::new();
        let gather_pragmas = |row: &rusqlite::Row| -> rusqlite::Result<()> {
            let mut i: usize = 0;

            // Pragmas don't return a lot of results, so 4 is adequate.
            let mut fields: Vec<XqliteValue> = Vec::with_capacity(4);

            while let Ok(value) = row.get(i) {
                fields.push(XqliteValue(value));
                i += 1;
            }

            acc.push(fields);
            Ok(())
        };

        match conn.pragma(
            Some(database_name),
            pragma_name,
            String::from(param),
            gather_pragmas,
        ) {
            Ok(_) => SharedResult::Success(acc),
            Err(e) => SharedResult::Failure(e.to_string()),
        }
    })
}
