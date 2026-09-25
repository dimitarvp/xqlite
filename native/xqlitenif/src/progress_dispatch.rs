//! Multi-subscriber dispatch on SQLite's single `progress_handler` slot.
//!
//! SQLite exposes one progress-handler callback per connection
//! (`sqlite3_progress_handler`). xqlite multiplexes that single slot
//! into two subscriber kinds, both fan-out:
//!
//! * **Cancel checkers** (`cancels`) — short-lived, scoped to a single
//!   cancellable query via `cancel::ProgressHandlerGuard`. Each
//!   cancellable call registers one subscriber per token; OR-semantics
//!   on signal.
//! * **Tick observers** (`ticks`) — long-lived, registered via
//!   `register_progress_hook` NIF. Each fires `{:xqlite_progress, …}`
//!   to a pid every `every_n` callback invocations.
//!
//! The C callback is registered exactly once at connection open and
//! stays installed. Both subscriber lists may be empty, in which case
//! the callback is a 2-load no-op.
//!
//! Safety story for the callback itself:
//!
//! * `user_data` is a stable `*const ProgressDispatch` pointing into
//!   the heap-allocated `XqliteConn` (held in a `ResourceArc`). SQLite
//!   calls it while stepping or compiling, which runs only while the
//!   conn `Mutex` is held by some thread; that thread also holds
//!   the `XqliteConn` `ResourceArc`, so the dispatch is alive.
//! * `HookList::for_each_snapshot` reads via atomic load — the C
//!   callback is wait-free.
//! * Cancel subscribers store a raw `*const AtomicBool` pointer into
//!   the `Arc<AtomicBool>` owned by the `XqliteCancelToken` resource.
//!   The `ProgressHandlerGuard` keeps the `Arc` alive for the duration
//!   of the registration; on drop, the guard unregisters before
//!   releasing the `Arc`, so the pointer is always valid while it is
//!   reachable from the dispatch.

use crate::hook_util::{self, HookList};
use rusqlite::ffi;
use rustler::sys::{
    enif_alloc_env, enif_free_env, enif_make_int64, enif_make_tuple_from_array, enif_send,
};
use rustler::types::LocalPid;
use std::os::raw::{c_int, c_void};
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU64, AtomicUsize, Ordering};
use std::time::Instant;

/// SQLite runs the progress callback at certain jumps (a loop's bottom, a
/// trigger's entry, the end of a statement's setup) and at the end of every
/// step once this many VM instructions have run since the last call, counting
/// across runs of the same statement, and while it compiles. Tighter values
/// regress cancellation latency without giving meaningful tick precision
/// (SQLite VM op cost varies wildly per op anyway).
pub(crate) const PROGRESS_NUM_OPS: c_int = 8;

/// One cancel-check subscriber.
#[derive(Debug, Clone)]
pub(crate) struct CancelSubscriber {
    /// Raw pointer into the `Arc<AtomicBool>` owned by the cancel
    /// token resource. Valid as long as the `ProgressHandlerGuard`
    /// holding the `Arc` lives — which is at least the duration of
    /// the cancellable query.
    flag: *const AtomicBool,
}

// SAFETY: the raw `*const AtomicBool` is dereferenced only under the
// `ProgressDispatch` invariants documented at the module level — the owning
// `Arc` outlives every subscriber via the `ProgressHandlerGuard`.
unsafe impl Send for CancelSubscriber {}
// SAFETY: see the `Send` impl above; the same pointer invariants apply.
unsafe impl Sync for CancelSubscriber {}

impl CancelSubscriber {
    /// # Safety
    ///
    /// `flag` must point to an `AtomicBool` that lives at least as long
    /// as the subscriber stays registered in a `ProgressDispatch`.
    /// Callers are `cancel::ProgressHandlerGuard`, which holds the
    /// owning `Arc<AtomicBool>` for that lifetime.
    pub(crate) unsafe fn new(flag: *const AtomicBool) -> Self {
        Self { flag }
    }
}

/// One tick-event subscriber.
///
/// `tag_bytes` stores the atom's UTF-8 bytes (extracted from
/// `Atom.to_string/1` on the Elixir side). The C callback recreates
/// the atom in the message env via `enif_make_atom_len`, sidestepping
/// the cross-env atom-handle problem.
#[derive(Clone)]
pub(crate) struct TickSubscriber {
    pub(crate) pid: LocalPid,
    pub(crate) every_n: u32,
    pub(crate) tag_bytes: Option<Vec<u8>>,
    /// Counts how many times *this* subscriber's branch in the C
    /// callback has fired. Decimated emit happens when
    /// `count.is_multiple_of(every_n)`. `AtomicU64` so we never
    /// panic on astronomical query lengths; wraps cleanly past 2^64.
    pub(crate) count: std::sync::Arc<AtomicU64>,
    pub(crate) install_instant: Instant,
}

