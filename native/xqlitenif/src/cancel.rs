use crate::progress_dispatch::{CancelSubscriber, ProgressDispatch};
use rustler::{Resource, resource_impl};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug)]
pub(crate) struct XqliteCancelToken(pub(crate) Arc<AtomicBool>);

#[resource_impl]
impl Resource for XqliteCancelToken {}

impl XqliteCancelToken {
    pub(crate) fn new() -> Self {
        XqliteCancelToken(Arc::new(AtomicBool::new(false)))
    }

    pub(crate) fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }
}

// ---------------------------------------------------------------------------
// ProgressHandlerGuard — RAII subscriber lifecycle on ProgressDispatch
// ---------------------------------------------------------------------------
//
// The guard pushes one cancel subscriber per token onto
// `dispatch.cancels`, holds the owning `Arc<AtomicBool>` for each
// (so the raw pointer stored in the subscriber stays valid), and
// unregisters them all on drop. The SQLite progress callback was
// already installed eagerly at connection open and stays put — no
// FFI work happens here.

pub(crate) struct ProgressHandlerGuard<'d> {
    dispatch: &'d ProgressDispatch,
    /// Subscriber IDs returned by `HookList::register`, paired with
    /// the `Arc<AtomicBool>` we hold to keep each pointee alive.
    /// The Arc lives as long as the guard, which lives as long as
    /// the cancellable query.
    entries: Vec<(u64, Arc<AtomicBool>)>,
}

impl<'d> ProgressHandlerGuard<'d> {
    /// Register one or more cancel tokens with the connection's
    /// dispatch. Empty-list input is allowed and produces a no-op
    /// guard (cheaper than guarding every call site against empty
    /// vectors).
    ///
    /// Caller must hold the connection Mutex.
    pub(crate) fn new(dispatch: &'d ProgressDispatch, tokens: Vec<Arc<AtomicBool>>) -> Self {
        let mut entries = Vec::with_capacity(tokens.len());
        for token in tokens {
            // SAFETY: we hold the Arc in `entries` for the guard's
            // lifetime, so the AtomicBool stays alive while the
            // subscriber's raw pointer is reachable from
            // `dispatch.cancels`.
            let raw = Arc::as_ptr(&token);
            let subscriber = unsafe { CancelSubscriber::new(raw) };
            let id = dispatch.cancels.register(subscriber);
            entries.push((id, token));
        }
        Self { dispatch, entries }
    }
}

impl Drop for ProgressHandlerGuard<'_> {
    fn drop(&mut self) {
        for (id, _arc) in self.entries.drain(..) {
            // Unregister first; the Arc drops afterwards. Order
            // matters: while the subscriber is reachable, the raw
            // pointer must be valid.
            self.dispatch.cancels.unregister(id);
        }
    }
}
