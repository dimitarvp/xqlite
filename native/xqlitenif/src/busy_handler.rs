use crate::atoms;
use crate::authorizer;
use crate::connection::XqliteConn;
use crate::error::XqliteError;
use crate::hook_util;
use rusqlite::{Connection, ffi};
use rustler::sys::{
    enif_alloc_env, enif_free_env, enif_make_int64, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;
use std::os::raw::{c_int, c_void};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// Every write happens under the connection Mutex; the callbacks write and read
/// these inside a call made under that Mutex too.
#[derive(Debug, Default)]
pub(crate) struct BusySlotFlags {
    internal_read: AtomicBool,
    timeout_written: AtomicBool,
    asked: AtomicBool,
    observer_handles: AtomicU64,
}

impl BusySlotFlags {
    #[inline]
    pub(crate) fn reading_own_pragma(&self) -> bool {
        self.internal_read.load(Ordering::Relaxed)
    }

    /// Run `read`, a PRAGMA read of xqlite's own, with the flag that lets the
    /// authorizer callback pass it whatever the caller denied.
    pub(crate) fn own_read<T>(&self, read: impl FnOnce() -> T) -> T {
        self.internal_read.store(true, Ordering::Relaxed);
        let value = read();
        self.internal_read.store(false, Ordering::Relaxed);
        value
    }

    #[inline]
    pub(crate) fn note_timeout_written(&self) {
        self.timeout_written.store(true, Ordering::Relaxed);
    }

    pub(crate) fn asked(&self) -> bool {
        self.asked.load(Ordering::Relaxed)
    }

    fn next_observer_handle(&self) -> u64 {
        self.observer_handles
            .fetch_add(1, Ordering::Relaxed)
            .wrapping_add(1)
    }
}

/// Retry policy half of the busy slot: decides retry vs give up.
/// Single-slot by design — a policy cannot compose.
#[derive(Clone)]
pub(crate) struct BusyPolicy {
    pub(crate) max_retries: u32,
    pub(crate) max_elapsed_ms: u64,
    pub(crate) sleep_ms: u64,
}

/// The busy slot, xqlite's from the open to the close.
///
/// Allocated via `Box::into_raw`, stored as a raw pointer in
/// `XqliteConn.callback_boxes`, and reclaimed on mutation or by `Drop`.
///
/// Mutation concurrency: every mutator runs under the connection Mutex,
/// and the C callback only ever runs inside `sqlite3_step`/friends —
/// which also hold that Mutex — so a mutation can never race a callback
/// read. Plain snapshot-build-swap is sufficient; no copy-on-write list.
pub(crate) struct BusySlotState {
    policy: Option<BusyPolicy>,
    observers: Vec<(u64, LocalPid)>,
    fallback_timeout_ms: u64,
    flags: Arc<BusySlotFlags>,
}

impl std::fmt::Debug for BusySlotState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BusySlotState")
            .field("has_policy", &self.policy.is_some())
            .field("observer_count", &self.observers.len())
            .finish()
    }
}

/// The C callback SQLite invokes before it answers SQLITE_BUSY. It notes that
/// SQLite asked and answers 0, so the call answers busy at once and the
/// process that made it waits instead (`delay`).
///
/// # Safety
///
/// `user_data` must point to a `BusySlotState` previously installed and
/// not yet reclaimed. SQLite guarantees the pointer is exactly what we
/// passed to `sqlite3_busy_handler`, and the connection Mutex held by the
/// stepping caller, or a dropped connection's close job owning the
/// `Connection`, excludes concurrent mutation.
unsafe extern "C" fn busy_callback(user_data: *mut c_void, _count: c_int) -> c_int {
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
        state.flags.asked.store(true, Ordering::Relaxed);
        0
    })
}

fn policy_delay_ms(policy: &BusyPolicy, retries: u32, elapsed_ms: u64) -> Option<u64> {
    match retries >= policy.max_retries || elapsed_ms >= policy.max_elapsed_ms {
        true => None,
        false => Some(policy.sleep_ms.min(policy.max_elapsed_ms - elapsed_ms)),
    }
}

