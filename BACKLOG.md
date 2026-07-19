# Backlog — xqlite (review program)

Confirmed-but-not-blocking items + tracked S3s. Severity per the
ratified bar in `REVIEW_AXES.md`. Nothing here is ever silently
dropped; S3s get a committed closer-look pass after the S0–S2
burn-down.

## Open

- [S3] F-A13-1 (Run 12, A13): hot code upgrade of the xqlite NIF is unsupported
  because rustler 0.38's init codegen hardcodes the `ErlNifEntry`
  `upgrade`/`reload`/`unload` callbacks to `None`
  (`rustler_codegen-0.38.0/src/init.rs:92-94`; only `load` is wired). Per the
  erl_nif contract a NULL `upgrade` makes `:erlang.load_nif` FAIL once the module
  has old code with a loaded NIF, so `:code.load_file(XqliteNIF)` on a running
  system returns `{:error, :on_load_failure}` (VM: `{:upgrade, "Upgrade not
  supported by this NIF library."}`). This is an OPEN UPSTREAM gap — there is no
  rustler API to supply an `upgrade` callback; wiring one would require an upstream
  rustler change (or a hand-written NIF entry that adopts resources on upgrade).
  It FAILS SAFE (old code + resources keep running, no crash, no corruption — probed
  `hot_upgrade/run.sh`), and the documented policy (`guides/gotchas.md` "Hot code
  upgrades are not supported — restart the node") IS the fix, so this is tracking-
  only, not a code change owed here. **Maintainer/upstream question:** if hot-
  upgrade support is ever wanted, carry it to rustler as a feature request (populate
  `upgrade`/`unload` from the `init!` macro). Repro: on a running node,
  `:code.load_file(XqliteNIF)` → `{:error, :on_load_failure}`.
- [S3] `cargo test` runs only in the Linux lint job — Rust unit
  tests never execute on macOS/Windows. Add lanes or justify.
  (wave-1 recon)
- [S3] Elixir floor: mix.exs claims `~> 1.15`, CI floor is 1.17.
  Add 1.15/1.16 lanes or raise the floor — floor-raise is a Dimi
  values call. Mirrors an identical gap in xqlite_ecto3. (wave-1)
- [probe] Docs-build telemetry-flag state: confirm what config
  hexdocs was built under for 0.9.0 (macro docs were flag-dependent
  until `51d1a17`; fix ships with the next release). (wave-1)
- [probe] Bundled-SQLite-in-artifact check: strings/symbol scan of
  each precompiled tarball proving SQLite 3.53.2 is statically in
  (feature-unification failure class). Cheap mechanical gate before
  the announcement. (wave-1)
- [probe] M5 sub-issue (Run 1): `enif_send(NULL,…)` from a NORMAL
  scheduler (session_changeset/patchset path) vs the repo's dirty-only
  note — the busy_handler comment claims "any thread (OTP 26.1+)".
  Reconcile the comments and confirm against an assertion-enabled ERTS.
## Closed

- 2026-07-20 (maintainer decisions, A11) `changeset_apply(_, _, :replace)` conflict
  handling — RULED keep-abort (closes the Run 9 open question). The owner ruled the
  current behavior correct: when a `:replace` request hits a conflict SQLite forbids
  replacing (NOTFOUND / CONSTRAINT / FOREIGN_KEY), abort the whole apply and roll back
  cleanly (SQLITE_ABORT, code 4) — never OMIT-skip the offending change. NO code change;
  behavior already regression-tested (`session_test.exs` replace-on-CONSTRAINT / -NOTFOUND
  assert code 4, refute misuse 21). Enhanced the `changeset_apply` docstring
  (`lib/xqlite/xqlitenif.ex`) to state plainly that a non-replaceable conflict aborts and
  rolls back the entire apply, returning an error — the offending change is not silently
  skipped (that is `:omit`).
- 2026-07-20 (maintainer decisions, A11) F-A11-4 — busy `:max_elapsed_ms` RESET PER STALL
  (per-event budget). The elapsed clock was anchored at the busy slot's first install and
  never reset, so a connection alive past `max_elapsed_ms` gave up on the first callback of
  every fresh contention (0 retries). FIXED: `BusySlotState.start` is now interior-mutable
  (`Cell<Instant>`); `busy_callback` resets it at `count == 0` (SQLite marks each fresh busy
  event's start there), so `max_elapsed_ms` is a per-event wall-time budget matching
  `max_retries`. RED→green (`test/nif/busy_handler_test.exs` new "per-event budget" test —
  added to that file's documented for-loop exception, since contention needs two file-backed
  handles): RED (pre-fix, this session) `assert first_elapsed < 400` failed `left: 600` (an
  aged conn's first callback already reported 600 ms since install → instant give-up); GREEN
  (post-fix) first callback `elapsed 0`, it keeps retrying, insert succeeds after release.
  Docstring (`lib/xqlite.ex`) + `guides/gotchas.md` busy section rewritten from footgun to the
  now-correct per-event semantics.
- 2026-07-20 (maintainer decisions, A4) F-A4-1 — the 20 trivial conn-`Mutex` readers MOVED
  TO DIRTYIO (owner chose robustness over hot-path latency). All 20 named readers were bare
  `#[rustler::nif]` at HEAD; flipped to `schedule = "DirtyIo"`. New census **91 DirtyIo /
  5 normal / 0 DirtyCpu** (was 71/25/0); the 5 remaining normal NIFs are the no-conn-Mutex
  ones that cannot block on a query (`create_cancel_token`, `cancel_operation`,
  `sqlite_version`, `register`+`unregister_log_hook`). MEASURED cost (this session,
  `changes/1` tight loop, 300k timed calls): normal mean ~101 ns / p50 100 / p99 200 →
  DirtyIo mean ~950 ns / p50 ~850 / p99 ~5500 — a ~+850 ns median per-call hop, fatter tail,
  still sub-µs median (well under the 1 ms bar). `scheduler/run.sh` RE-RAN, VERDICT PASS,
  control teeth 35 hits; S2 shared-handle contention now `long_schedule_hits=0` for all
  readers (was 1 each — the block still lasts the query's ~1.32 s but now on a DIRTY
  scheduler, off the normal ones). Consideration recorded: these readers now share the
  10-scheduler DirtyIo pool with real queries, adding to dirty-pool occupancy under heavy
  reader volume. `guides/gotchas.md` reader-scheduler section updated accordingly.
- 2026-07-20 (maintainer decisions, A12/A1) F-A12-3 — TEXT-encode OOM FIXED to match BLOB
  (graceful error, not panic). Row TEXT values crossed via rustler's `str`/`String` encoder,
  which `panic!`s if `OwnedBinary::new` returns `None` under allocation failure, while the
  BLOB encoders degrade with `ok_or_else(InternalEncodingError)`. Added `util::encode_text`
  (fallible `OwnedBinary::new` + `copy_from_slice`, returns `InternalEncodingError` on `None`,
  success path byte-identical to `str::encode`) and routed the three explicit value-return
  TEXT sites through it: `encode_val` `Value::Text` (query/execute/pragma row values — now
  returns `Result`), `sqlite_row_to_elixir_terms` `SQLITE_TEXT` (stream/step row values), and
  `XqliteQueryResult` column names (`connection.rs`). OOM-only, so no RED (documented, like the
  BLOB case); clippy `-D warnings` + dialyzer + full suite green; source audit shows no
  `str::encode`/`.encode(env)` on a String/&str remaining at those sites. LEFT (judgment —
  bounded metadata, NOT the ~1 GB payload, rustler-auto-encoded return types):
  `stmt_column_names` / `stream_get_columns` (`Vec<String>`), `db_path` (`Option<String>`),
  `sqlite_version`, the `schema.rs` introspection strings, and `get_create_sql` — converting
  them means abandoning rustler's return auto-encode for a non-OOM-reachable case, and the
  Run-1 return-encode `catch_unwind` (→ `:nif_panicked`) still nets any such OOM. No new error
  shape: `{:internal_encoding_error, String.t()}` already in `error_reason/0`; adapter blast
  radius NONE.
- 2026-07-20 (S3 fix pass round 3, A3) F-A3-1 — the CLAUDE.md "// SAFETY: on every
  unsafe block" house rule is now MACHINE-ENFORCED: added
  `#![warn(clippy::undocumented_unsafe_blocks)]` to `native/xqlitenif/src/lib.rs`,
  which the `mix verify` + CI gate (`cargo clippy -- -D warnings`) promotes to a
  hard error. Added the missing `// SAFETY:` comment to all 19 filed `unsafe {}`
  blocks: 12 in `explain_analyze.rs` (inner FFI blocks of the `# Safety`-doc'd
  `unsafe fn`s — each restates the fn contract: live stmt/db_handle, Mutex held),
  the three `send_*_to_pid` hook bodies (`commit_hook`/`rollback_hook`/`log_hook` —
  fresh-msg_env sends, cf. `send_busy_to_pid`), `busy_handler.rs` `ffi_rc_to_error`
  (re-prefixed the existing explanation to `// SAFETY:`), and the three
  adjacency-broken ones (`blob.rs`/`cancel.rs`/`connection.rs` — comment moved
  next to its block, or the block's statement reordered above the comment).
  Enabling the lint under `-D warnings` ALSO surfaced 3 undocumented `unsafe impl`
  blocks OUTSIDE the filed 19-block list (`progress_dispatch.rs` Send+Sync for
  `CancelSubscriber` used a `///` doc comment clippy does not count as a safety
  comment; `session.rs` Sync for `XqliteSession` — the existing `// SAFETY:`
  covered only the adjacent Send impl) — all three documented so the gate is
  clean. No review nomenclature in any comment. Clippy `-D warnings` + `mix verify`
  GREEN. Repro (now clean): `cd native/xqlitenif && cargo clippy -- -D warnings`.
- 2026-07-20 (S3 fix pass round 3, A10) F-A10-9 — two direct-NIF error atoms added
  to the `error_reason/0` union (`lib/xqlite.ex`, alphabetical bare-atom section):
  `:extension_loading_disabled` (from `load_extension` when extension loading is
  not enabled, `nif.rs:1674`) and `:invalid_conflict_strategy` (from
  `changeset_apply` for a `conflict_strategy` outside `:omit|:replace|:abort`,
  `nif.rs:1945`). Both are bare atoms. Runtime-confirmed this session (bundled
  SQLite 3.53.2, freshly source-built NIF):
  `XqliteNIF.load_extension(c, "/nonexistent/libfoo.so", nil)` →
  `{:error, :extension_loading_disabled}`;
  `XqliteNIF.changeset_apply(c, <<>>, :not_a_real_strategy)` →
  `{:error, :invalid_conflict_strategy}`. Dialyzer GREEN. Adapter blast radius:
  BENIGN — `xqlite_ecto3` `Error.wrap/1`'s bare-atom clause (`error.ex:208`,
  `wrap(reason) when is_atom(reason)`) already maps both to `%Error{type: <atom>}`;
  no adapter change owed.
- 2026-07-20 (S3 fix pass round 3, A5) Cancel token single-use footgun — CLOSED.
  The user-facing `guides/gotchas.md` "Cancel tokens are single-use" subsection
  (added when the guide was created) already spells out the set-once flag, the
  spent-token reuse hazard, "create a fresh token per cancellable operation", a
  correct code example, and the list-of-tokens OR distinction. The only residual
  this entry named — repeating the note in the inline `lib/xqlite.ex` docstrings —
  is now done: `create_cancel_token/0` and `cancel_operation/1` each state the
  token is single-use, stays signalled with no un-signal, and must be replaced per
  operation, cross-referencing the Gotchas guide. Doc-only, no behavior change.
- 2026-07-19 (Run 14, A14) F-A14-1 — the spurious-"out of memory" (`SQLITE_NOMEM`)
  flake behind gotcha #1: mechanism CONFIRMED (upgraded from PLAUSIBLE) via the
  deferred constrained-RAM deciding probe; CLOSED. Run 12 could not reproduce it at
  dev-box scale only because RAM was UNCONSTRAINED. The new capped extension
  (`test_arch/capped_probe.exs` + `capped_run.sh`, CI-isolated) holds a large
  `:memory:`-DB allocation per worker and compares a PARALLEL leg (K holds coexist
  at a barrier, peak ~876 MB for K=24×30 MB) against a SERIAL control (one hold at a
  time, peak ~134 MB — a ~6.5× amplification) under an external memory cap. RUN this
  session, both cap mechanisms reproduced the differential (parallel fails while
  serial survives at the SAME cap): (a) cgroup `MemoryMax`+`MemorySwapMax=0` →
  parallel OOM-KILLED (rc 137) at ≤768 MB, serial PASS down to 144 MB — peak-
  FOOTPRINT amplification; (b) `prlimit --as` → parallel `SQLITE_NOMEM` (code 7,
  exit 3; e.g. 18/24 workers) at ≤4000 MB, serial PASS — the LITERAL gotcha symptom
  (malloc-NULL inside SQLite). Teeth: both caps proven to bind (neutral python
  control + a real-process `alloc_tooth` 600 MB hold, PASS uncapped / die-or-NOMEM
  capped; the prlimit tooth prints `SQLITE_NOMEM at row 370 — cap BOUND via
  malloc-NULL`, VmSize pinned at the cap). NOT a product defect: SQLite correctly
  returns `SQLITE_NOMEM` under allocator starvation, xqlite propagates it as a
  structured `{:error, {:sqlite_failure, 7, _, _}}` with 0 crash / 0 corruption
  (`integrity_check` = ok on every completed hold); the flake is a TEST-ARCHITECTURE
  property and `mix test.seq` (one OS process per file → one connection's footprint
  at a time = the surviving serial model) is the confirmed load-bearing mitigation.
  Honest caveats: an OOM-kill is a cgroup SIGKILL, not the literal `NOMEM` atom (only
  the prlimit path yields the literal signature); BEAM's ~3.74 GB virtual-boot floor
  makes the prlimit window narrow, so a non-deterministic near-floor BEAM-side
  allocation ANOMALY (exit 1, an `erts_mmap`/`eheap` starve, NOT the SQLite path)
  hops the tightest rung between runs. Full transcript: REVIEW_LEDGER.md Run 14.
  Repro: `MECH=cgroup bash test_arch/capped_run.sh` and `MECH=prlimit bash
  test_arch/capped_run.sh`.
- 2026-07-19 (S3 fix pass round 2, A10) F-A10-1 — text-parse census exceptions:
  RESOLVED, split by whether SQLite gives a code. The four
  no-such-table/index + table/index-exists arms (`classify_sqlite_error`) are all
  primary `SQLITE_ERROR` (1) with NO distinguishing extended code, so the English
  message prefix is the only signal — DOCUMENTED as a deliberate exception in a
  code comment (mirroring `constraint_parse.rs`), stating the accepted consequence
  (a reword/localization gracefully downgrades to `SqliteFailure`, never a
  misclassification). The `message == "interrupted"` catch-all (former
  `error.rs:786`) was ELIMINATED as dead code: a SQLite interrupt is ALWAYS a
  `SqliteFailure` carrying extended `SQLITE_INTERRUPT` (9), classified by the code
  arm; the `From` catch-all only sees non-`SqliteFailure`/`SqlInputError` rusqlite
  variants and none `Display`s as "interrupted" (verified against rusqlite 0.40.1
  `error.rs` Display impl — no variant emits that string). Interrupt
  classification is now purely code-driven; existing cancellation tests stay green.
- 2026-07-19 (S3 fix pass round 2, A10) F-A10-2 — semantic variants dropped the
  extended result code: FIXED for the four variants where SQLite provides a
  discriminating code. `DatabaseBusyOrLocked` / `ReadOnlyDatabase` / `SchemaChanged`
  / `AuthorizationDenied` now carry `extended_code: i32` and encode as
  `{atom, extended_code, message}` (3-tuple; leading classification atom kept).
  `extended_code &&& 0xFF` recovers the primary (BUSY 5 vs LOCKED 6; READONLY
  sub-codes; AUTH) — the discriminator the message-only variants hid. The four
  text-classified variants (no_such_table/index, table/index_exists) DELIBERATELY
  stay message-only: their extended code is invariantly `SQLITE_ERROR` (1), so it
  carries no information (ties to F-A10-1) — cutting the shape change (and its
  blast radius) to the four that gain real signal. Flat-tuple shape chosen over a
  map for consistency with the existing `{:sqlite_failure, code, extended_code,
  message}`. Runtime-confirmed this session (bundled SQLite 3.53.2): readonly →
  `{:read_only_database, 8, "attempt to write a readonly database"}`; auth →
  `{:authorization_denied, 23, "not authorized"}` (RED before: 2-tuples, no code).
  `error_reason/0` typespec + ~18 in-repo test/doc sites updated; new low-byte
  assertions added. ADAPTER BLAST RADIUS (reported to orchestrator, NOT edited):
  `xqlite_ecto3` `Error.wrap/1` (`lib/xqlite_ecto3/error.ex:190` generic
  `{tag, msg}` clause) does not match the 3-tuple → falls to the `inspect/1`
  catch-all (`:198`) → `type: nil`, losing classification; needs a
  `wrap({tag, ext, msg})` clause. Dependent adapter sites: `error.ex:190`,
  `error_wrap_test.exs:118-123` (stale 2-tuple fixture), `driver_connect_pragmas_test.exs:136`
  (raw NIF 2-tuple assert), `fk_diagnostics_test.exs:222` (`%Error{type:
  :database_busy_or_locked}` becomes `type: nil`), `telemetry_open_telemetry_test.exs:50`
  (2-tuple fixture).
- 2026-07-19 (S3 fix pass round 2, A10) F-A10-4 — `:unsupported_atom` discarded
  the offending atom: FIXED. The encoder (`error.rs`) now emits
  `(atoms::unsupported_atom(), atom_value)` → `{:unsupported_atom, "the_atom_name"}`
  (the variant already carried `atom_value`; the encode threw it away). Bare
  `:unsupported_atom` replaced by `{:unsupported_atom, String.t()}` in
  `error_reason/0`. Runtime-confirmed: `[:some_bogus_atom]` param →
  `{:unsupported_atom, "some_bogus_atom"}` (RED before: bare `:unsupported_atom`).
  `error_input_test.exs` assertions tightened to the carried name. ADAPTER: benign
  — the adapter's generic `wrap({tag, msg})` clause absorbs the new 2-tuple
  (`type: :unsupported_atom` unchanged); no adapter grep hits.
- 2026-07-19 (S3 fix pass round 2, A10) F-A10-6 — doubled-`:error` fallback shape:
  FIXED. The map-build-failure arms (`error.rs` ×3, `connection.rs`, and a FIFTH
  un-enumerated site of the identical pattern, `schema.rs` `DefaultValue::Blob`)
  encoded `(atoms::error(), err)` → `{:error, {:error, {:internal_encoding_error,
  …}}}`. Now they encode `err` directly → `{:internal_encoding_error, ctx}` (a
  leading-classification-atom term already in `error_reason/0`). Practically
  unreachable (BEAM `map_new`/`map_put` don't fail; blob-alloc OOM-only) so no RED;
  clippy `-D warnings` + full suite green. The arm can't be dropped (the
  `Result` match needs both arms to typecheck) — emitting the plain term is the
  sanctioned resolution.
- 2026-07-19 (S3 fix pass round 2, A10) F-A10-7 — `error_reason/0` omitted
  `:invalid_transaction_mode`: FIXED (added to the union). Backs the existing
  `XqliteNIF.begin/2` docstring promise; dialyzer green.
- 2026-07-19 (S3 fix pass round 2, A10) F-A10-8 — `error_reason/0` omitted
  `{:cannot_convert_atom_to_string, String.t()}`: FIXED (added to the union).
  Dialyzer green.
- 2026-07-19 (S3 fix pass round 2, A12) F-A12-1 — query-vs-stream BLOB backing
  asymmetry: FIXED by making the query path (`encode_val`) size-adaptive. Blobs
  `> 64 B` still zero-copy-wrap a `BlobResource` (the large-blob win kept); blobs
  `<= 64 B` now copy into an `OwnedBinary` → a cheap process-heap binary instead of
  an off-heap resource binary with per-object overhead. 64 B is the BEAM
  heap-binary threshold (`enif_make_resource_binary` is off-heap at any size), so a
  sub-64 B resource binary was pure overhead. This is the filing's first suggested
  direction ("copy small blobs on the query path too") and STRICTLY improves the
  query path (no large-blob regression), so no maintainer tradeoff to punt.
  Measured this session (`binary_crossing/run.sh`, 100k × 16 B blobs): query path
  went from ~128 B/row off-heap resource binary (~23 MB, the pre-fix
  `:erlang.memory(:binary)` load) to **0.0 B/row** (heap binaries, not in the
  binary allocator); query total 9.32 MB now LEANER than stream 13.95 MB (was
  1.5-3× HEAVIER). All byte-exact edges (empty/sub-binary/survives-close/
  interior-NUL) still PASS; leak-gate PASS. New suite regression: query round-trips
  BLOBs byte-exact across `{1,63,64,65,200,4096}` B (both branches + the 64/65
  boundary).
- 2026-07-19 (S3 fix pass round 2, A12) F-A12-2 — `blob_read` double-copy: FIXED.
  `blob::read` now allocates the returned `OwnedBinary` first and
  `sqlite3_blob_read`s straight into its `as_mut_slice()`, dropping the
  intermediate `vec![0u8; n]` staging buffer + its `to_owned_binary` copy: 2
  allocs / 2 memcpys (and a transient 2× peak) → 1 alloc / 1 memcpy. `blob_read`
  fills exactly `actual_len` bytes on `SQLITE_OK`, so no uninitialised byte
  escapes; on error the binary is dropped, never released. Pure efficiency (no
  behavior change), so no RED; byte-exactness held by the existing blob_read
  suite (partial/past-end/100 KB-at-once/write-read-back) — all green. `serialize`
  already used this alloc-then-copy-once pattern.
- 2026-07-19 (S3 fix pass round 1, A10) F-A10-3 — `INSERT/UPDATE/DELETE …
  RETURNING` reporting `changes: 0`: FIXED. The `query_with_changes[_cancellable]`
  empty-columns heuristic was wrong twice (RETURNING DML has columns → misdetected
  and zeroed; DDL/read-PRAGMA has none → leaked the stale prior-DML count). Replaced
  with a `sqlite3_total_changes()`-delta detector in new
  `query::core_query_with_changes` (both NIFs share it): report `changes()` only
  when the total moved, else 0. Runtime-verified against bundled SQLite 3.53.2 for
  the full matrix (ledger table). RED (8 failing assertions ×2 openers) → green;
  `test/nif/query_with_changes_test.exs` gained UPDATE/DELETE RETURNING + PRAGMA-read
  and corrected the INSERT-RETURNING + DDL cases.
- 2026-07-19 (S3 fix pass round 1) F-A10-5 + F-A11-5 — `error_reason/0` typespec
  gaps: FIXED together. Added `{:invalid_open_option, …}` as the precise two-map
  union (unknown_key | invalid_value shapes from `validate_open_opts`) and corrected
  `{:utf8_error, String.t()}` → `{:utf8_error, non_neg_integer(), String.t()}`
  (matches `error.rs:545`). Both runtime-confirmed this session. Dialyzer GREEN.
- 2026-07-19 (S3 fix pass round 1, Run 1) M10 — `explain_analyze.rs`'s 24
  `map_put(…).unwrap()` across four `Encoder` impls: FIXED. Chained `and_then` +
  a `map_or_encoding_error` helper degrades a (practically-unreachable) map-build
  failure to a structured `InternalEncodingError` term, matching the crate's
  `ok_or_else`/`map_err` convention. Success path unchanged; clippy `-D warnings`
  + full suite green.
- 2026-07-19 (S3 fix pass round 1, Run 1) M11 — `nif.rs:2057
  OwnedBinary::new(0).unwrap()`: ALREADY RESOLVED, no code change owed. The site
  lived in the OLD rusqlite-`Blob`-wrapper `blob_read`; the blob raw-pointer
  refactor `b1c60b4` (Run 2 / B1) rewrote the module and the empty-binary path now
  routes through the graceful `to_owned_binary` → `OwnedBinary::new(…).ok_or_else(…)`
  (`session.rs:132`). Verified at HEAD: zero `.unwrap()` remain in `nif.rs`.
- 2026-07-19 (Run 9, A11) FTS5 guide is linear-executable — DONE: wired up as
  `test/nif/fts5_guide_test.exs` (executes the guide's CREATE VIRTUAL TABLE /
  trigger / MATCH+bm25 / highlight+snippet / match-language / rebuild /
  integrity-check / optimize / tokenizer SQL across every connection opener, so
  the guide fails the suite if it rots). (A11 seed)
- 2026-07-19 (Run 7, A9) D1 — offset-preserving `DateTime` (ISO 8601
  TEXT) sorting LEXICALLY, not chronologically, under `ORDER BY` across
  mixed UTC offsets: RULED keep-and-document. The behavior is
  intentional (the value round-trips exactly; only the SQL sort reads
  oddly), and the caveat plus the two sort-stable escape hatches
  (UTC-normalized storage, `Instant` int64 ns) are now documented
  user-facing in `guides/gotchas.md`.
- 2026-07-19 (Run 7, A9) D2 — stored NaN silently becomes NULL (SQLite
  has no NaN storage class): RULED document. Now surfaced in
  `guides/gotchas.md` alongside the non-finite-float read policy
  (±Inf → `:positive_infinity`/`:negative_infinity`, NaN → `nil`).
- 2026-07-19 new `guides/gotchas.md` ("Gotchas and sharp edges")
  catalogues the remaining user-facing DX quirks so they are publicly
  documented, not just ledger findings: non-finite float reads,
  NaN→NULL, `length()` interior-NUL truncation, offset-preserving
  `DateTime` sort, streaming `on_error` modes, cancel-token single-use,
  close-children-before-connection leak (defers to the security guide),
  `PRAGMA busy_timeout` callback replacement, and busy-sleep / WAL
  autocheckpoint connection pinning. Wired into `mix.exs` docs extras;
  cross-links `guides/security.md` both ways.
- 2026-07-19 (Run 7, A9) F1: reading a non-finite (±Inf) REAL raised
  `ArgumentError`; the row-value encoders now map ±Inf to the sentinel
  atoms `:positive_infinity`/`:negative_infinity` and NaN to `nil` at
  both float sites (`encode_val` + `sqlite_row_to_elixir_terms`),
  consistent with the `schema.rs` guard → `16ca65d`.
- 2026-07-19 (Run 7, A9) F2: `Xqlite.stream/4` gained an `on_error`
  option — `:raise` (default, raises `Xqlite.StreamError`), `:halt`
  (opt-in lossy), `:emit_error` (tagged `{:ok, row}` / terminal
  `{:error, reason}`); the old silent-truncate default is gone →
  `16ca65d`.
- 2026-07-19 M6 (Run 1): own `catch_unwind` guard on the three raw-FFI
  callbacks (progress/wal/busy) so a future callback panic degrades to a
  safe fallback instead of unwinding into SQLite and killing the VM →
  `7e575f7`.
- 2026-07-19 M7 (Run 1): documented the busy-sleep + wal-checkpoint
  connection-Mutex pinning in `set_busy_policy/2` and the security
  guide's thread-safety section → `7e575f7`.
- 2026-07-17 CLAUDE.md drift cluster (intro versions, structure map,
  current state, Hex-2.5 2FA gotcha) → `51d1a17`.
- 2026-07-17 hexdocs grouping + flag-stable telemetry macro docs →
  `51d1a17`.
- 2026-07-17 statement_cancel_test opener-loop rationale comment →
  `51d1a17`.
- 2026-07-17 CI pin alignment (checkout@v6, windows-2022 in
  release.yml) → `51d1a17`.
- 2026-07-17 erl_crash.dump: autopsied, dev-noise, gitignored stays.
