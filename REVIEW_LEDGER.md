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

### Resolution — F1 + F2 ruled and fixed → `16ca65d`

- **F1 fixed.** Non-finite REAL reads now map to sentinel atoms —
  `+Inf → :positive_infinity`, `-Inf → :negative_infinity`, `NaN → nil` — via
  `util.rs` `encode_f64`, applied at BOTH float-encode sites (`encode_val`
  query path + the `SQLITE_FLOAT` arm of `sqlite_row_to_elixir_terms`
  stream/step path); atoms added in `lib.rs`. Consistent with the
  `schema.rs` finiteness guard. Tests: query/stream/step read `±Inf` →
  sentinels, computed NaN → nil, conn stays usable, finite + NULL round-trip.
- **F2 fixed.** `Xqlite.stream/4` gains a ruled `on_error` option threaded
  through `stream_resource_callbacks.ex`: `:raise` (DEFAULT — raises
  `Xqlite.StreamError`, structured reason preserved), `:halt` (opt-in,
  documented LOSSY), `:emit_error` (uniform `{:ok, row}` / terminal
  `{:error, reason}`). Invalid value → `{:error, {:invalid_on_error, v}}` at
  stream open. Default flips silent-halt → raise (CHANGELOG noted). Tests
  per mode (happy-path element shape + mid-fetch error behavior).
- D1 + D2 remain open decision-debt (untouched). A9 dryness: this fix
  CHURNED the `util.rs` encoders + `stream_resource_callbacks.ex` as
  predicted — the owed covering re-run should re-pin the new sentinel /
  `on_error` behavior. `mix verify` GREEN at `16ca65d`.

## Run 8 — 2026-07-19 — A10 structured-error contract (SURFACE-ONLY)

- Commit at scan: `56315c2` (HEAD). Scope: the structured-error contract from the
  NIF boundary to the Elixir caller — the `From<RusqliteError>` + raw-FFI error
  builders (`error.rs`, `stream.rs`, `nif.rs`, `connection.rs`), the constraint
  message parser (`constraint_parse.rs`), the `XqliteError` enum + its `Display`
  and `Encoder` (`error.rs`), the Elixir `error_reason/0` union + `Xqlite.StreamError`,
  and `changes()` handling. Composition: single Opus pass (this agent) — a static
  census + a build-and-measure contract probe. **Budget-constrained SURFACE-ONLY
  pass: findings are recorded + filed to `BACKLOG.md`, NOT fixed** (the maintainer
  schedules fixes next session). Zero code fixes committed.

### Audit — the four sub-areas

1. **Text-parsing census → FINDING (F-A10-1, S3).** Enumerated EVERY error
   classification that keys off message text (`rg` over `native/**/*.rs`):
   (i) `constraint_parse.rs` — the SANCTIONED exception, documented in the module
   header (SQLite exposes constraint metadata — columns/index/constraint names —
   only as `sqlite3_errmsg` text; parsed ONCE at the lowest layer, keyed by the
   extended code, so structured fields flow up). (ii) `error.rs:689-704`
   `classify_sqlite_error` — `NoSuchTable` / `NoSuchIndex` / `TableExists` /
   `IndexExists` classified by `lower_msg.starts_with("no such table")` /
   `starts_with("no such index")` / `starts_with("table") && contains("already
   exists")` / `starts_with("index") && contains("already exists")`. (iii)
   `error.rs:786` — `message_string == "interrupted"` → `OperationCancelled` in the
   `From` catch-all. (i) is by-design; (ii)+(iii) are the exceptions the A10 seed
   predicted — see F-A10-1. `schema.rs` text-parsing (default-value literal grammar
   + the `contains("INT")` affinity algorithm) is NOT error classification (schema
   introspection / the documented SQLite affinity rules) — out of A10 scope.
2. **Extended result codes → HOLDS (+ completeness gap F-A10-2, S3).** Source-verified
   that rusqlite 0.40.1 UNCONDITIONALLY enables extended codes on every connection:
   `inner_connection.rs:81-86` ORs in `SQLITE_OPEN_EXRESCODE` for SQLite ≥ 3.37.0
   (ours is 3.53.2) regardless of caller flags, with a `sqlite3_extended_result_codes(db,1)`
   fallback (`:115`) for older libs. So every raw code IS extended. Every error path
   converges on `classify_sqlite_error` with the extended code intact: the rusqlite
   safe API (`From<RusqliteError>`), and ALL raw-FFI builders — stream step
   (`stream.rs:133`), stream bind (`stream.rs:195`), manual `prepare` ×2
   (`nif.rs:797`, `nif.rs:1122`), `wal_checkpoint_v2` (`nif.rs:456`) — all build
   `ffi::Error::new(rc)` where `ffi::Error::new` sets `extended_code = rc`
   (libsqlite3-sys `error.rs:98`). Classification matches `extended_code & 0xFF`
   against C constants (`ffi::SQLITE_BUSY` etc.) and the full extended code against
   `ffi::SQLITE_CONSTRAINT_UNIQUE` etc. — gotcha #2 (enum 3 vs C-constant 5) handled
   correctly everywhere; NO path uses the `ErrorCode` enum for matching. Open path
   preserves `ffi_err.extended_code` (`connection.rs:156`) with a `-1` sentinel for
   non-`SqliteFailure` opens. GAP (F-A10-2): the SEMANTIC variants
   (`DatabaseBusyOrLocked` / `ReadOnlyDatabase` / `SchemaChanged` /
   `AuthorizationDenied` / `NoSuchTable` / `NoSuchIndex` / `TableExists` /
   `IndexExists`) carry ONLY `message` — they DROP the extended code the generic
   `SqliteFailure` fallback keeps.
3. **`changes()` stickiness → HOLDS (+ RETURNING edge F-A10-3, S3).**
   `query_with_changes` (`nif.rs:137`, `:165`) zeroes the sticky counter for
   non-DML by `qr.columns.is_empty()` — correct for SELECT/DDL/PRAGMA; probe
   negative-control confirmed a SELECT-after-DML reports `changes=0`. `changes/1`
   (`nif.rs:736`) returns the raw sticky counter BY DESIGN (documented in CLAUDE.md).
   `execute` reads rusqlite's immediate DML count (`nif.rs:106`, DML-only — a SELECT
   returns `:execute_returned_results`). EDGE (F-A10-3): a DML with `RETURNING`
   returns columns, so the empty-columns heuristic misdetects it as non-DML and
   zeroes `changes`.
4. **Error-shape structural contracts → HOLDS (+ F-A10-4/5/6, all S3).** Every one
   of the ~40 `XqliteError` variants encodes to a bare classification atom or a
   `{atom, …}` tuple (maps ONLY ever nested inside a tuple: `{:sql_input_error, map}`,
   `{:constraint_violation, kind, map}`, `{:invalid_parameter_count, map}`) — all
   `with {:error, reason}`-destructurable, no top-level map, no bare `:error`
   reaching the caller in practice. `Exception.message` is a binary on the ONLY
   raising surface (`Xqlite.StreamError`, `stream_error.ex:22`, interpolated). Three
   gaps: F-A10-4 (`UnsupportedAtom` drops its `atom_value` on encode), F-A10-5
   (`error_reason/0` omits `{:invalid_open_option, map}`), F-A10-6 (latent
   doubled-`:error` fallback in the map-build-failure arms).

### Probe (`error_contract/`, invoke `bash error_contract/run.sh`)

- `probe.exs` drives 16 REAL error conditions through the ACTUAL public API and
  asserts the contract on each returned `{:error, reason}`: (a) STRUCTURED atom
  classification (never a bare binary, never bare `:error`), (b) EXTENDED code
  present+correct, (c) `Exception.message` binary, (d) shape destructured by a real
  `with`. CI-isolated exactly like `type_edges/` etc.: not under `test/`, not in
  `elixirc_paths` (`["lib"]`), and the formatter `inputs` glob (`{config,lib,test}/**`)
  matches ZERO `error_contract/` files (verified via `Path.wildcard` → `[]`) — `mix
  verify` untouched (re-run GREEN at HEAD with the harness present). `mix run
  --no-compile --no-start` children under an OS `timeout`; the BUSY + read-only
  conditions use real files in a private `mktemp -d` removed by an EXIT trap; no
  SIGKILL, no pkill, no ~1GB allocation (TOOBIG uses `zeroblob`, rejected before
  allocating).
- **TEETH (hard gate — 11 controls, run.sh ABORTS rc 2 otherwise).** The contract
  oracle MUST reject: a text-only error (bare binary), a bare `:error`, a number
  reason, a WRONG constraint kind (UNIQUE claimed as `:constraint_check`), a
  non-binary message, and an unmatchable shape; and must NOT false-positive 5
  correct structured reasons. **The wrong-kind tooth EARNED its keep**: the first
  oracle draft compared the leading atom (always `:constraint_violation`) instead of
  the kind (2nd element); the selftest FAILED and forced the fix
  (`constraint_kind/1`) before any real assertion ran.
- **Per-condition contract results (all HELD):** UNIQUE / NOT NULL / CHECK / PRIMARY
  KEY / FOREIGN KEY / DATATYPE constraint violations each classified with the
  SPECIFIC kind atom — `:constraint_unique` (ext 2067), `:constraint_not_null`,
  `:constraint_check`, `:constraint_primary_key` (ext 1555), `:constraint_foreign_key`,
  `:constraint_datatype` — which is itself the extended-code-preservation proof (a
  primary-only path would collapse all to the generic `:constraint_violation` kind);
  DATATYPE additionally carried typed `source_type`/`target_type` atoms. Syntax
  error → `{:sql_input_error, %{code, message, sql, offset}}` (typed map, integer
  offset). Bind bignum > i64 → `{:cannot_convert_to_sqlite_value, <bin>, <bin>}`.
  `zeroblob(1000000001)` → `{:sqlite_failure, 18, 18, <bin>}` (extended code present
  + correct — negative-tooth `not {:sqlite_failure, 0, …}` also asserted).
  Connection-closed → `:connection_closed`; finalized-step → `:statement_finalized`;
  `execute` a SELECT → `:execute_returned_results`. Read-only write →
  `{:read_only_database, "attempt to write a readonly database"}`. **SQLITE_BUSY
  reproduced via real 2-connection write contention** (busy_timeout 0, c1 `BEGIN
  IMMEDIATE`, c2 write) → `{:database_busy_or_locked, "database is locked"}`.
  `Xqlite.StreamError` on a mid-stream UTF-8 fault → `Exception.message` binary,
  structured reason preserved. ~60 assertions, all OK; `RESULT PASS_WITH_FINDINGS`.

### CONFIRMED findings — ALL S3, SURFACE-ONLY (filed to BACKLOG, NOT fixed)

- **F-A10-1 — S3 — error classification via English message-substring matching.**
  `error.rs:689-704` (`NoSuchTable`/`NoSuchIndex`/`TableExists`/`IndexExists`) +
  `error.rs:786` (`== "interrupted"`). These four are all primary `SQLITE_ERROR`
  (1) with NO distinguishing extended code, so message text is the ONLY signal
  SQLite gives — but (a) unlike `constraint_parse.rs` this is NOT documented as a
  sanctioned exception, and (b) it is coupled to SQLite's English message wording:
  a reword/localization silently downgrades all four to `{:sqlite_failure, 1, 1,
  msg}` (graceful — no wrong-result, no crash). Fragility/consistency, not a live
  misclassification.
- **F-A10-2 — S3 — semantic error variants drop the extended result code.** The
  `message`-only variants can't tell a caller BUSY(5) from LOCKED(6) (both →
  `:database_busy_or_locked`), nor the `READONLY_*` / `BUSY_SNAPSHOT` sub-codes,
  without parsing text — which the house rule forbids. The "nicer" atoms carry LESS
  structured info than the generic `SqliteFailure` fallback. Confirmed empirically
  (busy + readonly reasons carry only a message).
- **F-A10-3 — S3 — `INSERT/UPDATE/DELETE … RETURNING` reports `changes: 0`.**
  `query_with_changes`' empty-columns heuristic misdetects RETURNING DML (which
  returns columns) as non-DML and zeroes the count. Confirmed: `INSERT … RETURNING
  x` → `changes=0, num_rows=1, rows=[[4]]`. `Xqlite.query/4`'s doc ("changes = the
  number of affected rows" for DML) is violated for RETURNING. No data loss (rows
  are returned; `num_rows` is right).
- **F-A10-4 — S3 — `:unsupported_atom` throws away the offending atom.**
  `error.rs:447` `UnsupportedAtom { atom_value: _ } => atoms::unsupported_atom()`
  encodes a BARE atom, so the Elixir error never names the rejected atom, though the
  variant CARRIES `atom_value` and `Display` uses it. Inconsistent with
  `UnsupportedDataType` (which encodes its `term_type`). Lossy structured error vs
  the "most specific info" rule.
- **F-A10-5 — S3 — `error_reason/0` typespec omits `{:invalid_open_option, map}`.**
  `validate_open_opts` returns it (`lib/xqlite.ex:357,367`) but the union
  (`:136-179`) lists only `:invalid_on_error`, so `Xqlite.open/2` +
  `open_in_memory/1`'s `@spec … | error()` is inaccurate — a dialyzer contract gap.
