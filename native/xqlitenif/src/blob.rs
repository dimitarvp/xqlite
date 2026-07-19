use crate::connection::{self, XqliteConn};
use crate::error::XqliteError;
use crate::session::to_owned_binary;
use rusqlite::ffi;
use rustler::{Resource, ResourceArc, resource_impl};
use std::io::Write;
use std::os::raw::c_int;
use std::sync::atomic::{AtomicPtr, Ordering};

/// An open incremental-BLOB handle, owned as a RAW `*mut sqlite3_blob`.
///
/// This resource deliberately stores NO rusqlite `Blob` wrapper, and no future
/// maintainer may reintroduce one (see the WARNING below): doing so reopens a
/// use-after-move memory-safety bug that was already shipped and fixed once (in
/// `b1c60b4`). The rusqlite file:line citations below are from 0.40.1.
///
/// A rusqlite `Blob<'conn>` holds a real `&Connection` (`blob/mod.rs:202`) and
/// dereferences it on `Drop`: `Blob::drop` (`blob/mod.rs:399`) -> `close_()`
/// (`:302`) -> `self.conn.decode_result(rc)` (`:305`) ->
/// `Connection::decode_result` -> `self.db.borrow()` (`lib.rs:1033`) ->
/// `InnerConnection::decode_result` reads the raw db (`inner_connection.rs:135`,
/// `:131`). The old `blob_open` `transmute`d that borrow to `Blob<'static>` and
/// stored it here. When `close_connection` does `conn_guard.take()` (our
/// `connection.rs:176`), the inner `Connection` is moved out of
/// `Mutex<Option<Connection>>` and dropped, so the deref chain above reads a
/// moved-from value — a use-after-move reachable from the shipped `blob_close`
/// path AND from GC-drop of a live blob whose connection was already closed. The
/// native build hid it because the moved-from bytes read benignly on the
/// `SQLITE_OK` path; a different `Option` layout would instead panic in `Drop`,
/// and rustler 0.38 resource destructors have no `catch_unwind`, so that panic
/// unwinds into C and crashes the BEAM.
///
/// The C `sqlite3*` itself never dangles: an open blob registers an internal
/// Vdbe (`pBlob->pStmt`), so `sqlite3_close` (v1) sees `connectionIsBusy`,
/// returns `SQLITE_BUSY`, and leaves the db alive (SQLite amalgamation fact; see
/// `close`). ONLY the Rust `&Connection` wrapper was ever left dangling.
///
/// A Miri pattern-model demonstrated the UB: a `&T` into an `Option<T>` slot,
/// `.take()` drops the `T`, then a `Drop` derefs the stale `&T` — Miri reports
/// "reading uninitialized memory". That interim repro crate has since been
/// removed after serving its purpose.
///
/// MAINTAINER WARNING: never store a rusqlite `Blob` — or a `Session`, or ANY
/// lifetime-erased wrapper whose `Drop` dereferences an `&Connection` — in a
/// resource that can outlive an explicit connection close. Always own the raw C
/// handle and call the `sqlite3_*` C functions directly under the connection
/// `Mutex`. `session.rs` stores a `Session<'static>` safely ONLY because
/// rusqlite `Session` holds `PhantomData<&Connection>` (`session.rs:26`), so its
/// `Drop` touches only the raw `self.s` (`session.rs:207`) and never derefs the
/// connection. That is a fragile distinction — do NOT "unify" the two resources
/// by giving `XqliteSession` a real wrapper.
///
/// The pointer lives in an `AtomicPtr` (null == closed/finalized), mirroring
/// `XqliteStream`/`XqliteStatement`. Every `sqlite3_blob_*` call holds the
/// connection `Mutex` for its whole duration (the raw-handle locking rule) via
/// `with_live_blob`/`close`; `conn_resource_arc` keeps the `XqliteConn`
/// *resource* alive so the Mutex is always lockable, even after the inner
/// `Connection` is gone.
pub(crate) struct XqliteBlob {
    pub(crate) blob: AtomicPtr<ffi::sqlite3_blob>,
    pub(crate) conn_resource_arc: ResourceArc<XqliteConn>,
}

