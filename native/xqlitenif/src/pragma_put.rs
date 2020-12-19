use crate::shared::{
    database_name_from_opts, term_to_pragma_value, use_conn, SharedResult, XqliteConnection,
    XqliteValue,
};
use rustler::resource::ResourceArc;
use rustler::Term;

type PragmaPutResults = Vec<Vec<(String, XqliteValue)>>;

#[rustler::nif(schedule = "DirtyIo")]
fn pragma_put<'a>(
    container: ResourceArc<XqliteConnection>,
    pragma_name: &str,
    pragma_value: Term<'a>,
    opts: Vec<Term>,
) -> SharedResult<'a, PragmaPutResults> {
    use_conn(container, |conn| {
        let native_pragma_value: rusqlite::types::Value;

        match term_to_pragma_value(pragma_value) {
            Ok(value) => {
                native_pragma_value = value;
            }
            Err(term) => return SharedResult::UnsupportedValue(term),
        }

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

        match conn.pragma_update_and_check(
            Some(database_name),
            pragma_name,
            &native_pragma_value,
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
