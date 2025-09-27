use rusqlite::Connection;
use rustler::{resource_impl, Resource};
use std::fmt::Debug;
use std::os::raw::c_int;
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
        let handler = move || -> bool {
            if token_bool.load(Ordering::Relaxed) {
                true // Return true (non-zero) to interrupt
            } else {
                false // Return false (zero) to keep going
            }
        };

        // The progress_handler function itself doesn't return a Result we can use `?` on.
        // It doesn't typically error in a way that prevents registration if arguments are valid.
        // We'll assume registration works if types are correct.
        conn.progress_handler(interval as c_int, Some(handler));

        Ok(ProgressHandlerGuard {
            conn,
            is_registered: true,
        }) // Assume success if we get to here
    }
}

impl Drop for ProgressHandlerGuard<'_> {
    fn drop(&mut self) {
        if self.is_registered {
            self.conn.progress_handler(0, None::<fn() -> bool>);
        }
    }
}
