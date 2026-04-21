use crate::error::XqliteError;
use crate::hook_util;
use rusqlite::{Connection, ffi};
use rustler::sys::{
    enif_alloc_env, enif_free_env, enif_make_int64, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;
use std::os::raw::{c_int, c_void};
use std::sync::atomic::AtomicPtr;
use std::time::Instant;

/// State kept alive while a busy handler is installed on a connection.
///
/// Allocated via `Box::into_raw`, stored as a raw pointer in
/// `XqliteConn.busy_handler`, and reclaimed by `uninstall` or the
/// `XqliteConn` Drop impl.
pub(crate) struct BusyHandlerState {
    pid: LocalPid,
    max_retries: u32,
    max_elapsed_ms: u64,
    sleep_ms: u64,
    start: Instant,
}

impl std::fmt::Debug for BusyHandlerState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BusyHandlerState")
            .field("max_retries", &self.max_retries)
            .field("max_elapsed_ms", &self.max_elapsed_ms)
            .field("sleep_ms", &self.sleep_ms)
            .finish()
    }
}

/// The C callback SQLite invokes on SQLITE_BUSY. Decides retry vs give up,
/// forwards a `{:xqlite_busy, retries, elapsed_ms}` message to the
/// subscriber PID.
///
/// # Safety
///
/// `user_data` must point to a `BusyHandlerState` previously installed via
/// `install` and not yet reclaimed. SQLite guarantees the pointer is exactly
/// what we passed to `sqlite3_busy_handler`.
unsafe extern "C" fn busy_handler_callback(user_data: *mut c_void, count: c_int) -> c_int {
    // SAFETY: `user_data` is the Box<BusyHandlerState> pointer we leaked in
    // `install`. It remains valid until `uninstall` (or connection Drop)
    // clears the SQLite-side handler pointer *before* freeing the box.
    let state = unsafe { &*(user_data as *const BusyHandlerState) };

    let retries = count as u32;
    let elapsed_ms = state.start.elapsed().as_millis() as u64;

    // SAFETY: see `send_busy_to_pid`. All data is copied into a fresh
    // msg_env; we never retain references across the call.
    unsafe {
        send_busy_to_pid(&state.pid, retries, elapsed_ms);
    }

    if retries >= state.max_retries || elapsed_ms >= state.max_elapsed_ms {
        return 0; // surface SQLITE_BUSY to the caller
    }

    if state.sleep_ms > 0 {
        std::thread::sleep(std::time::Duration::from_millis(state.sleep_ms));
    }

    1 // retry
}

/// Send `{:xqlite_busy, retries, elapsed_ms}` to `pid`. Fire-and-forget.
///
/// # Safety
///
/// Since OTP 26.1, `enif_send` with NULL `caller_env` is valid from any
/// thread. We target OTP 26+. All data is copied into `msg_env` before
/// send; no references are retained across the call.
unsafe fn send_busy_to_pid(pid: &LocalPid, retries: u32, elapsed_ms: u64) {
    // SAFETY: all enif_* calls operate on a freshly allocated msg_env.
    unsafe {
        let msg_env = enif_alloc_env();

        let tag = hook_util::make_atom(msg_env, b"xqlite_busy");
        let retries_term = enif_make_int64(msg_env, retries as i64);
        let elapsed_term = enif_make_int64(msg_env, elapsed_ms as i64);

        let elements = [tag, retries_term, elapsed_term];
        let msg = enif_make_tuple_from_array(msg_env, elements.as_ptr(), 3);

        let _res = enif_send(std::ptr::null_mut(), pid.as_c_arg(), msg_env, msg);

        enif_free_env(msg_env);
    }
}

/// Install a busy handler on the given connection.
///
/// Atomically swaps the stored state pointer, reclaiming any previously-
/// installed state. Fails without leaking if SQLite refuses the handler.
///
/// Callers must hold the connection Mutex (via `with_conn`) for the
/// duration of this call — the FFI `sqlite3_busy_handler` mutates
/// connection state.
pub(crate) fn install(
    conn: &Connection,
    slot: &AtomicPtr<BusyHandlerState>,
    state: BusyHandlerState,
) -> Result<(), XqliteError> {
    hook_util::install_hook(slot, state, |new_ptr| {
        // SAFETY: caller holds the connection Mutex; `conn.handle()`
        // yields the raw db pointer for that locked connection.
        let rc = unsafe {
            ffi::sqlite3_busy_handler(
                conn.handle(),
                Some(busy_handler_callback),
                new_ptr as *mut c_void,
            )
        };
        if rc != ffi::SQLITE_OK {
            return Err(ffi_rc_to_error(conn, rc));
        }
        Ok(())
    })
}

/// Remove the busy handler from the given connection.
///
/// Safe to call when no handler is installed — it becomes a no-op on
/// the FFI side and a null-check on the slot side.
///
/// Callers must hold the connection Mutex.
pub(crate) fn uninstall(
    conn: &Connection,
    slot: &AtomicPtr<BusyHandlerState>,
) -> Result<(), XqliteError> {
    hook_util::uninstall_hook(slot, || {
        // SAFETY: caller holds the connection Mutex. Passing None+null
        // clears any registered handler; calling with no handler
        // installed is valid.
        let rc =
            unsafe { ffi::sqlite3_busy_handler(conn.handle(), None, std::ptr::null_mut()) };
        if rc != ffi::SQLITE_OK {
            return Err(ffi_rc_to_error(conn, rc));
        }
        Ok(())
    })
}

// --- NIF-facing constructor -------------------------------------------------

impl BusyHandlerState {
    pub(crate) fn new(
        pid: LocalPid,
        max_retries: u32,
        max_elapsed_ms: u64,
        sleep_ms: u64,
    ) -> Self {
        Self {
            pid,
            max_retries,
            max_elapsed_ms,
            sleep_ms,
            start: Instant::now(),
        }
    }
}

fn ffi_rc_to_error(conn: &Connection, rc: c_int) -> XqliteError {
    // Callers already hold the connection Mutex (public functions document
    // this); `conn.handle()` is valid for the duration of this read.
    let msg = unsafe {
        let ptr = ffi::sqlite3_errmsg(conn.handle());
        if ptr.is_null() {
            format!("sqlite3_busy_handler failed (code {rc})")
        } else {
            std::ffi::CStr::from_ptr(ptr).to_string_lossy().into_owned()
        }
    };
    let ffi_err = ffi::Error::new(rc);
    XqliteError::from(rusqlite::Error::SqliteFailure(ffi_err, Some(msg)))
}
