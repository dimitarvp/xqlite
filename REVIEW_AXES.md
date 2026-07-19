# Review axes — xqlite

The operative axis list for the adversarial review program (charter:
`~/kod/FLEET_REVIEW_BOOT.md`; this file + `REVIEW_LEDGER.md` +
`BACKLOG.md` are the program's durable state). The adapter's axes and
the cross-repo axes live in `xqlite_ecto3/REVIEW_AXES.md`.

## Constitution (applies to every run, both repos)

- **Waves:** finders (one per in-scope axis) + adversary stances
  (data-loss prosecutor, UB prosecutor, assumption auditor,
  interleaving attacker, blast-radius enumerator, cold adopter) →
  orchestrator dedup **by mechanism** → refuters (one per deduped
  finding, posture REFUTE; verdicts CONFIRMED / PLAUSIBLE / REFUTED)
  → orchestrator re-verifies every CONFIRMED against the code.
- **Hard rules:** agent claims about runtime behavior are
  inadmissible (orchestrator re-runs them against the BUNDLED
  SQLite); fleet spec written for owner sign-off before launch;
  ledger updated when wave 1 returns; every CONFIRMED gets RED repro
  → fix → `mix verify` → commit/push → ledger append; PLAUSIBLE gets
  a deciding probe or a backlog entry; nothing is silently dropped;
  close-out reconciles by grep-at-HEAD, never session memory;
  refactor-touched assertions must be ≥ original strength.
- **Severity:** consequence × reachability. **Ratified bar
  (2026-07-17): S0–S2 block the adapter first publish and the
  announcement** (waiver = Dimi, recorded in ledger +
  announcement-honesty ledger); S3 never blocks, never dropped —
  backlog + a committed post-burn-down pass. S0 = crash/UB/
  corruption/lost-writes/wrong-results · S1 = public-API panic,
  documented-path hang, unbounded leak, silent data transformation,
  success-on-failed-write · S2 = wrong error classification,
  doc-behavior divergence, bounded leak, ≥10× perf cliff · S3 =
  ergonomics/docs/naming. Rationale: these libraries aim to be
  critical infrastructure; complete rigor is non-negotiable.
- **Tiering:** mechanical finders → haiku/sonnet; correctness/UB/
  concurrency → opus minimum; adversaries/refuters/synthesis →
  strongest available.
- **Dryness:** an axis is DRY after two consecutive covering runs
  with zero new CONFIRMED; code churn in its scope re-wets it. A
  completeness critic closes every run.

## Axes

Fields: why it bites here · authoritative sources · seed probes ·
coverage state (updated per run; dryness lives in the ledger).

### A1. Panic-freedom — PRIORITY 1
"Panic-free / will never crash the BEAM" is public on Hex. Sources:
rustler source at the LOCKED version (0.38.0), rusqlite 0.40.1
source, our `unsafe` blocks. Seed probes: **rustler resource
destructors/`down`/`dyncall` have NO catch_unwind at 0.37/0.38
(source-verified in wave 1)** — enumerate every Drop impl on our
resources (conn, statement, stream, blob, session, token, hook
state) for panic-capable constructs; **poisoned-Mutex
`.lock().unwrap()` in a Drop = two-step chain to VM death**; any
callback registered via raw FFI (progress handler, master hook
callback, busy slot) needs our own unwind guard — rusqlite's own
trampolines are protected only where we go through its safe APIs;
unwrap/expect/index/overflow census on NIF-reachable paths; clippy
`undocumented_unsafe_blocks`. Even a CAUGHT panic surfaces as
opaque `:nif_panicked` (rustler discards the payload) — for the
public claim, any reachable panic is a broken promise (≥S1).
Coverage: none yet — no census run. Touched (S3 fix pass round 1,
2026-07-19): M10 removed 24 reachable-in-theory `map_put(…).unwrap()` from
`explain_analyze.rs`'s encoders (→ graceful `InternalEncodingError`), and M11
was verified already-resolved (`b1c60b4`) — both strictly shrink the panic
surface, but no census has run.
COVERING RE-RUN (Run 16, 2026-07-19): the FIRST full A1 census (whole crate at
HEAD, churn since `61cf771` hardest). unwrap/expect/panic/index/div-mod census
CLEAN (zero non-test unwrap/expect; the only integer `%` is `is_multiple_of`;
release wraps overflow, panic=unwind); all 7 Drop impls poison-safe (session
`into_inner`, rest `map_err→LockError`) + panic-free; all 3 raw `extern "C"`
callbacks M6-guarded; the alloc census caught the finding. ONE new CONFIRMED S0
(F-A1-1) + FIXED RED→GREEN: `stream_fetch`'s `Vec::with_capacity(batch_size)`
trusted an unbounded `pos_integer()` user arg → `handle_alloc_error` → `abort()`
(SIGABRT, uncatchable) → BEAM crash on `batch_size ≈ 1e13` (RED = child exit 134,
proven this session; GREEN = exit 0 after `Vec::new()`, matching the immune
sibling `stmt_multi_step_impl`); regression test in the `connection_openers`
for-loop. DRYNESS: a new CONFIRMED surfaced (and the fix churns `stream_fetch`),
so this is NOT clean — A1 stands at **0 of 2 consecutive clean covering runs, NOT
DRY**; two owed. Re-wet: any new unwrap/expect/index/`/`/`%`/
`with_capacity(user-value)`, any new Drop or raw callback, a `guard_ffi_callback`
change, or a rustler bump.

### A2. The locking law — PRIORITY 1
Every `sqlite3_*` call must hold the connection Mutex for its full
duration; `AtomicPtr` ownership ≠ connection access (we shipped that
bug once). Sources: CLAUDE.md critical rule; exqlite PR#342 (their
21-function audit of this exact class — the checklist shape).
Seed probes: enumerate EVERY raw call site in stream.rs /
statement.rs / nif.rs and prove lock coverage; NULL-guard placement
AFTER acquire, not before (check-then-use); cancel-vs-close
interleavings (the cancel path can't take the main lock — audit its
dedicated synchronization); swap/finalize windows under concurrent
finalize. Coverage: house rule + regression from the shipped bug;
no systematic call-site audit yet.
COVERING RE-RUN (Run 16, 2026-07-19): the FIRST systematic call-site audit — every
`sqlite3_*`/`ffi::` call site enumerated by `rg` at HEAD and classified against its
lock evidence (full table in the ledger). VERDICT: every C call holds the connection
Mutex for its full duration (`with_conn`/`with_conn_mut`/`with_live_stmt`/
`with_live_blob`/`with_session`, the swap-then-lock `take_and_finalize_raw`, or a
callback that fires under the lock); `sqlite3_libversion` is the only process-global
(no conn needed); `sqlite3_config` under `MASTER_LOCK`. Re-verified over the churn:
`conn.changes()`/`total_changes()` (F-A10-3) called INSIDE `with_conn`; the blob
rewrite's every `sqlite3_blob_*` under `with_live_blob`/`close`; the `stream_fetch`
finalize windows under the held guard (poison path finalizes only because a poisoned
lock excludes any holder); cancel-guard unregister under the held conn Mutex (W3); the
stream AtomicPtr swap-then-lock discipline intact at the historical-bug site. ZERO new
CONFIRMED. DRYNESS: Run 2 was A2's last clean covering pass but Runs 7/9/10 + both S3
fix passes churned this scope (blob rewrite, backup guard, changeset handler,
`reject_interior_nul`, error 3-tuple, `core_query_with_changes`, adaptive blob /
single-copy read) → RE-WET; Run 16 is the **first clean covering run over that churn —
1 of 2 consecutive, NOT DRY**, one more owed. (The F-A1-1 fix touched only
`stream_fetch`'s allocation, not lock discipline.) Re-wet: any new `sqlite3_*`/`ffi::`
site, a `with_*`/`take_and_finalize_raw` restructure, a new AtomicPtr resource, or a
cancel-path/hook-registration change.

### A3. UB tooling
Sources: Miri/ASan/TSan/cargo-careful docs. Probes: separability of
core logic from the NIF shim (inseparability is itself a finding);
sanitizer suite runs; clippy pedantic triage once. Coverage: none.

### A4. Scheduler discipline
NIFs must be <1ms proven or Dirty (CPU vs IO correctly chosen).
Probes: per-NIF classification table; `erlang:system_monitor`
long_schedule gate over the full suite. Coverage: Run 10 — first
dedicated covering measure+gate run (`scheduler/run.sh`, CI-isolated).
All 96 NIFs classified (census CONFIRMED 62/34 pre-fix → 71/25 post-fix,
0 DirtyCpu). Mechanism runtime-established: `long_schedule` fires for a
long NORMAL-scheduler NIF, NEVER for a Dirty one (1570 ms Dirty query →
0 events; 135 ms normal `blob_read` → 1) — so the gate is a valid A4
detector and a flip-to-DirtyIo is a real move, not a blind spot; PID
attribution (NIF schedule-in MFA is `:undefined`); fix-independent
`term_to_binary/[:compressed]` teeth control delivered 35 events every
run. ONE S2 mechanism CONFIRMED + FIXED (RED→GREEN): 9 session/blob/
changeset NIFs (`blob_open`/`blob_read`/`blob_write`/`blob_reopen`,
`session_changeset`/`session_patchset`/`session_delete`,
`changeset_invert`/`changeset_concat`) ran unbounded / DB-file work on
the normal scheduler (RED 28–248 ms, 1 hit each; the 6 unbounded ones
measured, `session_delete` 14.9 ms wall, `blob_open`/`reopen` coherence)
→ `schedule = "DirtyIo"`, all now 0 hits. ONE S3 (F-A4-1): the 20
conn-`Mutex` trivial normal readers block a normal scheduler for a
concurrent slow op's whole duration ONLY under cross-process handle
SHARING (measured ~1.45–1.49 s; against the documented single-owner
design) → BACKLOG + `guides/gotchas.md`. Blanket-DirtyIo (0 DirtyCpu)
RULED correct (every Dirty NIF blocks on I/O-class waits; DirtyCpu is
the wrong pool). The 25 normal NIFs are all PROVEN-FAST (LAT ≤ 60 µs
uncontended / O(1)-bounded). NOT yet DRY (first covering run; one more
owed). Churn re-wets: any new `#[rustler::nif]`, any `schedule=` change,
any new blocking work / lock a normal NIF does under the conn `Mutex`, or
a `with_conn`/`with_session`/`with_live_blob`/`with_live_stmt` restructure.

### A5. Cancellation semantics
8-VM-step progress-handler cadence, un-tuned. Probes: cancel latency
bounds; cancel-vs-completion race (what does the caller see?);
token reuse + stale-cancel-vs-next-operation; token lifecycle under
process death; overhead when never cancelled; cancel racing
connection teardown (sibling drivers shipped this). Coverage: Run 6 —
one covering adversarial+probe pass (`cancellation/run.sh`,
CI-isolated). All five windows HOLD (W1 cancel-vs-completion:
interrupt→`OperationCancelled` at `error.rs:668`, results Vec dropped
on Err so never torn; W2 token reuse: set-once `Arc<AtomicBool>`, no
reset path → SINGLE-USE footgun, S3 doc backlog; W3 cancel-vs-teardown,
DEEPER than A7: guard holds its own Arc clone + unregisters-before-
release under the conn Mutex, `close_connection` locks the same Mutex
`connection.rs:170-176`; W4 process death: guard clone keeps the flag
alive, clean refcount; W5 multi-token OR + double-cancel idempotent).
5 probes (latency / race / reuse / overhead / teardown) all PASS with
four teeth (CRASH-134, HANG-124, latency-validity-124, TORN-3) proven
to trip. Cancel latency median 55 µs (≤8-VM-op floor); race 300 hits
156 cancelled/144 completed/0 torn; teardown 400 iters + ~57 GC-drop
legs, 0 crash/hang/torn; never-cancelled marginal overhead ≈0–1.5%
(INFORMATIONAL, T4.7). 0 S0/S1/S2; one S3 doc-clarity (token
single-use). NOT yet DRY (first dedicated latency/race/reuse/teardown
matrix; one more owed; cancel.rs / progress_dispatch.rs / guard-scoping
churn re-wets).
COVERING RE-RUN (Run 17, 2026-07-19): re-verified all five windows at HEAD `9abf27e`.
`cancel.rs`/`progress_dispatch.rs`/`hook_util.rs` are a ZERO diff vs the Run-6 baseline
`4253b26` (M6/M7 predates it); re-wetting is ADJACENT — `query_with_changes_cancellable`
now runs `core_query_with_changes` (F-A10-3) INSIDE its `with_conn`+guard closure (a
mid-statement cancel short-circuits to `Err`, no cancel-vs-changes torn window), and the
`stream_fetch` interrupt path W1 relies on churned (F-A1-1). All five guard sites
(`nif.rs:157/179/196/212/953`) still drop before the conn Mutex releases (W3); DirtyIo
flips register no cancel guard. RE-RAN `cancellation/run.sh`: VERDICT PASS, 4 teeth
(CRASH-134/HANG-124/latency-validity-124/TORN-3) tripped; latency median 57 µs (40/40
cancelled), race 169/131/0-torn (300 iters), reuse single_use=true/auto_reset=false/
multi_token_or=true, teardown 271 cancelled/85 conn_closed/44 stmt_finalized/0 torn/0 crash
(400 iters + ~57 GC-drop legs). CLEAN — zero new CONFIRMED. DRYNESS: **1 of 2 consecutive
clean covering runs, NOT DRY** (Run 6 re-wet by the adjacent changes-detector + stream
churn; one more owed). Re-wet triggers unchanged.

### A6. Resource lifecycle
Probes: hostile drop orders (statement outliving conn; conn closed
with live statements; stream abandoned mid-iteration then GC'd);
destructor thread context vs SQLite thread-affinity; open/close
×10⁵ under RSS; double-finalize windows; cross-handle immunity
(XqliteStatement embeds its conn ResourceArc — verify structurally);
owning/non-owning aliasing census (any `from_handle`-style views?).
Coverage: Run 5 — one covering adversarial+probe pass
(`lifecycle/run.sh`, CI-isolated). Static audit of every lifecycle
window HOLDS (drop-once swap/take, raw-handle locking on every
SQLite-touching Drop, child-embeds-conn-ResourceArc immunity,
STRUCTURAL cross-handle immunity, aliasing census [blob raw-ptr,
session `PhantomData` Drop], `THREADSAFE=1` destructor context, conn
field-drop order). 6 leak loops (conn mem ×10⁵ / file ×30k, stmt /
stream / blob / session ×10⁵) all PASS RSS-steady & fd-stable;
hostile drop-order matrix (child-op-after-close, close-with-live-
child GC-drop, stream-abandoned-mid-iter, double-close,
drop-after-close, child-GC-while-open) PASS no-crash; 3 teeth
(conn / stmt / blob retain) proven to trip LEAK (>10× separation).
Documented conn-close-with-live-child leak quantified = one
`sqlite3*`/occurrence (~77 KB, bounded). 0 findings. NOT yet DRY
(first dedicated A6 covering run; one more owed; any resource-Drop /
AtomicPtr / conn-field-order / hook-registration churn re-wets).
COVERING RE-RUN (Run 17, 2026-07-19): re-verified every lifecycle window at HEAD `9abf27e`.
`session.rs`/`statement.rs`/`stream.rs` = ZERO diff vs the Run-5 baseline `51bbcb6`;
`connection.rs` = 1 line (F-A10-6 Encoder `err.encode`, NOT a Drop/field-order/AtomicPtr
change); `blob.rs` churned (single-copy read F-A12-2) but `Drop`→`close()` swap-then-lock is
byte-identical (change is internal to the read op — fills exactly `actual_len` on OK, drops
on error). The 9 DirtyIo flips are ATTRIBUTE-ONLY (`git show 8356dde`) — a `Drop` runs on a
GC/scheduler thread regardless of the schedule attribute; `THREADSAFE=1` makes thread
identity irrelevant, so no new drop/leak window. RE-RAN `lifecycle/run.sh`: VERDICT PASS, 3
teeth TRIPPED LEAK; 6 leak loops fd-stable 19→19 (conn mem −5.59 MB / file −6.55 MB, stmt
0.0 MB, stream −0.64 MB, blob −1.86 MB [single-copy read exercised 10^5×, no leak], session
+1.09 MB noise); hostile drop-order matrix 0 unexpected/no crash; documented
conn-close-with-live-child leak = 77,346 B/occurrence (one `sqlite3*`, unchanged). CLEAN —
zero new CONFIRMED. DRYNESS: **1 of 2 consecutive clean covering runs, NOT DRY** (the strict
Drop/AtomicPtr/field-order triggers did NOT fire, but the blob resource module churned +
DirtyIo moved blob/session scheduler → conservatively re-wet; one more owed). Re-wet
triggers unchanged.

### A7. Concurrency / interleaving
Probes: N-process hammering one handle; owner-process death mid-txn;
busy policy/observer split under real write contention; attempt to
reproduce rusqlite#1860 (open/close-churn VFS deadlock, OPEN
upstream) at our versions. Coverage: Run 4 — one covering
adversarial+probe pass (`concurrency/run.sh`, CI-isolated). Static
audit of all five interleaving windows HOLDS (swap-then-lock /
lock-then-load, conn-Mutex-serialised hook COW, lock-free cancel
store, N-handles, owner-death); 5 probes (hammer / owner-death /
orphan-txn / busy / churn) all PASS, with five teeth (byte-smash,
payload-tamper, hammer-drop, busy-drop, sleep-forever) proven to
trip. Substrate: bundled SQLite THREADSAFE=1 + MUTEX_PTHREADS
(runtime-verified) → globals mutex-protected; #1860 does NOT
reproduce at 3.53.2. 0 findings. NOT yet DRY (one covering run; one
more owed; AtomicPtr/close/open or hook-registration churn re-wets).
COVERING RE-RUN (Run 17, 2026-07-19): Run 4 was PRE-churn, so this is honestly a FRESH
covering run over the post-Run-4 code (M6 `guard_ffi_callback` on the raw progress callback,
F-A10-2 3-tuple errors, blob rewrite/single-copy read, the 9 DirtyIo flips), not a simple
+1. All five interleaving windows re-verified at HEAD `9abf27e`: swap-then-lock /
lock-then-load intact; the M6 wrapper only adds panic safety (progress still fires inside
`sqlite3_step` under the conn Mutex, serialised vs register/unregister); `session_changeset`/
`patchset` now DirtyIo fire progress from their internal SELECT but `with_session_mut` locks
the conn Mutex FIRST (`session.rs:109-113`) — the flip changes only the scheduler thread, not
the lock (M5 HOLDS). HARNESS MAINTENANCE forced by F-A10-2: `concurrency/probe_common.exs`
`Probe.insert` matched the stale 2-tuple `{:database_busy_or_locked, _}`; a live BUSY now
surfaces as the CORRECT 3-tuple `{…, 5, "database is locked"}` (ext-code 5 = SQLITE_BUSY),
which fell through → Probe 2's CONTROL leg emitted a FALSE CORRUPTION → verdict silently
degraded to PASS-WEAK (control teeth broken). RED captured, pattern fixed to
`{:database_busy_or_locked, _ext, _msg}`, GREEN: control leg restored to RECOVERED_BUSY (the
3-tuple-under-live-race confirmation). RE-RAN `concurrency/run.sh`: VERDICT PASS, 5 teeth
tripped; hammer 4800/4800, busy 300 rows/5 busy_events, churn 601 rows/1200 opens (#1860 no
repro), owner-death control RECOVERED_BUSY / test RECOVERED_WROTE, orphan-txn PASS. ZERO new
CONFIRMED product findings (the fix is review-infra, not product). DRYNESS: **1 of 2
consecutive clean covering runs, NOT DRY** (fresh covering run over post-Run-4 churn; one
more owed). Re-wet triggers unchanged.

### A8. Durability crash-harness — crown jewel
Probes: writer → `kill -9` the VM at random points → reopen →
`PRAGMA integrity_check` + row-count/checksum invariants → repeat
hundreds of times × {WAL, rollback journal}. Automate; distinguish
churn-deadlock (A7) from corruption. Coverage: harness built
(`durability/run.sh`) + one covering run (Run 3) — {WAL, DELETE}×200 on
xqlite defaults + deterministic & realistic-unsafe negative controls; 0
corruption/lost-write/hang, teeth proven. NOT yet DRY (one covering run);
process-kill ≠ power-loss (fsync/`synchronous` untested vs true power
loss); commit/open-path churn re-wets.

### A9. Type/value edges
Probes: Elixir bignums beyond i64 (error or truncation?); NaN/
Infinity (SQLite stores NaN as NULL — document + pin our policy);
interior NUL round-trips (write path fixed `a7dc84e`; probe read
paths); invalid-UTF-8 read-back end-to-end (rusqlite fixed 0.39 —
pin OUR behavior); SQLITE_MAX_LENGTH / MAX_VARIABLE_NUMBER edges;
offset-preserving DateTime TEXT vs ORDER BY (mixed offsets don't
sort chronologically — wrong-results class + decision-debt);
encode-only types' read-back story. Coverage: Run 7 — one covering
value-edge run (`type_edges/run.sh`, CI-isolated), byte-exact oracle
with proven teeth. Every round-trip HELD (bignum i64-boundary/over →
clean error nothing-stored; interior-NUL TEXT+BLOB byte-exact via
query/stream/step/blob_read; invalid-UTF-8 → structured
`{:utf8_error,…}` on query+step; MAX_VARIABLE_NUMBER + MAX_LENGTH →
clean `sql_input_error`/`SQLITE_TOOBIG`; Instant encode-only → raw
int64). TWO S1 findings: F1 reading ±Inf raises `ArgumentError` on
every read path (`enif_make_double` has no finiteness guard at
`util.rs:26`/`sqlite_row_to_elixir_terms`; conn stays usable; schema
layer DOES guard non-finite at `schema.rs:302` — inconsistent), F2
stream swallows a mid-fetch error into `Logger` + silent truncation
(`stream_resource_callbacks.ex:89-102`; query/step surface it). TWO
decision-debt: D1 offset-preserving DateTime TEXT sorts lexically not
chronologically under ORDER BY (value round-trips; only the sort is
wrong), D2 stored NaN→NULL (SQLite behavior, undocumented). 0 S0.
NOT yet DRY (first value-edge run; one more owed; F1/F2 fixes or any
`util.rs` encoder / stream-fetch / type_extension-encoder churn
re-wets). Findings → BACKLOG + ledger Run 7.

### A10. Structured-error contract
Probes: audit remaining text-parsing paths ("mostly succeeded" —
find the exceptions); extended result codes surfaced everywhere
(enum-vs-C-constant gotcha #2 is the cautionary tale); changes()
stickiness on every path; error-shape structural contracts
(Exception.message always binary; no shape a `with` can't match).
Coverage: Run 8 — one covering adversarial+probe pass, SURFACE-ONLY
(`error_contract/run.sh`, CI-isolated). All four sub-areas HOLD with
gaps: (1) text-parse census — `constraint_parse.rs` sanctioned, but
`error.rs:689-704` (no-such-table/index, table/index-exists via
message-substring) + `error.rs:786` (`== "interrupted"`) are the
exceptions (F-A10-1); (2) extended codes — rusqlite UNCONDITIONALLY
enables EXRESCODE (source-verified `inner_connection.rs:81`), every
raw-FFI builder + safe API converge on `classify_sqlite_error` with
the extended code intact, C-constant `& 0xFF` matching (gotcha #2
correct), but the semantic variants drop the code (F-A10-2); (3)
`changes()` — `query_with_changes` zeroes non-DML by empty-columns
(correct), `changes/1` sticky by design, but RETURNING DML is
misdetected → `changes:0` (F-A10-3); (4) shapes — every variant →
bare atom or `{atom,…}` tuple, all `with`-matchable, `Exception.message`
(StreamError) always binary; gaps F-A10-4 (`:unsupported_atom` drops
its atom), F-A10-5 (`error_reason/0` omits `{:invalid_open_option,_}`),
F-A10-6 (latent doubled-`:error` fallback). Probe: 16 conditions
(unique/not-null/check/PK/FK/datatype constraints, syntax, bind
conversion, TOOBIG, conn-closed, stmt-finalized, execute-returned-
results, read-only, SQLITE_BUSY via real 2-conn contention, StreamError,
RETURNING changes), ~60 assertions all HELD, 11-control teeth gate
(the wrong-kind tooth caught a real oracle bug pre-run). Specific
constraint-kind atoms (unique=2067, PK=1555, …) are the extended-code
proof. 0 S0/S1/S2, 6 S3 (F-A10-1…6) — surface-only, filed to BACKLOG,
NOT fixed. NOT yet DRY (first covering A10 run; one more owed; churn in
`error.rs` classify/Encoder/From, the raw-FFI builders, or the
`error_reason/0` typespec re-wets). RE-WET (S3 fix pass round 1,
2026-07-19): F-A10-3 replaced the `query_with_changes` changes()-detection
(empty-columns → `total_changes`-delta) and F-A10-5/F-A11-5 corrected the
`error_reason/0` union — both squarely in this axis's churn list; two new S3
union gaps filed (F-A10-7 `:invalid_transaction_mode`, F-A10-8
`:cannot_convert_atom_to_string`). The owed covering re-run should re-pin the
RETURNING/DDL/PRAGMA changes() matrix and the corrected specs. RE-WET (S3 fix pass
round 2, 2026-07-19): the remaining six A10 items fixed — F-A10-2 added
`extended_code` to the four busy/readonly/schema/auth variants (now
`{atom, ext, msg}`); F-A10-4 made `:unsupported_atom` carry the atom
(`{:unsupported_atom, name}`); F-A10-1 documented the four SQLITE_ERROR-1
text-parse arms as a sanctioned exception AND removed the dead `== "interrupted"`
catch-all (interrupt is code-classified); F-A10-6 replaced five doubled-`:error`
encodes with plain `{:internal_encoding_error, …}` (incl. a 5th un-filed
`schema.rs` site); F-A10-7/8 closed the `error_reason/0` union. This churns
`classify_sqlite_error` / `From` / the `Encoder` / the raw-FFI classification and
`error_reason/0` — all in A10's re-wet list. The owed covering re-run should re-pin
the busy/readonly/schema/auth extended-code surfacing, the sanctioned-text-parse
comment, the dead-code removal, and the two new/changed union members.
COVERING RE-RUN (Run 13, 2026-07-19): the owed re-run over the churn. RAN the
changes()-delta matrix (RETURNING INSERT/UPDATE/DELETE true count, DDL/read-PRAGMA/
SELECT no stale leak, AFTER-INSERT trigger → outer-only count, SAVEPOINT/RELEASE 0,
cross-db ATTACH counted, no-op/identical UPDATE) — all HELD; the busy/readonly/auth
3-tuple + `extended_code &&& 0xFF` (5/8/23) — HELD; interrupt via the code arm
(removed `"interrupted"` text-compare) → `:operation_cancelled` — HELD; all 43
Encoder shapes re-checked vs `error_reason/0`. Updated the `error_contract/` oracle
to the 3-tuple + delta-detector contract (11-control teeth re-proven, `RESULT PASS
no findings`). ONE new S3: F-A10-9 (direct-NIF atoms `:extension_loading_disabled` +
`:invalid_conflict_strategy` omitted from `error_reason/0` — the round-1 audit was
Encoder-scoped). DRYNESS: a new CONFIRMED (S3) surfaced, so this is NOT a clean
covering run — A10 stands at 0 of 2 consecutive clean covering runs, NOT DRY;
re-wet list unchanged.

### A11. Feature islands
Session/changesets, blob I/O, backup+progress, serialize,
authorizer, hooks — one adversarial pass each; every guide's code
EXECUTES (FTS5 guide is linear-executable — make it a test;
SpatiaLite is doc-first exempt). Coverage: Run 9 — first dedicated
covering pass (adversarial static audit of all six islands from six
stances + build-and-measure probes + guide-snippet execution). Run
1–2 blob/session/log S0 fixes re-verified HOLDING at HEAD by reading
the code. THREE S0-S2 CONFIRMED + FIXED (RED-then-green, regression
tests in `test/`): F-A11-1 (S1) `backup_with_progress` looped forever
on `pages_per_step <= 0` (`step(0)` copies nothing, reports "more") —
pinned conn + flooded pid; now rejected `{:invalid_pages_per_step,n}`
at the NIF boundary. F-A11-2 (S2) `changeset_apply(:replace)` returned
`SQLITE_MISUSE` on CONSTRAINT/NOTFOUND/FK conflicts (illegal REPLACE
return); handler now REPLACEs only DATA/CONFLICT and ABORTs otherwise
(clean SQLITE_ABORT, no data change). F-A11-3 (S2) the Security guide's
"NUL in SQL text is rejected, not truncated" was FALSE for
`query`/`execute`/`execute_batch` (rusqlite prepares length-delimited,
SQLite truncates at the NUL); `reject_interior_nul` added at the three
`core_*` choke points so every SQL-text path now returns
`:null_byte_in_string` (bound-value NULs still round-trip). TWO S3 →
BACKLOG: F-A11-4 busy-policy `max_elapsed_ms` anchored at install not
per-event (footgun on long-lived conns; documented + gotcha'd; teeth-
proven in `feature_islands/run.sh`); F-A11-5 `error_reason/0` says
`{:utf8_error, String.t()}` but actual/guide is the 3-tuple. Guides:
`full_text_search.md` codified as `test/nif/fts5_guide_test.exs` (A11
seed CLOSED); `spatialite.md` factual-skimmed (R*Tree/FTS5/API_ARMOR
compile-options verified); every `gotchas.md`/`security.md`/
`wiring_telemetry.md` snippet executed PASS (one security snippet was
the F-A11-3 finding). NOT yet DRY (first covering run; one more owed).
Churn re-wets: `nif.rs` backup guard / changeset handler, `query.rs`
`reject_interior_nul` + `core_*`, any session/blob/backup/serialize/
authorizer/hook code, `busy_handler.rs`, or any guide edit. RE-WET (S3 fix
pass round 1, 2026-07-19): F-A10-3 added `query::core_query_with_changes` (a
new `query.rs` `core_*`) and rewired the `query_with_changes` NIFs.
COVERING RE-RUN (Run 13, 2026-07-19): the owed re-run over the churn. RAN the
changeset `:replace` conflict matrix (replace/omit/abort × CONFLICT + replace ×
NOTFOUND → clean SQLITE_ABORT-4, no misuse-21, no data change — the maintainer's
ABORT-vs-OMIT semantics unchanged), blob byte-exactness on the query path
(size-adaptive `encode_val`) AND `blob_read` (single-copy) across {0,1,63,64,65,200,
4096,1_000_000} B incl. the 64/65 boundary + partial-straddle + past-end-clamp, the
backup `pages_per_step < 1` guard, and interior-NUL rejection on query/execute/
execute_batch/prepare/stream + no-partial-batch-run + bound-value byte-exact
round-trip. Re-ran `feature_islands/run.sh` (F-A11-4 reproduces, teeth held) and
`binary_crossing/run.sh` (size-adaptive backing confirmed: small-blob query 0.0 B/row,
>64 B→binary-alloc / ≤64 B→process-heap; teeth LIVE, leak-gate PASS); FTS5 guide test
green in the full suite. CLEAN — zero new findings. DRYNESS: first of TWO consecutive
clean covering runs after the Run-9 + S3-fix-pass re-wet; one more clean covering run
owed before A11 is DRY. Re-wet list unchanged.

### A12. Binary crossing
Probes: copy vs refcounted binaries across the boundary; memory
profile of large result sets; iodata acceptance on the way in.
Coverage: Run 11 — first dedicated covering run (source audit against the
LOCKED rustler-0.38.0 `Binary`/`OwnedBinary`/`make_binary` semantics +
build-and-measure `binary_crossing/run.sh`, CI-isolated). INBOUND map:
SQL text + params always COPY into owned rusqlite `Value`/`String`;
`blob_write`/`deserialize`/`changeset_*` take a ZERO-COPY `Binary::as_slice`
view consumed synchronously (SQLITE_TRANSIENT / `Cursor`). No `Binary`/`Term`/
slice stored in any resource → no view escapes its env (no use-after-env UB);
sub-binary of a huge parent never retained past the call (E2). OUTBOUND map:
TEXT + column names COPY via rustler `str::encode`; stream/step BLOB copies into
`OwnedBinary`; the query path BLOB is ZERO byte-copy via
`enif_make_resource_binary` wrapping the owned `Vec` (refcounted, keeps the Vec
alive independent of the local ResourceArc — source-verified). NO SQLite-owned
view escapes: every column view is copied before return, and the one zero-copy
path wraps OWNED memory (RUNTIME-PROVEN independent of the conn — a query blob
stays byte-exact after `close/1` + GC, E3). Hook payloads (`enif_make_new_binary`
into `msg_env`) are bounded (identifiers / log message / counts, never caller-
data-sized) and leak-free (alloc/free balanced 1:1 in all 8 senders; M4 holds).
iodata REJECTED everywhere (rustler decodes binaries only; `from_iolist` unused);
all specs `binary()`/`String.t()`, consistent — iolist SQL → ArgumentError,
iolist param → `{:unsupported_data_type, :list}` (E5). MEASURED (100k rows):
leak-gate PASS (0.0 MB residual after holder death, both paths); streaming
consume-and-discard peak 68.5× below full-query materialization; query-vs-stream
BLOB total-memory asymmetry 1.3× (large, query leaner) to ~1.5–3× (tiny blobs,
query heavier) — under the 10× cliff; teeth (a 20k×512 B retention control)
proven to grow + settle the `:erlang.memory(:binary)` counter. 0 S0/S1/S2; THREE
S3 (F-A12-1 query-vs-stream resource-binary/OwnedBinary asymmetry → BACKLOG +
gotchas; F-A12-2 `blob_read` double-copy → BACKLOG; F-A12-3 latent/OOM-only
`str::encode` alloc-panic vs graceful BLOB encode → BACKLOG). NOT yet DRY (first
covering run; one more owed). Churn re-wets: `util.rs` `encode_val` /
`sqlite_row_to_elixir_terms` / param decoders, `blob.rs` read/write,
`session.rs` `to_owned_binary`, `serialize`/`deserialize`/`changeset_*`,
`hook_util.rs` `make_binary` / any hook payload, or a rustler bump. RE-WET (S3 fix
pass round 2, 2026-07-19): both A12 items fixed — F-A12-1 made `util.rs encode_val`'s
blob arm size-adaptive (`<= 64 B` → heap-binary copy, `> 64 B` → zero-copy
`BlobResource`); F-A12-2 collapsed `blob.rs read` from a `vec` + `to_owned_binary`
double-copy to a single read straight into the returned `OwnedBinary`. Re-measured
against the (UNMODIFIED) `binary_crossing/run.sh` this session: the small-blob query
path went from ~128 B/row off-heap resource binary to 0.0 B/row (process-heap),
asymmetry flipped to query-leaner; byte-exact edges + leak-gate PASS. Both squarely
in A12's re-wet list; the owed covering re-run should re-pin the size-adaptive blob
backing and the single-copy blob_read (and note the harness's now-stale
"resource binary" small-blob label).
COVERING RE-RUN (Run 15, 2026-07-19): the owed re-run over the fix-pass churn, churn
attacked hardest. RE-AUDITED (source, LOCKED rustler 0.38.0) + RUNTIME-CONFIRMED (bundled
SQLite 3.53.2, commands captured): `encode_blob` boundary EXACT (query byte-exact across
{0,1,63,64,65,200,4096} B; 64 B×50k → 0 B/row process-heap, 65 B×50k → 128 B/row binary-
alloc — pins `HEAP_BINARY_THRESHOLD=64` to `ERL_ONHEAP_BIN_LIMIT`), OOM-degrade arm sound
(`owned_vec` still owned, no NEW panic), `copy_from_slice` lengths provably equal;
`blob::read` single-copy proven: no uninitialised byte escapes (`sqlite3_blob_read` fills
exactly `actual_len` on OK, bounds forbid the past-end error, err-arm drops the OwnedBinary),
locking law upheld (every `sqlite3_*` under `with_live_blob`), whole/partial/past-end-clamp/
at-end/beyond/zero-len byte-exact. Re-measured `binary_crossing/run.sh`: large-blob numbers
BYTE-IDENTICAL to Run 11 (S1 query 42.73 MB/448 B/row, stream 61.0 MB/640 B/row, leak 0.0 MB
both, S2 68.5×), small-blob query 128→0.0 B/row (F-A12-1 effect, asymmetry flipped 1.8×→1.4×
query-leaner), teeth LIVE (+10.83 MB grow/settle). Full sweep (term-lifetime census, inbound
copy map, outbound producers, hook msg_env 1:1 balance) HOLDS. gotchas.md "Memory and binaries"
threshold claim matches measured behavior (no doc change). Harness stale "resource binary"
small-blob labels FIXED (run.sh/probe.exs/edges.exs), teeth re-proven post-edit; surviving
"resource binary" labels are all `>64 B` (E3 4096 B, S4 1000 B). F-A12-3 untouched (OPEN
maintainer call). CLEAN — zero new CONFIRMED. DRYNESS: Run 11 surfaced 3 new S3 AND the S3 fix
pass round 2 churned this scope (F-A12-1/2), so A12 was RE-WET; Run 15 is the FIRST clean
covering run (zero new CONFIRMED) over that churn — A12 stands at 1 of 2 consecutive clean
covering runs, NOT DRY, one more clean covering run owed. Re-wet list UNCHANGED.

### A13. Hot-upgrade posture
rustler upgrade support is an open upstream gap; on_load is
panic-protected. Deliverable: an explicit documented policy, even
"unsupported — documented". Coverage: Run 12 — first covering run
(source-verify + empirical child-process probe, `hot_upgrade/run.sh`,
CI-isolated). GAP SOURCE-VERIFIED: `rustler_codegen-0.38.0/src/init.rs`
hardcodes the NIF entry's `upgrade`/`reload`/`unload` = `None` (`:92-94`,
only `load` wired) — no rustler API to supply them; per the erl_nif
contract (OTP 29 docs + installed `erl_nif.h`) a NULL `upgrade` makes
`load_nif` FAIL once the module has old code with a loaded NIF, and
resource destructors postpone the library unload. PROBED (RUN, teeth =
crash-oracle child `halt(134)` → CRASH): `:code.load_file(XqliteNIF)` →
`{:error, :on_load_failure}` + VM `{:upgrade, "Upgrade not supported by
this NIF library."}`; every live resource (conn/stmt/stream/blob/session)
survives the failed reload AND soft_purge; direct `:erlang.load_nif` from
a foreign module → `{:bad_lib,_}` (no back door); forced delete+purge+GC
of a live set → NO VM abort (destructors run out of the postponed-unload
library) → fresh open works. It FAILS SAFE — no crash-on-purge. POLICY
DOCUMENTED: `guides/gotchas.md` "Deployment and releases → Hot code
upgrades are not supported — restart the node". 0 S0/S1/S2; 1 S3
(F-A13-1, upstream rustler-upgrade gap, tracking). NOT yet DRY (first
covering run; one more owed). Churn re-wets: a rustler bump (re-check the
`init.rs` upgrade wiring), a `RustlerPrecompiled`/on_load change, or a new
resource type (re-verify its destructor survives purge).

### A14. Test-architecture load-bearer
Re-derive gotcha #1 (parallel tests corrupt global C state → VFS/
allocator sharing → test.seq). rusqlite#1860 now provides upstream
evidence FOR the mechanism. Probe: does the reasoning hold for
precompiled artifacts? Coverage: Run 12 — first independent re-derivation
(+ reproduction + symbol analysis, `test_arch/run.sh`, CI-isolated).
RE-DERIVED: bundled = statically-linked SQLite (nm/objdump: version baked
in, no `libsqlite3` DT_NEEDED) → one per-OS-process globals set (VFS list,
allocator, pcache, PRNG, memstatus, temp namespace); the two suite openers
are DB-isolated (private `:memory:` + temp file) so globals are the ONLY
shared surface (refutes `:memory:`-name / shared-file alternatives).
SUBSTRATE runtime-verified THIS session: `THREADSAFE=1` + `MUTEX_PTHREADS`
(SQLite 3.53.2) → globals mutex-protected → the "out of memory" symptom is
CONTENTION/resource-exhaustion, NOT corruption/UB (refutes literal "corrupt
global C state"). REPRODUCTION (RUN, teeth = byte-smash → SQLITE_CORRUPT
caught + clean serial control equal to parallel): 36×60 and 48×40 +48×600
churn parallel-vs-serial on isolated DBs → 0 crash / 0 corruption / 0
NOMEM both legs (~830k ops); #1860 does NOT repro at 3.53.2 (Run 4
corroborated). Non-repro does NOT refute (flake is RAM/environment-
sensitive; C-concurrency scheduler-capped ~10). PRECOMPILED ANSWER
(nm/objdump both source + precompiled `.so`): each exports ONLY
`nif_init`/`xqlitenif_nif_init`, NO `sqlite3_*` symbols → same per-OS-
process globals for precompiled consumers, and two bundled SQLites
(xqlite+exqlite) in one node are INDEPENDENT (private, non-exported → no
share/dedup — the safe answer). VERDICT: mechanism PLAUSIBLE, test.seq
CONFIRMED load-bearing (removes the surface regardless of the residual
cause), gotcha #1 wording CORRECTED in `CLAUDE.md` ("corrupt" → "contend
on"; not UB). 0 S0/S1/S2; 1 S3 (F-A14-1, deferred constrained-RAM
reproduction). NOT yet DRY (first covering run; one more owed). Churn
re-wets: a bundled-SQLite version bump (re-verify THREADSAFE + #1860 +
static-bundle symbols), a `test.seq`/opener change, or a rusqlite/
libsqlite3-sys bump (re-check `-DSQLITE_THREADSAFE=1`).
DECIDING PROBE (Run 14, 2026-07-19): the deferred F-A14-1 constrained-RAM
reproduction. A new CI-isolated capped extension (`test_arch/capped_probe.exs` +
`capped_run.sh`) holds a large `:memory:`-DB allocation per worker and compares a
barrier-synchronised PARALLEL leg (K holds coexist, peak ~876 MB @ K=24×30 MB)
against a SERIAL control (one hold at a time, peak ~134 MB — ~6.5× amplification)
under an external cap. RUN this session, BOTH mechanisms reproduced the
differential (parallel fails while serial survives at the SAME cap): cgroup
`MemoryMax`+`MemorySwapMax=0` → parallel OOM-KILLED (137) ≤768 MB / serial PASS to
144 MB (peak-FOOTPRINT amplification); `prlimit --as` → parallel `SQLITE_NOMEM`
(code 7) ≤4000 MB / serial PASS (the LITERAL "out of memory" symptom, malloc-NULL
inside SQLite). Teeth: both caps proven to bind (neutral python control + a
real-process 600 MB `alloc_tooth`; prlimit prints `SQLITE_NOMEM ... cap BOUND via
malloc-NULL`). Distinguished carefully: an OOM-kill is a cgroup SIGKILL, not the
literal NOMEM atom (only prlimit yields it); a non-deterministic near-boot-floor
BEAM `erts_mmap`/`eheap` ANOMALY (exit 1) is NOT the SQLite path. VERDICT: gotcha #1
mechanism CONFIRMED (upgraded from PLAUSIBLE — Run 12 non-repro was only the box's
unconstrained RAM); `test.seq` CONFIRMED load-bearing (the surviving serial leg IS
its model). This is a confirmed MECHANISM, **NOT a product defect** — SQLite
correctly returns `SQLITE_NOMEM` under starvation, xqlite propagates it structured
with 0 crash / 0 corruption (integrity ok on every completed hold). F-A14-1 CLOSED.
DRYNESS: zero new CONFIRMED product defects, so this counts toward the arithmetic;
Run 12 (re-derivation) + Run 14 (constrained-RAM decider) = two consecutive clean
covering runs → **A14 DRY**. Re-wet triggers UNCHANGED (a bundled-SQLite version
bump, a `test.seq`/opener change, or a rusqlite/libsqlite3-sys bump).

## Release-readiness axis (RC gate; both repos)

Hexdocs completeness + typespecs + dialyzer clean; accidental-public
audit; precompiled matrix honesty (checksums verified — DONE for
0.9.0; bundled-SQLite-in-artifact strings-check per artifact owed);
CI matrix vs claimed floors (Elixir ~> 1.15 claimed, 1.17 tested —
open); MSRV stated; license consistency; cargo audit + deps.audit;
CHANGELOGs honest; README quickstart cold-run; guides execute;
release.sh rehearsed (audited wave 1: safe, dirty-tree-gated, no
force-push); announcement fact-check claim by claim.