- **F-A10-6 — S3 (latent) — doubled-`:error` fallback shape.** The map-build-failure
  arms (`error.rs:513/579/626`, `connection.rs:95`) encode `(atoms::error(), err)`,
  i.e. `{:error, {:error, {:internal_encoding_error, …}}}` — violating the
  "leading classification atom, never `:error`" shape. Practically unreachable
  (BEAM `map_new`/`map_put` don't fail), but a latent wart.

### Disposition & dryness

- **0 S0 / 0 S1 / 0 S2.** The structured-error contract is STRONG: structured-atom
  classification held on every one of the 16 driven conditions, extended codes
  surface wherever SQLite provides them (constraint kinds + TOOBIG proven), messages
  are always binary, and every reason shape is `with`-matchable. The 6 findings are
  all S3 completeness / precision / fragility items — none blocks per the ratified
  bar. Per the SURFACE-ONLY mandate NONE were fixed; all six filed to `BACKLOG.md`
  with minimal repros (F-A10-2/3 additionally reproduced by the committed probe).
  `mix verify` GREEN with the harness present.
- **A10: strong-by-design → one covering adversarial+probe run, 0 S0/S1/S2, 6 S3,
  teeth proven.** Per the two-consecutive-covering-runs rule A10 is NOT yet DRY; one
  more covering run is owed. Churn in `error.rs` (`classify_sqlite_error` /
  `Encoder` / `From`), the raw-FFI error builders (`stream.rs` / `nif.rs` /
  `connection.rs`), `constraint_parse.rs`, the `query_with_changes` columns
  heuristic, or the `error_reason/0` typespec re-wets A10.

## Run 9 — 2026-07-19 — A11 feature islands

- Commit at scan: `ae7f9c5` (HEAD). Scope, HALF 1: one adversarial static pass
  per feature island — session/changesets, blob I/O, backup+progress,
  serialize, authorizer, hooks (update/wal/commit/rollback/log + busy
  policy/observers) — over the Rust surface (`native/xqlitenif/src/*`), the
  Elixir wrappers (`lib/`), and the island tests, from six stances (data-loss
  prosecutor, UB prosecutor, assumption auditor, interleaving attacker,
  blast-radius enumerator, cold adopter). HALF 2: guide-rot — every guide's code
  EXECUTES against the bundled SQLite 3.53.2. Composition: single Opus pass (this
  agent) — adversarial read + build-and-measure probes + guide-snippet
  execution; every runtime claim RUN this session (commands + output pasted
  below), never from memory. Did NOT re-litigate settled findings; verified the
  Run 1–2 blob/session/log S0 fixes still hold at HEAD by READING the code.

### Run 1–2 fix verification at HEAD (read, not trusted)

- **blob (Run 2 `b1c60b4`) HOLDS**: `XqliteBlob` owns a raw
  `AtomicPtr<sqlite3_blob>` (no rusqlite `Blob` wrapper), every `sqlite3_blob_*`
  runs under the conn Mutex via `with_live_blob`/`close` (swap-then-lock),
  `Drop` just `sqlite3_blob_close`es the raw pointer (`blob.rs:60-255`). No
  `&Connection` deref on any teardown path. The maintainer WARNING doc-comment
  is intact.
- **session (Run 1 `61cf771`) HOLDS**: `close` locks conn→session, deletes only
  while `conn_guard.is_some()`, else `mem::forget`s the session
  (`session.rs:45-70`); `Session<'static>` sound only because rusqlite `Session`
  is `PhantomData<&Connection>`. All ops under the conn Mutex.
- **log (Run 1 `61cf771`) HOLDS**: `log_callback` takes `MASTER_LOCK` before the
  snapshot read; register/unregister take the same lock across the Vec free
  (`log_hook.rs:53,89,109`).

### Per-island verdict

- **session/changesets — 1 FINDING (F-A11-2, S2, FIXED).** The `changeset_apply`
  conflict handler returned a FIXED `ConflictAction` ignoring the conflict type;
  for `:replace` it returned `SQLITE_CHANGESET_REPLACE` unconditionally, which is
  a C-API misuse for NOTFOUND/CONSTRAINT/FOREIGN_KEY conflicts. Everything else
  (new/attach/changeset/patchset/invert/concat/delete, close-order, apply under
  the conn Mutex serialising `xProgress`) HOLDS.
- **blob I/O — CLEAN.** Run 2 refactor holds (above); raw-pointer discipline,
  offset/length clamping, empty-on-out-of-range, idempotent close all intact.
- **backup+progress — 1 FINDING (F-A11-1, S1, FIXED).** `backup_with_progress`
  looped forever on `pages_per_step <= 0` (`sqlite3_backup_step(0)` copies
  nothing, reports "more"), pinning the source conn Mutex and flooding the pid.
  The Run 1 `msg_env`-leak fix (`send_backup_progress` frees unconditionally,
  `nif.rs:1811`) HOLDS.
- **serialize/deserialize — CLEAN.** `serialize` copies into an `OwnedBinary`
  (fallible alloc guarded); `deserialize` uses `deserialize_read_exact` under the
  conn Mutex. Snippet-verified round-trip (below).
- **authorizer — CLEAN.** Uses rusqlite's SAFE `conn.authorizer` API (guarded
  trampoline); the closure is a `HashSet` lookup that cannot panic; deny-list is
  atomic (unknown atom rejects the whole list). Snippet-verified DELETE deny.
  Action-kind granularity + deny-only are documented limits, not defects.
- **hooks — 1 FINDING (F-A11-4, S3, footgun).** update/wal/commit/rollback/log
  dispatch + the progress split all fire under the conn Mutex (log under
  `MASTER_LOCK`) with `guard_ffi_callback` unwind guards on the three raw-FFI
  callbacks — CLEAN. The busy POLICY half has a documented-but-surprising
  `max_elapsed_ms` anchoring (below).

### Findings

- **F-A11-1 — S1 — CONFIRMED — FIXED (`nif.rs` guard).** `Xqlite.backup_with_
  progress(conn, schema, dest, pid, 0, tokens)` hangs forever: `backup.step(0)`
  returns `More` without copying, so the loop spins — pinning the source conn
  Mutex (every other op on it blocks forever) and flooding `pid` with
  `{:xqlite_backup_progress,…}` (unbounded mailbox growth). Empty token list =
  unbreakable. The `@spec` says `pos_integer()` but nothing enforced it. RED
  (pre-fix, this session): `PPS=0` under a 20 s `timeout` → **rc 124 (hang)**;
  control `PPS=1` → `:ok` in 2 ms. FIX: reject `pages_per_step < 1` at the NIF
  boundary with `{:error, {:invalid_pages_per_step, n}}` (atom added `lib.rs`;
  shape added to `error_reason/0`). GREEN (post-fix): `PPS=0` →
  `{:error, {:invalid_pages_per_step, 0}}` in 0 ms, 0 progress msgs. Regression:
  `test/nif/backup_progress_test.exs` "non-positive pages_per_step is rejected,
  not spun on" (0 and -1, refutes any progress msg).
- **F-A11-2 — S2 — CONFIRMED — FIXED (`nif.rs` conflict handler).**
  `changeset_apply(conn, cs, :replace)` returned `SQLITE_MISUSE` (21, "bad
  parameter or other API misuse") whenever the changeset produced a CONSTRAINT,
  NOTFOUND, or FOREIGN_KEY conflict, because the fixed handler illegally returned
  `SQLITE_CHANGESET_REPLACE` (legal only for DATA/CONFLICT). Misleading
  classification + divergence from the doc ("`:replace` — overwrite with the
  changeset's values"). No corruption (SQLite savepoint-rolls-back on misuse).
  RED (pre-fix): CONSTRAINT+replace and NOTFOUND+replace both →
  `{:sqlite_failure, 21, 21, …}`, rows unchanged; `:omit` control → `:ok`. FIX:
  the handler now returns `REPLACE` only for `SQLITE_CHANGESET_DATA` /
  `SQLITE_CHANGESET_CONFLICT` and `ABORT` otherwise (imports `ConflictType`).
  GREEN: both → `{:sqlite_failure, 4, 4, "query aborted"}` (SQLITE_ABORT, clean
  rollback). Regression: `test/nif/session_test.exs` "replace on a
  CONSTRAINT/NOTFOUND conflict aborts cleanly, not misuse" (asserts code==4,
  refutes 21, asserts no data change). Legal-REPLACE (PK CONFLICT) path
  unchanged — existing "conflict :replace overwrites" test still passes.
- **F-A11-3 — S2 — CONFIRMED — FIXED (`query.rs` guard).** The Security guide
  claims "NUL bytes in SQL text are rejected, not truncated … returns
  `{:error, :null_byte_in_string}`." FALSE for `query`/`execute`/`execute_batch`:
  rusqlite's `prepare` hands SQLite the SQL length-delimited (`as_ptr`+`len`,
  `inner_connection.rs:216-217`), and SQLite's tokenizer STOPS at the first NUL,
  so `"SELECT\0 1"` ran as `"SELECT"` → `{:sqlite_failure, 1, 1, "incomplete
  input"}` (the rest silently dropped — the exact truncation the guide claims to
  prevent). Only the raw-FFI paths (`stmt_prepare`, `stream_open`,
  `explain_analyze`) rejected it (they build a `CString`). RED (pre-fix): query
  interior NUL → `{:sqlite_failure,1,1,"incomplete input"}`, not
  `:null_byte_in_string`. FIX: `reject_interior_nul/1` at the top of the three
  `core_*` functions in `query.rs` (the single choke point all query/execute
  entry points route through). GREEN (post-fix): query/execute/execute_batch AND
  prepare/stream all → `{:error, :null_byte_in_string}`; a clean query still
  works; a NUL in a BOUND VALUE still round-trips byte-exact (guard checks SQL
  text only). Regression: `test/nif/error_input_test.exs` "interior NUL in SQL
  text is rejected on query/execute/execute_batch".
- **F-A11-4 — S3 — CONFIRMED — BACKLOG + gotcha.** `set_busy_policy/2`'s
  `:max_elapsed_ms` is anchored at the busy slot's first INSTALL
  (`busy_handler.rs` `BusySlotState.start` set in `snapshot()` when the slot is
  null, preserved across mutations), NOT at each busy event's start. On a
  connection older than `max_elapsed_ms`, the elapsed check trips on the first
  callback of EVERY busy event → 0 retries (default `5_000` → policy stops
  retrying 5 s after install; worst on long-lived pooled connections). DOCUMENTED
  ("from the busy slot's first installation", `lib/xqlite.ex:1359`) + surfaces a
  clean busy error → S3, not a divergence, but a real footgun. Empirical
  (`feature_islands/run.sh`): young(age 0, ceiling 400, release 150)→SUCCEED
  153 ms; aged+huge(age 800, ceiling 100000)→SUCCEED 153 ms [teeth]; aged(age
  800, ceiling 400)→GAVE_UP 0 ms/0 retries [footgun]. Filed BACKLOG F-A11-4 +
  documented in `guides/gotchas.md`; maintainer question on per-event anchoring.
- **F-A11-5 — S3 — CONFIRMED — BACKLOG.** `error_reason/0` typespec
  (`lib/xqlite.ex:180`) lists `{:utf8_error, String.t()}` (2-tuple) but the
  actual encode is the 3-tuple `(utf8_error, column, reason)` (`error.rs:545`),
  which the Security guide correctly documents. Matching the real/guide shape is
  a dialyzer contract violation vs the spec. Fix: `{:utf8_error,
  non_neg_integer(), String.t()}`. Same class as F-A10-5. Filed BACKLOG.

### Guide-execution table (HALF 2 — every guide's code RUN this session)

- **`full_text_search.md` — EXECUTED, PASS → now a permanent test.** The whole
  linear flow runs: CREATE VIRTUAL TABLE fts5 (external content) + 3 sync
  triggers, INSERT, MATCH+`bm25()` join (rank -1.0e-6, best-first), `highlight`/
  `snippet` (`<b>schedulers</b>`), match language (`sched*`/`title:beam`/`AND
  (OR)`/`NEAR` all match; absent phrase → 0), operational commands (`rebuild`/
  `integrity-check`/`optimize`), tokenizers (`porter unicode61`, `trigram`).
  Codified as `test/nif/fts5_guide_test.exs` (across every opener). BACKLOG A11
  seed CLOSED.
- **`spatialite.md` — doc-first EXEMPT, factual skim.** Its concrete falsifiable
  claim (bundled SQLite "compiles R*Tree in") VERIFIED: `pragma_compile_options`
  contains `ENABLE_RTREE` (+ `ENABLE_FTS5`, `ENABLE_API_ARMOR`, `THREADSAFE=1`).
  Extension-load API names (`enable_load_extension`/`load_extension`) match code.
  No rot.
- **`gotchas.md` — every snippet PASS.** `1e308*10 → :positive_infinity` PASS;
  NaN→`{"null", nil}` PASS; `length()` interior-NUL (len 1 / byte_size 5) PASS;
  offset-DateTime lexical sort `[1,2]` PASS; cancel-token reuse →
  `:operation_cancelled` PASS (with a REAL recursive-CTE query — a trivial query
  finishes before the 8-VM-op progress fire; the guide's `big_table` is
  load-bearing); stream `:emit_error` yields `{:ok, row}` PASS; invalid
  `:on_error` → `{:error, {:invalid_on_error, :bogus}}` at stream open PASS.
- **`security.md` — every snippet PASS (one was the F-A11-3 fix).** authorizer
  DELETE deny → `{:authorization_denied, "not authorized"}` PASS; extension
  enable/disable + bogus-path load → structured `{:sqlite_failure,1,1,…}` (no
  crash) PASS; interior NUL in SQL → `:null_byte_in_string` PASS *after the
  F-A11-3 fix* (was FALSE for query/execute — the finding); invalid-UTF-8 read →
  3-tuple `{:utf8_error, 0, reason}` PASS (guide-correct; typespec wrong =
  F-A11-5); binary dispatch TEXT/BLOB `["text"],["blob"]` PASS; deserialize
  wholesale replace PASS.
- **`wiring_telemetry.md` — every snippet PASS (compile-flag-gated).**
  `enabled?/0` returns a boolean (dev=false, test=true) PASS; disabled-mode fires
  no `[:xqlite,:query,:stop]` event PASS (dev); `Telemetry.bridge/2`+`unbridge/1`
  → `:ok` when enabled (MIX_ENV=test verified + covered by the existing telemetry
  suite), `{:error, :telemetry_disabled}` when off — behaves per the guide's own
  "Enable telemetry" prerequisite; `OpenTelemetry.attributes/3` →
  `%{"db.system.name"=>"sqlite","db.query.text"=>…,"db.operation.name"=>"query"}`
  + `span_name/2` → `"query"` PASS (pure, no OTel dep, as documented).

### Probes / teeth

- **`feature_islands/run.sh`** (NEW, CI-isolated: not under `test/`, not in
  `elixirc_paths`, formatter glob `{config,lib,test}/**` matches ZERO
  `feature_islands/**` — verified via `Path.wildcard` → `[]`; `mix format
  --check-formatted` GREEN with it present). Carries the S3 busy-elapsed footgun
  (the three S0-S2 findings live as regression tests in `test/`). TEETH (hard
  gate, rc 2 on failure): young + aged-huge-ceiling connections MUST succeed by
  retrying through the lock release — proven this session (both 153 ms) — so the
  aged+small-ceiling 0 ms/0-retry give-up is meaningful.
