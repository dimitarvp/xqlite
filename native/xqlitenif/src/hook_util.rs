//! Shared helpers for SQLite hook modules.
//!
//! Two orthogonal concerns live here:
//!
//! * Term construction for messages sent back to Elixir (`make_atom`,
//!   `make_binary`) — used by every hook that forwards events as
//!   `{:xqlite_*, ...}` tuples.
//! * Atomic-slot state lifecycle (`install_hook`, `uninstall_hook`,
//!   `drop_hook`) — used by FFI-based hooks (busy, wal) that manage
//!   their own `Box<State>` outside of rusqlite's internal box
//!   management. Hooks that go through rusqlite's closure-accepting
//!   API (commit, rollback, update) do *not* need these helpers.
//!
//! The slot helpers encode the invariant: one Box owned by the
//! `AtomicPtr<T>` slot at a time; install swaps in a new Box and
//! reclaims the old; uninstall / Drop swap to null and reclaim.
//! `AcqRel` is the correct minimum ordering because the Box's bytes
//! must be visible to any thread that later reads the slot for
//! reclamation. The connection Mutex synchronises the FFI side.

use crate::error::XqliteError;
use rustler::sys::{ERL_NIF_TERM, ErlNifEnv, enif_make_atom_len, enif_make_new_binary};
use std::sync::atomic::{AtomicPtr, Ordering};

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
