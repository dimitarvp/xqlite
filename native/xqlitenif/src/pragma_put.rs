use crate::shared::{
    database_name_from_opts, term_to_pragma_value, use_conn, SharedResult, XqliteConnection,
    XqliteValue,
};
use rustler::ResourceArc;
use rustler::Term;

type PragmaPutResults = Vec<Vec<XqliteValue>>;

#[rustler::nif(schedule = "DirtyIo")]
fn pragma_put<'a>(
    container: ResourceArc<XqliteConnection>,
    pragma_name: &str,
    pragma_value: Term<'a>,
    opts: Vec<Term>,
) -> SharedResult<'a, PragmaPutResults> {
    use_conn(container, |conn| {
        let native_pragma_value: rusqlite::types::Value =
            match term_to_pragma_value(pragma_value) {
                Ok(value) => value,
                Err(term) => return SharedResult::UnsupportedValue(term),
            };

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

        match conn.pragma_update_and_check(
            Some(database_name),
            pragma_name,
            native_pragma_value,
            gather_pragmas,
        ) {
            Ok(_) => SharedResult::Success(acc),
            Err(e) => match e {
                rusqlite::Error::QueryReturnedNoRows => SharedResult::SuccessWithoutValue,
                _ => SharedResult::Failure(e.to_string()),
            },
        }
    })
}
