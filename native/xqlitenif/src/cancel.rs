use rusqlite::Connection;
use rustler::{Resource, resource_impl};
use std::fmt::Debug;
use std::os::raw::c_int;
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

// --- RAII Guard for Progress Handler ---
// Needs a lifetime tied to the Connection reference it holds temporarily
pub(crate) struct ProgressHandlerGuard<'conn> {
    conn: &'conn Connection,
    // Store a flag to ensure unregister is only called if register succeeded
    is_registered: bool,
}

impl<'conn> ProgressHandlerGuard<'conn> {
    pub(crate) fn new(
        conn: &'conn Connection,
        token_bool: Arc<AtomicBool>,
        interval: i32,
    ) -> Result<Self, rusqlite::Error> {
        let handler = move || token_bool.load(Ordering::Acquire);

        conn.progress_handler(interval as c_int, Some(handler))?;

        Ok(ProgressHandlerGuard {
            conn,
            is_registered: true,
        })
    }
}

impl Drop for ProgressHandlerGuard<'_> {
    fn drop(&mut self) {
        if self.is_registered {
            let _ = self.conn.progress_handler(0, None::<fn() -> bool>);
        }
    }
}
