use crate::authorizer;
use crate::connection::XqliteConn;
use crate::error::XqliteError;
use crate::hook_util;
use rusqlite::{Connection, ffi};
use rustler::sys::{
    enif_alloc_env, enif_free_env, enif_make_int64, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;
use std::cell::Cell;
use std::os::raw::{c_int, c_void};
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicUsize, Ordering};
use std::time::Instant;

/// What the busy slot holds right now, shared with the authorizer closure
/// and with the error mapping in `connection.rs`. Every write happens under
/// the connection Mutex; the closure reads these while SQLite prepares a
/// statement, which holds that Mutex too.
#[derive(Debug, Default)]
pub(crate) struct BusySlotFlags {
    slot_held: AtomicBool,
    internal_read: AtomicBool,
    write_refused: AtomicBool,
    policy: AtomicBool,
    observers: AtomicUsize,
}

impl BusySlotFlags {
    #[inline]
    pub(crate) fn slot_held(&self) -> bool {
        self.slot_held.load(Ordering::Relaxed)
    }

    #[inline]
    pub(crate) fn reading_own_timeout(&self) -> bool {
        self.internal_read.load(Ordering::Relaxed)
    }

    #[inline]
    pub(crate) fn note_write_refused(&self) {
        self.write_refused.store(true, Ordering::Relaxed);
    }

    pub(crate) fn clear_write_refused(&self) {
        self.write_refused.store(false, Ordering::Relaxed);
    }

    pub(crate) fn take_write_refused(&self) -> bool {
        self.write_refused.swap(false, Ordering::Relaxed)
    }

    pub(crate) fn policy(&self) -> bool {
        self.policy.load(Ordering::Relaxed)
    }

    pub(crate) fn observers(&self) -> usize {
        self.observers.load(Ordering::Relaxed)
    }

    fn set_slot_held(&self, held: bool) {
        self.slot_held.store(held, Ordering::Relaxed);
    }

    fn publish(&self, policy: bool, observers: usize) {
        self.policy.store(policy, Ordering::Relaxed);
        self.observers.store(observers, Ordering::Relaxed);
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

/// Read the connection's current `busy_timeout`, the value the slot is about
/// to displace. The flag around the read tells the authorizer closure that
/// this PRAGMA is xqlite's own, so a caller who denies `:pragma` cannot hide
/// the wait their connection had.
fn read_busy_timeout(conn: &Connection, flags: &BusySlotFlags) -> Result<u64, XqliteError> {
    flags.internal_read.store(true, Ordering::Relaxed);
    let read = conn.pragma_query_value(None, "busy_timeout", |row| row.get::<_, i64>(0));
    flags.internal_read.store(false, Ordering::Relaxed);

    let ms = read?;
    u64::try_from(ms)
        .map_err(|_| XqliteError::CannotExecute(format!("busy_timeout read back as {ms} ms")))
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

/// Set (or replace) the retry policy. Installs the callback if the slot
/// was empty. Callers must hold the connection Mutex.
pub(crate) fn set_policy(
    conn: &Connection,
    handle: &XqliteConn,
    policy: BusyPolicy,
) -> Result<(), XqliteError> {
    let mut next = snapshot(&handle.busy_handler);
    next.policy = Some(policy);
    swap_in(conn, handle, next)
}

/// Remove the retry policy, keeping any observers. Empties and removes
/// the callback when no observers remain. Safe to call with no policy
/// installed. Callers must hold the connection Mutex.
pub(crate) fn remove_policy(
    conn: &Connection,
    handle: &XqliteConn,
) -> Result<(), XqliteError> {
    let mut next = snapshot(&handle.busy_handler);
    next.policy = None;
    swap_in(conn, handle, next)
}

/// Set how long the connection waits on a locked database, removing
/// any retry policy first. With observers still registered the slot
/// keeps our callback and carries the new timeout; with none left the
/// slot empties and SQLite's own handler takes the C slot at `ms`.
/// Callers must hold the connection Mutex.
pub(crate) fn set_timeout(
    conn: &Connection,
    handle: &XqliteConn,
    timeout_ms: u64,
) -> Result<(), XqliteError> {
    busy_timeout_c_int(timeout_ms)?;
    let mut next = snapshot(&handle.busy_handler);
    next.policy = None;

    if next.observers.is_empty() {
        // `swap_in` puts back the displaced timeout; overwrite it after.
        swap_in(conn, handle, next)?;
        apply_busy_timeout(conn, timeout_ms)
    } else {
        next.fallback_timeout_ms = timeout_ms;
        swap_in(conn, handle, next)
    }
}

/// Register an observer pid; returns its unregistration handle.
/// Installs the callback if the slot was empty. Callers must hold the
/// connection Mutex.
pub(crate) fn register_observer(
    conn: &Connection,
    handle: &XqliteConn,
    pid: LocalPid,
) -> Result<u64, XqliteError> {
    let mut next = snapshot(&handle.busy_handler);
    let observer_handle = next.next_handle;
    next.next_handle += 1;
    next.observers.push((observer_handle, pid));
    swap_in(conn, handle, next)?;
    Ok(observer_handle)
}

/// Unregister an observer by handle. Idempotent — an unknown handle is a
/// no-op. Empties and removes the callback when nothing remains.
/// Callers must hold the connection Mutex.
pub(crate) fn unregister_observer(
    conn: &Connection,
    handle: &XqliteConn,
    observer_handle: u64,
) -> Result<(), XqliteError> {
    let mut next = snapshot(&handle.busy_handler);
    next.observers.retain(|(h, _pid)| *h != observer_handle);
    swap_in(conn, handle, next)
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
/// allocation and leave the connection's authorizer matching the result.
fn swap_in(
    conn: &Connection,
    handle: &XqliteConn,
    mut next: BusySlotState,
) -> Result<(), XqliteError> {
    let slot = &handle.busy_handler;
    let has_policy = next.policy.is_some();
    let observer_count = next.observers.len();

    if !has_policy && observer_count == 0 {
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

        restore_busy_timeout(conn, next.fallback_timeout_ms)?;
        handle.busy_flags.set_slot_held(false);
        handle.busy_flags.publish(false, 0);
        authorizer::sync(conn, handle)
    } else {
        let was_empty = slot.load(Ordering::Acquire).is_null();

        if was_empty {
            handle.busy_flags.set_slot_held(true);
            match take_slot(conn, handle) {
                Ok(displaced) => next.fallback_timeout_ms = displaced,
                Err(e) => {
                    give_slot_back(conn, handle);
                    return Err(e);
                }
            }
        }

        let installed = hook_util::install_hook(slot, next, |new_ptr| {
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
        });

        match installed {
            Ok(()) => {
                handle.busy_flags.publish(has_policy, observer_count);
                Ok(())
            }
            Err(e) => {
                if was_empty {
                    give_slot_back(conn, handle);
                }
                Err(e)
            }
        }
    }
}

/// Put the authorizer the held slot needs on the connection, then read the
/// `busy_timeout` the slot is about to displace — in that order, so the read
/// is the one xqlite is allowed to make. Callers must hold the connection
/// Mutex.
fn take_slot(conn: &Connection, handle: &XqliteConn) -> Result<u64, XqliteError> {
    authorizer::sync(conn, handle)?;
    read_busy_timeout(conn, &handle.busy_flags)
}

/// Undo `take_slot` when the slot was not taken after all. The authorizer's
/// own answer is dropped: the caller must hear why the take failed.
fn give_slot_back(conn: &Connection, handle: &XqliteConn) {
    handle.busy_flags.set_slot_held(false);
    let _ = authorizer::sync(conn, handle);
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