#[resource_impl]
impl Resource for XqliteBlob {}

impl Drop for XqliteBlob {
    fn drop(&mut self) {
        if let Err(e) = close(self) {
            // Errors from Drop cannot be propagated. Log to stderr — writeln!,
            // never eprintln!: eprintln! panics on a broken stderr (EPIPE), and
            // rustler 0.38 resource destructors have no catch_unwind, so a panic
            // here would unwind into C and kill the VM.
            let _ = writeln!(
                std::io::stderr(),
                "[xqlite] Error closing SQLite blob during resource drop: {e:?}"
            );
        }
    }
}

/// Open a blob and wrap its raw pointer. Runs entirely under the connection
/// Mutex (via `with_conn`), proving the connection open before the raw
/// `sqlite3_blob_open`.
pub(crate) fn open(
    handle: &ResourceArc<XqliteConn>,
    db: &str,
    table: &str,
    column: &str,
    row_id: i64,
    read_only: bool,
) -> Result<ResourceArc<XqliteBlob>, XqliteError> {
    connection::with_conn(handle, |conn| {
        let c_db = std::ffi::CString::new(db).map_err(|_| XqliteError::NulErrorInString)?;
        let c_table =
            std::ffi::CString::new(table).map_err(|_| XqliteError::NulErrorInString)?;
        let c_column =
            std::ffi::CString::new(column).map_err(|_| XqliteError::NulErrorInString)?;

        // SAFETY: `with_conn` holds the connection Mutex, so `conn.handle()`
        // yields the live `sqlite3*`. `sqlite3_blob_open` writes `blob_ptr`
        // only on SQLITE_OK; the C string pointers are valid for the call.
        let raw_db = unsafe { conn.handle() };
        let mut blob_ptr: *mut ffi::sqlite3_blob = std::ptr::null_mut();
        let rc = unsafe {
            ffi::sqlite3_blob_open(
                raw_db,
                c_db.as_ptr(),
                c_table.as_ptr(),
                c_column.as_ptr(),
                row_id,
                c_int::from(!read_only),
                &mut blob_ptr,
            )
        };
        if rc != ffi::SQLITE_OK {
            // SAFETY: raw_db is valid while the connection Mutex is held.
            return Err(unsafe { blob_error(raw_db, rc) });
        }
        Ok(ResourceArc::new(XqliteBlob {
            blob: AtomicPtr::new(blob_ptr),
            conn_resource_arc: handle.clone(),
        }))
    })
}

/// Read up to `length` bytes at `offset`. Clamps to the bytes available and
/// returns an empty binary when `offset` is at or past the end (preserving the
/// original rusqlite `read_at_exact`-based behavior).
pub(crate) fn read(
    blob_handle: &ResourceArc<XqliteBlob>,
    offset: usize,
    length: usize,
) -> Result<rustler::OwnedBinary, XqliteError> {
    with_live_blob(blob_handle, |ptr, db| {
        // SAFETY: `ptr` is a live `sqlite3_blob` held under the connection Mutex.
        let size = unsafe { ffi::sqlite3_blob_bytes(ptr) }.max(0) as usize;
        let actual_len = if offset >= size {
            0
        } else {
            std::cmp::min(length, size - offset)
        };
        if actual_len == 0 {
            // Nothing in range: return an empty binary WITHOUT touching SQLite,
            // exactly as rusqlite's `raw_read_at` short-circuits `read_len == 0`.
            return to_owned_binary(&[], "blob read");
        }
        // `0 <= offset < size` and `offset + actual_len <= size`, and `size`
        // came from an i32, so both casts are lossless.
        let c_offset = offset as c_int;
        let c_len = actual_len as c_int;
        // Read straight into the OwnedBinary we hand back — a single alloc + a
        // single copy (was: a `vec![0; n]` staging buffer plus a second
        // alloc+copy through `to_owned_binary`, i.e. 2 allocs / 2 memcpys and a
        // transient 2x peak). `sqlite3_blob_read` writes exactly `actual_len`
        // bytes on SQLITE_OK, so every byte of the freshly-allocated (and thus
        // uninitialised) binary is filled before it can escape; on any error we
        // drop it, never releasing it to the BEAM.
        let mut binary = rustler::OwnedBinary::new(actual_len).ok_or_else(|| {
            XqliteError::InternalEncodingError {
                context: "failed to allocate binary for blob read".to_string(),
            }
        })?;
        // SAFETY: `binary` owns `actual_len` writable bytes; `[offset, offset +
        // actual_len)` is in bounds (checked above); `ptr`/`db` are valid under
        // the Mutex.
        let rc = unsafe {
            ffi::sqlite3_blob_read(
                ptr,
                binary.as_mut_slice().as_mut_ptr().cast(),
                c_len,
                c_offset,
            )
        };
        if rc != ffi::SQLITE_OK {
            // SAFETY: `db` is valid while the connection Mutex is held.
            return Err(unsafe { blob_error(db, rc) });
        }
        Ok(binary)
    })
}

