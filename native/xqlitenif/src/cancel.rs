use crate::error::{ListRefusal, XqliteError};
use crate::progress_dispatch::{CancelSubscriber, ProgressDispatch};
use crate::util::walk_list;
use rustler::{Resource, ResourceArc, Term, resource_impl};
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

/// Reads a caller's list of cancel tokens and answers the flags they carry.
///
/// The list is walked by hand, so a broken tail is a structured refusal rather
/// than a panic, and an element that is no cancel token names its own position,
/// one-based. Every refusal is told about the token list, so a caller can tell
/// it from the same call's parameter list.
pub(crate) fn decode_tokens(term: Term<'_>) -> Result<Vec<Arc<AtomicBool>>, XqliteError> {
    let items = walk_list(term).map_err(XqliteError::about_cancel_tokens)?;
    let mut flags = Vec::with_capacity(items.len());

    for (index, item) in items.iter().enumerate() {
        match item.decode::<ResourceArc<XqliteCancelToken>>() {
            Ok(token) => flags.push(token.0.clone()),
            Err(_not_a_token) => {
                return Err(XqliteError::InvalidCancelTokens {
                    refusal: ListRefusal::BadElement {
                        position: index + 1,
                    },
                    value_type: item.get_type(),
                });
            }
        }
    }

    Ok(flags)
}

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
            let raw = Arc::as_ptr(&token);
            // SAFETY: we hold the Arc in `entries` for the guard's
            // lifetime, so the AtomicBool stays alive while the
            // subscriber's raw pointer is reachable from
            // `dispatch.cancels`.
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