/// The sleep before retry `retries`, or `None` once `timeout_ms` is spent:
/// `sqliteDefaultBusyCallback`'s tables and clipping, verbatim.
fn fallback_delay_ms(retries: u32, timeout_ms: u64) -> Option<u64> {
    const DELAYS: [u64; 12] = [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100];
    const TOTALS: [u64; 12] = [0, 1, 3, 8, 18, 33, 53, 78, 103, 128, 178, 228];
    const LAST: usize = DELAYS.len() - 1;

    let index = retries as usize;
    let (delay, prior) = if index <= LAST {
        (DELAYS[index], TOTALS[index])
    } else {
        (
            DELAYS[LAST],
            TOTALS[LAST] + DELAYS[LAST] * (index - LAST) as u64,
        )
    };

    if prior + delay > timeout_ms {
        timeout_ms.checked_sub(prior).filter(|clipped| *clipped > 0)
    } else {
        Some(delay)
    }
}

/// Read the connection's `busy_timeout`: the one it opened with, or the one a
/// `PRAGMA busy_timeout` written as SQL just set. The flag around the read
/// tells the authorizer callback that this PRAGMA is xqlite's own, so a caller
/// who denies `:pragma` cannot hide the wait their connection has.
fn read_busy_timeout(conn: &Connection, flags: &BusySlotFlags) -> Result<u64, XqliteError> {
    let read = flags.own_read(|| {
        conn.pragma_query_value(None, "busy_timeout", |row| row.get::<_, i64>(0))
    });

    let ms = read?;
    u64::try_from(ms).map_err(|_| XqliteError::InternalEncodingError {
        context: format!("busy_timeout read back as {ms} ms"),
    })
}

pub(crate) fn busy_timeout_c_int(timeout_ms: u64) -> Result<c_int, XqliteError> {
    c_int::try_from(timeout_ms).map_err(|_| XqliteError::InvalidPragmaValue {
        pragma: atoms::busy_timeout(),
        value: timeout_ms,
    })
}

/// Send `{:xqlite_busy, retries, elapsed_ms}` to `pid`. Fire-and-forget.
///
/// # Safety
///
/// Sends with a NULL `caller_env`, which `hook_util`'s module doc covers.
/// All data is copied into `msg_env` before the send; no references are
/// retained across the call.
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

/// Takes the busy slot as the connection opens, with the timeout it has
/// (rusqlite opens every connection with 5000 ms), and puts on the authorizer
/// that notices a `busy_timeout` written as SQL. Callers hold the connection Mutex.
pub(crate) fn install(conn: &Connection, handle: &XqliteConn) -> Result<(), XqliteError> {
    authorizer::sync(conn, handle)?;
    handle.busy_flags.note_timeout_written();
    rearm(conn, handle)
}

/// One retry of a waiting call, as `XqliteNIF.busy_delay/4` says; callers hold the Mutex.
pub(crate) fn delay(handle: &XqliteConn, retries: u32, elapsed_ms: u64) -> Option<u64> {
    let current = handle.callback_boxes.busy.load(Ordering::Acquire);
    // SAFETY: a non-null slot pointer always points to a live BusySlotState;
    // the connection Mutex the caller holds excludes its reclamation.
    let state = unsafe { current.as_ref() }?;
    for (_handle, pid) in &state.observers {
        // SAFETY: see `send_busy_to_pid`; this runs inside a DirtyIo NIF.
        unsafe { send_busy_to_pid(pid, retries, elapsed_ms) };
    }
    match &state.policy {
        None => fallback_delay_ms(retries, state.fallback_timeout_ms),
        Some(policy) => policy_delay_ms(policy, retries, elapsed_ms),
    }
}

