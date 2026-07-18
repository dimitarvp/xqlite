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
