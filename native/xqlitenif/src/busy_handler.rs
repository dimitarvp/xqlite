use crate::error::XqliteError;
use crate::hook_util;
use rusqlite::{Connection, ffi};
use rustler::sys::{
    enif_alloc_env, enif_free_env, enif_make_int64, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;
use std::cell::Cell;
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
/// The callback also resets `start` (an interior-mutable `Cell`) at the
/// beginning of each busy event; that write is serialised by the same
/// Mutex, so it never races a mutator or another callback.
pub(crate) struct BusySlotState {
    policy: Option<BusyPolicy>,
    observers: Vec<(u64, LocalPid)>,
    next_handle: u64,
    start: Cell<Instant>,
    /// The `busy_timeout` this slot displaced when it took SQLite's single
    /// busy callback (`sqlite3_busy_handler` zeroes it); 0 when there was none.
    fallback_timeout_ms: u64,
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
/// policy installed it falls back to emulating the `busy_timeout` the
/// slot displaced, which is 0 (give up at once) unless one was set.
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
        // SQLite starts a fresh busy event at count == 0; reset the elapsed
        // clock there so `max_elapsed_ms` is a per-event budget (matching
        // `max_retries`), not an absolute ceiling from the slot's install.
        if retries == 0 {
            state.start.set(Instant::now());
        }
        let elapsed_ms = state.start.get().elapsed().as_millis() as u64;

        for (_handle, pid) in &state.observers {
            // SAFETY: see `send_busy_to_pid`. All data is copied into a fresh
            // msg_env; we never retain references across the call.
            unsafe {
                send_busy_to_pid(pid, retries, elapsed_ms);
            }
        }

        match &state.policy {
            None => match fallback_delay_ms(retries, state.fallback_timeout_ms) {
                None => 0,
                Some(delay_ms) => {
                    std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                    1
                }
            },
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

/// Read the connection's current `busy_timeout`. An unreadable value
/// (an authorizer can veto the PRAGMA) degrades to "none to displace".
fn read_busy_timeout(conn: &Connection) -> u64 {
    conn.pragma_query_value(None, "busy_timeout", |row| row.get::<_, i64>(0))
        .ok()
        .and_then(|ms| u64::try_from(ms).ok())
        .unwrap_or(0)
}

/// Hand the C slot to SQLite's own timeout handler at `timeout_ms`.
/// Callers must hold the connection Mutex.
fn busy_timeout_c_int(timeout_ms: u64) -> Result<c_int, XqliteError> {
    c_int::try_from(timeout_ms).map_err(|_| {
        XqliteError::CannotExecute(format!(
            "busy_timeout {timeout_ms} ms exceeds SQLite's limit of {} ms",
            c_int::MAX
        ))
    })
}

fn apply_busy_timeout(conn: &Connection, timeout_ms: u64) -> Result<(), XqliteError> {
    let ms = busy_timeout_c_int(timeout_ms)?;
    // SAFETY: caller holds the connection Mutex; `conn.handle()` yields
    // the raw db pointer for that locked connection.
    let rc = unsafe { ffi::sqlite3_busy_timeout(conn.handle(), ms) };
    if rc == ffi::SQLITE_OK {
        Ok(())
    } else {
        Err(ffi_rc_to_error(conn, "sqlite3_busy_timeout", rc))
    }
}

/// Put back the timeout the slot displaced, so emptying the slot undoes
/// taking it. Callers must hold the connection Mutex.
fn restore_busy_timeout(conn: &Connection, timeout_ms: u64) -> Result<(), XqliteError> {
    if timeout_ms == 0 {
        return Ok(());
    }

    apply_busy_timeout(conn, timeout_ms)
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

/// Set how long the connection waits on a locked database, removing
/// any retry policy first. With observers still registered the slot
/// keeps our callback and carries the new timeout; with none left the
/// slot empties and SQLite's own handler takes the C slot at `ms`.
/// Callers must hold the connection Mutex.
pub(crate) fn set_timeout(
    conn: &Connection,
    slot: &AtomicPtr<BusySlotState>,
    timeout_ms: u64,
) -> Result<(), XqliteError> {
    busy_timeout_c_int(timeout_ms)?;
    let mut next = snapshot(slot);
    next.policy = None;

    if next.observers.is_empty() {
        // `swap_in` puts back the displaced timeout; overwrite it after.
        swap_in(conn, slot, next)?;
        apply_busy_timeout(conn, timeout_ms)
    } else {
        next.fallback_timeout_ms = timeout_ms;
        swap_in(conn, slot, next)
    }
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
/// the current `start` instant and handle counter across mutations. The
/// callback resets `start` at each busy event's first callback, so a
/// mutation mid-contention keeps that event's clock rather than restarting
/// it.
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
            start: Cell::new(Instant::now()),
            fallback_timeout_ms: 0,
        }
    } else {
        // SAFETY: non-null slot pointers always point to a live
        // BusySlotState; the connection Mutex excludes reclamation.
        let state = unsafe { &*current };
        BusySlotState {
            policy: state.policy.clone(),
            observers: state.observers.clone(),
            next_handle: state.next_handle,
            start: Cell::new(state.start.get()),
            fallback_timeout_ms: state.fallback_timeout_ms,
        }
    }
}

/// Swap the derived state in: empty states clear the C callback, restore
/// the displaced timeout and clear the slot; non-empty states (re-)register
/// the callback pointing at the new allocation, remembering the timeout
/// they displace when the slot was empty. Both paths reclaim the previous
/// allocation.
fn swap_in(
    conn: &Connection,
    slot: &AtomicPtr<BusySlotState>,
    mut next: BusySlotState,
) -> Result<(), XqliteError> {
    if next.policy.is_none() && next.observers.is_empty() {
        // Nothing of ours is installed, so the C slot holds SQLite's own
        // timeout handler (or nothing): clearing it would destroy that.
        if slot.load(Ordering::Acquire).is_null() {
            return Ok(());
        }

        hook_util::uninstall_hook(slot, || {
            // SAFETY: caller holds the connection Mutex. Passing None+null
            // clears any registered handler; calling with no handler
            // installed is valid.
            let rc = unsafe {
                ffi::sqlite3_busy_handler(conn.handle(), None, std::ptr::null_mut())
            };
            if rc != ffi::SQLITE_OK {
                return Err(ffi_rc_to_error(conn, "sqlite3_busy_handler", rc));
            }
            Ok(())
        })?;

        restore_busy_timeout(conn, next.fallback_timeout_ms)
    } else {
        if slot.load(Ordering::Acquire).is_null() {
            next.fallback_timeout_ms = read_busy_timeout(conn);
        }

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
                return Err(ffi_rc_to_error(conn, "sqlite3_busy_handler", rc));
            }
            Ok(())
        })
    }
}

fn ffi_rc_to_error(conn: &Connection, what: &str, rc: c_int) -> XqliteError {
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
    use super::fallback_delay_ms;

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
    fn past_the_table_the_last_delay_repeats() {
        assert_eq!(fallback_delay_ms(12, 100_000), Some(100));
        assert_eq!(fallback_delay_ms(500, 100_000), Some(100));
    }
}