/// Puts xqlite's callback back in a usable state: once it answered, SQLite asks
/// it again only from the next statement's step on, and a `PRAGMA busy_timeout`
/// written as SQL swapped in SQLite's own sleeping handler, whose timeout the
/// slot keeps from then on. Callers hold the connection Mutex.
pub(crate) fn rearm(conn: &Connection, handle: &XqliteConn) -> Result<(), XqliteError> {
    let flags = &handle.busy_flags;
    let written = flags.timeout_written.load(Ordering::Relaxed);
    if written || flags.asked() {
        let mut next = snapshot(handle);
        if written {
            next.fallback_timeout_ms = read_busy_timeout(conn, flags)?;
        }
        swap_in(conn, handle, next)?;
        flags.timeout_written.store(false, Ordering::Relaxed);
        flags.asked.store(false, Ordering::Relaxed);
    }
    Ok(())
}

/// Set (or replace) the retry policy. Callers must hold the connection Mutex.
pub(crate) fn set_policy(
    conn: &Connection,
    handle: &XqliteConn,
    policy: BusyPolicy,
) -> Result<(), XqliteError> {
    let mut next = snapshot(handle);
    next.policy = Some(policy);
    swap_in(conn, handle, next)
}

/// Remove the retry policy, keeping any observers and the timeout. Safe to
/// call with no policy installed. Callers must hold the connection Mutex.
pub(crate) fn remove_policy(
    conn: &Connection,
    handle: &XqliteConn,
) -> Result<(), XqliteError> {
    let mut next = snapshot(handle);
    next.policy = None;
    swap_in(conn, handle, next)
}

/// Set the busy timeout the slot keeps, leaving any retry policy in place:
/// a waiting call spends it once no policy decides. Callers must hold the
/// connection Mutex.
pub(crate) fn set_timeout(
    conn: &Connection,
    handle: &XqliteConn,
    timeout_ms: u64,
) -> Result<(), XqliteError> {
    busy_timeout_c_int(timeout_ms)?;
    let mut next = snapshot(handle);
    next.fallback_timeout_ms = timeout_ms;
    swap_in(conn, handle, next)
}

/// The busy timeout the slot keeps, `None` only before the open took the
/// slot. Callers must hold the connection Mutex.
pub(crate) fn kept_timeout(handle: &XqliteConn) -> Option<u64> {
    let current = handle.callback_boxes.busy.load(Ordering::Acquire);
    // SAFETY: a non-null slot pointer always points to a live
    // BusySlotState; the connection Mutex the caller holds excludes its
    // reclamation.
    unsafe { current.as_ref() }.map(|state| state.fallback_timeout_ms)
}

/// Register an observer pid; returns its unregistration handle.
/// Callers must hold the connection Mutex.
pub(crate) fn register_observer(
    conn: &Connection,
    handle: &XqliteConn,
    pid: LocalPid,
) -> Result<u64, XqliteError> {
    let mut next = snapshot(handle);
    let observer_handle = handle.busy_flags.next_observer_handle();
    next.observers.push((observer_handle, pid));
    swap_in(conn, handle, next)?;
    Ok(observer_handle)
}

/// Unregister an observer by handle. Idempotent — an unknown handle is a
/// no-op. Callers must hold the connection Mutex.
pub(crate) fn unregister_observer(
    conn: &Connection,
    handle: &XqliteConn,
    observer_handle: u64,
) -> Result<(), XqliteError> {
    let mut next = snapshot(handle);
    next.observers.retain(|(h, _pid)| *h != observer_handle);
    swap_in(conn, handle, next)
}

/// Clone the current slot contents, or a fresh state before the open took
/// the slot.
///
/// Callers must hold the connection Mutex — that is what makes the raw
/// read of the current pointee sound (no concurrent reclaim, no
/// concurrent callback).
fn snapshot(handle: &XqliteConn) -> BusySlotState {
    let current = handle.callback_boxes.busy.load(Ordering::Acquire);

    if current.is_null() {
        BusySlotState {
            policy: None,
            observers: Vec::new(),
            fallback_timeout_ms: 0,
            flags: Arc::clone(&handle.busy_flags),
        }
    } else {
        // SAFETY: non-null slot pointers always point to a live
        // BusySlotState; the connection Mutex excludes reclamation.
        let state = unsafe { &*current };
        BusySlotState {
            policy: state.policy.clone(),
            observers: state.observers.clone(),
            fallback_timeout_ms: state.fallback_timeout_ms,
            flags: Arc::clone(&state.flags),
        }
    }
}