- **Regression tests (teeth = revert-would-fail):** backup guard (pages 0/-1 →
  structured error, refute progress); changeset replace (code 4 not 21, no data
  change); interior-NUL rejection on all five SQL entry points + bound-value
  round-trip; FTS5 guide end-to-end. Full `mix test.seq` GREEN (43 files, "All
  tests passed!") with all four touched/added files passing.

### Completeness critic

- Islands covered: session/changesets, blob, backup+progress, serialize,
  authorizer, all six hooks + busy policy/observers — all six islands passed
  under all six stances. Guides: all five executed (FTS5 codified; spatialite
  factual-skimmed; gotchas/security/wiring every snippet run). NOT covered /
  honest gaps: (1) the authorizer's rusqlite trampoline `catch_unwind` posture is
  an A1 concern, not re-audited here (the closure is panic-free by construction —
  a `HashSet` lookup). (2) `changeset_apply`'s ABORT-vs-OMIT fallback for
  `:replace` is a chosen semantics (loud, no silent data skip); OMIT (partial
  apply) is a maintainer alternative, noted. (3) The busy-elapsed fix (per-event
  anchoring) is a maintainer semantics call (F-A11-4), not made here. (4)
  serialize/deserialize against a connection with OPEN statements/streams was not
  stress-probed (would surface as a structured error, not UB — the conn Mutex
  serialises it). (5) No TSan/Miri on the live NIF (Runs 2/4/5 established Miri
  can't run the bundled C SQLite); the oracle is behavior + exit-code + the
  source audit bounded by `THREADSAFE=1` + single-Mutex.

### Disposition & dryness

- **3 CONFIRMED S0-S2 all FIXED this run** (F-A11-1 S1, F-A11-2 S2, F-A11-3 S2)
  with RED-then-GREEN repro (empirical RED pasted above) + permanent regression
  tests; **2 S3 filed to BACKLOG** (F-A11-4 busy-elapsed footgun +
  `guides/gotchas.md`; F-A11-5 `:utf8_error` typespec). `mix verify` GREEN.
- **A11: guides-never-executed + per-feature-suites-only → one covering
  adversarial+guide-execution run, 3 S0-S2 fixed + 2 S3, teeth proven.** This is
  the FIRST dedicated A11 covering run (Run 2 touched only the blob island
  incidentally). Per the two-consecutive-covering-runs rule A11 is NOT yet DRY;
  one more covering run is owed. Churn re-wets it: the F-A11-1/2/3 fixes touched
  `nif.rs` (backup guard + changeset handler), `query.rs` (`reject_interior_nul`
  + the three `core_*`), `lib.rs` (atom), and `error_reason/0` — plus any
  session/blob/backup/serialize/authorizer/hook code or any guide edit re-wets
  A11.

## Run 10 — 2026-07-19 — A4 scheduler discipline

- Commit at scan: `2afa44e` (HEAD). Scope: the scheduler classification of ALL
  96 `#[rustler::nif]` functions — normal (<1ms-proven) vs Dirty (CPU vs IO
  chosen right) — plus the adversarial angle the axis names: a normal-scheduler
  NIF that acquires the connection `Mutex` (or any blocking resource) can occupy
  a normal scheduler for the FULL duration of a concurrent slow operation.
  Composition: single Opus pass (this agent) — full census + a build-and-measure
  probe under `erlang:system_monitor`'s `long_schedule` gate (A4 is a
  drive-and-measure axis, not a fleet read). Did NOT re-litigate settled
  findings; the M5 (Run 1) note "`session_changeset`/`patchset` step an internal
  SELECT on the normal scheduler" was flagged then for the progress-list UAF
  (fixed), never as a scheduling defect — this run owns the scheduling angle.

### Census (VERIFIED against the prior 62/34 claim)

- **Pre-run: 62 DirtyIo / 34 normal / 0 DirtyCpu** — the 62/34 census claim is
  CONFIRMED exact. **Post-fix: 71 DirtyIo / 25 normal / 0 DirtyCpu** (9 flips,
  below). Zero DirtyCpu either way (blanket-DirtyIo — RULED correct, below).

### The mechanism (established this session, runtime-verified — the reason the
### monitor gate is a valid A4 detector)

- `erlang:system_monitor(pid, [{long_schedule, T}])` delivers `{:monitor, Pid,
  :long_schedule, [timeout: Ms, in: _, out: _]}` when a process runs on a NORMAL
  scheduler > T ms without yielding. A NIF has no yield points, so a
  normal-scheduler NIF running > T trips it; the schedule-in MFA is reported
  `:undefined` for NIF frames (ERTS limitation), so attribution is by the
  offending process's **pid** (each workload runs in a dedicated single-call
  process). **A Dirty-scheduler NIF NEVER trips it** — proven this session: a
  1570 ms Dirty `query` and 7.7 s Dirty CTE both delivered **0** events, while a
  135 ms normal `blob_read` delivered 1. So flipping a hog to DirtyIo silences
  the gate not by hiding but by moving the blocking off the normal schedulers,
  which is the fix. `:erlang.md5/1` traps (0 events); `:erlang.term_to_binary/2`
  with `[:compressed]` does NOT — it is the fix-INDEPENDENT teeth control.

### Full 96-NIF classification table

**normal scheduler — 25 NIFs, ALL PROVEN-FAST (LAT-measured µs, or O(1)/
O(bounded) by inspection). Worst-case argument | conn-Mutex? :**

| NIF | worst-case work | conn Mutex |
|---|---|---|
| `db_path` | `conn.path()` cached filename, O(1); LAT max 16 µs | yes (`with_conn`) |
| `autocommit` | `sqlite3_get_autocommit` flag, O(1); 12 µs | yes |
| `txn_state` | `sqlite3_txn_state`, O(1); 6 µs | yes |
| `changes` | `sqlite3_changes64`, O(1); 17 µs | yes |
| `total_changes` | `sqlite3_total_changes64`, O(1) | yes |
| `set_busy_policy` | install busy slot, O(1) | yes |
| `remove_busy_policy` | clear busy slot, O(1) | yes |
| `register_busy_observer` | COW-append, O(observers) | yes |
| `unregister_busy_observer` | COW-remove, O(observers) | yes |
| `set_authorizer` | `parse_denied` O(list) pre-lock + install O(1) | yes |
| `remove_authorizer` | clear authorizer, O(1) | yes |
| `register_progress_hook` | COW-append tick sub, O(subs) | yes |
| `unregister_progress_hook` | COW-remove, O(subs) | yes |
| `enable_load_extension` | `sqlite3_db_config` flag, O(1) | yes |
| `session_new` | `sqlite3session_create` alloc, O(1) | yes |
| `session_attach` | record table name, O(1) | yes (`with_session_mut`) |
| `session_is_empty` | `sqlite3session_isempty`, O(1); 1 µs | yes (`with_session`) |
| `blob_size` | `sqlite3_blob_bytes` cached `nByte`, O(1); 10 µs | yes (`with_live_blob`) |
| `blob_close` | swap-null + `sqlite3_blob_close` (free Vdbe), O(1) | yes (teardown) |
| `stmt_column_names` | loop `sqlite3_column_count` ≤ 2000, O(cols); 60 µs | yes (`with_live_stmt`) |
| `create_cancel_token` | `Arc<AtomicBool>` alloc, O(1); 79 µs | **no** |
| `cancel_operation` | lock-free `store(true)`, O(1) | **no** (deliberate) |
| `sqlite_version` | `sqlite3_libversion` static ptr, O(1) | **no** |
| `register_log_hook` | COW-append, O(subs) | **no** (`MASTER_LOCK`) |
| `unregister_log_hook` | COW-remove, O(subs) | **no** (`MASTER_LOCK`) |

- The 20 conn-Mutex normal readers are intrinsically <1ms (LAT proves the
  representative set at ≤60 µs) but are exposed to the Mutex-contention S3 below.
  The 5 no-conn-Mutex NIFs (`create_cancel_token`, `cancel_operation`,
  `sqlite_version`, `register/unregister_log_hook`) cannot block on a slow query
  at all; `cancel_operation` is deliberately lock-free so any process can cancel
  without the handle (design tradeoff, CLAUDE.md).

**DirtyIo scheduler — 71 NIFs, all correct (every one touches the DB file or
does unbounded work; DirtyIo absorbs the file-I/O / lock / busy-sleep blocking).
Grouped, worst-case noted:**

- open/close (6): `open`,`open_in_memory`,`open_readonly`,`open_in_memory_readonly`,
  `open_temporary`,`close` — VFS open/first-page read / `sqlite3_close`.
- query/execute (9): `query`,`execute`,`execute_batch`,`query_with_changes`,
  `query_cancellable`,`query_with_changes_cancellable`,`execute_cancellable`,
  `execute_batch_cancellable`,`explain_analyze` — unbounded scan/sort/join +
  busy-sleep + fsync (measured `query` 1570 ms → 0 hits, the Dirty-silence proof).
- pragma/txn (10): `get_pragma`,`set_pragma`,`begin`,`commit`,`rollback`,
  `savepoint`,`rollback_to_savepoint`,`release_savepoint`,`transaction_status`,
  `last_insert_rowid` — checkpoint/commit I/O (`last_insert_rowid` is O(1) but
  harmlessly over-classified; being Dirty is never a correctness risk).
- schema (7): `schema_databases`,`schema_list_objects`,`schema_columns`,
  `schema_foreign_keys`,`schema_indexes`,`schema_index_columns`,`get_create_sql`
  — `sqlite_schema` scan + PRAGMA introspection, O(schema size).
- statement (8): `stmt_prepare`,`stmt_bind`,`stmt_step`,`stmt_multi_step`,
  `stmt_multi_step_cancellable`,`stmt_reset`,`stmt_clear_bindings`,`stmt_finalize`
  — prepare/step touch pages; reset/finalize over-classified but safe.
- stream (4): `stream_open`,`stream_get_columns`,`stream_fetch`,`stream_close`.
- hooks-register (8): `register/unregister_update_hook`, `…_wal_hook`,
  `…_commit_hook`, `…_rollback_hook` — in-memory COW only (over-classified vs the
  normal `register_progress_hook`, but Dirty is harmless; NOT flipped — the safe
  direction).
- observability (3): `wal_checkpoint`,`connection_stats`,`compile_options`.
- serialize/backup (5): `serialize`,`deserialize`,`backup`,`restore`,
  `backup_with_progress` — whole-DB copy, O(db size).
- extension (1): `load_extension` — dlopen + entry-point run.
- session/changeset (10): `changeset_apply` (pre-existing) + the **9 flipped**
  below.

### CONFIRMED finding — F-A4 (S2) — 9 NIFs hogged a NORMAL scheduler → FIXED

- **Nine session/blob/changeset NIFs ran unbounded / DB-file work on the normal
  scheduler.** Exposed ONLY through the public, documented `XqliteNIF` module (no
  higher-level wrapper, no size clamp — e.g. `XqliteNIF.blob_read(blob, 0,
  500_000_000)` reads up to `SQLITE_MAX_LENGTH` bytes on a normal scheduler in a
  single call), reachable in ordinary SINGLE-OWNER use (no handle sharing, no
  contention needed — the NIF itself runs long). This is a ≥10×–200× breach of
  the <1ms normal-scheduler bar → **S2** (scheduler-health / VM-latency cliff;
  not UB/corruption, so not S0/S1). **RED (pre-fix, threshold 25 ms, this
  session):** each ran on a normal scheduler and delivered a `long_schedule`
  event —

  | NIF | worst-case driver | RED wall | RED hits |
  |---|---|---|---|
  | `blob_read` | caller-controlled `length` (≤ blob size); 64 MB read | 106.8 ms | 1 |
  | `blob_write` | caller-controlled binary; 64 MB write | 77.4 ms | 1 |
  | `session_changeset` | serialize ALL recorded changes (steps internal SELECT); 400k rows → 15.9 MB | 228.0 ms | 1 |
  | `session_patchset` | same, patchset form | 247.9 ms | 1 |
  | `changeset_invert` | process caller-supplied changeset binary; 15.9 MB | 28.1 ms | 1 |
  | `changeset_concat` | process two caller-supplied changesets; 2×15.9 MB | 131.9 ms | 1 |
  | `session_delete` | free O(session-size) change records; 400k | 14.9 ms | 0* |
  | `blob_open` | b-tree descent + page I/O (single row) | ~0 ms (warm) | 0* |
  | `blob_reopen` | b-tree descent to a new row + page I/O | ~0 ms (warm) | 0* |

  *`session_delete` (14.9 ms) exceeds the <1ms bar but not the 25 ms monitor
  threshold; flipped on the wall-time + scales-with-session-size argument.
  `blob_open`/`blob_reopen` are fast WARM in-memory (no RED) but do genuine
  DB-file b-tree I/O that is not provably <1ms on cold/large file-backed storage;
  flipped for blob-island coherence (every other DB-file op is DirtyIo) — the
  weakest two of the nine, flipped as the safe direction, not on a measured
  breach.

- **FIX:** `schedule = "DirtyIo"` on all nine (`native/xqlitenif/src/nif.rs`
  attribute flips; the 6 unbounded ones are the measured core, `session_delete`
  the wall-time case, `blob_open`/`blob_reopen` the coherence pair). DirtyIo (not
  DirtyCpu) chosen: every one can block on file I/O, page-cache misses, or the
  conn `Mutex`; the pure-CPU pair (`changeset_invert`/`concat`, no conn, no file)
  would tolerate DirtyCpu but take DirtyIo for crate-wide consistency with
  `changeset_apply`. **GREEN (post-fix, same probe):** all nine → **0**
  `long_schedule` hits (same wall time, now off the normal schedulers — e.g.
  `blob_read` 116 ms/0 hits, `session_changeset` 230 ms/0 hits) while the
  fix-independent control STILL delivered 35 events (monitor provably live, not
  dead-silent). `scheduler/run.sh` VERDICT flips FAIL→PASS.

### S3 (BACKLOG, F-A4-1) — Mutex-contention: trivial normal readers block a
### normal scheduler under cross-process handle SHARING

- The 20 conn-`Mutex` normal readers (`changes`/`db_path`/`txn_state`/… above)
  are <1ms intrinsically, but `with_conn` blocks on the connection `Mutex`. If a
  handle is SHARED across processes and one runs a slow Dirty op, a reader on
  another process blocks on a NORMAL scheduler for the op's whole duration.
  **Measured (this session):** holder pins the Mutex with a ~1.5 s Dirty query on
  a shared handle; each victim blocked ~1.45–1.49 s on a normal scheduler with 1
  `long_schedule` hit — `changes` 1493 ms, `db_path` 1456 ms, `txn_state`
  1479 ms, `total_changes` 1454 ms. **Graded S3, not S2:** it requires SHARING a
  connection handle across processes, which the documented architecture forbids
  (CLAUDE.md: "read concurrency belongs in the Ecto adapter layer — a pool of
  independent handles"); a single owner is sequential (its own slow op can't race
  its own reader), and the blocking IS the intentional serialization surfacing on
  the wrong scheduler. Consequence is latency degradation, not corruption. Filed
  BACKLOG F-A4-1 (maintainer question: flip the conn-Mutex trivial readers to
  DirtyIo to keep the block off the normal schedulers, at a per-call
  dirty-hop cost on hot introspection paths?) + documented user-facing in
  `guides/gotchas.md`.

