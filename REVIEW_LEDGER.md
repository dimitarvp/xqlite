# Review ledger — xqlite (append-only)

One entry per fleet run: date, commit, scope, fleet composition,
findings with verdicts + severity + fix commit or backlog ref,
per-axis dryness state. Nothing found is ever silently dropped.

---

## Run 0 — 2026-07-17 — Phase-1 recon (wave 1)

- Commit at scan: `e20707e` (release 0.9.0). Fleet: 4 sonnet
  read-only agents (repo recon ×2, failure-mode mining ×2) +
  orchestrator synthesis. No refuter wave (recon, not findings).
- Raw transcripts + distillates: `~/kod/fleet_review_staging/recon/`.
- Outcomes:
  - erl_crash.dump autopsies (BOTH repos): dev-noise, closed.
    xqlite's (Jul 17) is a boot-time stderr race, xqlitenif absent
    from taints. Re-open only if a dump ever shows xqlitenif tainted.
  - rusqlite UTF-8 panic (the maintainer's upstream find): fixed
    upstream in 0.39.0 (PR#1819); source-verified gone at 0.40.1.
  - **rustler 0.37/0.38 resource destructors/`down`/`dyncall` have
    no catch_unwind** (source-verified) → A1 priority probes seeded
    (Drop census, poisoned-Mutex chain, raw-FFI callback guards).
  - exqlite PR#342 lock-scope audit shape adopted as A2's method.
  - release.sh audited: dirty-tree-gated, no force-push; amend at
    :161, tag -f at :165. Safe with a dirty-tree-on-partial-failure
    wart.
  - Doc drift + docs/CI findings → fixed in `51d1a17` (CLAUDE.md
    sync, hexdocs grouping + flag-stable telemetry docs, CI pins,
    statement_cancel opener comment) or filed in BACKLOG.md.
  - 23 Elixir-ecosystem + 15 Rust/cross-ecosystem failure classes
    harvested → seeded across A1–A14 probes (distillates hold the
    class → axis map).
- Dryness: all axes WET (no adversarial pass has run yet).

---

## Run 1 — 2026-07-17 — wave-2 chunk 1 (A1 panic-freedom + A2 locking law)

- Commit at scan: `f9cb120` (post-0.9.0). Scope: `native/xqlitenif/
  src/*` + every raw-FFI touchpoint. Fleet: 3 opus finders (F1 panic-
  census, F2 locking-law, F3 cancel/teardown) + 3 fable adversaries
  (UB prosecutor, interleaving attacker, assumption auditor), READ-ONLY,
  structured findings; orchestrator mechanism-dedup + source-level
  re-verification against the BUNDLED SQLite (libsqlite3-sys 0.38.1,
  amalgamation 3.53.2) and rusqlite 0.40.1 / rustler 0.38.0 sources.
  18 raw findings → 8 mechanisms after dedup. No separate refuter wave:
  every mechanism was settled decisively at the source level (open
  flags, dependency Drop bodies, `sqlite3Close`/`connectionIsBusy`
  logic, `enif_free_env` asymmetry, process-global log callback, no
  Elixir serialization layer) — proof supersedes argumentation.

### CONFIRMED

- **M1 — S0 — blob & session ops bypass the connection Mutex → data
  race on a NOMUTEX handle.** `blob.rs:32`/`session.rs:34`:
  `with_blob`/`with_session` lock only the resource's OWN
  `Mutex<Option<…>>`, never `XqliteConn.conn`. Every other raw-FFI path
  (`stream_fetch` nif.rs:1295, `take_and_finalize_raw` stream.rs:51,
  backup, checkpoint, serialize) correctly holds the connection Mutex;
  blob/session are the sole violators. Connections open `NO_MUTEX`
  (verified: rusqlite `OpenFlags::default()`; xqlite `Connection::open`
  at nif.rs:39/45 never overrides), so SQLite does zero internal
  serialization — a concurrent `sqlite3_step` on the connection races
  `sqlite3_blob_read/write/reopen/close` and `sqlite3session_*`.
  `sqlite3_blob_read` itself steps an internal VDBE, so it is literally
  two concurrent `sqlite3_step`s on one connection. Found independently
  by ALL 6 agents + orchestrator audit. Root cause of M2(session) & M5.
- **M2(session) — S0 — close()-then-GC-drop of a live session →
  use-after-free.** `session_new` erases the connection lifetime via
  `transmute` to `Session<'static>`; the `XqliteSession` keeps the
  XqliteConn *resource* alive but NOT the inner `Connection`.
  `close_connection` (connection.rs:176) does `conn_guard.take()`,
  dropping the `Connection`. A session registers no persistent
  `db->pVdbe`, so `connectionIsBusy` (sqlite3.c:188438) returns 0 →
  `sqlite3_close` (v1) SUCCEEDS and frees `db` → later session GC-drop
  calls `sqlite3session_delete(freed db)`. UAF.
- **M3 — S0 — global log-hook HookList reader races the Vec free.**
  `log_hook.rs`: the process-wide callback (installed via
  `sqlite3_config`) fires from ANY thread emitting a log, holding no
  connection Mutex; it walks `LOG_SUBSCRIBERS.for_each_snapshot`
  lock-free (:46). `register`/`unregister` run under `MASTER_LOCK`
  only and immediately `drop(Box::from_raw(prev))` the old Vec
  (hook_util.rs:200-209,247-253). The per-connection hooks are safe
  because callback+writer share the conn Mutex; the STATIC log list has
  no such shared lock → reader-mid-iteration vs writer-free = UAF.
  Distinct root from M1.
- **M4 — S1 — `backup_with_progress` leaks a `msg_env` per successful
  progress message.** `send_backup_progress` (nif.rs:1810) frees
  `msg_env` ONLY when `enif_send` returns 0 (failure); on success it
  leaks. The crate's four other senders (`send_busy_to_pid`,
  `send_tick_to_pid`, `send_wal_to_pid`, `send_log_to_pid`) all free
  UNCONDITIONALLY — this is the lone inconsistency. Unbounded, driven
  by DB size (one leak per backup step). Code-verified.
- **M5 — S0 — session changeset stepping fires the progress handler
  without the conn Mutex → progress-list UAF (+ enif_send(NULL) from a
  normal scheduler).** Corollary of M1: `session_changeset`/`patchset`
  (normal scheduler, session Mutex only) step an internal SELECT that
  fires `progress_dispatch_callback`, which walks the lock-free
  cancels/ticks HookList while a conn-Mutex-holding
  `register_progress_hook`/`query_cancellable` on another thread
  COW-frees the old Vec. Premise SOURCE-CONFIRMED: the session
  extension steps an internal SELECT (`sqlite3_step`, sqlite3.c:56077+)
  and the progress check rides the VDBE exec loop (sqlite3.c:97575), so
  changeset generation does fire `xProgress`.
  `send_tick_to_pid`'s `enif_send(NULL,…)` also
  then runs on a normal scheduler, contra the repo's own dirty-only
  note (PLAUSIBLE sub-issue; assertion-ERTS probe owed). M1's fix
  (session ops hold the conn Mutex) resolves the UAF leg.
- **M8 — S2 — `schema.rs:57` `.expect()` on fallible
  `OwnedBinary::new`** in the `DefaultValue::Blob` encoder is a
  reachable public-API panic (→ opaque `:nif_panicked`); the identical
  call elsewhere uses `ok_or_else`. Bounded reachability (pathological
  blob-default size / OOM). Caught by rustler's NIF-body/encode
  `catch_unwind`, so ≥S1 promise-break but not S0.
- **M9 — S2 — `eprintln!` in `XqliteStream`/`XqliteStatement`
  destructors** (stream.rs:79, statement.rs:71) is panic-capable
  (stderr EPIPE) on a resource-destructor path that rustler 0.38 does
  NOT wrap in `catch_unwind` → unwind-into-C. Double-conditional
  (finalize error + broken stderr), hence S2, but destructors must be
  panic-proof.

### REFUTED / RECLASSIFIED

- **M2(blob) — REFUTED as UAF → S2 leak.** The finders lumped blob with
  session, but an open blob holds an internal `Vdbe`, so
  `connectionIsBusy` returns 1 → `sqlite3_close` (v1) returns
  SQLITE_BUSY and does NOT free `db`. No dangling pointer. Instead the
  `sqlite3*` (and its file handle) LEAKS: rusqlite's `Connection` Drop
  discards the BUSY result and no owner remains to retry the close.
  Reclassified to S2 bounded leak (one connection per close-with-open-
  blob). The asymmetry (blob self-defused, session not) is the orch
  re-verification catching an over-broad finder claim.

### S3 (backlogged; never blocks — committed post-burn-down pass)

- **M6** — wal/progress/busy C callbacks are registered via RAW ffi
  (not rusqlite's guarded trampolines), so they ride NO `catch_unwind`;
  panic-free today by construction only. Hardening: add our own guard.
  (Falsifies seed assumption 2.)
- **M7** — `busy_callback` `thread::sleep` and `wal_hook_callback`
  checkpoint I/O run on the C stack holding the conn Mutex. Largely
  by-design (busy retry / autocheckpoint emulation); docs/scheduler
  note owed. (Falsifies seed assumption 4.)
- **M10/M11** — `explain_analyze.rs:380-490` (`map_put().unwrap()` ×24)
  and `nif.rs:2057` (`OwnedBinary::new(0).unwrap()`) use `unwrap` where
  the crate's graceful `map_err`/`ok_or_else` convention applies.
  Latent (never Errs in practice); consistency fix.
- **M6 & M7 → closed `7e575f7` (2026-07-19)** — own `catch_unwind` guard
  on the three raw-FFI callbacks (M6); busy-sleep / wal-checkpoint
  mutex-pinning documented in `set_busy_policy/2` + security guide (M7).
  M10/M11 remain open.

### Key positive results (defensive posture that HELD)

- Zero `.lock().unwrap()` in the crate — every Drop-path lock uses
  `.map_err` → `LockError`, DEFUSING the seeded poison→unwrap→VM-death
  chain (A1 priority probe: HELD).
- The classic rusqlite `sqlite3_close`-busy→panic S0 is gone at 0.40.1
  (Drop discards the close result).
- rustler 0.38: NIF-body AND return-value-encode panics both ride
  `catch_unwind` → surface as `:nif_panicked` (≥S1), never unwind-into-C
  (S0). The ONLY S0 panic surface is resource destructors — which is
  exactly where M9 lives. xqlite defines no `down`/`dyncall`.

### Fixes landed (2026-07-17)

- **M4 / M8 / M9 → `2d100bf`.** backup `send_backup_progress` frees
  `msg_env` unconditionally; `DefaultValue::Blob` encoder degrades to an
  `InternalEncodingError` term instead of `.expect()`; stream/statement
  destructors use `writeln!` (panic-proof) instead of `eprintln!`.
- **M1 / M2-session / M3 / M5 → `61cf771`** (owner-steered
  2026-07-17: leak-on-explicit-close over a children refcount; plain
  `Mutex` for the log callback). blob & session ops + `Drop` +
  explicit close/delete all funnel through the connection Mutex via
  `with_blob`/`with_session`/`close`, proving the connection open and
  running teardown under the lock (session close-order leaks the small
  session object rather than delete a freed db). The log callback takes
  `MASTER_LOCK`, serialising its read against the writers that free the
  list. Regression tests: op-on-connection-closed-after-open + safe
  teardown for both blob and session.
- **M2-blob (S2 connection leak) — ACCEPTED, not fixed.** Closing a
  connection with a live blob leaks that one `sqlite3*` (its internal
  Vdbe makes `sqlite3_close` return BUSY; no owner remains to retry).
  Fixing it needs the connection-owns-children refcount the owner
  declined (2026-07-17). Documented as misuse; not a crash.

### Disposition & dryness

- All S0/S1 CONFIRMED findings FIXED (`2d100bf`, `61cf771`); M2-blob S2
  leak accepted as documented misuse. The publish/announcement blocker
  from this run is CLEARED pending the A2 re-run below. S3 (M6, M7,
  M10/M11) → BACKLOG.md + committed post-burn-down pass.
- Dryness: A1 — one covering run, 0 live S0 (poison chain HELD; the
  destructor-eprintln residual is fixed); needs one more covering run
  to go DRY. A2 — the blob/session/log fix CHURNS this scope, so it
  re-wets: a follow-up covering run over `61cf771` (blob/session
  locking + log callback) is owed before A2 can approach DRY, and it
  should also cover A6 (lifecycle) and A11 (feature islands), which the
  same seam touched.

---

## Run 2 — 2026-07-17 — wave-2 chunk-1 adversarial re-run (A2/A6/A11 over `61cf771`)

- Commit at scan: `dca9232` (HEAD; targets under attack = `61cf771` +
  `2d100bf`). Scope: the blob/session/log memory-safety fix — `blob.rs`,
  `session.rs`, `log_hook.rs`, the blob/session NIF sites in `nif.rs`, and the
  `connection.rs`/`stream.rs`/`statement.rs` teardown seam. Fleet: 3 opus
  prosecutors (UB/close-order, deadlock/interleaving, resource-lifecycle) +
  opus synthesis-orchestrator re-verification (all-opus; Fable's guardrails
  forced delegation of the adversary stances). READ-ONLY, structured findings;
  orchestrator mechanism-dedup + independent source-level re-verification
  against the BUNDLED SQLite (libsqlite3-sys 0.38.1, amalgamation 3.53.2) and
  rusqlite 0.40.1 / rustler 0.38.0 sources. 2 raw findings (one mechanism,
  found by 2 of 3 prosecutors; the 3rd returned a clean deadlock/lock-order
  sweep) → 1 mechanism after dedup.

### CONFIRMED (fixed this run)

- **B1 — S0 — blob teardown dereferenced the moved-out rusqlite `Connection`
  wrapper (use-after-move / UB).** `blob::close`'s Ok arm ran `drop(blob)` with
  NO `conn_guard.is_some()` gate — unlike `session::close` (session.rs:58).
  After `close_connection` `conn_guard.take()`s and drops the `Connection`
  (connection.rs:176), the ResourceArc's `Option<Connection>` slot is `None`,
  yet the blob's `Blob<'static>.conn` (a real `&Connection`, rusqlite
  blob/mod.rs:202, set by the old blob_open's `transmute`) still pointed at that
  slot. `drop(blob)` → `Blob::drop` → `close_()` (blob/mod.rs:400,302) →
  `self.conn.decode_result(rc)` (blob/mod.rs:305) → `self.db.borrow()`
  (lib.rs) + raw db read (inner_connection.rs:135), reading a `Connection`
  through a reference after it was moved out and dropped. The C object is fine
  (an open blob's Vdbe `pBlob->pStmt` (sqlite3VdbeCreate → `db->pVdbe`) makes
  `connectionIsBusy` return 1, so `sqlite3_close` v1 returns SQLITE_BUSY and
  leaks the live `sqlite3*`; rusqlite `InnerConnection::drop` discards that
  result — `#[expect(unused_must_use)]`) — but the RUST-wrapper deref is not.
  **The exact gap Run 1's M2(blob) refutation missed**: it proved the *C db* is
  not freed and stopped there, never noticing rusqlite's `Blob` independently
  holds and derefs a `&Connection`. Session is immune — `PhantomData<&Connection>`,
  Drop touches only `self.s`. Reachable from the shipped public path
  (blob_test.exs "blob ops on a connection closed after open…") AND from GC-drop
  of a live `XqliteBlob` after its connection is closed.

### REFUTED (prosecutor attacks that HELD — no code change)

- **M2(session) close-order UAF** — `session::close` gates delete on
  `conn_guard.is_some()` and `mem::forget`s otherwise; rusqlite `Session` is
  `PhantomData<&Connection>`, Drop touches only `self.s`. take() and the gate
  both run under the conn Mutex — no TOCTOU. Sound; this is the guard blob
  structurally lacked, now made moot by the raw-pointer refactor.
- **M3 log-hook Vec-free race** — `log_callback` takes `MASTER_LOCK` before its
  snapshot read; register/unregister take the same lock across the free.
  `MASTER_LOCK` is a leaf (callback only calls `enif_*`) → serialized, no cycle.
  Sound.
- **New deadlock / lock-order inversion** — every blob/session site acquires the
  conn Mutex first, then the per-resource guard; single total order
  L_conn→L_resource, MASTER_LOCK a disjoint leaf, callbacks under L_conn
  lock-free. No reverse edge. Sound.
- **M5 progress-list UAF via session stepping** — session_changeset/patchset run
  under `with_session_mut` (conn Mutex held), so `xProgress` fires under the
  conn Mutex, serialized against `register_progress_hook`/`query_cancellable`.
  Sound.
- **Self-deadlock: construct-under-lock Drop re-locks L_conn** — the ResourceArc
  is the `with_conn` closure's return value, moved out, never dropped under
  L_conn. Sound.

### RED repro — level achieved: Miri-pattern-model + written proof

- **Miri over an isolated pure-Rust model** (`native/xqlitenif/miri/`): a `&T`
  into an `Option<T>` slot, `.take()` so the `T` is dropped, then a `Drop` that
  derefs the stale `&T` — the exact unsound shape of the old blob teardown.
  `cargo +nightly miri run` flags it deterministically (exit 1: "reading memory
  … but memory is uninitialized", at the `RefCell` borrow-flag read inside
  `Blob::drop` → `close_()` → `Conn::decode_result`). The native build exits 0
  — the moved-from bytes read benignly on the current layout, proving the UB is
  latent and layout-dependent (a niche/borrow-flag collision would panic-in-drop
  → unwind into C → BEAM crash, since rustler-0.38 destructors have no
  catch_unwind).
- **A crashing end-to-end NIF repro is infeasible** under the available
  toolchain and is honestly reported as such: Miri cannot execute the bundled C
  SQLite (no real FFI); no sanitizer-instrumented sqlite build is available for
  ASan; and the live `Option<Connection>` layout reads benignly, so the crash
  cannot be forced deterministically. The Miri pattern-model + the source-level
  deref-chain proof (verified file:line across rusqlite + xqlite, above) are the
  strongest achievable evidence.
- **Interim artifacts removed (cleanup).** The `native/xqlitenif/miri/`
  pattern-model crate was intentionally deleted after serving its purpose; its
  finding now lives permanently in the `XqliteBlob` struct doc comment
  (`native/xqlitenif/src/blob.rs`) and in this ledger entry (together the
  complete record). The nightly toolchain + `miri` component installed only to
  run it were uninstalled too; `mise`/`.tool-versions` untouched.

### FIX — Refactor B (`b1c60b4`)

- `XqliteBlob` no longer stores a rusqlite `Blob` wrapper anywhere. It now owns
  a raw `AtomicPtr<ffi::sqlite3_blob>` (null == closed) plus the conn
  `ResourceArc`, mirroring `XqliteStream`/`XqliteStatement`. All ops
  (`open`/`read`/`write`/`size`/`reopen`/`close`) are reimplemented in raw FFI
  (`sqlite3_blob_open`/`_read`/`_write`/`_bytes`/`_reopen`/`_close`), each
  holding the connection Mutex for the whole call via `with_live_blob` (mirrors
  `with_live_stmt`) or `close` (mirrors `take_and_finalize_raw`). **No
  `&Connection` is dereferenced on any blob teardown path** — `Drop` and
  `blob_close` just `sqlite3_blob_close` the raw pointer, sound even after the
  connection is closed (the open blob keeps the db alive at SQLITE_BUSY;
  source-confirmed against the amalgamation). The two `unsafe impl Send/Sync`
  are gone (the raw-pointer struct is auto `Send + Sync`, like stream/statement).
  Public behavior preserved exactly: offset/length clamping, empty-binary on
  out-of-range offset, `BlobSizeError`→`{:cannot_execute, …}` on oversized
  write, `{:read_only_database, …}` on read-only write, idempotent close.
- Tests: existing regression tests pass; the two closed-state tests tightened
  from `{:error, _}` to `{:error, :connection_closed}`; added a GC-drop
  regression (a blob abandoned by a dying process after its connection is closed
  is torn down crash-free). `cargo fmt`/`clippy --all-targets -D warnings` clean;
  `mix verify` green.
- Not touched (out of scope, unchanged): the accepted M2(blob) S2
  connection-leak decision (still documented misuse) and the S3 backlog items.

### Disposition & dryness

- B1 was the sole publish/announcement blocker from this run; FIXED (`b1c60b4`).
  It was NOT a re-litigation of the accepted M2(blob) S2 leak — that leak stands
  as documented misuse; B1 was a distinct, coexisting Rust-level UB on the same
  teardown that Run 1 did not surface.
- Dryness: **A2** — the locking law HELD on the re-run (M1/M5 fix verified
  sound, deadlock-free) and the B1 refactor keeps every `sqlite3_blob_*` under
  the conn Mutex; this run is one clean covering pass over the new blob
  teardown, one more owed to reach DRY. **A6** (resource lifecycle) and **A11**
  (blob I/O feature island) — one clean covering run each with the refactor +
  GC-drop test; one more owed. **A1** — B1's panic-in-drop manifestation is
  eliminated (no wrapper, no borrow-flag read in `Drop`), so the blob path no
  longer re-implicates the rustler-0.38 no-catch_unwind destructor seed. No axis
  reaches DRY this run.

---

## Run 3 — 2026-07-18 — A8 durability crash-harness (crown jewel)

- Commit at scan: `3893256` (HEAD). Scope: durability + integrity of the
  commit path through the xqlite public API under a hard SIGKILL of the writer
  OS process mid-write, across both journal modes. Composition: single Opus
  pass (this agent) — harness authored, run, and classified; no fleet (A8 is a
  build-and-measure axis, not an adversarial read). Artifact checked in under
  `durability/`, isolated from `mix test.seq`/CI: not under `test/`, not in
  `elixirc_paths` (never compiled by `mix compile`), and the formatter `inputs`
  glob (`{config,lib,test}/**`) does not match it — `mix verify` is untouched.

### Harness (`durability/`, invoke `bash durability/run.sh`)

- `run.sh` — orchestrator. Per iteration: spawns `writer.exs` as a child OS
  process, waits until it is actually committing (>=1 ack line), SIGKILLs it
  BY ITS EXACT PID (captured shell `$!`, cross-checked against the writer's own
  `System.pid/0` — abort on mismatch; never a name/pattern kill) at a random
  moment in the active-write window, reaps it, then reopens the DB in a FRESH
  process (`verify.exs`) under an OS-level `timeout` and classifies the reopen.
- `writer.exs` — opens a file-backed DB via `Xqlite.open/2` (real open flags +
  pragma defaults) and inserts rows in per-row `IMMEDIATE` transactions
  (`begin`/`execute`/`commit`), each an increasing id + payload + CRC32. After
  `commit/1` RETURNS it appends the id to a raw (unbuffered) ack file — a
  SIGKILL-surviving record of a durably-committed row (the watermark).
- `verify.exs` — reopens (runs WAL/rollback recovery), `PRAGMA
  integrity_check`, reads all rows; classifies CORRUPTION (integrity fail / bad
  checksum / DB unopenable) · LOSTWRITE (an ack'd id absent, or a gap in the
  1..max prefix) · PASS. Verifier timeout → HANG (A7, counted separately,
  never conflated with corruption).

### Methodology / scope honesty

- A process SIGKILL kills the BEAM but NOT the OS: every byte already
  `write()`n (WAL frames, rollback journal, DB pages) stays in the OS page
  cache and reaches disk, so a reopen sees a consistent view. This harness
  therefore validates **crash-atomicity + crash-recovery under process death**
  — the real scenario for a BEAM app whose VM is OOM-killed / `kill -9`'d /
  crashes mid-write. It does NOT validate **power-loss / OS-crash** durability
  (that turns on fsync/`synchronous` and needs a block-device fault injector or
  a VM power-cut, unavailable here). Configs are xqlite's real defaults: WAL +
  synchronous=normal, and DELETE + synchronous=normal.

### Negative control — the harness HAS TEETH (proven before any PASS trusted)

- **Deterministic injections (hard gate; the run aborts if either fails to
  trip).** On a real post-crash DB that first verifies PASS: (1) a mid-file
  byte-smash (16 KB of 0xFF) → **CORRUPTION** (vcode 3), and (2) deleting one
  ack'd committed id → **LOSTWRITE** (vcode 4). Both tripped. This proves the
  SAME verifier that green-lights the safe runs fails on a corrupt DB and on a
  lost committed write.
- **Realistic unsafe config (corroborating).** `journal_mode=off`,
  `synchronous=off`, 4 MB transactions, 100 iterations → **15 CORRUPTION / 85
  PASS** (the 85 pass because a process-kill can't lose OS-cached bytes unless
  a torn multi-page write lands). The corruption surfaces as
  `{:open_failed, {:cannot_execute_pragma, "PRAGMA journal_mode = off;",
  "database disk image is malformed"}}` — the DB is unopenable.

### Crash-lands-mid-write evidence

- Every kill (100% of iterations across all tags, `alive_at_kill=yes`) landed
  with the writer actively committing — readiness-gated (the delay timer starts
  only after row 1 commits) and the writer loops on a 5 M-row budget it never
  exhausts, so k is never "max". Rows committed-at-kill (k) varied widely and
  was never 0: **WAL k ∈ 469..15051 (mean 7547)**, **DELETE k ∈ 288..4626
  (mean 2300)**, unsafe (4 MB txns) k ∈ 2..16 (mean 9). k neither always 0 nor
  always max — kills sample the real active-write window.

### Results (exact tallies, 500 reopens total)

- **WAL** (journal_mode=wal, synchronous=normal), **200** iterations:
  PASS=200, CORRUPTION=0, LOSTWRITE=0, HANG=0, ERROR=0, SKIP_BOOT=0.
- **DELETE** (journal_mode=delete, synchronous=normal), **200** iterations:
  PASS=200, CORRUPTION=0, LOSTWRITE=0, HANG=0, ERROR=0, SKIP_BOOT=0.
- unsafe neg-control (journal=off, sync=off), **100** iterations: PASS=85,
  CORRUPTION=15, LOSTWRITE=0, HANG=0, ERROR=0, SKIP_BOOT=0.

### Verdict — PASS

- Per this harness, xqlite upholds SQLite's crash-atomicity / durability
  guarantee through a SIGKILL of the writer VM mid-commit, on its default WAL
  config and on rollback-journal DELETE: **0 CORRUPTION, 0 LOSTWRITE, 0 HANG
  across 400 safe-mode reopens.** Every externally-acknowledged commit
  survived; present ids were always a valid contiguous, checksum-clean prefix;
  `integrity_check` == ok every time. Caveat, stated plainly: process-kill ≠
  power-loss — the `synchronous` level was NOT tested against true power loss.
  This PASS is only as strong as the negative control that backs it, and the
  control (deterministic hard-gate + realistic config) tripped.

### Disposition & dryness

- No finding — nothing to fix, nothing backlogged. **A8: NONE → one covering
  run** (harness built + green on defaults, teeth proven). Per the
  two-consecutive-covering-runs rule A8 is NOT yet DRY; one more covering run
  (or a power-loss-class extension via a real fault injector) is owed, and
  churn in the commit/open path re-wets it.

---

## Run 4 — 2026-07-18 — A7 concurrency / interleaving

- Commit at scan: `46c215c` (HEAD). Scope: the whole concurrency surface — the
  `AtomicPtr` swap/finalize discipline in `stream.rs`/`statement.rs`/`blob.rs`
  under concurrent step/finalize/close; hook-dispatch register/unregister racing
  a firing C callback (update/commit/rollback/wal/progress/busy + the global
  log); cancel-vs-close and cancel-vs-Drop; N BEAM processes sharing ONE handle;
  and owner-process death mid-transaction. Composition: single Opus pass (this
  agent) — adversarial static interleaving audit + a build-and-run probe harness
  (A7 is build-and-measure like A8, not a fleet read). Did NOT re-litigate the
  already-fixed blob/session/log findings (Runs 1–2); looked only for NEW
  distinct defects.

### Substrate fact (runtime-verified — the reason the model is sound)

- The bundled SQLite is compiled **`THREADSAFE=1`** (SERIALIZED) with
  **`MUTEX_PTHREADS`** — confirmed at runtime via `PRAGMA compile_options`
  (`["THREADSAFE=1"]`, `["MUTEX_PTHREADS"]`) and in `libsqlite3-sys` `build.rs:139`
  (`-DSQLITE_THREADSAFE=1`). So SQLite's process-global structures (allocator,
  VFS, pcache) are internally mutex-protected; NOMUTEX connections are
  single-threaded via OUR `Mutex<Connection>`, and independent handles used
  concurrently across dirty-scheduler OS threads do not corrupt global C state.
  This puts gotcha #1 / A14 in the CONTENTION/robustness bucket, not hard-UB:
  `sqlite3_threadsafe() != 0`, so `rusqlite::ensure_safe_sqlite_threading_mode`
  (`inner_connection.rs:415`) would reject any non-threadsafe build at open —
  and opens succeed.

### Static interleaving audit — every window HOLDS (guard cited)

- **W1 AtomicPtr swap/finalize.** Finalizers use swap-then-lock
  (`take_and_finalize_raw` `stream.rs:45-66`, `blob::close` `blob.rs:237-255`);
  users use lock-then-load (`with_live_stmt` `statement.rs:44-65`,
  `with_live_blob` `blob.rs:266-286`, `stream_fetch` `nif.rs:1295-1340`). The
  swap is atomic so only one caller ever gets the non-null pointer → no
  double-finalize; and `sqlite3_finalize`/`_blob_close` can only run under the
  conn `Mutex`, so a pointer loaded non-null *under the lock* cannot be
  finalized until the guard drops. Finalize and use are mutually excluded by the
  one `Mutex`; a concurrent swap-to-null between a user's load and use is
  harmless (it does not free — freeing needs the lock the user holds). Airtight
  in both orders.
- **W2 hook dispatch vs register/unregister.** All per-connection lists
  (`update`/`commit`/`rollback`/`wal`/`progress.ticks`/`progress.cancels`/`busy`)
  fire their C callback only inside `sqlite3_step`/commit, i.e. while the conn
  `Mutex` is held; every register/unregister NIF wraps the `HookList`
  COW mutation in `with_conn` (`nif.rs:283-334,1461-1608`) or `with_live_stmt`,
  so the reader and the writer that frees the old `Vec` are serialised by that
  same `Mutex` — the COW reclaim can never race a snapshot walk. The
  process-global log hook has no conn `Mutex`, so its callback and
  register/unregister share `MASTER_LOCK` (`log_hook.rs:53,89,109`). HOLDS.
- **W3 cancel-vs-close / cancel-vs-Drop.** `cancel()` is a lock-free
  `AtomicBool` store (`cancel.rs:17-19`) to an `Arc<AtomicBool>` kept alive by
  BOTH the `XqliteCancelToken` resource and the `ProgressHandlerGuard`
  (`cancel.rs:39,49-62`), so the store always targets live memory even if the
  token is GC'd or the connection closed concurrently. The `cancels` HookList
  register/unregister run under the conn `Mutex` (the guard is constructed and
  dropped INSIDE `with_conn`/`with_live_stmt`: `nif.rs:161-193,206-226,960-982`),
  serialised against the progress callback. Close just `take()`s the
  `Connection` under the `Mutex`; an in-flight cancellable query holds that
  `Mutex`, so close waits, or the query sees `ConnectionClosed`. HOLDS.
- **W4 N handles / one connection.** Every raw path funnels through the single
  `Mutex<Option<Connection>>`; the two disciplines above are its only readers of
  the raw pointers. Serialised by construction — verified by probe.
- **W5 owner death mid-txn.** The connection is a `ResourceArc`; a dead owner
  drops one ref but survivors keep it alive. A half-open transaction is left in
  SQLite's `:write` state and is recoverable — verified by probes 2 + 2b.

### Probes — harness `concurrency/` (invoke `bash concurrency/run.sh`)

- CI-isolated exactly like `durability/`: not under `test/`, not in
  `elixirc_paths` (`["lib"]` / `["lib","test/support"]`), and the formatter
  `inputs` glob (`{config,lib,test}/**`) does not match `concurrency/**` — `mix
  verify` is untouched (re-run green at HEAD). Every child is a `mix run`
  subprocess under `timeout`; Probe 2's SIGKILL targets the exact captured `$!`,
  cross-checked against the holder's self-reported `System.pid()` (abort on
  mismatch); DBs in a private `mktemp` dir, removed on exit.

