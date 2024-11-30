use crate::shared::{use_conn, SharedResult, XqliteConnection};
use rusqlite::params;
use rustler::ResourceArc;

#[rustler::nif(schedule = "DirtyIo")]
fn exec<'a>(container: ResourceArc<XqliteConnection>, sql: String) -> SharedResult<'a, usize> {
    use_conn(container, |conn| match conn.execute(&sql, params![]) {
        Ok(affected) => SharedResult::Success(affected),
        Err(e) => SharedResult::Failure(e.to_string()),
    })
}