/// Swap the derived state in: register the callback pointing at the new
/// allocation, which also resets SQLite's count of its answers, then reclaim
/// the previous allocation.
fn swap_in(
    conn: &Connection,
    handle: &XqliteConn,
    next: BusySlotState,
) -> Result<(), XqliteError> {
    hook_util::install_hook(&handle.callback_boxes.busy, next, |new_ptr| {
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
            return Err(ffi_rc_to_error(conn, "sqlite3_busy_handler", rc));
        }
        Ok(())
    })
}

pub(crate) fn ffi_rc_to_error(conn: &Connection, what: &str, rc: c_int) -> XqliteError {
    // SAFETY: callers already hold the connection Mutex (public functions
    // document this); `conn.handle()` is valid for the duration of this read.
    let msg = unsafe {
        let ptr = ffi::sqlite3_errmsg(conn.handle());
        if ptr.is_null() {
            format!("{what} failed (code {rc})")
        } else {
            std::ffi::CStr::from_ptr(ptr).to_string_lossy().into_owned()
        }
    };
    let ffi_err = ffi::Error::new(rc);
    XqliteError::from(rusqlite::Error::SqliteFailure(ffi_err, Some(msg)))
}

#[cfg(test)]
mod tests {
    use super::{BusyPolicy, fallback_delay_ms, policy_delay_ms};

    fn schedule(timeout_ms: u64) -> Vec<u64> {
        let mut delays = Vec::new();
        let mut retries = 0;

        while let Some(delay) = fallback_delay_ms(retries, timeout_ms) {
            delays.push(delay);
            retries += 1;
        }

        delays
    }

    #[test]
    fn no_remembered_timeout_gives_up_at_once() {
        assert_eq!(fallback_delay_ms(0, 0), None);
        assert_eq!(fallback_delay_ms(11, 0), None);
        assert_eq!(fallback_delay_ms(9_999, 0), None);
    }

    #[test]
    fn the_schedule_matches_sqlites_and_the_last_delay_is_clipped() {
        assert_eq!(
            schedule(300),
            vec![1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 72]
        );
    }

    #[test]
    fn total_sleep_never_exceeds_the_remembered_timeout() {
        for timeout_ms in [1, 2, 3, 7, 40, 228, 229, 300, 1_000, 5_000] {
            let total: u64 = schedule(timeout_ms).iter().sum();
            assert_eq!(total, timeout_ms, "timeout {timeout_ms}");
        }
    }

    #[test]
    fn a_policy_sleeps_up_to_its_ceiling_and_never_past_it() {
        for max_retries in [0, 1, 3, 50] {
            for max_elapsed_ms in [0, 1, 7, 50, 400] {
                for sleep_ms in [0, 1, 10, 49, 50, 51, 400, 5_000] {
                    let policy = BusyPolicy {
                        max_retries,
                        max_elapsed_ms,
                        sleep_ms,
                    };
                    let (mut retries, mut clock_ms) = (0, 0);
                    while let Some(delay) = policy_delay_ms(&policy, retries, clock_ms) {
                        assert!(
                            delay <= sleep_ms,
                            "{max_retries} {max_elapsed_ms} {sleep_ms}"
                        );
                        clock_ms += delay;
                        retries += 1;
                    }
                    let ceiling = max_elapsed_ms.min(sleep_ms * u64::from(max_retries));
                    assert_eq!(
                        clock_ms, ceiling,
                        "{max_retries} {max_elapsed_ms} {sleep_ms}"
                    );
                }
            }
        }
    }

    #[test]
    fn past_the_table_the_last_delay_repeats() {
        assert_eq!(fallback_delay_ms(12, 100_000), Some(100));
        assert_eq!(fallback_delay_ms(500, 100_000), Some(100));
    }
}