### Ruling — blanket DirtyIo (0 DirtyCpu) is CORRECT (first-covering-run ruling)

- Every Dirty NIF touches the DB file and/or can block (file I/O, page-cache
  miss, lock wait, busy-handler `thread::sleep`, fsync) — all I/O-class waits the
  DirtyIo pool (10 schedulers here) exists to absorb; DirtyCpu (= cores) is for
  pure computation and is the wrong pool for blocking work. The lone
  arguably-pure-CPU pair (`changeset_invert`/`concat`) is bounded by input size
  and comfortably absorbed by DirtyIo. **No DirtyCpu is warranted; blanket
  DirtyIo stands.** Not re-litigated further.

### Probe — harness `scheduler/` (invoke `bash scheduler/run.sh`)

- CI-isolated exactly like `durability/`…`error_contract/`: not under `test/`,
  not in `elixirc_paths` (`["lib"]`), formatter `inputs` glob
  (`{config,lib,test}/**`) matches ZERO `scheduler/` files (verified via
  `Path.wildcard` → `[]`) — `mix verify` untouched (re-run GREEN at HEAD with the
  harness present). One `mix run --no-compile --no-start` child under an OS
  `timeout`; in-memory DBs except one backup file in a private `mktemp` dir
  removed by an EXIT trap; no SIGKILL, no pkill/name-match.
- **TEETH (hard gate; run.sh aborts rc 2 otherwise):** a fix-INDEPENDENT
  `:erlang.term_to_binary(term, [:compressed])` control MUST deliver > 0
  `long_schedule` events, else the monitor is not observing and every "0 hits" is
  meaningless. Delivered **35** events every run (pre- and post-fix) — the
  silence of the flipped NIFs post-fix is therefore real silence. Second teeth
  leg: the pre-fix RED itself (9 families delivering events) proves the monitor
  detects our NIFs; the Dirty-family silence at 1570 ms proves it ignores Dirty
  schedulers (so the fix is a real move, not a blind spot).
- Sections: S1 intrinsic discipline (PASS/FAIL — the gate), S2 Mutex-contention
  (informational, F-A4-1 evidence), LAT micro-latency (all trivial readers
  ≤ 60 µs uncontended — the <1ms proof).

### Completeness critic

- Every one of the 96 NIFs is classified (table above). NIF families driven under
  the monitor: open/close, query/execute/explain, stream, prepared step,
  pragma, schema, serialize, backup, blob (open/read/write/reopen/size/close),
  session+changeset (new/attach/changeset/patchset/invert/concat/delete),
  hooks-register, cancel, trivial readers — all covered. NOT covered / honest
  gaps: (1) `long_schedule` observes NORMAL schedulers only; a Dirty NIF that
  monopolises the DirtyIo pool (e.g. 11+ concurrent multi-second queries starving
  the 10 DirtyIo schedulers) is a pool-saturation concern this gate cannot see —
  bounded by the blanket-DirtyIo ruling + the pool being sized for blocking, not
  measured here. (2) Worst-case blob/changeset sizes were driven to 64 MB /
  ~16 MB (enough to breach 25 ms by 4–10×); the true ceiling is
  `SQLITE_MAX_LENGTH` (~1 GB) — extrapolated, not run at 1 GB (RAM). (3) The
  Mutex-contention block time equals the concurrent op's duration (unbounded in
  principle); measured at ~1.5 s, not at pathological multi-minute holds. (4) The
  monitor threshold is 25 ms (customary 10–50 ms; well above the <1ms bar so any
  hit is a gross breach); NIFs in the 1–25 ms band pass the gate but the LAT
  section + wall-time catch them (how `session_delete` was found). (5) No
  DirtyCpu-vs-DirtyIo pool-latency benchmark — the ruling is by-construction
  (blocking work → IO pool), not A/B-measured.

### Disposition & dryness

- **1 CONFIRMED S2 mechanism (9 NIFs) FIXED this run** (attribute flips, RED→GREEN
  proven by the same probe); **1 S3 filed** (F-A4-1 Mutex-contention +
  `guides/gotchas.md`). 0 S0/S1. `mix verify` GREEN with the harness present.
- **A4: dirty-flags-existed-unaudited → one covering measure+gate run, 9-NIF S2
  fixed + 1 S3, teeth proven.** This is the FIRST dedicated A4 covering run. Per
  the two-consecutive-covering-runs rule A4 is NOT yet DRY; one more covering run
  is owed. Churn re-wets it: any new `#[rustler::nif]`, any `schedule=` change,
  any change to what a normal NIF does under the conn `Mutex` (new blocking work,
  new lock), or a `with_conn`/`with_session`/`with_live_blob`/`with_live_stmt`
  restructuring.

## Run 11 — 2026-07-19 — A12 binary crossing

- Commit at scan: `a6292ff` (HEAD). Scope: what happens to bytes crossing the
  NIF boundary, BOTH directions — every inbound binary-accepting path (SQL text,
  string/blob params, `blob_write`/`deserialize`/`changeset_*` payloads) and
  every outbound producer (row TEXT/BLOB via the query path AND the stream/step
  path, `blob_read`, `serialize`, `session_changeset`/`patchset`,
  `changeset_invert`/`concat`, column names, and the raw-`enif_make_new_binary`
  hook payloads). Composition: single Opus pass (this agent) — a source-level
  copy-vs-refcount audit grounded in the LOCKED rustler-0.38.0 source (read, not
  recalled: `Binary`/`OwnedBinary`/`NewBinary` `types/binary.rs`, `str`/`String`
  encode+decode `types/string.rs`, `ResourceArc::make_binary` +
  `enif_make_resource_binary` `resource/arc.rs`) + a build-and-measure memory
  profile + a correctness-edges probe. A12 is a drive-and-measure axis (like
  A4/A6), not a fleet read; every runtime claim RUN this session (harness output
  pasted below). Did NOT re-litigate settled findings.

### Inbound audit (Elixir → Rust) — copy-vs-zero-copy map

| Path | Arg decode | Copy? | Notes |
|---|---|---|---|
| SQL text (`query`/`execute`/`execute_batch`/`query_with_changes` + cancellable) | `sql: String` (`String::decode` = `enif_inspect_binary` + `from_utf8` + `to_string`) | COPY 1× → Rust `String` | binary-ONLY; iolist → `BadArg` → ArgumentError; interior NUL → `:null_byte_in_string` (A11 F-A11-3) |
| text params | `Term` → `elixir_term_to_rusqlite_value` `decode::<String>` | COPY → `Value::Text(String)` | then rusqlite bind SQLITE_TRANSIENT (2nd copy into SQLite) |
| blob params (non-UTF-8) | `decode::<Binary>` → `as_slice().to_vec()` | COPY → `Value::Blob(Vec)` | then SQLITE_TRANSIENT (2nd copy) |
| `blob_write` data | `data: Binary` → `as_slice()` | ZERO-COPY view → `sqlite3_blob_write` (SQLite copies) | binary-only |
| `deserialize` data | `data: Binary` → `as_slice()` → `Cursor` | ZERO-COPY view, consumed synchronously | binary-only |
| `changeset_apply`/`invert`/`concat` | `Binary` → `as_slice()` → `Cursor` | ZERO-COPY view, consumed synchronously | binary-only |

- **Term-lifetime discipline HOLDS.** `Binary::decode` (`enif_inspect_binary`)
  yields a view tied to the term's env lifetime; every inbound path either COPIES
  it into an owned `Value`/`String` at once (params, SQL) or CONSUMES it
  synchronously within the call (blob_write via SQLITE_TRANSIENT; deserialize /
  changeset via a `Cursor` read that finishes before return). NO resource stores
  a `Binary<'a>`, a `Term<'a>`, or a `&[u8]` view (struct census: XqliteConn /
  Stream / Statement / Blob / Session hold raw ptrs / `Vec` / `AtomicPtr` only) —
  so no slice outlives its env (no use-after-env UB).
- **Sub-binary of a huge parent HOLDS.** A sub-binary term decodes to a
  zero-copy view into its parent ProcBin, but since every inbound path copies or
  synchronously consumes, the parent is never retained past the call → no
  parent-pinning leak. Exercised for real (edge E2 below).
- **iodata story — consistent, no divergence.** Nothing accepts iodata: rustler's
  `Binary::decode`/`String::decode` are `enif_inspect_binary` (binary-only);
  `Binary::from_iolist` (`enif_inspect_iolist_as_binary`, the only iolist path)
  is UNUSED by xqlite. All public specs are `binary()`/`String.t()` (grep:
  `lib/**` has ZERO `iodata`/`iolist`). An iolist SQL arg → `BadArg` →
  ArgumentError (edge E5); an iolist param VALUE → structured
  `{:unsupported_data_type, :list}`. Behavior matches typespecs and docs.

### Outbound audit (Rust → Elixir) — allocation map

| Producer | Mechanism | Copy? | Binary kind |
|---|---|---|---|
| query/execute row TEXT + all column names / schema strings | rustler `str::encode` = `OwnedBinary::new` + `enif_make_binary` | COPY | refc binary (always) |
| query/execute row BLOB | `ResourceArc<BlobResource>::make_binary` = `enif_make_resource_binary` | **ZERO byte-copy** (wraps the owned `Vec`) | resource binary (refc, off-heap) + per-resource overhead |
| stream/step row TEXT | `str::encode` (copies the SQLite `column_text` view) | COPY | refc binary |
| stream/step row BLOB | `OwnedBinary::new` + `copy_from_slice` | COPY | refc binary |
| `blob_read` | `vec![0;len]` then `to_owned_binary` (OwnedBinary copy) | COPY 2× (F-A12-2) | refc binary |
| `serialize` / `session_changeset`/`patchset` / `changeset_invert`/`concat` | Vec → `to_owned_binary` / OwnedBinary | COPY | refc binary |
| hook payloads (update/log/wal/commit/rollback/busy) | `enif_make_new_binary` into a fresh `msg_env` | COPY | heap binary ≤64 B else refc |

- **No escaped view into SQLite-owned memory.** The stream/step TEXT path encodes
  the `sqlite3_column_text` `&str` via `str::encode`, which allocates + copies
  IMMEDIATELY (under the conn Mutex, pointer still valid) — the view never
  survives the next `sqlite3_step`; BLOB copies into an `OwnedBinary` at once. The
  ONE zero-copy outbound path (`encode_val` BLOB) wraps OWNED memory (rusqlite's
  `Value::Blob(Vec)`), NOT a SQLite pointer, and `enif_make_resource_binary`
  refcounts the `BlobResource` so the binary keeps its `Vec` alive independent of
  the local `ResourceArc` (source-verified `resource/arc.rs:81-95`). RUNTIME-PROVEN
  independent of the connection: a query blob stays byte-exact after `Xqlite.close/1`
  + GC (edge E3). No resource holds an Elixir term (no term-pinning).
