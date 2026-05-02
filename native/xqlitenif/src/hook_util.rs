//! Shared helpers for SQLite hook modules.
//!
//! Three orthogonal concerns live here:
//!
//! * Term construction for messages sent back to Elixir (`make_atom`,
//!   `make_binary`) — used by every hook that forwards events as
//!   `{:xqlite_*, ...}` tuples.
//! * Single-subscriber atomic-slot lifecycle (`install_hook`,
//!   `uninstall_hook`, `drop_hook`) — used by `busy_handler`, where
//!   the callback returns a policy decision and multi-subscriber
//!   composition is ill-defined.
//! * Multi-subscriber lists (`HookList<T>`) — used by every fan-out
//!   hook (`update`, `wal`, `commit`, `rollback`, `log`, `progress`,
//!   plus the cancel sub-list inside `progress_dispatch`). N
//!   subscribers can register independently; each gets a unique
//!   handle for unregistration; the C callback walks a snapshot
//!   without locks.
//!
//! Both slot styles share the same release-acquire ordering and the
//! same "caller holds connection Mutex during writes" invariant. The
//! connection Mutex serialises *registration*; the AtomicPtr swap
//! gives the C callback a wait-free read path with no torn views of
//! the underlying state.

use crate::error::XqliteError;
use rustler::sys::{ERL_NIF_TERM, ErlNifEnv, enif_make_atom_len, enif_make_new_binary};
use std::sync::atomic::{AtomicPtr, AtomicU64, Ordering};

#[inline]
pub(crate) unsafe fn make_atom(env: *mut ErlNifEnv, name: &[u8]) -> ERL_NIF_TERM {
    // SAFETY: env is a valid msg_env; name is a valid byte slice.
    unsafe { enif_make_atom_len(env, name.as_ptr().cast(), name.len()) }
}

#[inline]
pub(crate) unsafe fn make_binary(env: *mut ErlNifEnv, data: &[u8]) -> ERL_NIF_TERM {
    // SAFETY: env is valid; enif_make_new_binary returns a buffer of
    // exactly data.len() bytes owned by msg_env.
    unsafe {
        let mut term: ERL_NIF_TERM = 0;
        let buf = enif_make_new_binary(env, data.len(), &mut term);
        std::ptr::copy_nonoverlapping(data.as_ptr(), buf, data.len());
        term
    }
}

/// Install a hook whose state lives in a `Box<T>` tracked by an
/// `AtomicPtr<T>` slot on `XqliteConn`.
///
/// Callers must hold the connection `Mutex` — `register_fn` performs
/// the SQLite FFI registration that mutates connection state.
///
/// Lifecycle: box the new state, run the FFI registration with the raw
/// pointer, on success swap it into the slot and reclaim any
/// predecessor. On failure, reclaim the new box (so there's no leak)
/// and propagate the error without touching the slot.
pub(crate) fn install_hook<T, F>(
    slot: &AtomicPtr<T>,
    state: T,
    register_fn: F,
) -> Result<(), XqliteError>
where
    F: FnOnce(*mut T) -> Result<(), XqliteError>,
{
    let new_ptr = Box::into_raw(Box::new(state));

    match register_fn(new_ptr) {
        Ok(()) => {
            let old_ptr = slot.swap(new_ptr, Ordering::AcqRel);
            if !old_ptr.is_null() {
                // SAFETY: we just replaced the handler at the SQLite C
                // level inside register_fn; the old pointer can no
                // longer be reached by a callback.
                unsafe {
                    drop(Box::from_raw(old_ptr));
                }
            }
            Ok(())
        }
        Err(e) => {
            // SAFETY: register_fn signalled failure, so SQLite never
            // saw new_ptr. Reclaim our leak before surfacing the error.
            unsafe {
                drop(Box::from_raw(new_ptr));
            }
            Err(e)
        }
    }
}

/// Uninstall a hook — clear the FFI side then reclaim the slot's box.
///
/// Callers must hold the connection `Mutex`. `unregister_fn` must
/// clear the SQLite handler pointer *before* we free the box; otherwise
/// a concurrent callback could still dereference it.
pub(crate) fn uninstall_hook<T, F>(
    slot: &AtomicPtr<T>,
    unregister_fn: F,
) -> Result<(), XqliteError>
where
    F: FnOnce() -> Result<(), XqliteError>,
{
    unregister_fn()?;

    let old_ptr = slot.swap(std::ptr::null_mut(), Ordering::AcqRel);
    if !old_ptr.is_null() {
        // SAFETY: the SQLite handler has been cleared above; no
        // callback can still read the old state.
        unsafe {
            drop(Box::from_raw(old_ptr));
        }
    }
    Ok(())
}

/// Reclaim any box still held by the slot — used by `XqliteConn::drop`.
///
/// Called after the connection has been dropped (which clears SQLite's
/// internal state), so there's no active FFI side to tear down.
pub(crate) fn drop_hook<T>(slot: &AtomicPtr<T>) {
    let ptr = slot.swap(std::ptr::null_mut(), Ordering::AcqRel);
    if !ptr.is_null() {
        // SAFETY: the Connection has already been dropped, so no
        // SQLite callback can fire. We own the allocation.
        unsafe {
            drop(Box::from_raw(ptr));
        }
    }
}

// ---------------------------------------------------------------------------
// Multi-subscriber primitive: HookList<T>
// ---------------------------------------------------------------------------