/// Write `data` at `offset`. A write that would extend past the end of the blob
/// is an error and writes nothing (matching rusqlite `Blob::write_at`).
pub(crate) fn write(
    blob_handle: &ResourceArc<XqliteBlob>,
    offset: usize,
    data: &[u8],
) -> Result<(), XqliteError> {
    with_live_blob(blob_handle, |ptr, db| {
        // SAFETY: `ptr` is a live `sqlite3_blob` held under the connection Mutex.
        let size = unsafe { ffi::sqlite3_blob_bytes(ptr) }.max(0) as usize;
        if data.len().saturating_add(offset) > size {
            return Err(XqliteError::from(rusqlite::Error::BlobSizeError));
        }
        // Bounds above prove `offset` and `data.len()` each fit in the i32
        // `size`, so both casts are lossless.
        let c_offset = offset as c_int;
        let c_len = data.len() as c_int;
        // SAFETY: `[offset, offset + data.len())` is in bounds (checked above);
        // SQLite copies from `data` during the call; `ptr`/`db` valid under the
        // Mutex.
        let rc =
            unsafe { ffi::sqlite3_blob_write(ptr, data.as_ptr().cast(), c_len, c_offset) };
        if rc != ffi::SQLITE_OK {
            // SAFETY: `db` is valid while the connection Mutex is held.
            return Err(unsafe { blob_error(db, rc) });
        }
        Ok(())
    })
}

/// Current size of the blob in bytes.
pub(crate) fn size(blob_handle: &ResourceArc<XqliteBlob>) -> Result<usize, XqliteError> {
    with_live_blob(blob_handle, |ptr, _db| {
        // SAFETY: `ptr` is a live `sqlite3_blob` held under the connection Mutex;
        // `sqlite3_blob_bytes` returns the cached, non-negative byte count.
        Ok(unsafe { ffi::sqlite3_blob_bytes(ptr) }.max(0) as usize)
    })
}

/// Move this blob handle to a different row of the same table/column.
pub(crate) fn reopen(
    blob_handle: &ResourceArc<XqliteBlob>,
    row_id: i64,
) -> Result<(), XqliteError> {
    with_live_blob(blob_handle, |ptr, db| {
        // SAFETY: `ptr` is a live `sqlite3_blob` held under the connection Mutex.
        let rc = unsafe { ffi::sqlite3_blob_reopen(ptr, row_id) };
        if rc != ffi::SQLITE_OK {
            // SAFETY: `db` is valid while the connection Mutex is held.
            return Err(unsafe { blob_error(db, rc) });
        }
        Ok(())
    })
}

