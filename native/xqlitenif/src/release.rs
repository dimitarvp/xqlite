//! The release thread. Every resource destructor runs on one of the BEAM's normal
//! schedulers, so none takes a connection lock or calls SQLite: a collected handle
//! is queued on its connection and wakes this one thread, which takes the lock with
//! `try_lock` only, so a busy connection never holds up the others, and a
//! connection dropped without `close/1` is closed here.

use crate::cancel::XqliteCancelToken;
use crate::connection::{CallbackBoxes, ChildHandle, Orphan, XqliteConn};
use rusqlite::Connection;
use rustler::ResourceArc;
use std::mem::ManuallyDrop;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::OnceLock;
use std::sync::atomic::Ordering;
use std::sync::mpsc::{SendError, Sender, channel};
use std::thread::Builder;

pub(crate) enum Job {
    /// Release what is queued on this connection, if its lock is free.
    Drain(ResourceArc<XqliteConn>),
    /// A dropped connection with its queued handles and the boxes its callbacks
    /// read: the handles are released, the connection closed, the boxes freed.
    Close(Box<(Connection, CallbackBoxes, Vec<Orphan>)>),
}

static JOBS: OnceLock<Sender<Job>> = OnceLock::new();

/// ERTS closes a purged library once the last resource of its types is gone, and
/// the release thread runs its code; none can be made while the library loads, so
/// the first connection's open makes this one.
pub(crate) static KEEP_LOADED: OnceLock<ResourceArc<XqliteCancelToken>> = OnceLock::new();

/// Starts the release thread once per loaded library, so a load after a purge
/// finds it running; a thread that cannot start fails the load.
pub(crate) fn start() -> bool {
    let (jobs, received) = channel::<Job>();
    let run = move || {
        for job in received {
            let _ = catch_unwind(AssertUnwindSafe(|| job.run()));
        }
    };
    let thread = Builder::new().name("xqlite-release".into());
    JOBS.get().is_some() || (thread.spawn(run).is_ok() && JOBS.set(jobs).is_ok())
}

/// Queues a collected handle on its connection and wakes the release thread; one
/// already released queues nothing.
pub(crate) fn orphan(conn: &ResourceArc<XqliteConn>, handle: Orphan) {
    let live = match &handle {
        Orphan::Child(ChildHandle::Stmt(cell)) => !cell.load(Ordering::Acquire).is_null(),
        Orphan::Child(ChildHandle::Blob(cell)) => !cell.load(Ordering::Acquire).is_null(),
        Orphan::Session(_) => true,
    };
    if live {
        conn.queue().push(handle);
        let _ = send(Job::Drain(ResourceArc::clone(conn)));
    }
}

/// Hands a job to the release thread, or back when there is none.
pub(crate) fn send(job: Job) -> Result<(), Job> {
    match JOBS.get() {
        Some(jobs) => jobs.send(job).map_err(|SendError(job)| job),
        None => Err(job),
    }
}

impl Job {
    pub(crate) fn run(self) {
        match self {
            Job::Drain(conn) => conn.release_queued(),
            Job::Close(close) => {
                let (conn, boxes, orphans) = *close;
                for orphan in orphans {
                    match orphan {
                        // SAFETY: the job owns the Connection every queued handle was opened on.
                        Orphan::Child(child) => unsafe { child.release() },
                        Orphan::Session(session) => drop(ManuallyDrop::into_inner(session.0)),
                    }
                }
                drop(conn);
                drop(boxes);
            }
        }
    }
}