/// One subscriber inside a `HookList<T>`. The `id` is the opaque handle
/// returned to Elixir on register and accepted on unregister.
#[derive(Debug)]
pub(crate) struct HookEntry<T> {
    pub(crate) id: u64,
    pub(crate) state: T,
}

/// Lock-free copy-on-write list of subscribers.
///
/// Reads (in C callbacks) are wait-free atomic loads of a `Box<Vec<…>>`
/// pointer; iteration walks a stable snapshot. Writes (register /
/// unregister, called under the connection Mutex) clone the current
/// Vec, mutate the clone, and atomic-swap the pointer; the previous
/// Vec is reclaimed.
///
/// Vec is a deliberate proof-of-concept choice. If hook firings show
/// up as a hot-path bottleneck in benchmarks, candidates to evaluate
/// are intrusive linked lists (no per-fire snapshot allocation),
/// `arc-swap` for cleaner semantics, or bounded SPSC ring buffers.
/// See `project_hook_subscriber_perf_followup` memory.
#[derive(Debug)]
pub(crate) struct HookList<T> {
    head: AtomicPtr<Vec<HookEntry<T>>>,
    next_id: AtomicU64,
}

impl<T> HookList<T> {
    pub(crate) const fn new() -> Self {
        Self {
            head: AtomicPtr::new(std::ptr::null_mut()),
            next_id: AtomicU64::new(1),
        }
    }

    /// Register a subscriber. Returns the handle the caller passes to
    /// `unregister` to remove this entry.
    ///
    /// Caller must hold the connection Mutex (writes are serialised).
    pub(crate) fn register(&self, state: T) -> u64
    where
        T: Clone,
    {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let entry = HookEntry { id, state };

        let old_ptr = self.head.load(Ordering::Acquire);
        let new_vec: Vec<HookEntry<T>> = if old_ptr.is_null() {
            vec![entry]
        } else {
            // SAFETY: caller holds the conn Mutex, so no other writer
            // is mutating the slot. The C callback only reads via
            // atomic load on its own thread.
            let existing = unsafe { &*old_ptr };
            let mut clone: Vec<HookEntry<T>> = existing
                .iter()
                .map(|e| HookEntry {
                    id: e.id,
                    state: e.state.clone(),
                })
                .collect();
            clone.push(entry);
            clone
        };

        let new_ptr = Box::into_raw(Box::new(new_vec));
        let prev = self.head.swap(new_ptr, Ordering::AcqRel);
        if !prev.is_null() {
            // SAFETY: we just replaced the live Vec; no concurrent
            // reader will start a new traversal of `prev` after the
            // swap. Reclaim the old box.
            unsafe {
                drop(Box::from_raw(prev));
            }
        }
        id
    }

    /// Unregister the subscriber with the given handle. Idempotent —
    /// unregistering an unknown / already-removed handle is a no-op
    /// and returns `false`.
    ///
    /// Caller must hold the connection Mutex.
    pub(crate) fn unregister(&self, id: u64) -> bool
    where
        T: Clone,
    {
        let old_ptr = self.head.load(Ordering::Acquire);
        if old_ptr.is_null() {
            return false;
        }
        // SAFETY: see `register`. Caller holds the Mutex.
        let existing = unsafe { &*old_ptr };
        let filtered: Vec<HookEntry<T>> = existing
            .iter()
            .filter(|e| e.id != id)
            .map(|e| HookEntry {
                id: e.id,
                state: e.state.clone(),
            })
            .collect();

        if filtered.len() == existing.len() {
            // No matching entry; leave the list untouched.
            return false;
        }

        let new_ptr = if filtered.is_empty() {
            std::ptr::null_mut()
        } else {
            Box::into_raw(Box::new(filtered))
        };
        let prev = self.head.swap(new_ptr, Ordering::AcqRel);
        if !prev.is_null() {
            // SAFETY: see `register`.
            unsafe {
                drop(Box::from_raw(prev));
            }
        }
        true
    }

    /// Run `f` against the current snapshot of subscribers. Used by C
    /// callbacks; lock-free.
    ///
    /// # Safety
    ///
    /// The caller must guarantee the `HookList` outlives the borrow
    /// of `&[HookEntry<T>]` passed to `f`. In practice this is
    /// trivially true because the C callback runs while SQLite holds
    /// the connection Mutex (so the conn — and the list — is alive
    /// for the duration of the call).
    pub(crate) unsafe fn for_each_snapshot<F>(&self, mut f: F)
    where
        F: FnMut(&HookEntry<T>),
    {
        let head = self.head.load(Ordering::Acquire);
        if head.is_null() {
            return;
        }
        // SAFETY: callers contract.
        let snapshot = unsafe { &*head };
        for entry in snapshot.iter() {
            f(entry);
        }
    }

    /// True if there are no subscribers. O(1).
    pub(crate) fn is_empty(&self) -> bool {
        self.head.load(Ordering::Acquire).is_null()
    }

    /// Reclaim any list still held by the slot. Used by
    /// `XqliteConn::drop` after the SQLite Connection has dropped, so
    /// no callback can fire and dereference the snapshot.
    pub(crate) fn drop_all(&self) {
        let ptr = self.head.swap(std::ptr::null_mut(), Ordering::AcqRel);
        if !ptr.is_null() {
            // SAFETY: see `drop_hook`. The Connection is gone; the C
            // callback won't fire again. We own the allocation.
            unsafe {
                drop(Box::from_raw(ptr));
            }
        }
    }
}

impl<T> Default for HookList<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> Drop for HookList<T> {
    fn drop(&mut self) {
        self.drop_all();
    }
}
