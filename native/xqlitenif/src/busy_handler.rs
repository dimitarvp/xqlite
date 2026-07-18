use crate::error::XqliteError;
use crate::hook_util;
use rusqlite::{Connection, ffi};
use rustler::sys::{
    enif_alloc_env, enif_free_env, enif_make_int64, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;
use std::os::raw::{c_int, c_void};
use std::sync::atomic::{AtomicPtr, Ordering};
use std::time::Instant;

/// Retry policy half of the busy slot: decides retry vs give up.
/// Single-slot by design — a policy cannot compose.
#[derive(Clone)]
pub(crate) struct BusyPolicy {
    pub(crate) max_retries: u32,
    pub(crate) max_elapsed_ms: u64,
    pub(crate) sleep_ms: u64,
}

/// State kept alive while the busy callback is installed on a connection:
/// an optional retry policy plus any number of observer subscribers.
///
/// Allocated via `Box::into_raw`, stored as a raw pointer in
/// `XqliteConn.busy_handler`, and reclaimed on mutation, by `Drop`, or
/// when the slot empties (no policy, no observers → callback removed).
///
/// Mutation concurrency: every mutator runs under the connection Mutex,
/// and the C callback only ever runs inside `sqlite3_step`/friends —
/// which also hold that Mutex — so a mutation can never race a callback
/// read. Plain snapshot-build-swap is sufficient; no copy-on-write list.
pub(crate) struct BusySlotState {
    policy: Option<BusyPolicy>,
    observers: Vec<(u64, LocalPid)>,
    next_handle: u64,
    start: Instant,
}

impl std::fmt::Debug for BusySlotState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BusySlotState")
            .field("has_policy", &self.policy.is_some())
            .field("observer_count", &self.observers.len())
            .finish()
    }
}

