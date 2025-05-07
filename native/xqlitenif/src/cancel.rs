use rustler::{resource_impl, Resource};
use std::fmt::Debug;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

#[derive(Debug)]
pub(crate) struct XqliteCancelToken(pub(crate) Arc<AtomicBool>);

#[resource_impl]
impl Resource for XqliteCancelToken {}

impl XqliteCancelToken {
    pub(crate) fn new() -> Self {
        XqliteCancelToken(Arc::new(AtomicBool::new(false)))
    }

    pub(crate) fn cancel(&self) {
        self.0.store(true, Ordering::Release); // Use Release for store
    }

    // #[allow(dead_code)] // Mark as allowed since it's not used in this immediate step
    pub(crate) fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Relaxed) // Use Relaxed for load (Acquire also fine if store is Release)
    }
}
