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
Coverage: none yet — no census run.

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

### A3. UB tooling
Sources: Miri/ASan/TSan/cargo-careful docs. Probes: separability of
core logic from the NIF shim (inseparability is itself a finding);
sanitizer suite runs; clippy pedantic triage once. Coverage: none.

### A4. Scheduler discipline
NIFs must be <1ms proven or Dirty (CPU vs IO correctly chosen).
Probes: per-NIF classification table; `erlang:system_monitor`
long_schedule gate over the full suite. Coverage: dirty flags exist
in code, unaudited.

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
`error_reason/0` typespec re-wets).

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
authorizer/hook code, `busy_handler.rs`, or any guide edit.

### A12. Binary crossing
Probes: copy vs refcounted binaries across the boundary; memory
profile of large result sets; iodata acceptance on the way in.
Coverage: none measured.

### A13. Hot-upgrade posture
rustler upgrade support is an open upstream gap; on_load is
panic-protected. Deliverable: an explicit documented policy, even
"unsupported — documented". Coverage: no policy stated.

### A14. Test-architecture load-bearer
Re-derive gotcha #1 (parallel tests corrupt global C state → VFS/
allocator sharing → test.seq). rusqlite#1860 now provides upstream
evidence FOR the mechanism. Probe: does the reasoning hold for
precompiled artifacts? Coverage: rationale documented; never
independently re-derived.

## Release-readiness axis (RC gate; both repos)

Hexdocs completeness + typespecs + dialyzer clean; accidental-public
audit; precompiled matrix honesty (checksums verified — DONE for
0.9.0; bundled-SQLite-in-artifact strings-check per artifact owed);
CI matrix vs claimed floors (Elixir ~> 1.15 claimed, 1.17 tested —
open); MSRV stated; license consistency; cargo audit + deps.audit;
CHANGELOGs honest; README quickstart cold-run; guides execute;
release.sh rehearsed (audited wave 1: safe, dirty-tree-gated, no
force-push); announcement fact-check claim by claim.
