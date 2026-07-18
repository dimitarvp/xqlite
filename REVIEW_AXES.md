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
connection teardown (sibling drivers shipped this). Coverage:
cancellation suites exist incl. the deflaked mid-flight case; no
latency/reuse matrix.

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
encode-only types' read-back story. Coverage: type-extension suites
(49+ tests); no edge matrix.

### A10. Structured-error contract
Probes: audit remaining text-parsing paths ("mostly succeeded" —
find the exceptions); extended result codes surfaced everywhere
(enum-vs-C-constant gotcha #2 is the cautionary tale); changes()
stickiness on every path; error-shape structural contracts
(Exception.message always binary; no shape a `with` can't match).
Coverage: strong by design (30+ variants, no-text-assertion rule);
no adversarial audit yet.

### A11. Feature islands
Session/changesets, blob I/O, backup+progress, serialize,
authorizer, hooks — one adversarial pass each; every guide's code
EXECUTES (FTS5 guide is linear-executable — make it a test;
SpatiaLite is doc-first exempt). Coverage: per-feature NIF suites
exist; guides never executed.

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