impl std::fmt::Debug for TickSubscriber {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TickSubscriber")
            .field("every_n", &self.every_n)
            .field("tag_bytes", &self.tag_bytes)
            .field("count", &self.count.load(Ordering::Relaxed))
            .finish()
    }
}

impl TickSubscriber {
    /// `every_n` must be >= 1; callers validate at the NIF boundary.
    pub(crate) fn new(pid: LocalPid, every_n: u32, tag_bytes: Option<Vec<u8>>) -> Self {
        Self {
            pid,
            every_n,
            tag_bytes,
            count: std::sync::Arc::new(AtomicU64::new(0)),
            install_instant: Instant::now(),
        }
    }
}

/// Per-connection dispatch state. Owned by `XqliteConn` directly (no
/// box indirection — its address inside the `ResourceArc` is stable).
#[derive(Debug, Default)]
pub(crate) struct ProgressDispatch {
    pub(crate) cancels: HookList<CancelSubscriber>,
    pub(crate) ticks: HookList<TickSubscriber>,
    db: AtomicPtr<ffi::sqlite3>,
    /// The live guard's count of the connection's mid-run statements, taken
    /// when it registered its tokens, the statement its call steps left out.
    pub(crate) busy_before: AtomicUsize,
}

impl ProgressDispatch {
    pub(crate) const fn new() -> Self {
        Self {
            cancels: HookList::new(),
            ticks: HookList::new(),
            db: AtomicPtr::new(std::ptr::null_mut()),
            busy_before: AtomicUsize::new(0),
        }
    }

    /// # Safety
    ///
    /// `install_callback` has run, and the caller holds the connection Mutex,
    /// which every step and compile on the connection runs under.
    pub(crate) unsafe fn busy_statements(&self, except: *mut ffi::sqlite3_stmt) -> usize {
        let db = self.db.load(Ordering::Acquire);
        let mut busy = 0;
        // SAFETY: this function's own contract keeps the connection open and
        // its statement list unchanged while the list is walked.
        unsafe {
            let mut stmt = ffi::sqlite3_next_stmt(db, std::ptr::null_mut());
            while !stmt.is_null() {
                // A blob handle is a statement without SQL text, and an R*Tree
                // keeps one running until its write transaction ends.
                let sql = ffi::sqlite3_sql(stmt);
                busy += usize::from(
                    stmt != except && !sql.is_null() && ffi::sqlite3_stmt_busy(stmt) != 0,
                );
                stmt = ffi::sqlite3_next_stmt(db, stmt);
            }
        }
        busy
    }
}

/// Register the dispatch callback on a freshly opened SQLite connection.
///
/// The callback stays installed for the lifetime of the connection;
/// subscriber-level register/unregister never touches SQLite again.
///
/// # Safety
///
/// `dispatch` must outlive the SQLite Connection (i.e., live in the
/// same `ResourceArc<XqliteConn>` whose Mutex<Connection> field
/// drops first on Drop). Caller holds the connection Mutex.
pub(crate) unsafe fn install_callback(
    conn: &rusqlite::Connection,
    dispatch: &ProgressDispatch,
) {
    let user_data = dispatch as *const ProgressDispatch as *mut c_void;
    // SAFETY: see safety doc at the module level + on this fn. The C
    // signature for sqlite3_progress_handler matches our callback;
    // user_data lives long enough.
    unsafe {
        dispatch.db.store(conn.handle(), Ordering::Release);
        ffi::sqlite3_progress_handler(
            conn.handle(),
            PROGRESS_NUM_OPS,
            Some(progress_dispatch_callback),
            user_data,
        );
    }
}

