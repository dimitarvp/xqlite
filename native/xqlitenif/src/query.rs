use crate::shared::{use_conn, SharedResult, XqliteConnection, XqliteValue};
use rustler::resource::ResourceArc;

type QueryResults = Vec<Vec<XqliteValue>>;

#[rustler::nif(schedule = "DirtyIo")]
fn query<'a>(
    container: ResourceArc<XqliteConnection>,
    sql: String,
) -> SharedResult<'a, QueryResults> {
    use_conn(container, |conn| {
        // Prepare SQL statement.
        let mut stmt = match conn.prepare(&sql) {
            Ok(x) => x,
            Err(e) => return SharedResult::Failure(e.to_string()),
        };

        let column_count = stmt.column_count();

        // Execute query.
        let mut rows = match stmt.query([]) {
            Ok(x) => x,
            Err(e) => return SharedResult::Failure(e.to_string()),
        };

        let mut records = Vec::new();

        // Populate and return results.
        loop {
            match rows.next() {
                Err(e) => return SharedResult::Failure(e.to_string()),
                Ok(None) => break,
                Ok(Some(row)) => {
                    let mut record = Vec::with_capacity(column_count);
                    for i in 0..column_count {
                        match row.get(i) {
                            Ok(val) => record.push(XqliteValue(val)),
                            // If any record's column value fetching fails,
                            // then we fail the entire query.
                            Err(e) => return SharedResult::Failure(e.to_string()),
                        }
                    }
                    records.push(record);
                }
            };
        }

        SharedResult::Success(records)
    })
}