- **TEETH (hard gate — all five TRIPPED before any PASS was trusted):** a
  mid-page byte-smash → CORRUPTION (`integrity_check` "database disk image is
  malformed"); a payload-tamper → CORRUPTION (per-row checksum leg); hammer with
  one acked row deleted → WRONGRESULT (set-diff oracle); busy with one committed
  row deleted → WRONGRESULT (lost-update oracle); a sleep-forever control →
  HANG (the OS `timeout` fires, rc=124). The same oracles green-light the real
  runs, so a real corruption/lost-write/hang would have been caught.

- **Probe 1 — hammer (N BEAM procs, ONE shared handle).** 8 writers + 6 readers
  + 4 prepared-statement workers × 400 ops on a single shared connection, PLUS a
  finalize-vs-step race (6 steppers vs 1 finalizer on ONE shared statement, ×20
  rounds). Oracle = `integrity_check` + acked-vs-actual row-set equality +
  per-row checksum. **PASS 4800/4800**; stable **5/5** reruns (3600/3600 each).
  No crash, no torn/lost/phantom row, integrity clean.
- **Probe 2 — owner death mid-txn (separate OS processes, shared file).** Holder
  opens, `BEGIN IMMEDIATE`, inserts an uncommitted row, is SIGKILLed by exact
  PID. Control (holder still alive) → verifier write **RECOVERED_BUSY** (lock
  genuinely held — the teeth for "not wedged"); test (holder killed) → verifier
  **RECOVERED_WROTE**, uncommitted row rolled back, integrity clean. The
  contrast proves death released the lock and recovery is clean.
- **Probe 2b — orphan txn (BEAM owner dies, SHARED handle, one VM).** A BEAM
  process does `BEGIN IMMEDIATE` + uncommitted insert on a shared handle then is
  `Process.exit(:kill)`ed mid-transaction. Survivor observes `txn_state ==
  {:ok, :write}` (not wedged), `ROLLBACK` recovers the handle, the orphaned row
  is gone, integrity clean. **PASS.** No UB from the owner vanishing mid-call.
- **Probe 3 — busy contention + observer (two conns, shared file).** Two
  connections run contended `BEGIN IMMEDIATE`/INSERT/COMMIT loops over disjoint
  bands under a retry policy + observer. **PASS 300/300** rows, `busy_events`
  observed (≥1; 4 in the full run) proving the policy retried and observers
  received `{:xqlite_busy,…}`, zero lost updates, no deadlock (completed well
  under the bounded timeout).
- **Probe 4 — open/close churn (rusqlite#1860).** 8–12 workers × 120–150
  concurrent `open`+op+`close` cycles on ONE WAL file (real dirty-scheduler OS
  threads sharing the process-global VFS — the faithful model for a library-VFS
  thread deadlock, which separate OS processes would NOT reproduce). **PASS**,
  1200–1440 opens in ~1s, **5/5** reruns, integrity clean. **#1860 does NOT
  reproduce at bundled SQLite 3.53.2 / THREADSAFE=1.**

### Findings

- **CLEAN — zero S0/S1/S2/S3.** No new distinct concurrency defect. The five
  interleaving windows hold at the source level and survived teeth-backed
  stress. (One noted non-defect, S3-adjacent at most: sharing ONE connection
  handle across BEAM processes shares that connection's transaction — a survivor
  can join or roll back another process's open txn. This is documented SQLite
  connection semantics, serialised with zero UB by the `Mutex`, not a bug; the
  Ecto-layer model is a pool of independent handles.)

### Verdict — A7 HOLDS

- The Mutex-per-handle + swap-then-lock/lock-then-load + conn-Mutex-serialised
  hook COW model is sound against interleaving, and the probes reproduce clean
  behavior with proven teeth. This is only as strong as those teeth — all five
  tripped on known-bad input.

### Honest gaps

- No TSan/Miri on the LIVE NIF: Miri cannot execute the bundled C SQLite (Run 2
  established this) and no TSan-instrumented SQLite build is available. The
  probes' UB oracle is `integrity_check` + row invariants + crash/exit-code
  detection, not a happens-before race detector — a benign data race that never
  perturbs observable state within the run window could go unseen; the
  THREADSAFE=1 + single-Mutex source analysis is what bounds that.
- Cross-OS-process sharing of ONE handle is impossible by construction (a
  `ResourceArc` lives in one VM); "N processes / one handle" was exercised with
  N BEAM processes = genuine OS-thread concurrency via dirty schedulers.
- Contention in Probe 3 is real but modest (the fast retry policy resolves it);
  no pathological sustained-contention or DEFERRED-upgrade livelock case was
  engineered.

### Disposition & dryness

- Nothing to fix, nothing backlogged. **A7: single-writer-tests-only → one
  covering adversarial+probe run, 0 findings, teeth proven.** Per the
  two-consecutive-covering-runs rule A7 is NOT yet DRY; one more covering run is
  owed. Churn in the AtomicPtr/close/open-path or the hook-registration seam
  re-wets it.

---

## Run 5 — 2026-07-19 — A6 resource lifecycle

- Commit at scan: `51bbcb6` (HEAD). Scope: the full lifecycle of every resource
  — `XqliteConn`, `XqliteStatement`, `XqliteStream`, `XqliteBlob` (raw
  `*mut sqlite3_blob`), `XqliteSession`, `XqliteCancelToken`, and the
  `HookList`/dispatch hook state — under hostile drop orders, cross-handle
  immunity, an owning/non-owning aliasing census, destructor thread context, and
  open/use/close leak loops. Composition: single Opus pass (this agent) —
  adversarial static lifecycle audit + a build-and-run probe harness (A6 is
  build-and-measure like A7/A8, not a fleet read). Did NOT re-litigate the
  settled blob/session/log memory-safety findings (Runs 1–2, blob raw-pointer
  refactor `b1c60b4`); looked only for NEW distinct lifecycle defects.

### Static audit — every lifecycle window HOLDS (guard cited)

- **Drop-once discipline (all resources).** Teardown swaps the raw pointer to
  null (or `Option::take`s) BEFORE touching SQLite, so a resource tears down at
  most once: stmt/stream `take_and_finalize_raw` swap-then-finalize
  (`stream.rs:45-66`), blob `close` swap-then-`sqlite3_blob_close`
  (`blob.rs:237-255`), session `close` `guard.take()` then drop/forget
  (`session.rs:45-70`), conn `close_connection` `conn_guard.take()`
  (`connection.rs:169-178`) + `Drop` reclaiming the busy_handler box
  (`connection.rs:57-66`). A second close/finalize/delete gets null/None → no-op.
- **Raw-handle locking rule on every SQLite-touching Drop.** stmt/stream
  finalize under the conn Mutex (`stream.rs:52-66`), blob close under it
  (`blob.rs:242-253`), session delete only while the conn is still open and
  under its Mutex (`session.rs:57-62`). Cancel token / `ProgressHandlerGuard`
  Drops touch no SQLite (`cancel.rs:65-74`).
- **Child-outlives-conn immunity.** Every child embeds
  `conn_resource_arc: ResourceArc<XqliteConn>` (`statement.rs:21`,
  `stream.rs:17`, `blob.rs:62`, `session.rs:19`), so the `XqliteConn` *resource*
  — hence its `Mutex` — always outlives the child; teardown can always lock even
  after `close/1` `take()`d the inner `Connection`. Ops on a closed conn return
  `ConnectionClosed` (`statement.rs:53`, `blob.rs:276`, `nif.rs:1317-1320`,
  `session.rs:88`), verified by probe (scenario A).
- **Cross-handle immunity — STRUCTURAL.** Every statement/stream/blob/session
  NIF takes ONLY its child handle and drives that child's embedded conn (grep of
  all `nif.rs` resource signatures); NO NIF pairs a conn with a foreign child.
  Constructors clone the conn INTO the child (`stmt_prepare` `nif.rs:758,846`,
  `stream_open` `nif.rs:1085,1202`, `session_new` `nif.rs:1864`, blob `open`
  `blob.rs:123`). `changeset_apply` (`nif.rs:1929`) takes a conn + a raw
  changeset *binary* (self-describing replication data, not a handle to
  validate) — the one place a conn meets foreign data, and correctly so.
- **Aliasing census.** Blob owns a raw `*mut sqlite3_blob`, no rusqlite wrapper
  (the Run-2 fix, doc-locked with a maintainer warning at `blob.rs:10-59`).
  Session stores `Session<'static>` soundly ONLY because rusqlite `Session` is
  `PhantomData<&Connection>`, so its `Drop` touches raw `self.s` and never
  derefs the conn (`session.rs:7-25`). stmt/stream own raw `*mut sqlite3_stmt`.
  No lifetime-erased view can outlive its owner.
- **Destructor thread context.** Bundled SQLite is `THREADSAFE=1` (Run 4
  runtime-verified) → no thread-affinity; every Drop that calls `sqlite3_*`
  holds the conn Mutex, so a GC/scheduler-thread destructor is serialised
  against any in-flight step. Panic-proofing intact: all three destructors log
  via `writeln!` not `eprintln!` (`stream.rs:83`, `statement.rs:76`,
  `blob.rs:75`) — rustler 0.38 destructors have no `catch_unwind` — and no
  `unwrap`/`expect`/index sits on a Drop path (lock poison → `LockError`;
  session recovers a poisoned guard via `into_inner`).
- **Conn field-drop order.** Fields drop in declaration order after the
  `Drop::drop` body, so `conn` (the `Connection`) drops before the hook lists
  (`connection.rs:59-64`) — no callback can fire while subscriber state is
  reclaimed. NOTE (latent no-op, not a defect): the custom `Drop` frees the
  busy_handler box BEFORE the `conn` field closes, briefly leaving SQLite's C
  busy-handler pointer dangling; sound because a resource `Drop` runs only at
  refcount 0 (no other thread holds the handle to step it) and `sqlite3_close`
  never invokes the busy handler.

### Probes — harness `lifecycle/` (invoke `bash lifecycle/run.sh`)

- CI-isolated exactly like `durability/` and `concurrency/`: not under `test/`,
  not in `elixirc_paths` (`["lib"]`), and the formatter `inputs` glob
  (`{config,lib,test}/**`) does not match `lifecycle/**` — `mix verify` is
  untouched (re-run GREEN at HEAD with the harness present; the passing
  `mix format --check-formatted` leg independently confirms the isolation).
  Every child is a `mix run` subprocess under `timeout`; no SIGKILL, no
  pkill/name-match; file DBs in a private `mktemp` dir, removed on exit.

- **TEETH (hard gate — all three TRIPPED LEAK before any PASS was trusted).**
  Retain variants plant a REAL leak (resources opened, never closed/GC'd). The
  classifier keys on **back-half RSS growth** — a bounded loop plateaus, a leak
  keeps climbing — threshold 24 MB. conn-retain → **+407 MB** back-half
  (79,088 B/occurrence = one `sqlite3*`); stmt-retain → **+64 MB** (3,108 B/stmt);
  blob-retain → **+42 MB** (2,060 B/blob). Real probes sit at ±4 MB back-half →
  a >10× separation from the teeth floor.

- **Leak loops (all PASS — RSS steady-state, fd stable 19→19).** All ×10^5
  except the file conn (×30,000):
  - conn open/use/close, **in-memory ×100,000** → back-half **−3.83 MB** (RSS
    DROPS; allocator returns memory).
  - conn open/use/close, **file WAL ×30,000** → back-half **−0.01 MB**, fd stable
    (no descriptor leak on the VFS/`sqlite3_close` path).
  - statement prepare/step/reset/finalize **×100,000** (persistent conn) →
    back-half **+0.07 MB**.
  - stream open/fetch/close **×100,000** → back-half **−1.55 MB**.
  - blob open/read/write/close **×100,000** → back-half **0.0 MB**.
  - session new/attach/changeset/delete **×100,000** → back-half **0.0 MB**.

- **Hostile drop-order matrix (PASS — 0 unexpected, no crash; reaching RESULT is
  the proof, since a double-free/UAF/unwind-into-C would exit 134/139).**
  (A) all four child ops after `close/1` return `{:error, :connection_closed}`;
  (B) conn closed with a LIVE child then the child GC-dropped (all four types) —
  crash-free; (C) stream abandoned MID-iteration then GC'd — crash-free;
  (D) double-close / close-then-drop / drop-after-close for every resource — all
  idempotent (`:ok` ×10); (E) child GC'd while the conn stays open, conn still
  usable; (F) the DOCUMENTED conn-close-with-live-child leak QUANTIFIED — 2000
  occurrences → **77,928 B/occurrence**, matching the conn-retain teeth (one
  leaked `sqlite3*`), bounded-per-occurrence, no crash, no unbounded-per-op.

### Findings

- **CLEAN — zero S0/S1/S2/S3 NEW.** Every lifecycle window holds at the source
  level and survived teeth-backed 10^5-iteration stress. The only leak observed
  is the pre-existing, ACCEPTED, DOCUMENTED conn-close-with-live-child behavior
  (ledger Run 1 M2-blob; `lib/xqlite.ex` `prepare/2` docs cover the stmt/stream
  case). Probe F confirms it is **exactly one `sqlite3*` per occurrence**
  (~77 KB, bounded, no crash) — not a new or worse defect, not re-litigated.

### Verdict — A6 HOLDS

- The `Mutex`-per-handle + swap/`take`-to-null-then-teardown + child-embeds-conn-
  `ResourceArc` model is sound against every hostile drop order, structurally
  immune to cross-handle misuse, and free of aliasing that outlives its owner.
  10^5-iteration leak loops leave RSS flat-or-shrinking with fds stable. This is
  only as strong as the teeth — all three tripped LEAK on planted leaks.

### Honest gaps

- The leak instrument is OS RSS + BEAM `:erlang.memory` + fd count, not a
  resource-count BIF (rustler exposes none). A leak smaller than back-half noise
  (~±4 MB over the measured window) could hide; the teeth calibrate the floor
  (the lightest, blob at ~2 KB/unit, cleared 24 MB by ~12k retained). The 10^5
  real loops sit far below that floor (flat/shrinking).
- No TSan/Miri on the live NIF (Run 2 established Miri cannot run the bundled C
  SQLite; no TSan-instrumented SQLite build available) — the oracle is
  crash/exit-code + RSS/fd trend, not a happens-before detector; `THREADSAFE=1`
  + single-`Mutex` source analysis bounds it.
- GC-forced teardown is driven by throwaway-process death + `:erlang.
  garbage_collect` sweeps; a resource whose `Reference` lingered in another live
  process's heap would not be reclaimed, but the probes hold no such
  cross-references (handles are created and abandoned within the dying process).

### Disposition & dryness

- Nothing to fix, nothing backlogged. **A6: close-path-tests-only → one covering
  adversarial+probe run, 0 findings, teeth proven.** Runs 1–2 touched the
  blob/session lifecycle seam, but this is the first dedicated A6 leak-loop +
  drop-matrix pass. Per the two-consecutive-covering-runs rule A6 is NOT yet
  DRY; one more covering run is owed. Churn in any resource `Drop` / `AtomicPtr`
  swap / conn field-drop order / hook-registration seam re-wets it.

---

## Run 6 — 2026-07-19 — A5 cancellation semantics

- Commit at scan: `4253b26` (HEAD). Scope: the whole cancellation surface — the
  `XqliteCancelToken(Arc<AtomicBool>)` lock-free store, the `ProgressHandlerGuard`
  register/unregister lifecycle on `ProgressDispatch.cancels`, the every-8-VM-op
  `progress_dispatch_callback` interrupt, the interrupt→`OperationCancelled`
  error mapping, and all cancellable NIFs (`query`/`query_with_changes`/`execute`/
  `execute_batch` cancellable variants, `stmt_multi_step_cancellable`,
  `backup_with_progress`'s own token loop). Composition: single Opus pass (this
  agent) — adversarial static audit of five race windows + a build-and-run probe
  harness (A5 is build-and-measure like A7/A8/A6, not a fleet read). Went DEEPER
  than A7's W3 (which settled cancel-vs-teardown at a high level) with a
  teardown storm. Did NOT re-litigate settled findings; looked only for NEW
  cancellation-specific defects.

### The mechanism (verified in source)

- `cancel()` is a lock-free `store(true, Ordering::Release)` (`cancel.rs:17-19`)
  on an `Arc<AtomicBool>` created `false` (`cancel.rs:13-15`). Any process can
  cancel without the conn handle — the store deliberately takes no Mutex.
- `ProgressHandlerGuard::new` registers one `CancelSubscriber` per token on the
  connection's `progress_dispatch.cancels` `HookList`, holding its OWN Arc CLONE
  (`t.0.clone()` at the NIF boundary: `nif.rs:159,187,204,220,927`) for the
  guard's lifetime (`cancel.rs:49-62`). Built AND dropped INSIDE
  `with_conn`/`with_live_stmt` — i.e. under the conn Mutex
  (`nif.rs:161-171,189-193,206-210,222-226,960-982`).
- `progress_dispatch_callback` fires every `PROGRESS_NUM_OPS=8` VM steps
  (`progress_dispatch.rs:51,175`), inside `sqlite3_step`, which runs only while
  the conn Mutex is held; it walks the FULL cancels snapshot and returns 1 if
  ANY flag is set (`progress_dispatch.rs:192-205`). SQLite aborts the statement
  with `SQLITE_INTERRUPT`.

### Static review — every window HOLDS (guard cited)

- **W1 cancel-vs-completion race — HOLDS, well-defined + crash-free on every
  ordering.** The interrupt return maps to the caller at `error.rs:668`
  (`SQLITE_INTERRUPT => OperationCancelled`) and `error.rs:786-788` (rusqlite
  "interrupted" fallback), encoded as `:operation_cancelled` (`error.rs:464`).
  Orderings: (a) store lands before the last progress fire → `SQLITE_INTERRUPT`
  → `{:error, :operation_cancelled}`; (b) store lands after the query already
  finished stepping → normal `{:ok, …}`, the never-fired-again check is moot;
  (c) never torn/partial — `process_rows` DROPS its results Vec on any `Err`
  (`util.rs:112`), `process_single_step` maps the interrupt code to `Err`
  (`stream.rs:121-138`), and `stmt_multi_step_impl` discards the batch `rows` on
  `Err` (`nif.rs:984-1000`). The flag memory is always live (Arc held by both the
  token resource and the guard clone), so the store never targets freed memory
  regardless of ordering.
- **W2 token reuse / stale cancel — HOLDS mechanically; SINGLE-USE by design
  (footgun, S3 doc-clarity).** The flag is set-once-true and NEVER reset — grep
  of the whole crate finds only `AtomicBool::new(false)` (`cancel.rs:14`) and
  `store(true)` (`cancel.rs:18`), no reset path. So a signalled token reused on
  the NEXT op aborts it immediately (the callback sees `flag==true` on its first
  fire, ≤8 VM ops in; backup's `any()` sees it on loop entry). This is CORRECT +
  already TESTED as intended (`statement_cancel_test.exs:38` "an already-signalled
  token cancels before any stepping"), and the recovery test reruns with an EMPTY
  token list (`:57-78`), tacitly confirming a signalled token can't be reused.
  Semantics = single-use; only `XqliteNIF.cancel_operation/1` hints it ("the
  cancellation signal remains active for the token", `xqlitenif.ex:1063`), while
  the user-facing `create_cancel_token/0`/`cancel_operation/1` docs don't say
  "single-use — create a fresh token per op". Doc gap → BACKLOG [S3]; NOT a
  crash/wrong-result (returning `:operation_cancelled` for a spent token is the
  defined behavior).
- **W3 cancel racing teardown — HOLDS (deeper than A7's W3).** The raw
  `*const AtomicBool` in `CancelSubscriber` can never dangle: (1) the guard holds
  its own Arc clone, so the pointee outlives even a GC'd token resource; (2)
  `ProgressHandlerGuard::drop` (`cancel.rs:65-73`) unregisters the subscriber
  FIRST, releasing the Arc only after, so while the subscriber is reachable from
  `dispatch.cancels` the pointer is valid; (3) register/unregister AND the
  callback read all happen under the conn Mutex (guard scoped inside
  `with_conn`/`with_live_stmt`; callback fires inside `sqlite3_step`), so
  reader/writer are serialised; (4) `close_connection` locks the SAME conn Mutex
  before `conn_guard.take()` (`connection.rs:170-176`), so an in-flight
  cancellable op (holding the Mutex) makes close wait, or a not-yet-started op
  sees `ConnectionClosed`; (5) the guard's `&'d ProgressDispatch` borrows into
  the `XqliteConn` ResourceArc that `with_conn` keeps alive for the whole closure.
- **W4 token lifecycle under process death — HOLDS.** A cancellable op runs on a
  dirty scheduler holding the conn Mutex + guard (with its Arc clone). If the
  process holding the token dies, its token-resource ref drops but the guard
  clone keeps the flag alive until the op finishes/interrupts, then the guard
  releases it — refcount decrements cleanly, no leak/wedge. Process death does
  not auto-cancel (only an explicit `cancel()` sets the flag); the op simply
  completes normally.
- **W5 multi-token OR + double-cancel idempotency — HOLDS.** The callback ORs
  across the full subscriber list (`progress_dispatch.rs:192-205`); backup uses
  `cancel_tokens.iter().any(...)` (`nif.rs:1749`). Each token is a separate
  subscriber (guard registers one per token, unregisters each on drop). Double
  `store(true)` is idempotent; empty token list = no-op guard (`cancel.rs:49`).

### Probes — harness `cancellation/` (invoke `bash cancellation/run.sh`)

- CI-isolated exactly like `durability/`/`concurrency/`/`lifecycle/`: not under
  `test/`, not in `elixirc_paths` (`["lib"]`), and the formatter `inputs` glob
  (`{config,lib,test}/**`) matches ZERO `cancellation/` files (verified via
  `Path.wildcard`) — `mix verify` untouched (re-run GREEN at HEAD with the harness
  present). Every child is a `mix run --no-compile --no-start` subprocess under
  an OS `timeout`; in-memory DBs only; no SIGKILL, no pkill/name-match; scratch
  in a private `mktemp` dir removed on exit.

- **TEETH (hard gate — all four TRIPPED before any PASS was trusted):**
  (a) a forced `System.halt(134)` control → **CRASH** (rc=134), proving the
  teardown crash oracle detects an abnormal exit (a real cancel-vs-teardown UAF
  aborts the same way); (b) a sleep-forever control → **HANG** (rc=124), proving
  the timeout leg fires; (c) the "unbounded" slow query run with NO cancel and no
  internal timeout → killed by the OS timeout (rc=124), proving it never
  self-completes so a fast cancelled return is CAUSED by the cancel; (d) the race
  probe with `TEETH=torn` injecting one synthetic undefined outcome →
  **RACE_TORN** (rc=3), proving the `:torn` classifier is not rubber-stamping.

- **Probe 1 — cancel latency (40 trials).** Settle 40 ms into an unbounded
  recursive-CTE query, then cancel and time to the NIF returning
  `:operation_cancelled`. All 40 cancelled; end-to-end wall latency **median
  55 µs**, p95 0.11 ms, p99/max 5.59 ms (one scheduler-wakeup outlier), min
  0.04 ms. This is an UPPER bound on the pure progress-handler detection latency
  (includes dirty-scheduler wakeup + message delivery); the theoretical floor is
  ≤8 VM ops after the store is observed. **Bounded and sub-millisecond.**
- **Probe 2 — cancel-vs-completion race (300 iters).** Query bound calibrated to
  ~79 ms natural runtime; cancel fired at jitter uniform(0, 2×natural) so cancels
  land clearly-before and clearly-after completion. Every result classified
  `{completed | cancelled}`; anything else = `:torn` (S0). **156 cancelled /
  144 completed / 0 torn** — BOTH classes exercised (the window is real), zero
  torn/undefined/partial outcomes, no crash.
- **Probe 3 — token reuse (deterministic).** Observed & documented:
  `single_use=true`, `auto_reset=false`, `stale_poisons_next=true`,
  `multi_token_or=true`. Teeth: a FRESH token completes the same query
  (`fresh_completes`) and three-tokens-none-signalled completes
  (`none_signalled_completes`) — proving the immediate-cancel of a reused token
  is the stale flag, not a broken path. S5 (3 tokens, only the middle signalled)
  → cancels (OR-semantics, probe-backed).
- **Probe 4 — never-cancelled overhead (INFORMATIONAL; T4.7).** Marginal cost of
  a `query_cancellable` (one live never-signalled token: guard reg/unreg +
  per-8-op Acquire flag load) vs plain `query` (empty cancels list, callback a
  null-check no-op). Tiny queries (50k × `SELECT 1`): **−6.27%** (within noise —
  cancellable measured slightly faster). Heavy queries (20 × 3M-row CTE,
  ~375k progress fires each): **+0.84%**. So the marginal cost of one registered
  cancel token is **≈0–1.5%, noise-level on tiny calls**. NOT a perf concern.
  Honest gap: the ABSOLUTE always-on progress-handler cost (vs a no-handler
  build) is not Elixir-measurable — it needs a recompile.
- **Probe 5 — cancel racing teardown (400 iters).** Each iter: a fresh
  in-memory conn + slow stmt + token; an in-flight `multi_step_cancellable`
  racing 2 cancel-storm tasks (200 cancels each) and a teardown action
  (close/finalize, rotated); plus cancel-after-teardown storms (store to a live
  Arc, conn gone); plus a GC-drop-under-cancel leg every 7th iter (~57×: a holder
  process runs a step, a sibling cancels the shared token, the holder is killed
  mid-op → conn/stmt/token destructors run while a cancel is live); plus 3
  churned+abandoned tokens/iter so token destructors overlap the next iter.
  **266 cancelled / 93 conn_closed / 41 stmt_finalized / 0 torn / 0 crash /
  0 hang** — all three teardown-race outcomes observed, zero undefined results.
  Reaching RESULT is the no-crash proof (a UAF/double-free/unwind-into-C aborts
  the VM → run.sh CRASH; a wedge → OS-timeout HANG).

### Findings

- **CLEAN — zero S0/S1/S2 NEW.** Every cancellation window holds at the source
  level and survived teeth-backed stress: latency bounded (median 55 µs), the
  cancel-vs-completion race produced only well-defined outcomes across 300 hits
  (0 torn), and the teardown storm ran 400 iters + ~57 GC-drop legs crash-free.
- **S3 (BACKLOG, doc-clarity only):** cancel tokens are single-use (set-once
  `Arc<AtomicBool>`, no reset); a reused signalled token silently aborts the
  next op. Correct + tested behavior, under-documented at the user-facing API.
  Filed in `BACKLOG.md`. Not a crash/wrong-result; never blocks.

### Verdict — A5 HOLDS

- The lock-free-store + guard-holds-Arc-clone + unregister-before-release +
  conn-Mutex-serialised-callback model is sound against completion races, token
  reuse, teardown, and process death; cancellation is prompt (sub-ms median) and
  its never-cancelled overhead is negligible. Only as strong as the teeth — all
  four (CRASH, HANG, latency-validity, TORN) tripped on known-bad input.

### Honest gaps

- The teardown oracle is a crash/hang exit-code oracle (like A6/A7/A8), NOT a
  happens-before race detector. A live-NIF UAF cannot be injected from Elixir
  (safety is compiled in) and no ASan/TSan-instrumented SQLite build is available
  (Runs 2/4/5 established Miri can't run the bundled C SQLite); the forced-134 +
  sleep-forever controls prove the oracle detects crash/hang exits, and the
  source-level W3 proof + `THREADSAFE=1` bound the residual.
- Cancel latency is end-to-end wall time (store → dirty-scheduler wakeup →
  detect → interrupt → return → message), an upper bound on the pure
  progress-handler latency; the ≤8-VM-op floor is reasoned, not instrumented at
  the C level.
- The always-on progress-handler ABSOLUTE cost is not measured (needs a
  no-handler recompile); only the marginal cancellable-vs-plain delta is.

### Disposition & dryness

- Nothing to fix (the one S3 is doc-clarity, backlogged). **A5:
  cancellation-suites-only → one covering adversarial+probe run, 0 S0/S1/S2, teeth
  proven.** Existing tests covered the deflaked mid-flight + already-signalled +
  reset-and-rerun cases; this is the first dedicated latency/race/reuse/teardown/
  overhead matrix. Per the two-consecutive-covering-runs rule A5 is NOT yet DRY;
  one more covering run is owed. Churn in `cancel.rs` / `progress_dispatch.rs` /
  the `ProgressHandlerGuard` scoping in any cancellable NIF re-wets it.

---

## Run 7 — 2026-07-19 — A9 type/value edges

- Commit at scan: `d5507c6` (HEAD). Scope: end-to-end value round-trips through
  the ACTUAL public API (`Xqlite.open_in_memory` → bind/insert → read back), across
  ALL read paths — `query`/`execute` (rusqlite `process_rows`, `query.rs:50`),
  `stream` and prepared `step`/`multi_step` (raw-FFI `sqlite_row_to_elixir_terms`,
  `util.rs:277` via `process_single_step`), and incremental `blob_read`
  (`nif.rs:2022`) — plus the bind path (`util.rs` `elixir_term_to_rusqlite_value`)
  and the type-extension encoders. Composition: single Opus pass (this agent) —
  a build-and-measure edge matrix (A9 is a drive-real-values axis, not a fleet
  read), each edge PINNED against a KNOWN input with a byte-exact equality oracle
  that has proven teeth. Did NOT re-litigate settled findings.

### Harness (`type_edges/`, invoke `bash type_edges/run.sh`)

- `probe.exs` drives 7 edges; `run.sh` gates on an oracle self-test first.
  CI-isolated exactly like `durability/`/`concurrency/`/`lifecycle/`/`cancellation/`:
  not under `test/`, not in `elixirc_paths` (`["lib"]`), and the formatter `inputs`
  glob (`{config,lib,test}/**`) matches ZERO `type_edges/` files (verified via
  `Path.wildcard`: `matched_by_formatter_glob: false`) — `mix verify` untouched
  (re-run GREEN at HEAD with the harness present). One `mix run --no-compile
  --no-start` child under an OS `timeout`; in-memory DBs only; no files, no SIGKILL,
  no pkill/name-match. The MAX_LENGTH probe uses `zeroblob(1000000001)`, which
  SQLite rejects with SQLITE_TOOBIG BEFORE any allocation (source-verified:
  `sqlite3_result_zeroblob64` checks `n > db->aLimit[SQLITE_LIMIT_LENGTH]` first,
  libsqlite3-sys-0.38.1 amalgamation), so the box is never asked for ~1GB.

### TEETH (hard gate — the equality oracle self-test must pass first)

- `probe.exs selftest` plants 4 corruptions the oracle MUST flag (truncate-at-NUL
  `<<1>>`≠`<<1,0,2>>`, int wrap `-2^63`≠`2^63`, int-vs-float `1`≠`1.0`, NUL-text
  truncation `"a"`≠`"a\0b"`) and 2 correct values it must NOT false-positive. All 6
  behave; run.sh ABORTS (rc 2) otherwise. The same `===` oracle green-lights every
  real round-trip, so a truncated/wrapped/type-drifted read would FAIL the probe.

### Per-edge PINNED behavior (observed vs expected)

- **Bignum beyond i64 — CLEAN (expected).** i64 max/min round-trip byte-exact;
  `+2^63` and `-2^63-1` → `{:error, {:cannot_convert_to_sqlite_value, "<decimal>",
  "{error, badarg}"}}` with NOTHING stored (rustler `i64` decode rejects the bignum
  at the bind boundary; `util.rs` Integer arm). No silent wrap/truncate. Instant
  type-extension on a year-2300 `DateTime` (ns = 1.04e19 > i64) → same clean error.
- **NaN / ±Infinity — TWO behaviors, one a finding.** (a) Non-finite floats CANNOT
  be materialized as BEAM floats (`binary_to_term` of a non-finite `NEW_FLOAT_EXT`
  raises), so the BIND path can never receive one — the only non-finite exposure is
  READ-side. (b) **Reading a ±Inf REAL raises `ArgumentError "argument error"` on
  EVERY read path** (F1 below). (c) NaN stored → NULL (`typeof`=null); computed NaN
  (`SELECT 9e999-9e999`) → `nil` too — consistent, SQLite converts NaN→NULL at the
  value layer, so NaN never reaches the float encoder (D2 doc below).
- **Interior-NUL round-trips — CLEAN (expected), READ PATHS PROVEN.** TEXT
  `"a\0b\0c"` (5 B) and BLOB `<<1,0,255,0,2>>` (5 B) both read back BYTE-EXACT via
  query, stream, prepared step, AND incremental blob_read — no truncation on any
  read path (both decoders length-bind via `sqlite3_column_bytes`; the write-path
  fix `a7dc84e` completes the trip). NOTE: SQL `length()` on the NUL-TEXT returns
  1 (SQLite C-string-length quirk) though the value is the full 5 bytes — a SQLite
  behavior, not an xqlite data issue.
- **Invalid-UTF-8 TEXT read-back — CLEAN on query/step, SWALLOWED on stream.**
  `CAST(X'ff41' AS TEXT)` (TEXT storage class, invalid bytes). query & step → clean
  structured `{:error, {:utf8_error, 0, "invalid utf-8 sequence of 1 bytes from
  index 0"}}` (query path: rusqlite `TryFrom<ValueRef>` `from_utf8?` `value_ref.rs:159`
  → `row.rs:295` → `error.rs:752`; raw-FFI path: `from_utf8` in `util.rs` →
  `XqliteError::Utf8Error`). No lossy replacement, no raw bytes. The stream path is
  the exception → F2 below.
- **SQLITE_MAX_LENGTH / MAX_VARIABLE_NUMBER — CLEAN (expected).** 40 000 binds →
  `{:error, {:sql_input_error, %{code: 1, message: "…too many SQL variables", …}}}`
  at prepare (limit 32766); 100 binds OK. `zeroblob(1000000001)` →
  `{:error, {:sqlite_failure, 18, 18, "string or blob too big"}}` (SQLITE_TOOBIG,
  zero allocation); 1000-byte zeroblob OK.
- **Offset-preserving DateTime TEXT vs ORDER BY — DECISION-DEBT (D1 below).**
- **Encode-only Instant read-back — CLEAN (expected).** Reads back the raw int64 ns
  byte-exact (`Instant.decode` is always `:skip`, documented "no decode").

### CONFIRMED findings (reported for maintainer ruling — NOT fixed speculatively)

- **F1 — S1 — reading a non-finite (±Inf) REAL raises `ArgumentError "argument
  error"` on every read path.** `SELECT 9e999` / `SELECT -9e999` (computed) AND
  `INSERT INTO f VALUES(9e999); SELECT x FROM f` (stored) both raise via `query`,
  `stream`, and prepared `step`. Root: rustler `f64::encode` → `enif_make_double`
  with NO finiteness guard (`rustler-0.38.0/src/types/primitive.rs:61`), called at
  `util.rs:26` (`encode_val` `Value::Real(f) => f.encode(env)`, query/process_rows
  path) and in `sqlite_row_to_elixir_terms`'s `SQLITE_FLOAT` arm
  (`sqlite3_column_double` → `val.encode(env)`, stream/step path). `enif_make_double`
  on a non-finite double posts a return-time `badarg`, so the caller gets an
  `ArgumentError` — NOT the library's `{:ok|:error}` contract, and NOT a value. NOT
  S0: it is loud (a raise, not a silent wrong value), no UB, no VM crash, and the
  connection is STILL USABLE afterward (`inf_raise_conn_still_usable` = OK — the
  conn Mutex drops cleanly before the return-time raise). INCONSISTENT with the
  schema layer, which DELIBERATELY guards non-finite floats
  (`schema.rs:302` `f.is_finite()` → `{:expr,…}`; documented `column_info.ex:28`) —
  the row-value read path has no equivalent guard, and this is undocumented at the
  `query`/`stream` API. Reachable: `SELECT 1e309`, float-overflow arithmetic/
  aggregates, `INSERT … VALUES(1e400)` then read. **MAINTAINER QUESTION (yes/no):**
  should reading a non-finite float raise, or return a structured
  `{:error, :non_finite_float}` / a sentinel atom (`:infinity`/`:"-infinity"`) /
  the float via a lossless encoding? Pick a policy and document it.
- **F2 — S1 — the stream path SWALLOWS a mid-stream fetch error into `Logger.error`
  and silently truncates the result set.** `stream_resource_callbacks.ex:89-102`
  (`next_fun` `{:error, reason}` arm: `Logger.error(…)` then `{:halt, acc}`; the code
  comment ITSELF notes "Stream.resource/3 does not propagate this error to the
  consumer … logging is safer for now"). Demonstrated: a 4-row table with invalid
  UTF-8 in row 3, streamed `batch_size: 1`, yields ONLY `["g1","g2"]` — row 3 AND the
  trailing good row 4 are silently dropped, no error to the caller, only a log line;
  `query`/`step` on the SAME data return `{:error, {:utf8_error, 0, …}}`. A consumer's
  `Enum.to_list` cannot distinguish a complete stream from one aborted mid-flight
  (success-on-failed-read / silent result truncation). Deliberate but user-
  undocumented. **MAINTAINER QUESTION (yes/no):** should the stream propagate fetch
  errors (raise, or emit a terminal `{:error, …}` element, or take an `on_error:`
  option) instead of silently truncating?

### DECISION-DEBT (pinned; maintainer yes/no)

- **D1 — offset-preserving `DateTime` stored as ISO 8601 TEXT sorts LEXICALLY, not
  chronologically, under `ORDER BY`, when rows carry different UTC offsets.**
  Demonstrated: `dtA = 2024-06-01T23:00:00+00:00` (unix 1717282800) and
  `dtB = 2024-06-02T00:00:00+02:00` (unix 1717279200, EARLIER); `ORDER BY ts ASC`
  returns `["A","B"]` but chronological order is `["B","A"]`. The VALUE round-trips
  EXACTLY (`decode(B) == dtB`) — storage is not corrupt; only the SQL sort is wrong.
  `Xqlite.TypeExtension.DateTime` encodes via `DateTime.to_iso8601/1`, which keeps
  the offset. **MAINTAINER QUESTION (yes/no):** acceptable as-is (document the
  caveat), or should `DateTime` store a sort-stable form (UTC-normalized ISO 8601,
  or the `Instant` int64 ns) so `ORDER BY` is chronological?
- **D2 — S3 doc — stored NaN silently becomes NULL.** `INSERT … VALUES(9e999-9e999)`
  → `typeof` = null, value `nil`. Documented SQLite behavior (no NaN storage class),
  but not surfaced in xqlite's value-handling docs. **MAINTAINER QUESTION (yes/no):**
  document the NaN→NULL policy alongside the F1 Inf policy?

### Disposition & dryness

- F1 + F2 are CONFIRMED S1 and — per the ratified bar — announcement-blockers
  pending Dimi's ruling (both hinge on a desired-semantics DESIGN choice, so NOT
  fixed speculatively; captured with minimal repros above + in the reusable probe).
  D1 + D2 pinned as decision-debt. All FOUR filed in `BACKLOG.md`. Every byte-exact
  round-trip HELD (bignum, interior-NUL ×4 paths, blob, DateTime value, Instant) —
  zero S0 silent value corruption. `mix verify` GREEN with the harness present.
- **A9: type-extension-suites-only → one covering value-edge run, 0 S0, 2 S1
  (F1/F2) + 2 decision-debt (D1/D2), teeth proven.** Per the two-consecutive-
  covering-runs rule A9 is NOT yet DRY; one more covering run is owed (and any
  F1/F2 fix will CHURN the `util.rs` encode paths / `stream_resource_callbacks.ex`
  and re-wet it). Churn in the `util.rs` value encoders, the stream fetch loop, or
  any type_extension encoder re-wets A9.