/// The single C callback registered with SQLite. Walks both subscriber
/// lists, the cancel checks first.
///
/// # Safety
///
/// Invoked by SQLite while the conn Mutex is held; `user_data` is the
/// `*const ProgressDispatch` we passed to `install_callback`.
unsafe extern "C" fn progress_dispatch_callback(user_data: *mut c_void) -> c_int {
    // Guard the body against a future panic: this callback is registered
    // via raw `ffi::sqlite3_progress_handler`, so no rusqlite trampoline
    // catches a panic before it unwinds into SQLite's C stack. Fallback 0
    // is the callback's normal-path "do not interrupt" value — a panic
    // must never spuriously abort a user query, and 0 leaves SQLite state
    // untouched (a missed cancel waits for SQLite's next check, if any).
    hook_util::guard_ffi_callback("progress_dispatch_callback", 0, move || {
        // SAFETY: user_data is the dispatch pointer we registered;
        // guaranteed alive while a step or a compile is in flight.
        let dispatch = unsafe { &*(user_data as *const ProgressDispatch) };

        let mut signalled = false;
        // SAFETY: dispatch outlives the snapshot borrow (module invariants).
        unsafe {
            dispatch.cancels.for_each_snapshot(|entry| {
                // SAFETY: CancelSubscriber::flag invariant.
                signalled |= (*entry.state.flag).load(Ordering::Acquire);
            });
        }
        // SQLite runs this after a statement's last step too, past its commit
        // (sqlite3.c:105815): interrupt only while the call's statement runs.
        let running = || {
            // SAFETY: SQLite calls this under the connection Mutex.
            let busy = unsafe { dispatch.busy_statements(std::ptr::null_mut()) };
            busy > dispatch.busy_before.load(Ordering::Relaxed)
        };
        if signalled && running() {
            return 1;
        }

        if !dispatch.ticks.is_empty() {
            // SAFETY: see above.
            unsafe {
                dispatch.ticks.for_each_snapshot(|entry| {
                    let n = entry.state.count.fetch_add(1, Ordering::Relaxed);
                    if n.is_multiple_of(entry.state.every_n as u64) {
                        let elapsed_ms =
                            entry.state.install_instant.elapsed().as_millis() as u64;
                        // SAFETY: send_tick_to_pid uses a fresh msg_env.
                        send_tick_to_pid(
                            &entry.state.pid,
                            entry.state.tag_bytes.as_deref(),
                            n,
                            elapsed_ms,
                        );
                    }
                });
            }
        }

        0
    })
}

/// Send `{:xqlite_progress, tag, count, elapsed_ms}` (or
/// `{:xqlite_progress, count, elapsed_ms}` if no tag was supplied at
/// registration) to `pid`. Fire-and-forget.
///
/// # Safety
///
/// See `busy_handler::send_busy_to_pid` for the OTP 26.1 NULL-env
/// invariant.
unsafe fn send_tick_to_pid(
    pid: &LocalPid,
    tag_bytes: Option<&[u8]>,
    count: u64,
    elapsed_ms: u64,
) {
    // SAFETY: all enif_* calls operate on a freshly allocated msg_env.
    unsafe {
        let msg_env = enif_alloc_env();

        let event_tag = hook_util::make_atom(msg_env, b"xqlite_progress");
        let count_term = enif_make_int64(msg_env, count as i64);
        let elapsed_term = enif_make_int64(msg_env, elapsed_ms as i64);

        let msg = match tag_bytes {
            Some(bytes) => {
                let user_tag = hook_util::make_atom(msg_env, bytes);
                let elements = [event_tag, user_tag, count_term, elapsed_term];
                enif_make_tuple_from_array(msg_env, elements.as_ptr(), 4)
            }
            None => {
                let elements = [event_tag, count_term, elapsed_term];
                enif_make_tuple_from_array(msg_env, elements.as_ptr(), 3)
            }
        };

        let _ = enif_send(std::ptr::null_mut(), pid.as_c_arg(), msg_env, msg);

        enif_free_env(msg_env);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_rtree_node_blob_kept_open_is_not_a_running_statement() {
        let dispatch = ProgressDispatch::new();
        let conn = rusqlite::Connection::open_in_memory().expect("an in-memory connection");
        // SAFETY: `dispatch` is declared first, so it outlives `conn`, and this
        // thread owns the connection outright.
        unsafe { install_callback(&conn, &dispatch) };
        conn.execute_batch("CREATE VIRTUAL TABLE r USING rtree(id, x0, x1); BEGIN;")
            .expect("an R*Tree table and an open transaction");

        // SAFETY: this thread owns the connection, and no step is in flight.
        let before = unsafe { dispatch.busy_statements(std::ptr::null_mut()) };
        conn.execute("INSERT INTO r VALUES (1, 0, 1)", [])
            .expect("an R*Tree insert");
        // SAFETY: as above.
        let after = unsafe { dispatch.busy_statements(std::ptr::null_mut()) };
        assert_eq!(after, before);
    }
}
