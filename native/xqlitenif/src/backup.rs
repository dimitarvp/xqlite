use crate::cancel::cancel_if_signalled;
use crate::error::XqliteError;
use rusqlite::backup::{Backup, StepResult};
use rusqlite::{Connection, OpenFlags, ffi};
use std::ffi::c_int;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

/// Copies `schema` of `conn` over the main database of the file at
/// `dest_path`, `pages` pages a step. The tokens are read before the file is
/// opened, so a signalled one creates no file, and between steps.
pub(crate) fn backup_to(
    conn: &Connection,
    schema: &str,
    dest_path: &str,
    pages: c_int,
    tokens: &[Arc<AtomicBool>],
    on_step: impl FnMut(Option<(c_int, c_int)>, &[u8]),
) -> Result<(), XqliteError> {
    cancel_if_signalled(tokens)?;
    let mut dst = open_file(dest_path, OpenFlags::default())?;
    let backup = Backup::new_with_names(conn, schema, &mut dst, "main")?;
    run(&backup, pages, tokens, on_step)
}

/// Copies the main database of the file at `src_path` over `schema`. The file
/// is opened read-only and never created. A source with no pages is rejected
/// before anything is copied, and so is a copy while any statement, stream or
/// blob of the connection is mid-run, since the copy's end drops every cached
/// schema.
pub(crate) fn restore_from(
    conn: &mut Connection,
    schema: &str,
    src_path: &str,
    read_only: bool,
) -> Result<(), XqliteError> {
    // The backup API writes past `query_only`, which is all that keeps a
    // read-only connection on a shared cache opened read-write from writing.
    if read_only {
        return Err(XqliteError::CannotRestoreReadOnly);
    }
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY
        | OpenFlags::SQLITE_OPEN_NO_MUTEX
        | OpenFlags::SQLITE_OPEN_URI;
    let src = open_file(src_path, flags)?;
    let pages: i64 = src.query_row("PRAGMA page_count", [], |row| row.get(0))?;
    if pages == 0 {
        return Err(XqliteError::NoPages);
    }
    crate::progress_dispatch::require_idle(conn)?;
    let restore = Backup::new_with_names(&src, "main", conn, schema)?;
    run(&restore, 100, &[], |_, _| ())
}

/// Opens the file at `path` with no busy wait, so a lock another connection
/// holds on it answers at once rather than after rusqlite's 5000 ms, and
/// rejects a name SQLite gives no file for — `""`, `:memory:` or another
/// in-memory name, which it opens as a new empty database — with
/// `SQLITE_CANTOPEN`.
fn open_file(path: &str, flags: OpenFlags) -> Result<Connection, XqliteError> {
    let conn = Connection::open_with_flags(path, flags).map_err(|err| match err {
        rusqlite::Error::SqliteFailure(ffi_err, message) => XqliteError::CannotOpenDatabase {
            path: path.to_string(),
            code: ffi_err.extended_code,
            message: message.unwrap_or_else(|| ffi_err.to_string()),
        },
        other => XqliteError::from(other),
    })?;
    conn.busy_timeout(Duration::ZERO)?;
    if conn.path().is_none_or(str::is_empty) {
        return Err(XqliteError::CannotOpenDatabase {
            path: path.to_string(),
            code: ffi::SQLITE_CANTOPEN,
            message: format!("no database file at {path:?}"),
        });
    }
    Ok(conn)
}

fn run(
    backup: &Backup<'_, '_>,
    pages: c_int,
    tokens: &[Arc<AtomicBool>],
    mut on_step: impl FnMut(Option<(c_int, c_int)>, &[u8]),
) -> Result<(), XqliteError> {
    let mut counts = None;
    let code = loop {
        let step = match backup.step(pages) {
            Err(rusqlite::Error::SqliteFailure(error, _))
                if matches!(
                    error.extended_code & 0xFF,
                    ffi::SQLITE_BUSY | ffi::SQLITE_LOCKED
                ) =>
            {
                break error.extended_code;
            }
            step => step?,
        };
        if matches!(step, StepResult::Done | StepResult::More) {
            let progress = backup.progress();
            counts = Some((progress.remaining, progress.pagecount));
            on_step(counts, b"copied");
        }
        match step {
            StepResult::Done => return Ok(()),
            StepResult::More => cancel_if_signalled(tokens)?,
            StepResult::Busy => break ffi::SQLITE_BUSY,
            _locked => break ffi::SQLITE_LOCKED,
        }
    };
    on_step(counts, b"busy");
    Err(rejected_step(code))
}

/// The error for a step SQLite rejected with `code`, carrying SQLite's text
/// for the code.
fn rejected_step(code: c_int) -> XqliteError {
    // SAFETY: sqlite3_errstr reads no connection; it answers a pointer to a
    // static string, or NULL for a code it has no text for.
    let text = unsafe { ffi::sqlite3_errstr(code) };
    let message = (!text.is_null()).then(|| {
        // SAFETY: a non-NULL answer points to a static NUL-terminated string.
        unsafe { std::ffi::CStr::from_ptr(text) }
            .to_string_lossy()
            .into_owned()
    });
    XqliteError::from(rusqlite::Error::SqliteFailure(
        ffi::Error::new(code),
        message,
    ))
}