/// The C callback SQLite invokes on SQLITE_BUSY. Fans
/// `{:xqlite_busy, retries, elapsed_ms}` out to every observer, then
/// applies the policy: retry (1) or surface SQLITE_BUSY (0). With no
/// policy installed the answer is always 0 — pure observation.
///
/// # Safety
///
/// `user_data` must point to a `BusySlotState` previously installed and
/// not yet reclaimed. SQLite guarantees the pointer is exactly what we
/// passed to `sqlite3_busy_handler`, and the connection Mutex (held by
/// the stepping caller) excludes concurrent mutation.
unsafe extern "C" fn busy_callback(user_data: *mut c_void, count: c_int) -> c_int {
    // Guard the body against a future panic: this callback is registered
    // via raw `ffi::sqlite3_busy_handler`, so — unlike rusqlite's own busy
    // trampoline — nothing catches a panic before it unwinds into SQLite's
    // C stack. Fallback 0 stops retrying and surfaces SQLITE_BUSY: a clean,
    // defined outcome, and never an unbounded retry loop.
    hook_util::guard_ffi_callback("busy_callback", 0, move || {
        // SAFETY: `user_data` is the Box<BusySlotState> pointer we leaked on
        // install; mutators hold the same connection Mutex as the caller
        // driving this callback, so the pointee cannot be reclaimed mid-read.
        let state = unsafe { &*(user_data as *const BusySlotState) };

        let retries = count as u32;
        let elapsed_ms = state.start.elapsed().as_millis() as u64;

        for (_handle, pid) in &state.observers {
            // SAFETY: see `send_busy_to_pid`. All data is copied into a fresh
            // msg_env; we never retain references across the call.
            unsafe {
                send_busy_to_pid(pid, retries, elapsed_ms);
            }
        }

        match &state.policy {
            None => 0,
            Some(policy) => {
                if retries >= policy.max_retries || elapsed_ms >= policy.max_elapsed_ms {
                    return 0; // surface SQLITE_BUSY to the caller
                }

                if policy.sleep_ms > 0 {
                    std::thread::sleep(std::time::Duration::from_millis(policy.sleep_ms));
                }

                1 // retry
            }
        }
    })
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

/// Set (or replace) the retry policy. Installs the callback if the slot
/// was empty. Callers must hold the connection Mutex.
pub(crate) fn set_policy(
    conn: &Connection,
    slot: &AtomicPtr<BusySlotState>,
    policy: BusyPolicy,
) -> Result<(), XqliteError> {
    let mut next = snapshot(slot);
    next.policy = Some(policy);
    swap_in(conn, slot, next)
}

/// Remove the retry policy, keeping any observers. Empties and removes
/// the callback when no observers remain. Safe to call with no policy
/// installed. Callers must hold the connection Mutex.
pub(crate) fn remove_policy(
    conn: &Connection,
    slot: &AtomicPtr<BusySlotState>,
) -> Result<(), XqliteError> {
    let mut next = snapshot(slot);
    next.policy = None;
    swap_in(conn, slot, next)
}

/// Register an observer pid; returns its unregistration handle.
/// Installs the callback if the slot was empty. Callers must hold the
/// connection Mutex.
pub(crate) fn register_observer(
    conn: &Connection,
    slot: &AtomicPtr<BusySlotState>,
    pid: LocalPid,
) -> Result<u64, XqliteError> {
    let mut next = snapshot(slot);
    let handle = next.next_handle;
    next.next_handle += 1;
    next.observers.push((handle, pid));
    swap_in(conn, slot, next)?;
    Ok(handle)
}

/// Unregister an observer by handle. Idempotent — an unknown handle is a
/// no-op. Empties and removes the callback when nothing remains.
/// Callers must hold the connection Mutex.
pub(crate) fn unregister_observer(
    conn: &Connection,
    slot: &AtomicPtr<BusySlotState>,
    handle: u64,
) -> Result<(), XqliteError> {
    let mut next = snapshot(slot);
    next.observers.retain(|(h, _pid)| *h != handle);
    swap_in(conn, slot, next)
}

/// Clone the current slot contents (or a fresh empty state), preserving
/// the install-time `start` instant and handle counter across mutations.
///
/// Callers must hold the connection Mutex — that is what makes the raw
/// read of the current pointee sound (no concurrent reclaim, no
/// concurrent callback).
fn snapshot(slot: &AtomicPtr<BusySlotState>) -> BusySlotState {
    let current = slot.load(Ordering::Acquire);

    if current.is_null() {
        BusySlotState {
            policy: None,
            observers: Vec::new(),
            next_handle: 0,
            start: Instant::now(),
        }
    } else {
        // SAFETY: non-null slot pointers always point to a live
        // BusySlotState; the connection Mutex excludes reclamation.
        let state = unsafe { &*current };
        BusySlotState {
            policy: state.policy.clone(),
            observers: state.observers.clone(),
            next_handle: state.next_handle,
            start: state.start,
        }
    }
}

/// Swap the derived state in: empty states clear the C callback and the
/// slot; non-empty states (re-)register the callback pointing at the new
/// allocation. Both paths reclaim the previous allocation.
fn swap_in(
    conn: &Connection,
    slot: &AtomicPtr<BusySlotState>,
    next: BusySlotState,
) -> Result<(), XqliteError> {
    if next.policy.is_none() && next.observers.is_empty() {
        hook_util::uninstall_hook(slot, || {
            // SAFETY: caller holds the connection Mutex. Passing None+null
            // clears any registered handler; calling with no handler
            // installed is valid.
            let rc = unsafe {
                ffi::sqlite3_busy_handler(conn.handle(), None, std::ptr::null_mut())
            };
            if rc != ffi::SQLITE_OK {
                return Err(ffi_rc_to_error(conn, rc));
            }
            Ok(())
        })
    } else {
        hook_util::install_hook(slot, next, |new_ptr| {
            // SAFETY: caller holds the connection Mutex; `conn.handle()`
            // yields the raw db pointer for that locked connection.
            let rc = unsafe {
                ffi::sqlite3_busy_handler(
                    conn.handle(),
                    Some(busy_callback),
                    new_ptr as *mut c_void,
                )
            };
            if rc != ffi::SQLITE_OK {
                return Err(ffi_rc_to_error(conn, rc));
            }
            Ok(())
        })
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
