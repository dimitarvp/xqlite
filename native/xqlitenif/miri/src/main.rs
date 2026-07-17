//! Isolated pure-Rust model of the xqlite `blob::close` use-after-move that was
//! shipped before the raw-pointer refactor (REVIEW_LEDGER Run 2, wf_8a7388b0-464).
//!
//! This crate is intentionally NOT part of the `xqlitenif` build (no workspace
//! links it in), so it never runs under `cargo test` / `mix test.seq` / CI. It
//! exists only to demonstrate, under Miri, that the *pattern* the old code used
//! is Undefined Behavior — Miri cannot drive the bundled C SQLite (no real FFI),
//! so we reproduce the exact unsound shape in pure Rust instead.
//!
//! It mirrors the shipped shape:
//!   * `Inner` models rusqlite `InnerConnection` (owns a heap box == the
//!     `*mut sqlite3` / interrupt Arc a real drop frees).
//!   * `Conn`  models rusqlite `Connection { db: RefCell<InnerConnection> }`.
//!   * `Blob`  models rusqlite `Blob<'conn> { conn: &'conn Conn, .. }`,
//!     lifetime-erased to `&'static` exactly like xqlite's `std::mem::transmute`
//!     in the old `blob_open` (nif.rs, pre-fix).
//!   * the slot models `Mutex<Option<Connection>>` inside `XqliteConn`.
//!
//! Sequence reproduced (the shipped bug):
//!   1. `blob_open` borrows `&Conn` from the `Some(..)` slot, transmutes it to
//!      `&'static`, stores it in the `Blob`.
//!   2. `close_connection` does `slot.take()` -> the `Conn` is moved out and
//!      DROPPED (its heap box is freed).
//!   3. `Blob::drop` -> `close_()` -> `self.conn.decode_result()` dereferences
//!      the now-stale `&'static Conn` (== rusqlite `Blob::drop` -> `close_()` ->
//!      `self.conn.decode_result()` -> `self.db.borrow()`). Use-after-move.
//!
//! Run it:
//!   rustup +nightly component add miri     # one-time
//!   cd native/xqlitenif/miri && cargo +nightly miri run
//!
//! Observed 2026-07-17 (nightly Miri, rusqlite 0.40.1 / libsqlite3-sys 0.38.1
//! era layout):
//!
//!   error: Undefined Behavior: reading memory at alloc..[0x10..0x18], but
//!   memory is uninitialized at [0x10..0x18], and this operation requires
//!   initialized memory
//!      --> library/core/src/cell.rs:555  (Cell::<isize>::get, the RefCell flag)
//!       = note: stack backtrace:
//!         3: RefCell::<Inner>::borrow
//!         4: Conn::decode_result        (src/main.rs)
//!         5: Blob::close_               (src/main.rs)
//!         6: <Blob as Drop>::drop       (src/main.rs)
//!   miri exit = 1
//!
//! `cargo run` (native, no Miri) exits 0: the freed/moved-from bytes read
//! benignly on the current layout. THAT is the point — the bug is latent,
//! layout-dependent UB. A layout where the `Option` niche collides with the
//! `RefCell` borrow flag makes `borrow()` observe "already borrowed" and PANIC
//! inside `Blob::drop`; rustler 0.38 resource destructors have no `catch_unwind`,
//! so that panic would unwind into C and crash the BEAM.
//!
//! The fix (blob.rs) removes the rusqlite `Blob` wrapper entirely: the resource
//! owns a raw `*mut sqlite3_blob` and calls `sqlite3_blob_*` directly, so no
//! `&Connection` is ever dereferenced on any blob teardown path.

use std::cell::RefCell;

struct Inner {
    // Heap allocation so a real free happens on drop; models the owned SQLite
    // handle / interrupt Arc that rusqlite's InnerConnection::drop reclaims.
    db: Box<u64>,
}

impl Inner {
    fn decode_result(&self) -> u64 {
        *self.db
    }
}

struct Conn {
    inner: RefCell<Inner>,
}

impl Conn {
    // Models Connection::decode_result -> self.db.borrow().decode_result().
    fn decode_result(&self) -> u64 {
        self.inner.borrow().decode_result()
    }
}

struct Blob {
    // The lifetime-erased borrow, exactly like the old transmuted Blob<'static>.
    conn: &'static Conn,
}

impl Blob {
    // Models rusqlite Blob::close_(): touches self.conn after the real close.
    fn close_(&mut self) -> u64 {
        self.conn.decode_result()
    }
}

impl Drop for Blob {
    fn drop(&mut self) {
        // rusqlite's Blob::drop calls close_() and discards the result.
        let v = self.close_();
        std::hint::black_box(v);
    }
}

fn main() {
    // Mutex<Option<Conn>> analog. A plain cell is enough to model the slot; the
    // real Mutex adds no memory-safety guarantee against this move.
    let slot: RefCell<Option<Conn>> = RefCell::new(Some(Conn {
        inner: RefCell::new(Inner {
            db: Box::new(0xDEAD_BEEF),
        }),
    }));

    // blob_open: borrow &Conn from Some(..) and erase the lifetime.
    let blob = {
        let guard = slot.borrow();
        let conn_ref: &Conn = guard.as_ref().unwrap();
        // SAFETY(model): intentionally the SAME unsound transmute the old
        // blob_open performed -- this is exactly what we are proving is unsound.
        let static_ref: &'static Conn = unsafe { std::mem::transmute(conn_ref) };
        Blob { conn: static_ref }
    };

    // close_connection: take() moves the Conn out and drops it (frees the box).
    let taken = slot.borrow_mut().take();
    drop(taken);

    // GC-drop of the still-live Blob after its connection was closed:
    // Blob::drop -> close_() -> stale &Conn deref -> USE-AFTER-MOVE.
    drop(blob);
}