/// Close the `sqlite3_blob` under the connection Mutex. Shared by the
/// `blob_close` NIF and `Drop`; idempotent (a null pointer means already
/// closed).
///
/// Mirrors `stream::take_and_finalize_raw`: atomically swap the pointer to null
/// (exclusive ownership, no racing close), then close under the connection
/// Mutex so no concurrent `sqlite3_*` runs on the same NOMUTEX connection.
///
/// Closing is sound even after the connection was explicitly closed. An open
/// blob registers an internal Vdbe (`pBlob->pStmt`, on `db->pVdbe`), so
/// `connectionIsBusy` is true and `sqlite3_close` (v1) returns `SQLITE_BUSY`
/// without freeing `db` — rusqlite's `Connection` Drop discards that result, so
/// the `sqlite3*` is leaked-but-alive. `sqlite3_blob_close` therefore operates
/// on a valid db either way, unlike the old rusqlite-`Blob` teardown that
/// dereferenced a possibly moved-from `&Connection`. On a poisoned connection
/// lock we must not touch SQLite state, so we leak the blob instead.
pub(crate) fn close(blob_handle: &XqliteBlob) -> Result<(), XqliteError> {
    let old_ptr = blob_handle
        .blob
        .swap(std::ptr::null_mut(), Ordering::AcqRel);
    if !old_ptr.is_null() {
        let _conn_guard = blob_handle
            .conn_resource_arc
            .conn
            .lock()
            .map_err(|e| XqliteError::LockError(e.to_string()))?;
        // SAFETY: `old_ptr` came from the atomic swap, so we exclusively own it
        // and no other close can race it. The connection Mutex is held, so no
        // concurrent `sqlite3_*` runs on this db, and the open blob kept the db
        // alive (see the doc comment). `sqlite3_blob_close`'s flush result is
        // discarded — the blob is destroyed regardless, per SQLite.
        let _ = unsafe { ffi::sqlite3_blob_close(old_ptr) };
    }
    Ok(())
}

/// Runs `f` with the connection Mutex held, the connection proven open, and the
/// raw blob pointer proven live. Passes the raw `sqlite3_blob*` plus the owning
/// `sqlite3*` (for error reporting). Mirrors
/// `XqliteStatement::with_live_stmt`.
///
/// Lock-then-load makes this sound against a concurrent close: a closer may
/// swap the pointer to null at any moment, but it cannot call
/// `sqlite3_blob_close` without this same Mutex — so a pointer loaded non-null
/// *under the lock* stays valid until the guard drops.
#[inline]
fn with_live_blob<F, R>(blob_handle: &ResourceArc<XqliteBlob>, f: F) -> Result<R, XqliteError>
where
    F: FnOnce(*mut ffi::sqlite3_blob, *mut ffi::sqlite3) -> Result<R, XqliteError>,
{
    let guard = blob_handle
        .conn_resource_arc
        .conn
        .lock()
        .map_err(|e| XqliteError::LockError(e.to_string()))?;
    let conn = guard.as_ref().ok_or(XqliteError::ConnectionClosed)?;

    let ptr = blob_handle.blob.load(Ordering::Acquire);
    if ptr.is_null() {
        return Err(XqliteError::ConnectionClosed);
    }
    // SAFETY: `handle()` only extracts the raw `sqlite3*`; `guard` keeps the
    // Connection alive (and exclusively ours) for the whole duration of `f`.
    let db = unsafe { conn.handle() };
    f(ptr, db)
}

/// Builds an `XqliteError` from a non-OK blob result code, classified exactly as
/// rusqlite's `decode_result` would: read `sqlite3_errmsg` off the db handle,
/// then route through `XqliteError::from`.
///
/// # Safety
///
/// `db` must be the valid `sqlite3*` owning the blob, held under the connection
/// Mutex for the duration of this call.
#[inline]
unsafe fn blob_error(db: *mut ffi::sqlite3, rc: c_int) -> XqliteError {
    // SAFETY: `db` is valid under the connection Mutex; `sqlite3_errmsg` returns
    // an internal buffer valid until the next API call, and we copy immediately.
    let message = unsafe {
        let err_msg_ptr = ffi::sqlite3_errmsg(db);
        if err_msg_ptr.is_null() {
            format!("SQLite blob operation failed (code {rc})")
        } else {
            std::ffi::CStr::from_ptr(err_msg_ptr)
                .to_string_lossy()
                .into_owned()
        }
    };
    XqliteError::from(rusqlite::Error::SqliteFailure(
        ffi::Error::new(rc),
        Some(message),
    ))
}