- **Hook payloads bounded + leak-free.** update/wal/commit/rollback/log/busy
  payloads carry only SQLite identifiers (db/table name), a formatted log
  message, and integer rowid/frame counts — NONE is caller-data-sized (no hook
  forwards column values), so all bounded. Every sender pairs `enif_alloc_env`
  with an UNCONDITIONAL `enif_free_env` (verified 1:1 in all 8 hook modules +
  the backup sender `nif.rs:1806/1822`; M4's conditional-free leak stays fixed).

### Measurement — harness `binary_crossing/` (invoke `bash binary_crossing/run.sh`)

- CI-isolated exactly like `scheduler/`…`type_edges/`: not under `test/`, not in
  `elixirc_paths` (`["lib"]`), and the formatter `inputs` glob
  (`{config,lib,test}/**`) matches ZERO `binary_crossing/` files (verified via
  `Path.wildcard` → `[]`) — `mix verify` untouched (re-run GREEN at HEAD with the
  harness present). Two `mix run --no-compile --no-start` children under an OS
  `timeout`; in-memory DBs only, source data generated INSIDE SQLite via a
  recursive-CTE `randomblob`/`hex` INSERT (no big inbound crossing to conflate);
  no files, no SIGKILL, no pkill/name-match. Instrument: `:erlang.memory(:binary)`
  (precise for refc + resource binaries; SQLite's own copy of the data lives in
  SQLite's malloc heap, NOT this counter, so it isolates the crossing) + OS RSS
  (`/proc/self/status` VmRSS). Each crossing runs INSIDE a `Task` so its death
  frees every crossed binary → a parent snapshot after `await` isolates any
  retention leak.

- **TEETH (hard gate — run.sh ABORTs rc 2 otherwise):** a deliberate-retention
  control (20 000 × 512 B refc binaries held across a GC) MUST grow
  `:erlang.memory(:binary)`. Delivered **+10.83 MB** for a 9.77 MB nominal
  payload while referenced, and **fell 10.83 MB back** on release — so the counter
  provably tracks retained refc binaries AND detects release; every "0 residual"
  below is real. (Analogue of the lifecycle-harness leak teeth.)

- **S1 — large result (100 000 rows × [256 B TEXT + 256 B BLOB], ~48.8 MB
  payload), full materialization:** `query` held **42.73 MB binary / 61.9 MB
  total**, peak RSS Δ +98 MB, **448 B/row** binary; `stream`-to-list held
  **61.0 MB binary / 83.7 MB total**, peak RSS Δ +124 MB, **640 B/row** binary
  (the query path is ~1.3× leaner — its zero-copy resource binaries don't
  re-copy blob bytes into the binary allocator; stream's OwnedBinary path does).
  **RETENTION-LEAK gate: 0.0 MB residual on BOTH paths** (holder-process death
  reclaims every crossed binary) → no leak.
- **S2 — streaming consume-and-discard bounded peak (batch 500):** peak binary
  **0.62 MB above start** for the same 100 000-row scan vs 42.73 MB for the full
  query → **68.5× smaller peak**. The streaming memory advantage, measured: peak
  is ~one batch, independent of N.
- **S3 — many small blobs (100 000 × 16 B):** `query` (resource binary)
  **23.4 MB total / 128 B/row binary**; `stream` (OwnedBinary → heap binary for
  ≤64 B) **~7.5–13 MB total / ~0–2 B/row binary**; total-memory ratio **1.8×**
  (run-to-run 1.5–3× under settle noise; the ≤64 B blobs become process-heap
  binaries on the stream path but always-off-heap resource binaries on the query
  path). Well under the 10× cliff → S3 characterization (F-A12-1).
- **S4 — refc classification:** a 1000 B blob lands in the binary allocator
  (>64 B), an 8 B value in the process heap (≤64 B) — the documented threshold,
  confirmed.

### Correctness edges — `binary_crossing/edges.exs` (hard assertions, all PASS)

- **E1** empty (0-byte) BLOB round-trips as `<<>>` on BOTH paths — query
  (`make_binary` on an empty `Vec`, dangling-aligned ptr, len 0) and stream
  (null-ptr + len-0 branch). No crash.
- **E2** a 32-byte SUB-BINARY carved from an 8 MB parent round-trips byte-exact as
  a blob PARAM and as `blob_write` data (inbound copies the view; never retains
  the parent).
- **E3** a `query` blob (resource binary owning a copied-out `Vec`) stays
  byte-exact AFTER `Xqlite.close/1` + GC → the crossed binary is independent of
  SQLite-owned memory (no escaped view).
- **E4** interior-NUL BLOB `<<1,0,255,0,2>>` + TEXT `"a\0b\0c"` byte-exact via
  query AND stream.
- **E5** an iolist SQL arg → ArgumentError; an iolist param value →
  `{:unsupported_data_type, :list}` — iodata rejected, binary-only, matching the
  typespecs.

### Findings — 0 S0/S1/S2, 3 S3 (BACKLOG, NOT fixed this run)

- **F-A12-1 — S3 — query-path resource-binary vs stream-path OwnedBinary
  asymmetry for BLOB columns.** Same bytes, different backing; measured 1.3×
  (large, query leaner) to ~1.5–3× (tiny blobs, query heavier via per-resource
  overhead). No correctness impact, no leak, < 10× cliff. → BACKLOG +
  `guides/gotchas.md` ("BLOB values are backed differently by `query` vs `stream`").
- **F-A12-2 — S3 — `blob_read` double-copies** (SQLite → `vec` → `OwnedBinary`);
  reading straight into an `OwnedBinary` target would halve the peak + memcpys.
  Pure efficiency. → BACKLOG.
- **F-A12-3 — S3 (latent/OOM-only) — TEXT/string encode panics on alloc failure
  while BLOB encode degrades gracefully.** rustler's `str::encode`
  (`string.rs:34`) `panic!`s if `OwnedBinary::new` returns `None`; our BLOB
  encoders use `ok_or_else(InternalEncodingError)`. Caught by the return-encode
  `catch_unwind` (Run 1) → `:nif_panicked`, never a VM crash; OOM-only (a ~1 GB
  TEXT near `SQLITE_MAX_LENGTH`). Same class as M8/M10/M11; crate-wide consistency
  call (column names + schema strings share `str::encode`). Cross-refs A1. →
  BACKLOG.

### Completeness critic

- Covered: every inbound binary path (SQL/params/blob_write/deserialize/changeset)
  and every outbound producer (row TEXT/BLOB × query+stream, blob_read, serialize,
  changeset/session, column names, all six hook payloads) mapped copy-vs-refcount
  against the LOCKED rustler source; large-result memory profiled query-vs-stream
  with teeth; sub-binary, empty-blob, escaped-view, interior-NUL, and iodata
  exercised at runtime; hook-payload bounds + msg_env balance verified. NOT covered
  / honest gaps: (1) the memory instrument is `:erlang.memory(:binary)` + RSS +
  the holder-death leak gate, not a per-binary refcount BIF (none exposed); a leak
  smaller than settle noise (~±0.5 MB) could hide, but the teeth prove the counter
  tracks retention at the MB scale. (2) Values were driven to 256 B / 64 MB, not to
  the `SQLITE_MAX_LENGTH` (~1 GB) ceiling (RAM) — the OOM-panic reachability of
  F-A12-3 is reasoned, not forced. (3) No TSan/Miri on the live NIF (Runs 2/4/5:
  Miri can't run the bundled C SQLite); the escaped-view conclusion rests on the
  source deref-chain audit + E3's after-close byte-exactness, bounded by the fact
  that the sole zero-copy path wraps OWNED memory. (4) `str::encode`'s OOM panic is
  not force-triggered (needs real allocator exhaustion); its catch-and-surface is
  inherited from Run 1's source-verified rustler behavior, not re-run here.

### Disposition & dryness

- **0 S0/S1/S2 — nothing to fix.** The binary-crossing model is sound: inbound
  copies-or-synchronously-consumes with no term/slice escaping its env; outbound
  copies every SQLite view before return and the lone zero-copy path refcounts
  owned memory; no leak (gate + msg_env balance); no ≥10× cliff (query-vs-stream
  1.3–3×); iodata consistently rejected per the typespecs. 3 S3 filed to BACKLOG
  (F-A12-1 + gotchas, F-A12-2, F-A12-3); none blocks per the ratified bar.
  `mix verify` GREEN with the harness present.
- **A12: none-measured → one covering measure+audit run, 0 S0/S1/S2, 3 S3, teeth
  proven.** This is the FIRST dedicated A12 covering run. Per the
  two-consecutive-covering-runs rule A12 is NOT yet DRY; one more covering run is
  owed. Churn re-wets it: any change to `util.rs` `encode_val` /
  `sqlite_row_to_elixir_terms` / the param decoders, `blob.rs` read/write,
  `session.rs` `to_owned_binary`, the `serialize`/`deserialize`/`changeset_*` NIFs,
  the `hook_util.rs` `make_binary` / any hook payload, or a rustler bump (the
  Binary/OwnedBinary/resource-binary semantics are version-locked evidence).

## Run 12 — 2026-07-19 — A13 hot-upgrade posture + A14 test-architecture load-bearer

- Commit at scan: `fc502fb` (HEAD). Two bundled axes in one run. Composition:
  single Opus pass (this agent) — A13 is a source-verify + empirical-probe axis,
  A14 a re-derivation + build-and-measure axis; neither is a fleet read. Every
  runtime claim RUN this session (commands + output captured below) against the
  BUNDLED SQLite 3.53.2 on OTP 29 (erts-17.0.3) / Elixir 1.20.2, rustler 0.38.0.
  Did NOT re-litigate settled findings.

### A13 — hot-upgrade posture

- **Source-verified gap.** rustler's init codegen hardcodes the NIF entry's
  upgrade/reload/unload callbacks to `None`: `rustler_codegen-0.38.0/src/init.rs`
  (`:63-99`) builds `DEF_NIF_ENTRY { … load: Some(nif_load), reload: None (:92),
  upgrade: None (:93), unload: None (:94), … }` — only `load` is wired (the sole
  option the macro extracts, `:17`); a rustler user CANNOT supply an upgrade
  callback. The FFI struct HAS the fields (`rustler-0.38.0/src/sys/types.rs:62-84`,
  matching the installed `erl_nif.h:142-145` `enif_entry_t`, NIF major.minor
  2.18), so the gap is purely that codegen never populates them. Per the erl_nif
  contract (OTP 29 docs, erlang.org/doc/apps/erts/erl_nif.html): "The library
  fails to load if upgrade … is NULL" once the module has old code with a loaded
  NIF; "unload is called when the module instance … is purged as old"; and "The
  unloading of a library is postponed as long as there exist resource objects
  with a destructor function in the library." So xqlite, built with rustler 0.38,
  CANNOT be hot-upgraded, and its resource destructors keep the old library
  resident until the resources die. This is an OPEN upstream gap (no rustler API
  to wire upgrade) → F-A13-1 (S3, tracking).
- **Probe transcript (`hot_upgrade/run.sh`, RUN this session; teeth: a separate
  `HOTUP_MODE=teeth` child loads the NIF, proves it works, then `System.halt(134)`
  → run.sh classified CRASH rc=134, so the no-crash results below are trusted).**
  With a live conn + prepared statement + stream + blob + session held open:
  - `:code.load_file(XqliteNIF)` → **`{:error, :on_load_failure}`**, and the VM
    logs the on_load return `{:error, {:upgrade, ~c"Upgrade not supported by this
    NIF library."}}` — the exact erl_nif NULL-upgrade refusal. The reload is
    REFUSED, never a silent success (a silent success would mean two library
    instances — the dangerous case the probe hard-asserts against).
  - After the failed reload AND after `:code.soft_purge` (→ `true`), EVERY live
    resource still works: conn `query` `{:ok,…}`, `stmt_step` `{:row,…}`,
    `stream_fetch` `{:ok,%{rows:…}}`/`:done`, `blob_read` `{:ok,<<…>>}`,
    `session_is_empty` `{:ok,true}`. The old code + its NIF keep running untouched.
  - Direct `:erlang.load_nif(path, 0)` from a foreign module → **`{:error,
    {:bad_lib, "…does not match calling module…"}}`** — no back door; the only
    load path is the module's own on_load, which is exactly the failing path.
  - Forced `:code.delete` (→ `true`) + `:code.purge` (→ `false`) with a SECOND
    live resource set held, then drop-refs + `garbage_collect` → the resource
    destructors (`sqlite3_close` etc.) run out of a to-be-unloaded library with
    **no VM abort**; a fresh `open_in_memory` afterward succeeds `{:ok,#Ref}` (once
    the old code is fully purged there is no old NIF to conflict, so the auto-load
    takes). Reaching the end IS the no-crash proof (a UAF/unwind-into-C aborts the
    VM → rc 134/139 → run.sh CRASH). `hot_upgrade/run.sh` RESULT **PASS**.
- **Grading.** No crash-on-purge was found (the axis's ≥S1 candidate) — every
  documented OTP hot-code operation on the loaded NIF **fails safe**: refused
  cleanly, resources intact, VM alive, no data loss. So A13 has NO S0/S1/S2
  finding; the axis deliverable is the missing POLICY, and the documented policy
  IS the fix.
- **Policy (the deliverable).** New `guides/gotchas.md` section "Deployment and
  releases → Hot code upgrades are not supported — restart the node": states
  plainly that the xqlite NIF cannot be hot-upgraded in place (full node restart
  required), shows the exact `{:error, :on_load_failure}` / `{:upgrade, …}` the VM
  returns, explains the rustler-NULL-upgrade root cause, documents that it FAILS
  SAFE (old code keeps running, live handles survive, no corruption, no two-
  instance state), and gives operational guidance (deploy with a node restart;
  wrapping libraries must not assume upgrade-in-place; exclude xqlite from
  `relup`s). Placed in gotchas.md (not security.md) because it is a deployment/DX
  sharp edge, not a threat — gotchas.md is where operational footguns already live.

### A14 — test-architecture load-bearer

- **Re-derivation from first principles (gotcha #1).** `bundled` = statically
  linked SQLite → confirmed by nm/objdump on the built `.so` (below), so ONE OS
  process = ONE set of SQLite process-global C structures: the VFS registration
  list, the memory allocator, the page cache (pcache1), the PRNG, the
  memstatus counter (`SQLITE_DEFAULT_MEMSTATUS` on — not overridden in
  `libsqlite3-sys-0.38.1/build.rs`), and the temp-file namespace
  (`TEMP_STORE=1`). `mix test` runs test files concurrently as async ExUnit
  processes in ONE OS process → all share that one globals set; `mix test.seq`
  (`lib/mix/tasks/test_seq.ex`, `System.cmd("mix",["test",file])` per file) gives
  each file its OWN OS process → its own globals. **Adversarial both ways:**
  (a) the alternative diagnoses are REFUTED — the two suite openers
  (`test/support/test_util.ex:6-8`) are `:memory_private` (private in-memory, no
  shared name) and `:file_temp` (a fresh temp FILE), so there is NO `:memory:`-name
  collision and NO shared file; DB-level isolation is real, which is exactly why
  gotcha #1 says "regardless of file isolation" — the shared globals are the ONLY
  common surface. (b) BUT "corrupt global C state" is itself REFUTED as literal
  corruption: the bundle is `-DSQLITE_THREADSAFE=1` (`libsqlite3-sys-0.38.1/
  build.rs:139`) and runtime-verified THIS session `PRAGMA compile_options` →
  `["THREADSAFE=1"]` + `["MUTEX_PTHREADS"]` (SQLite 3.53.2), so the process-global
  structures are mutex-protected even though rusqlite opens connections NOMUTEX
  (SQLite "multi-thread" mode: core mutexes on, per-connection off — xqlite's own
  `Mutex<Connection>` covers the latter). Mutex-protected globals do not corrupt
  under concurrent access; the "out of memory" symptom is CONTENTION /
  resource-exhaustion (spurious `SQLITE_NOMEM`), not UB. Git archaeology: the
  origin commits (`d250fe6` "make tests sequential in CI" 2025-06-28, `13805b8`
  "add mix testing task running each file sequentially") carry no evidence body;
  the rationale lives only in the `test.seq` @moduledoc ("SQLite's global VFS
  contention that causes spurious 'out of memory' errors when test files run in
  parallel") and gotcha #1 — i.e. the diagnosis was never independently re-derived
  until now.
- **Reproduction attempt (`test_arch/run.sh`, RUN this session; teeth: a
  byte-smashed file DB → `{:sqlite_failure, 11, 11, "database disk image is
  malformed"}` (SQLITE_CORRUPT), a clean DB → `integrity_check ["ok"]` — the
  corruption oracle trips, so a real corruption would be seen).** K concurrent
  BEAM workers each churn an ISOLATED DB (alternating private `:memory:` + a fresh
  temp file, `cache_size=-1000` like the suite), 200×1 KB-row transactions +
  scans + per-file `integrity_check`, vs the SAME total work serialized (control).
  Plus an open/close-churn leg (the rusqlite#1860 angle). Results: **36×60**
  workers → parallel **439560 ok / 0 nomem / 0 busy / 0 corruption / 0 crash**,
  serial control IDENTICAL 439560 ok / 0 anomalies; **48×40 + 48×600 churn** →
  parallel **390720 ok / 0 nomem / 0 corruption**, 0 churn failures both legs.
  **The mechanism did NOT reproduce** (no crash, no corruption, no spurious NOMEM)
  at dev-box scale — consistent with Run 4 (rusqlite#1860 does not repro at 3.53.2
  / THREADSAFE=1). Honest reading (per the axis): a non-repro does NOT refute the
  gotcha — the flake is memory-pressure- and environment-sensitive (a 7 GB GHA
  runner holding many async connections is a far tighter allocator than this box;
  true C-level concurrency is also capped at ~10 dirty-IO schedulers, which the
  probe already saturates), and #1860 is a real OPEN upstream issue in the class.
  A control note: the FIRST probe draft's serial leg reused temp-file paths and
  self-inflicted 211050 PK violations — fixed to `System.unique_integer` per
  cycle, restoring a clean control (the tooth: an unclean control would invalidate
  the comparison).
- **Precompiled answer (nm/objdump, RUN this session).** The built `.so`
  (`priv/native/xqlitenif.so`) and the older precompiled artifact
  (`libxqlitenif-v0.5.2-…-linux-gnu.so`) BOTH: statically bundle SQLite (version
  string "3.53.2"/"3.51.3" baked in; NO `libsqlite3` in `DT_NEEDED`; zero
  UNDEFINED `sqlite3_*` in dynsym), and export in their dynamic symbol table
  EXACTLY two real symbols — `nif_init` + `xqlitenif_nif_init` — and **NO
  `sqlite3_*` symbols at all**. Two consequences: (1) precompiled consumers get
  the SAME statically-linked SQLite → the SAME per-OS-process globals, so the
  test.seq reasoning holds identically for them (not just source builds). (2) The
  two-bundled-SQLites-in-one-node question (e.g. host app loads xqlite AND
  exqlite) has the SAFE answer: because neither `.so` exports its `sqlite3_*`
  symbols, the two statically-linked SQLites are completely PRIVATE to their
  respective `.so`s — they cannot interpose, dedup, or share globals (the
  DANGEROUS answer would be shared/deduped globals + a version clash; ruled out by
  the non-export, and belt-and-suspenders by ERTS's RTLD_LOCAL NIF dlopen). So
  gotcha #1's "single global VFS/allocator per OS process" is precisely "per
  loaded NIF library" — for xqlite (one XqliteNIF `.so` per VM) that IS per OS
  process, and a second bundled SQLite is independent.
- **Verdict on gotcha #1 — mechanism PLAUSIBLE; test.seq CONFIRMED load-bearing;
  wording CORRECTED.** The STRUCTURAL claim (one per-OS-process SQLite-globals
  surface that DB-file isolation cannot remove) is CONFIRMED (static-link symbols
  + opener isolation + runtime substrate). The literal "corrupt global C state" is
  REFUTED (THREADSAFE=1 mutex-protects; 0 corruption across ~830k parallel ops).
  The spurious-NOMEM flake is PLAUSIBLE (not reproduced here, but a real
  environment-sensitive contention/flake class; #1860 open upstream). `test.seq`
  stays load-bearing REGARDLESS of which of {contention, a since-fixed SQLite bug,
  genuine GHA-RAM pressure} the residual is — it deterministically removes the
  shared-globals surface, so its value does not depend on the flake reproducing.
  Wording fix landed in `CLAUDE.md` gotcha #1: "corrupt global C state" →
  "contend on the shared global C state; the symptom is spurious 'out of memory'
  = contention/resource-exhaustion, not memory corruption (THREADSAFE=1 protects
  the globals), not UB" — the load-bearing test.seq conclusion preserved. No
  public-facing guide misstates the mechanism (gotchas.md's runtime-contention
  section is about the connection Mutex, a different surface; the test-suite
  angle is dev-facing = CLAUDE.md), so no public correction is owed. Deferred
  deciding probe → F-A14-1 (S3): re-run `test_arch/` under a cgroup RAM cap
  mimicking a 7 GB runner to try to force the spurious NOMEM.

### Teeth

- **A13** (evidence bar = exact child-output capture): the crash oracle is proven
  live — the `HOTUP_MODE=teeth` child (`System.halt(134)` after confirming the NIF
  works) is classified CRASH (rc 134), so the main probe's crash-free traversal of
  delete+purge+GC-of-live-resources is real silence, not a dead detector. Every
  reload/soft_purge/back-door result is captured verbatim above.
- **A14**: the corruption oracle trips — a byte-smashed file DB →
  `{:sqlite_failure, 11, 11, …}` (SQLITE_CORRUPT) while a clean DB passes
  `integrity_check`; and the serialized CONTROL leg is clean and byte-for-byte
  equal to the parallel leg (439560 ok each), so a parallel-only corruption/NOMEM
  would have shown as a divergence. run.sh aborts (rc 2) if either oracle fails.

### Completeness critic

- **A13 covered:** the rustler-0.38 init codegen (upgrade/reload/unload = None),
  the erl_nif NULL-upgrade contract (OTP 29 docs + installed `erl_nif.h`), and the
  empirical reload / soft_purge / delete+purge+GC / direct-load_nif paths with all
  five resource types held live. NOT covered / honest gaps: (1) a genuine
  release-handler `relup`/`appup` in-place upgrade of a running release was not
  driven end-to-end — the `:code.*` sequence is its mechanism, but a full
  `release_handler` cycle (with `.appup` instructions) is a heavier apparatus not
  built here; the on_load-refusal it would hit is the same. (2) Windows/macOS load
  paths not exercised (Linux only); the codegen gap is platform-independent but
  the exact VM message text is not re-verified off-Linux. (3) An `upgrade`-capable
  hand-written entry (adopting resources) is a hypothetical fix not prototyped —
  out of scope (the deliverable is the policy, not upgrade support).
- **A14 covered:** the shared-globals enumeration, the THREADSAFE substrate
  (runtime), the opener-isolation refutation, the parallel-vs-serial corruption/
  NOMEM stress with teeth, the open/close-churn (#1860) angle, and the
  static-link + symbol-visibility analysis for both source and precompiled `.so`s.
  NOT covered / honest gaps: (1) the spurious NOMEM was NOT reproduced — not under
  a constrained-RAM cgroup (F-A14-1), and true C-concurrency is scheduler-capped
  at ~10, so the box may simply be too roomy to flake. (2) A literal bare-`mix
  test` (full async suite) flake-hunt was not run — the synthetic probe stresses
  the same shared surface far harder, but the exact CI failure mode (many test
  files' setup pressure at once) is modeled, not replayed. (3) No TSan/Miri on the
  live NIF (Runs 2/4/5: Miri can't run the bundled C SQLite); the oracle is
  integrity + crash/exit-code + tallies, bounded by the THREADSAFE=1 source
  analysis. (4) A two-bundled-SQLites node (xqlite + exqlite loaded together) was
  reasoned from symbol non-export + RTLD_LOCAL, not physically co-loaded.

### Disposition & dryness

- **A13:** 0 S0/S1/S2 (hot upgrade fails SAFE — no crash-on-purge). Deliverable
  DONE: policy documented in `guides/gotchas.md`. 1 S3 filed (F-A13-1, upstream
  rustler-upgrade gap, tracking). `mix verify` GREEN with the harness present.
  **A13: no-policy → one covering source-verify + empirical-probe run, policy
  documented, teeth (crash-oracle) proven.** First covering run; NOT yet DRY, one
  more owed. Churn re-wets: a rustler bump (re-check `init.rs` upgrade wiring), a
  `RustlerPrecompiled`/on_load change, or a new resource type (re-verify its
  destructor survives purge).
- **A14:** 0 S0/S1/S2 (no corruption/crash/wrong-result; test.seq is the working
  mitigation). CLAUDE.md gotcha #1 wording CORRECTED this run (S3-class doc
  sharpening, done not backlogged). 1 S3 filed (F-A14-1, deferred constrained-RAM
  reproduction). **A14: never-independently-re-derived → one covering
  re-derivation + reproduction + symbol-analysis run, mechanism PLAUSIBLE, gotcha
  #1 confirmed load-bearing + wording sharpened, teeth (corruption oracle + clean
  control) proven.** First covering run; NOT yet DRY, one more owed. Churn re-wets:
  a bundled-SQLite version bump (re-verify THREADSAFE + #1860 non-repro + the
  static-bundle symbols), any `test.seq`/opener change, or a rusqlite/libsqlite3-sys
  bump (re-check the `-DSQLITE_THREADSAFE=1` build flag).

---

## S3 fix pass — round 1 — 2026-07-19 — F-A10-3, F-A10-5, F-A11-5, M10, M11

- Commit at scan: `1e4bafa` (HEAD, clean). A committed post-burn-down S3 pass
  (not an axis run): the three assigned filed items fixed, `mix verify` green,
  orchestrator commits. Composition: single Opus pass (this agent). Every runtime
  claim below was RUN this session against the bundled SQLite 3.53.2 (commands +
  output captured). Scope held to exactly the three fixes; two newly-surfaced
  spec gaps were FILED (F-A10-7/8), not fixed.

### Fix 1 — F-A10-3: `… RETURNING` DML reported `changes: 0` (arguably-S2)

- **Mechanism found.** `query_with_changes` / `query_with_changes_cancellable`
  (`nif.rs`) zeroed the sticky `sqlite3_changes()` whenever `qr.columns.is_empty()`.
  That heuristic is wrong TWICE: (a) an `INSERT/UPDATE/DELETE … RETURNING` returns
  columns, so it was misdetected as non-DML and zeroed despite changing rows (the
  filed F-A10-3); (b) symmetrically, a DDL / read-PRAGMA returns NO columns, hit
  the `changes()` branch, and LEAKED the stale prior-DML count (a second, unfiled
  leg of the same defect — DDL-after-DML reported the previous INSERT's count).
- **Detector chosen: `sqlite3_total_changes()` delta.** Capture
  `conn.total_changes()` before and after `core_query`; report `conn.changes()`
  only when the total moved, else 0. `total_changes()` rises iff THIS statement
  (or its triggers) actually changed rows — exactly "is this a row-changing DML",
  independent of whether it returns columns. `Statement::readonly()` REJECTED:
  DDL (CREATE TABLE) is NOT readonly yet must report 0, so a readonly detector
  would still leak the stale count for DDL-after-DML. Keyword parsing REJECTED
  (fragile; house rule disfavors SQL text parsing). The RETURNING-timing concern
  resolves cleanly: `core_query`'s `process_rows` steps to `SQLITE_DONE`, so both
  `changes()` and `total_changes()` are fully updated by the time the closure
  reads them.
- **Runtime justification (bundled SQLite 3.53.2, this session).** Seeded 3 rows
  (sticky `changes()`=3), then per statement measured Δtotal_changes / changes() /
  detector-report:

  | statement (after the seed)   | Δtotal_changes | changes() | detector |
  |------------------------------|----------------|-----------|----------|
  | plain SELECT                 | 0              | 3 (stale) | **0**    |
  | PRAGMA user_version          | 0              | 3 (stale) | **0**    |
  | CREATE TABLE (DDL)           | 0              | 3 (stale) | **0**    |
  | plain INSERT                 | 1              | 1         | **1**    |
  | INSERT … RETURNING (2 rows)  | 2              | 2         | **2**    |
  | UPDATE … RETURNING (2 rows)  | 2              | 2         | **2**    |
  | DELETE … RETURNING (1 row)   | 1              | 1         | **1**    |
  | no-op DELETE (0 rows)        | 0              | 0         | **0**    |
  | SELECT after DML             | 0              | 0         | **0**    |

  Every matrix row holds: RETURNING DML now reports the true count; DDL / PRAGMA /
  SELECT report 0 with no stale leak.
- **Fix.** New `query::core_query_with_changes` centralises the detector; both
  NIFs call it (the duplicated empty-columns heuristic is gone).
- **RED → green.** Corrected the test matrix (`test/nif/query_with_changes_test.exs`,
  inside the `connection_openers()` `for`) to the true contract, then ran
  `mix test.seq` against the UNFIXED NIF: **8 failures** — INSERT/UPDATE/DELETE
  RETURNING each `changes:0` (expected n) and DDL-after-DML `changes:1` (expected
  0), ×2 openers. After the Rust fix: `query_with_changes_test.exs` 41 passed,
  full suite green. Tests added: UPDATE RETURNING, DELETE RETURNING, PRAGMA-read;
  INSERT-RETURNING + DDL assertions corrected (the DDL test previously asserted
  the stale `changes:1` as "documented behavior" — that was the bug's second leg,
  now `changes:0`).

### Fix 2 — F-A10-5 + F-A11-5: `error_reason/0` union corrections

- Runtime shapes (this session): `Xqlite.query(c, "SELECT CAST(X'ff41' AS TEXT)")`
  → `{:error, {:utf8_error, 0, "invalid utf-8 sequence of 1 bytes from index 0"}}`
  (3-tuple, confirming F-A11-5); `Xqlite.open_in_memory(bogus_key: 1)` →
  `{:error, {:invalid_open_option, %{key: :bogus_key, reason: :unknown_key,
  allowed: [...], value: nil}}}`; `Xqlite.open_in_memory(foreign_keys: :not_a_bool)`
  → `{:error, {:invalid_open_option, %{key: :foreign_keys, reason: :invalid_value,
  value: :not_a_bool, message: "…"}}}` (map payload, two shapes, confirming F-A10-5).
- **Fix.** `{:utf8_error, String.t()}` → `{:utf8_error, non_neg_integer(),
  String.t()}` (matches `error.rs:545`). Added `{:invalid_open_option, …}` as the
  precise two-map union (`%{key, reason: :unknown_key, allowed, value: nil}` |
  `%{key, reason: :invalid_value, value, message}`) matching `validate_open_opts`
  (`lib/xqlite.ex:352`). `error.rs` has NO `InvalidOpenOption` variant — it is
  Elixir-generated (NimbleOptions), so the map type was read off the Elixir
  source + runtime, not the Rust encoder. Dialyzer GREEN.

### Fix 3 — M10 fixed (+ M11 already resolved)

- **M10 — FIXED.** `explain_analyze.rs`'s four `Encoder` impls used 24
  `map_put(…).unwrap()`. Replaced with a chained `and_then` build + a
  `map_or_encoding_error` helper that degrades a (practically-unreachable)
  map-build failure to a structured `InternalEncodingError` term instead of
  panicking — matching the crate's `ok_or_else`/`map_err` convention (cf.
  `encode_query_result_with_changes`, `session::to_owned_binary`,
  `util.rs:346/363`). Success path byte-identical; existing explain_analyze tests
  green. No RED test is possible (`map_put` never Errs on a real map — OOM-only);
  the fix removes a panic surface, verified by clippy `-D warnings` + full suite.
- **M11 — ALREADY RESOLVED (no code change).** The filed site
  (`nif.rs:2057 OwnedBinary::new(0).unwrap()`) lived in the OLD rusqlite-`Blob`-
  wrapper `blob_read`; the blob raw-pointer refactor `b1c60b4` (Run 2 / B1)
  rewrote that module. Verified at HEAD: the empty-binary path is now
  `blob::read` → `to_owned_binary(&[], …)` → `OwnedBinary::new(…).ok_or_else(…)`
  (`session.rs:132`), and `rg '\.unwrap\(\)'` over `nif.rs` returns zero hits.

### New filings — audit of `error_reason/0` vs the `error.rs` Encoder (FILED, not fixed)

- **F-A10-7 — S3 — `error_reason/0` omits `:invalid_transaction_mode`.**
  `error.rs:523` encodes `XqliteError::InvalidTransactionMode` as the bare atom
  `:invalid_transaction_mode` (`transaction.rs:23`, `TransactionMode::from_atom`
  on a mode that isn't `:deferred`/`:immediate`/`:exclusive`). `XqliteNIF.begin/2`
  is `@spec … :: :ok | Xqlite.error()` AND its docstring (`xqlitenif.ex:479`)
  explicitly promises `{:error, :invalid_transaction_mode}`, but the union omits
  it — a dialyzer contract gap at the raw-NIF layer (the high-level `Xqlite.begin/2`
  guards the mode, so it can't reach it). Runtime-confirmed this session:
  `XqliteNIF.begin(c, :bogus_mode)` → `{:error, :invalid_transaction_mode}`. Same
  class as F-A10-5/F-A11-5; add `:invalid_transaction_mode` to the union.
- **F-A10-8 — S3 (latent) — `error_reason/0` omits
  `{:cannot_convert_atom_to_string, String.t()}`.** `error.rs:491` encodes
  `(cannot_convert_atom_to_string, reason)`, produced at `util.rs:204`
  (keyword-param key atom that fails `atom_to_string`) and `util.rs:242`
  (`format_term_for_pragma` non-nil/true/false atom). Reachable via query/execute
  keyword params or the PRAGMA-value path, spec'd through `Xqlite.error()`, but
  omitted from the union. Latent (`atom_to_string` rarely fails). Add
  `{:cannot_convert_atom_to_string, String.t()}`.

### Disposition & dryness

- 5 filed items closed (F-A10-3, F-A10-5, F-A11-5, M10 fixed; M11 already-
  resolved-by-`b1c60b4`). 2 new S3 spec gaps FILED (F-A10-7/8). `mix verify`
  GREEN. This pass CHURNS **A10** (the `query_with_changes` columns heuristic +
  the `error_reason/0` typespec are both in A10's re-wet list — re-wet, one clean
  covering run still owed), **A11** (`query.rs core_*` — added
  `core_query_with_changes`), and **A1** (removed 24 reachable-in-theory
  `unwrap`s from `explain_analyze.rs`, strictly improving the panic-freedom
  posture). Axis coverage annotated in `REVIEW_AXES.md`.
- **Docs note (out of this pass's scope, flagged for the maintainer):** CLAUDE.md's
  `sqlite3_changes()` architecture note still says non-DML is "detected by empty
  columns" — now superseded by the total_changes-delta detector.

---

## S3 fix pass — round 2 — 2026-07-19 — F-A10-1/2/4/6/7/8, F-A12-1/2

- Commit at scan: `287c403` (HEAD, clean, CI green). A committed post-burn-down S3
  pass (not an axis run): the eight assigned filed items fixed, `mix verify` green,
  orchestrator commits. Composition: single Opus pass (this agent). Every runtime
  claim below was RUN this session against the bundled SQLite 3.53.2 (commands +
  output captured). Scope held to the eight items; one un-enumerated FIFTH site of
  F-A10-6's pattern (`schema.rs`) was found and folded in (identical class, not a
  separate finding). Per a mid-run maintainer directive, all NEW/edited code
  comments (and three pre-existing ones in touched files) were scrubbed of
  review-program nomenclature — finding IDs / run+axis refs / severity grades now
  live only here, in BACKLOG.md, and REVIEW_AXES.md; code comments state the
  engineering constraint in plain domain terms.

### Fix 1 — F-A10-1: text-parse census exceptions (resolved two ways)

- **Mechanism.** Two distinct message-text classifications outside the sanctioned
  `constraint_parse.rs`: (a) the four `NoSuchTable`/`NoSuchIndex`/`TableExists`/
  `IndexExists` arms in `classify_sqlite_error`, and (b) a `message == "interrupted"`
  string-compare in the `From<RusqliteError>` catch-all (former `error.rs:786`).
- **Resolution split by whether SQLite gives a code.** (a) The four table/index
  conditions are ALL primary `SQLITE_ERROR` (1) with no distinguishing extended
  code — SQLite gives no other signal, so the English message prefix is the only
  discriminator. KEPT but DOCUMENTED as a deliberate exception in a code comment
  (mirroring `constraint_parse.rs`'s justification), stating the accepted
  consequence: a reword/localization gracefully downgrades to the generic
  `SqliteFailure` (no wrong result, no crash), never a misclassification. (b) The
  `"interrupted"` compare is DEAD and was ELIMINATED. A SQLite interrupt is always a
  `SqliteFailure` carrying extended `SQLITE_INTERRUPT` (9), classified by the code
  arm at the top of `classify_sqlite_error`; the `From` catch-all only sees
  non-`SqliteFailure`/`SqlInputError` rusqlite variants, and NONE `Display`s as
  "interrupted". Proof this session: read rusqlite 0.40.1 `src/error.rs` Display
  impl — the only literal-string arms are `SqliteFailure(_, Some(s)) => "{s}"`
  (routed through `classify`, not the catch-all) and fixed strings like "unwinding
  panic" / "Multiple statements provided"; no variant emits "interrupted". Interrupt
  classification is now purely code-driven.
- **Evidence.** Dead-code removal ⇒ no RED (nothing triggered it). The interrupt
  path stays exercised by the existing cancellation suite (interrupt →
  `:operation_cancelled` via the code arm) — full suite green.

### Fix 2 — F-A10-2: semantic variants dropped the extended result code

- **Mechanism.** `DatabaseBusyOrLocked`/`ReadOnlyDatabase`/`SchemaChanged`/
  `AuthorizationDenied` carried only `message: String`, so a caller could not tell
  BUSY (5) from LOCKED (6), nor the READONLY_*/BUSY_SNAPSHOT/AUTH sub-codes, without
  parsing text — while the generic `SqliteFailure` fallback carried both codes.
- **Fix.** Added `extended_code: i32` to exactly those four variants (constructed in
  `classify_sqlite_error`, where `ffi_err.extended_code` is in hand) and encode as
  `{atom, extended_code, message}` — a 3-tuple that KEEPS the leading classification
  atom (dispatch ergonomics intact). `extended_code &&& 0xFF` recovers the primary
  class. **Deliberately surgical:** the four TEXT-classified variants
  (no_such_table/index, table/index_exists) stay message-only because their extended
  code is invariantly `SQLITE_ERROR` (1) — surfacing it would be noise, not signal,
  and would needlessly widen the blast radius (their Elixir synthesizer at
  `lib/xqlite.ex` and ~10 test sites keep the 2-tuple). This ties F-A10-1 and
  F-A10-2 into one coherent story: the four "SQLite gives no discriminating code"
  cases are both text-classified AND kept codeless. **Shape choice:** flat tuple
  over a map, for consistency with the sibling `{:sqlite_failure, code,
  extended_code, message}`; the pre-1.0 loud MatchError on old 2-tuple matchers is a
  cleaner break than a silent string→map type swap.
- **RED → green (runtime, bundled SQLite 3.53.2, this session).** BEFORE (unfixed
  NIF): `NIF.execute(ro, "CREATE TABLE x…")` → `{:error, {:read_only_database,
  "attempt to write a readonly database"}}`; authorizer DELETE →
  `{:error, {:authorization_denied, "not authorized"}}` — both 2-tuples, no code.
  AFTER: `{:read_only_database, 8, "…"}` and `{:authorization_denied, 23,
  "not authorized"}`. New structured-field assertions (`read_only_db_test.exs`,
  `authorizer_test.exs`) assert `is_integer(code)` and `code &&& 0xFF == 8` / `== 23`;
  ~16 in-repo 2-tuple test/doc sites updated to the 3-tuple (incl. the authorizer
  doctest); `error_reason/0` union updated. Full suite green.
- **ADAPTER BLAST RADIUS (`xqlite_ecto3`, read-only — enumerated, NOT edited).** The
  code carries the shape change: `lib/xqlite_ecto3/error.ex` `Error.wrap/1` has a
  generic 2-tuple clause `wrap({tag, msg}) when is_atom(tag) and is_binary(msg)`
  (`:190`) but NO 3-tuple clause; a `{:read_only_database, 8, msg}` now falls
  through to the `inspect/1` catch-all `wrap(reason)` (`:198`) → `%Error{type:
  nil}`, LOSING the classification. Load-bearing adapter fix owed: add a
  `wrap({tag, ext, msg})` clause. Dependent sites (file:line): `error.ex:190/198`
  (the clause + catch-all); `test/xqlite_ecto3/error_wrap_test.exs:118-123` (unit
  test of `wrap({:database_busy_or_locked, msg})` — still passes but now a STALE
  2-tuple fixture; add 3-tuple coverage); `driver_connect_pragmas_test.exs:136-137`
  (asserts the RAW NIF `{:error, {:read_only_database, _}}` — breaks to 3-tuple);
  `fk_diagnostics_test.exs:222` (asserts wrapped `%Error{type:
  :database_busy_or_locked}` — becomes `type: nil` until the wrap clause lands);
  `telemetry_open_telemetry_test.exs:50` (2-tuple fixture models the shape). No
  `lib/` production code beyond `error.ex` matches these atoms. NOT touched (adapter
  is read-only for this pass).

### Fix 3 — F-A10-4: `:unsupported_atom` discarded the offending atom

- **Mechanism.** `UnsupportedAtom { atom_value: _ } => atoms::unsupported_atom()`
  encoded a BARE atom, dropping the `atom_value` the variant already carried.
- **Fix.** Encode `(atoms::unsupported_atom(), atom_value)` →
  `{:unsupported_atom, "the_atom_name"}`; replaced bare `:unsupported_atom` with
  `{:unsupported_atom, String.t()}` in `error_reason/0`.
- **RED → green.** BEFORE (this session): `NIF.execute(c, "…VALUES(?1)",
  [:some_bogus_atom])` → `{:error, :unsupported_atom}` (bare; the rejected atom is
  gone). AFTER: `{:error, {:unsupported_atom, "some_bogus_atom"}}`.
  `error_input_test.exs` tightened to assert the carried name (3 sites).
- **ADAPTER: benign.** The adapter's generic `wrap({tag, msg})` clause absorbs the
  new 2-tuple (`type: :unsupported_atom`, `details: name` — unchanged type); zero
  `unsupported_atom` grep hits in the adapter.

### Fix 4 — F-A10-6: doubled-`:error` fallback shape (+ 5th site)

- **Mechanism.** Map-build-failure arms encoded `(atoms::error(), err)` →
  `{:error, {:error, {:internal_encoding_error, …}}}`, violating the "leading
  classification atom, never `:error`" shape. Filed sites: `error.rs` ×3
  (`InvalidParameterCount`/`SqlInputError`/`ConstraintViolation`),
  `connection.rs` (`XqliteQueryResult`). A FIFTH identical site not in the filing
  was found by grep and folded in: `schema.rs` `DefaultValue::Blob`'s
  OwnedBinary-alloc-failure arm.
- **Fix.** All five now encode `err` directly → `{:internal_encoding_error, ctx}`
  (already in `error_reason/0`). The `Err(_)` arm can't be dropped (the `Result`
  match needs both arms to typecheck), so emitting the plain structured term is the
  resolution. Practically unreachable (BEAM `map_new`/`map_put` never fail; the
  blob arm is OOM-only) ⇒ no RED; clippy `-D warnings` + full suite green.

### Fix 5 — F-A10-7 / F-A10-8: `error_reason/0` union gaps

- Added `:invalid_transaction_mode` (backs the existing `XqliteNIF.begin/2`
  docstring promise) and `{:cannot_convert_atom_to_string, String.t()}`. Both shapes
  were runtime-confirmed in the round-1 ledger; dialyzer green.

### Fix 6 — F-A12-1: query-vs-stream BLOB backing asymmetry

- **Mechanism.** `encode_val` (query/execute path) wrapped EVERY blob — including
  tiny ones — in a `BlobResource` off-heap resource binary
  (`enif_make_resource_binary`, off-heap + per-object overhead at any size), while
  the stream path copies into an `OwnedBinary` (heap binary when `<= 64 B`). Same
  bytes, different backing; measured (Run 11) ~1.5-3× HEAVIER on the query path for
  many small blobs.
- **Fix.** Made `encode_val`'s blob arm SIZE-ADAPTIVE (helper `encode_blob` +
  `HEAP_BINARY_THRESHOLD = 64`): blobs `> 64 B` still zero-copy-wrap a
  `BlobResource` (the large-blob win preserved — the stream path can't do this,
  working from a transient pointer); blobs `<= 64 B` copy into an `OwnedBinary` → a
  cheap process-heap binary. 64 B is the BEAM heap-binary boundary, so a sub-64 B
  resource binary was pure overhead. This is the filing's OWN first-suggested
  direction ("copy small blobs on the query path too") and STRICTLY improves the
  query path (no large-blob regression), so it needed no maintainer tradeoff ruling
  — the residual large-blob backing difference (query resource-binary vs stream
  OwnedBinary) is benign (query leaner). Small-blob-copy OOM degrades to the wrap
  (graceful, non-panic).
- **Measured before/after (`binary_crossing/run.sh`, RUN this session; harness
  UNMODIFIED).** 100k × 16 B blobs, query path: BEFORE (Run 11) ~128 B/row off-heap
  resource binary (~23 MB `:erlang.memory(:binary)`, the ~1.5-3× heavier case);
  AFTER **0.0 B/row** in the binary allocator (now process-heap binaries) — query
  total 9.32 MB, now LEANER than stream's 13.95 MB (asymmetry flipped to the good
  direction, ratio 1.5×). Large-result (256 B blobs) query stays 448 B/row (still
  wrapped, `> 64 B`). All byte-exact edges (empty / sub-binary / survives-conn-close
  / interior-NUL) PASS; leak-gate PASS; teeth LIVE. New suite regression
  (`blob_test.exs`, inside `for_each_opener`): query round-trips BLOBs byte-exact
  across `{1, 63, 64, 65, 200, 4096}` B — both branches + the 64/65 boundary,
  payloads led by a UTF-8 continuation byte so they bind as BLOB not TEXT.

### Fix 7 — F-A12-2: `blob_read` double-copy

- **Mechanism.** `blob::read` read SQLite into `vec![0u8; actual_len]`, then
  `to_owned_binary` allocated an `OwnedBinary` and copied the Vec into it — 2 allocs
  / 2 memcpys and a transient 2× peak per read.
- **Fix.** Allocate the returned `OwnedBinary` first and `sqlite3_blob_read`
  straight into its `as_mut_slice()`, dropping the staging `Vec`: 1 alloc / 1
  memcpy. `sqlite3_blob_read` fills exactly `actual_len` bytes on `SQLITE_OK`, so no
  uninitialised byte can escape; on error the binary is dropped, never released to
  the BEAM. Mirrors `serialize`'s alloc-then-copy-once. The empty-range short-circuit
  keeps its single 0-byte `to_owned_binary`.
- **Evidence.** Pure efficiency, no behavior change ⇒ no RED. Byte-exactness held by
  the existing `blob_read` suite (partial / past-end-clamp / offset-beyond-size /
  zeroblob / write-read-back / 100 KB chunked / 100 KB at-once) — all green; the
  copy-count halving (2→1 alloc, 2→1 copy) is evident from the diff. A pre-fix
  runtime probe this session confirmed whole/mid-slice/past-end reads byte-exact
  (the post-fix suite re-confirms).

### Disposition & dryness

- All eight assigned filed items closed (F-A10-1/2/4/6/7/8, F-A12-1/2), plus a 5th
  F-A10-6-class site (`schema.rs`) folded in. No new findings filed. `mix verify`
  green (see below). Adapter blast radius for the two error-shape changes
  (F-A10-2, F-A10-4) reported, not edited (adapter read-only).
- CHURN / re-wet: this pass re-wets **A10** (touched `classify_sqlite_error`,
  `From`, the `Encoder`, and `error_reason/0` — squarely A10's re-wet list; the
  owed covering re-run should re-pin the busy/readonly/schema/auth extended-code
  surfacing, the sanctioned-text-parse comment, and the dead-`"interrupted"`
  removal) and **A12** (touched `util.rs encode_val`, `blob.rs read` — A12's re-wet
  list; the owed re-run should re-pin the size-adaptive query-blob backing and the
  single-copy blob_read against `binary_crossing`). A1 posture unchanged-to-slightly-
  improved (F-A10-6 removed five reachable-in-theory doubled-`:error` encodes; no new
  panic surface). Neither axis reaches DRY. Annotated in `REVIEW_AXES.md`.
- **Docs note (flagged, out of scope):** CLAUDE.md's `sqlite3_changes()` note still
  cites the superseded empty-columns detector (already flagged round 1); and the
  `binary_crossing/` harness labels still say "encode_val -> resource binary" for the
  small-blob case, now stale (the harness is CI-isolated and was intentionally not
  modified this pass).

---

## Run 13 — 2026-07-19 — A10+A11 dryness covering re-run

- Commit at scan: `6046806` (HEAD, clean; targets = the two S3 fix passes' churn
  over `1e4bafa` + `287c403`). Scope: a full covering re-run of BOTH axes with
  emphasis on the fresh churn — A10 (structured-error contract: text-parse census,
  extended codes, changes() paths, error-shape contracts, `error_reason/0`
  end-to-end) and A11 (feature islands: backup guard, changeset `:replace` handler,
  blob raw-handle + single-copy read + size-adaptive backing, NUL-in-SQL
  rejection, guide-rot). Composition: single Opus pass (this agent) — adversarial
  source read + a runtime churn-edges probe + re-run of the three CI-isolated
  harnesses + full `mix test.seq`. Every runtime claim RUN this session against the
  bundled SQLite 3.53.2 (commands + output captured); nothing from memory.
  Orchestrator commits.

### A10 — all four sub-areas re-covered, churn attacked at runtime

- **Text-parse census (churn: sanctioned-exception comment + removed
  `"interrupted"` compare).** The four SQLITE_ERROR-1 table/index arms are the only
  message-text classifications outside `constraint_parse.rs`, carrying the
  documented sanctioned-exception comment. The dead `message == "interrupted"`
  catch-all is GONE; interrupts still classify via the code arm — RAN a real
  cancellation of a recursive-CTE query → `{:error, :operation_cancelled}`.
- **Extended codes (churn: F-A10-2 3-tuples).** The four semantic variants encode
  `{atom, extended_code, message}`. RAN: read-only write → `{:read_only_database,
  8, …}` (low8=8); authorizer DELETE deny → `{:authorization_denied, 23, …}`
  (low8=23); 2-conn write contention → `{:database_busy_or_locked, 5, …}` (low8=5).
  The four text-classified variants stay message-only by design (ext invariantly 1).
- **changes() (churn: new `core_query_with_changes` total_changes-delta detector).**
  Re-pinned the full matrix by RUNNING it: plain INSERT=3; INSERT/UPDATE/DELETE
  RETURNING report the TRUE count (2/2/1); SELECT / read-PRAGMA / DDL-after-DML all
  0 with NO stale leak (the F-A10-3 second leg); no-op DELETE=0. Adversarial edges
  the churn invited, all HELD: an AFTER-INSERT TRIGGER → changes reports the OUTER
  statement only (1, trigger rows excluded) while the detector still fires
  (total moved, log row confirmed); SAVEPOINT/RELEASE report 0 (not DML, no leak);
  a cross-database ATTACH INSERT is counted (2) and the following attached-db SELECT
  reports 0; `UPDATE t SET x=x` matching rows reports the matched count. Both
  counters are read after `process_rows` steps to SQLITE_DONE, under the conn Mutex.
- **Shapes + `error_reason/0` end-to-end (churn: F-A10-4/6/7/8 union edits +
  encoder fallbacks).** Cross-checked all 43 `XqliteError` `Encoder` shapes against
  the union — all match (incl. F-A10-4 `{:unsupported_atom, name}` and the five
  F-A10-6 plain `{:internal_encoding_error, ctx}` fallbacks across
  `error.rs`/`connection.rs`/`schema.rs`/`explain_analyze.rs`). The map-build /
  blob-alloc fallback arms are OOM-only (source audit; no RED possible).

### A10 — ONE new finding (S3, filed): F-A10-9

- **F-A10-9 — S3 — CONFIRMED — BACKLOG.** The round-1 `error_reason/0` audit was
  scoped "vs the `error.rs` Encoder" and MISSED the direct-NIF error atoms (the
  `(atoms::error(), <atom>)` returns in `nif.rs` that bypass `XqliteError`). Two are
  absent from the union AND from all of `lib/`: `:extension_loading_disabled`
  (`load_extension/3`, reachable via a well-typed call before enabling extensions —
  the default disabled state) and `:invalid_conflict_strategy` (`changeset_apply/3`,
  reachable only by a param-type violation). Both spec'd `:ok | Xqlite.error()`;
  both are correctly-classified structured atoms — a pure typespec-completeness gap
  (dialyzer "can never match" for a caller matching either atom). Same class as the
  fixed F-A10-5/7/8. RAN this session: load_extension-before-enable →
  `{:error, :extension_loading_disabled}`; changeset_apply bogus strategy →
  `{:error, :invalid_conflict_strategy}`. Filed BACKLOG (fix deferred per the S3
  mandate: add both atoms to the union). The third direct-NIF atom
  `:invalid_pages_per_step` IS in the union (Run 9), so the gap is exactly these two.

### A11 — churned islands re-covered, CLEAN

- **backup (pages_per_step guard).** Source-verified the `< 1` reject →
  `{:error, {:invalid_pages_per_step, n}}` (0 and negatives); a huge positive
  copies-all-in-one-step, no hang. Regression test present + green.
- **session/changeset (`:replace` handler — OPEN maintainer call, NOT changed).**
  RAN the conflict matrix against the implemented ABORT-vs-OMIT behavior:
  replace+CONFLICT (dup PK) overwrites (`:ok`, row→999); omit+CONFLICT skips (`:ok`,
  unchanged); abort+CONFLICT → clean `{:sqlite_failure, 4, 4, _}` (SQLITE_ABORT), no
  change; replace+NOTFOUND (a genuine UPDATE of a missing row, seeded before the
  session so it is not coalesced to an INSERT) → the same clean ABORT-4, no change.
  The handler returns REPLACE only for DATA/CONFLICT and ABORT otherwise — no
  misuse(21) reachable.
- **blob (raw-handle + single-copy read + size-adaptive backing).** RAN
  byte-exactness on BOTH the query path (size-adaptive `encode_val`) and the
  `blob_read` single-copy path across {0, 1, 63, 64, 65, 200, 4096, 1_000_000} B —
  every size byte-identical on both paths, including the 64/65 backing boundary and
  the empty/huge extremes; a partial `blob_read` straddling the boundary is
  byte-exact; a past-end read clamps to `<<>>`.
- **NUL-in-SQL rejection (bypass attempts).** RAN interior-NUL through every
  SQL-text entry point: query / execute / execute_batch / prepare / stream(open)
  all → `{:error, :null_byte_in_string}` (stream returns it eagerly per its
  `Enumerable.t() | error()` spec — never a silently-truncated stream). A
  multi-statement batch `"CREATE TABLE keep(x);\0DROP TABLE keep"` is REJECTED and
  does NOT partially run (`keep` absent afterward). A bound VALUE with an interior
  NUL still round-trips byte-exact (`<<97,0,98>>`) — the guard checks SQL text only.

### Harness runs (all CI-isolated; teeth re-proven; `mix verify` untouched)

- **`error_contract/run.sh` — HARNESS MAINTENANCE + re-run.** Its oracle expected
  the OLD 2-tuple `read_only`/`busy` shapes and pinned the now-fixed F-A10-2/3 as
  open S3 findings. Updated to the post-churn contract: `read_only`/`busy` assert
  the 3-tuple + `extended_code &&& 0xFF` (8 / {5,6}); the changes()-RETURNING pin
  became a positive assertion and gained DDL-no-leak + read-PRAGMA legs. Teeth
  RE-PROVEN: the 11-control selftest gate PASSED first (`SELFTEST_PASS`), then the
  probe → `RESULT PASS contract held, no findings` (was `PASS_WITH_FINDINGS`).
- **`feature_islands/run.sh` — re-run.** The F-A11-4 busy-elapsed footgun still
  reproduces with teeth intact: young + aged-huge-ceiling both SUCCEED (153 ms),
  aged+small-ceiling GIVES UP in 0 ms / 0 retries.
- **`binary_crossing/run.sh` — re-run (re-pins the size-adaptive backing).** Teeth
  LIVE (20000×512 B retention grew the binary counter 10.83 MB, settled on
  release); leak-gate PASS (0.0 MB residual both paths). Small-blob query path =
  0.0 B/row (process-heap binaries, F-A12-1) vs stream 2.0 B/row, total-memory
  ratio 1.4× (query LEANER; under the 10× cliff). S4: a 1000 B blob lands in the
  binary allocator, an 8 B value on the process heap (the 64 B threshold split).
  The harness's "encode_val -> resource binary" small-blob label is now stale (the
  0.0 B/row measurement is correct); harness left unmodified (A12's, CI-isolated).
- **Guides.** `test/nif/fts5_guide_test.exs` runs green in the suite. Churned-surface
  snippets spot-run: `security.md` interior-NUL → `:null_byte_in_string`;
  `gotchas.md` blob/backing behavior consistent with the byte-exact + memory results.
- **`mix test.seq` — full suite GREEN** ("All tests passed!", 66 files), incl. the
  permanent regressions for the churn: blob {1,63,64,65,200,4096} boundary
  (round-2), changeset replace-abort (Run 9), interior-NUL on all SQL entry points
  (Run 9), query_with_changes RETURNING/DDL/PRAGMA matrix (round-1), FTS5 guide.

### Churn-attack table (edge → verdict)

| axis | churn edge attacked | verdict |
|------|---------------------|---------|
| A10 | RETURNING DML (INSERT/UPDATE/DELETE) true count | HELD (2/2/1) |
| A10 | DDL-after-DML stale sticky leak | HELD (0, no leak) |
| A10 | read-PRAGMA / SELECT after DML | HELD (0) |
| A10 | AFTER-INSERT trigger vs changes() | HELD (outer-only 1) |
| A10 | SAVEPOINT / RELEASE (not DML) | HELD (0) |
| A10 | cross-db ATTACH INSERT counted | HELD (2) |
| A10 | no-op / identical-value UPDATE | HELD (0 / matched) |
| A10 | busy/readonly/auth 3-tuple + ext low byte | HELD (5/8/23) |
| A10 | interrupt via code (removed "interrupted" text) | HELD (:operation_cancelled) |
| A10 | error_reason/0 vs direct-NIF atoms | BROKE → F-A10-9 (S3) |
| A11 | backup pages_per_step < 1 | HELD (rejected) |
| A11 | changeset replace/omit/abort × CONFLICT | HELD |
| A11 | changeset replace × NOTFOUND | HELD (clean ABORT-4) |
| A11 | blob byte-exact {0,1,63,64,65,200,4096,1M} × query+blob_read | HELD |
| A11 | blob partial read straddling 64/65 / past-end | HELD |
| A11 | NUL reject: query/execute/batch/prepare/stream | HELD |
| A11 | NUL multi-statement batch no partial run | HELD |
| A11 | bound-value interior NUL round-trip | HELD (byte-exact) |

### Completeness critic

- A10 sub-areas: all four re-covered with the churn (3-tuples, delta-detector,
  removed text-compare, union edits, encoder fallbacks) attacked at runtime. A11
  islands: backup, session/changeset, blob, NUL — the churned surfaces — re-covered;
  the four non-churned islands (serialize, authorizer, hooks, busy footgun) were NOT
  re-audited (covered clean Run 9, no churn since). Honest gaps: (1) SQLITE_SCHEMA
  (17) 3-tuple not reproduced at runtime (hard to force) — source-verified only;
  (2) the OOM-only encoder fallbacks have no RED — source audit only; (3) no
  TSan/Miri on the live NIF (Miri can't run the bundled C SQLite — Runs 2/4/5); the
  oracle is behavior + exit-code + the source audit bounded by THREADSAFE=1 +
  single-Mutex.

### Disposition & dryness

- **A10: covering re-run done — 0 new S0/S1/S2, ONE new CONFIRMED S3 (F-A10-9)
  filed to BACKLOG.** The `error_contract` oracle was updated to the post-churn
  contract (harness maintenance, teeth re-proven) and passes with no findings.
  Because a new CONFIRMED finding surfaced, this run is NOT a clean covering run:
  A10 stands at **0 of 2** consecutive clean covering runs (re-wet by both S3 fix
  passes; residual union gap now filed). NOT DRY. Re-wet triggers unchanged
  (`error.rs` classify/Encoder/From, the raw-FFI builders, `constraint_parse.rs`,
  the `query_with_changes` detector, the `error_reason/0` typespec).
- **A11: CLEAN — zero new findings (S0/S1/S2/S3).** Every churned island held under
  runtime attack; the three harnesses + full suite are green. This is the **first
  of two** consecutive clean covering runs after the Run-9 + S3-fix-pass churn
  re-wet A11; **one more clean covering run owed** before DRY. Re-wet triggers
  unchanged (nif.rs backup guard / changeset handler, `query.rs core_*`, any
  session/blob/backup/serialize/authorizer/hook code, `busy_handler.rs`,
  `util.rs encode_val`, `blob.rs read`, or any guide edit).
- `mix verify` GREEN (below). No S0/S1/S2 anywhere; the sole finding is the S3
  union gap. Only intended files changed: `error_contract/probe.exs` (oracle
  maintenance), `REVIEW_LEDGER.md`, `REVIEW_AXES.md`, `BACKLOG.md`.
