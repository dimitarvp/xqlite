# Backlog — xqlite (review program)

Confirmed-but-not-blocking items + tracked S3s. Severity per the
ratified bar in `REVIEW_AXES.md`. Nothing here is ever silently
dropped; S3s get a committed closer-look pass after the S0–S2
burn-down.

## Open

- [S3] F-A10-1 (Run 8): error classification by English message-substring.
  `error.rs:689-704` classifies `NoSuchTable` / `NoSuchIndex` / `TableExists`
  / `IndexExists` via `lower_msg.starts_with("no such table")` /
  `starts_with("no such index")` / `starts_with("table") && contains("already
  exists")` / `starts_with("index") && contains("already exists")`, and
  `error.rs:786` classifies `OperationCancelled` via `message_string ==
  "interrupted"`. All four table/index cases are primary `SQLITE_ERROR` (1)
  with no distinguishing extended code, so message text is the only signal —
  but this is (a) undocumented as a sanctioned exception (unlike
  `constraint_parse.rs`, whose module header justifies it) and (b) coupled to
  SQLite's English wording: a reword/localization silently downgrades all four
  to `{:sqlite_failure, 1, 1, msg}`. Fix options: document these as a
  sanctioned exception like `constraint_parse`, or accept the downgrade
  explicitly. Repro: `Xqlite.query(c, "SELECT * FROM nope", [])` →
  `{:error, {:no_such_table, "no such table: nope"}}` today.
- [S3] F-A10-2 (Run 8): semantic error variants drop the extended result
  code. `DatabaseBusyOrLocked` / `ReadOnlyDatabase` / `SchemaChanged` /
  `AuthorizationDenied` / `NoSuchTable` / `NoSuchIndex` / `TableExists` /
  `IndexExists` (`error.rs`) carry only `message: String`, so a caller cannot
  distinguish `SQLITE_BUSY` (5) from `SQLITE_LOCKED` (6) — both →
  `:database_busy_or_locked` — nor the `READONLY_*` / `BUSY_SNAPSHOT`
  sub-codes, without parsing text (forbidden by the house rule). The generic
  `SqliteFailure` fallback carries BOTH codes; the "nicer" variants carry
  less. Consider adding an `extended_code` field to these variants (or at
  least splitting busy vs locked). Repro (from `error_contract/`): busy →
  `{:database_busy_or_locked, "database is locked"}`, readonly →
  `{:read_only_database, "attempt to write a readonly database"}` — no code.
- [S3] F-A10-3 (Run 8): `INSERT/UPDATE/DELETE … RETURNING` reports
  `changes: 0`. `query_with_changes` (`nif.rs:137,165`) detects non-DML by
  `qr.columns.is_empty()` and zeroes the sticky counter; a RETURNING DML
  returns columns, so it is misdetected and `changes` is zeroed despite
  modifying rows. `Xqlite.query/4`'s doc ("`changes` is the number of affected
  rows" for DML) is then wrong for RETURNING. No data loss (rows come back,
  `num_rows` is correct). Repro: `Xqlite.query(c, "INSERT INTO t(x)
  VALUES(4) RETURNING x", [])` → `%{changes: 0, num_rows: 1, rows: [[4]]}`.
  Fix options: detect DML by statement keyword rather than empty-columns, or
  document the RETURNING caveat.
- [S3] F-A10-4 (Run 8): `:unsupported_atom` discards the offending atom.
  `error.rs:447` `UnsupportedAtom { atom_value: _ } => atoms::unsupported_atom()`
  encodes a BARE atom, so the Elixir error never names which atom was rejected,
  even though the variant carries `atom_value` (and `Display` uses it).
  Inconsistent with `UnsupportedDataType`, which encodes its `term_type`.
  Encode it as `(atoms::unsupported_atom(), atom_value)` and add the tuple form
  to `error_reason/0`. Latent-ish (needs a bad atom param to trigger).
- [S3] F-A10-5 (Run 8): `error_reason/0` typespec omits
  `{:invalid_open_option, map}`. `validate_open_opts` returns it
  (`lib/xqlite.ex:357,367`) but the `@type error_reason` union (`:136-179`)
  lists only `:invalid_on_error`, so `Xqlite.open/2` + `open_in_memory/1`'s
  `@spec {:ok, conn()} | error()` is inaccurate (dialyzer contract gap). Add
  `{:invalid_open_option, map()}` (two shapes: `%{key, reason: :unknown_key,
  allowed, value}` and `%{key, reason: :invalid_value, value, message}`).
- [S3] F-A10-6 (Run 8, latent): doubled-`:error` fallback shape. The
  map-build-failure arms of the encoders (`error.rs:513/579/626`,
  `connection.rs:95`) encode `(atoms::error(), err)`, i.e. `{:error, {:error,
  {:internal_encoding_error, …}}}`, violating the "leading classification
  atom, never `:error`" shape. Practically unreachable (BEAM `map_new`/
  `map_put` don't fail) but a latent wart — either prove it dead and drop the
  arm, or emit a plain `{:internal_encoding_error, ctx}`.
- [S3] F-A11-4 (Run 9, A11): `set_busy_policy/2`'s `:max_elapsed_ms` is
  anchored at the busy slot's **first installation**, not at the start of each
  busy event, so it never resets. Once a connection has been alive (with a
  policy installed) longer than `max_elapsed_ms`, the elapsed check trips on the
  first callback of every subsequent busy event → the policy gives up with ZERO
  retries, as if none were installed. Hits long-lived/pooled connections hardest
  (default `max_elapsed_ms: 5_000` → policy stops retrying 5 s after install).
  Behavior is DOCUMENTED ("from the busy slot's first installation",
  `lib/xqlite.ex:1359`) and surfaces a clean `{:database_busy_or_locked, …}`
  error (no corruption/wrong-result), so S3 — but a genuine footgun. Confirmed
  empirically (`feature_islands/run.sh` busy-elapsed probe: aged conn gives up in
  ~0 ms / 0 retries; young conn + huge-ceiling conn both succeed in ~150 ms).
  Now documented user-facing in `guides/gotchas.md`. **Maintainer question:**
  reset the elapsed clock at the start of each busy event (count == 0) so
  `max_elapsed_ms` becomes a per-event budget (needs `start` to be interior-
  mutable in `BusySlotState`), or keep-and-document? Repro:
  `set_busy_policy(c, max_retries: 1000, max_elapsed_ms: 400, sleep_ms: 5)`,
  `Process.sleep(600)`, then contend → instant give-up.
- [S3] F-A11-5 (Run 9, A11): `error_reason/0` typespec understates
  `:utf8_error`. `error.rs:545` encodes it as the 3-tuple `(atoms::utf8_error(),
  column, reason)` and the Security guide documents `{:utf8_error, column,
  reason}` (both correct), but the `@type error_reason` union
  (`lib/xqlite.ex:180`) lists only `{:utf8_error, String.t()}` (2-tuple). A
  caller matching the real/guide shape `{:utf8_error, col, reason}` is a dialyzer
  contract violation against the spec. Fix: change it to `{:utf8_error,
  non_neg_integer(), String.t()}`. Same class as F-A10-5 (do together). Repro:
  `Xqlite.query(c, "SELECT CAST(X'ff41' AS TEXT)", [])` →
  `{:error, {:utf8_error, 0, "invalid utf-8 sequence of 1 bytes from index 0"}}`.
- [S3] F-A4-1 (Run 10, A4): the 20 conn-`Mutex` trivial normal-scheduler readers
  (`changes`/`total_changes`/`db_path`/`autocommit`/`txn_state`/`set_busy_policy`/
  `remove_busy_policy`/`register_busy_observer`/`unregister_busy_observer`/
  `set_authorizer`/`remove_authorizer`/`register_progress_hook`/
  `unregister_progress_hook`/`enable_load_extension`/`session_new`/`session_attach`/
  `session_is_empty`/`blob_size`/`blob_close`/`stmt_column_names`) are <1ms
  intrinsically (LAT ≤ 60 µs uncontended) but acquire the connection `Mutex` via
  `with_conn`/`with_session`/`with_live_blob`/`with_live_stmt`. If a connection
  handle is SHARED across processes and one runs a slow Dirty op, a reader on
  another process blocks on a NORMAL scheduler for that op's whole duration →
  normal-scheduler occupancy (a `long_schedule` hit). Confirmed empirically
  (`scheduler/run.sh` S2): a ~1.5 s Dirty query on a shared handle blocked
  `changes` 1493 ms / `db_path` 1456 ms / `txn_state` 1479 ms / `total_changes`
  1454 ms, 1 long_schedule hit each. **S3, not S2:** it requires sharing a handle
  across processes, which the documented architecture forbids (CLAUDE.md: read
  concurrency = a pool of independent handles); a single owner is sequential, and
  the blocking IS the intentional serialization surfacing on the wrong scheduler.
  Consequence is latency degradation, not corruption. Now documented user-facing
  in `guides/gotchas.md`. **Maintainer question:** flip these conn-`Mutex` trivial
  readers to `DirtyIo` so a contended reader blocks a Dirty (not normal)
  scheduler — at a per-call dirty-scheduler-hop cost on hot introspection paths
  (`changes`/`txn_state` are called often) — or keep normal (fast in the intended
  single-owner model) and rely on the gotcha? Repro: share one handle across two
  processes, run a slow `query` on one, `changes` on the other → the `changes`
  call blocks for the query's full duration on a normal scheduler.
- [S3] F-A12-1 (Run 11, A12): BLOB column values cross the boundary two ways —
  `query`/`query_with_changes`/`execute` (via `encode_val`, `util.rs:27-36`) hand
  a blob back as a ZERO-copy resource binary (`ResourceArc<BlobResource>::
  make_binary` → `enif_make_resource_binary`, refcounted, off-heap regardless of
  size), while `stream`/prepared `step`/`blob_read` (via
  `sqlite_row_to_elixir_terms`, `util.rs:337-373`, and `blob::read`) COPY into an
  `OwnedBinary`. Byte-identical values; only the backing differs. Measured
  (`binary_crossing/run.sh`, 100k rows): for LARGE blobs the query path is ~1.3×
  LEANER in total memory (no copy); for MANY SMALL blobs the query path is
  ~1.5–3× HEAVIER (every blob is an off-heap resource binary with per-object
  overhead, vs a ≤64 B streamed copy that can live on the process heap). No
  correctness impact, no leak (leak-gate PASS), and the ratio is well under the
  10× cliff bar → S3 characterization, not a divergence. Documented user-facing in
  `guides/gotchas.md` ("BLOB values are backed differently by `query` vs
  `stream`"). Maintainer question: acceptable as-is (documented), or unify the two
  paths (e.g. copy small blobs on the query path too, or wrap on the stream path)?
- [S3] F-A12-2 (Run 11, A12): `blob_read` double-copies. `blob::read`
  (`blob.rs:131-164`) reads SQLite into a `vec![0u8; actual_len]` buffer, then
  `to_owned_binary` (`session.rs:128-139`) allocates an `OwnedBinary` and copies
  the buffer into it — two allocations and two memcpys for one read, and a
  transient 2× peak on a large `blob_read`. Reading directly into an
  `OwnedBinary`/`NewBinary` target (as `serialize` does: alloc-then-copy-once)
  would halve both. Pure efficiency, no correctness impact. Fix: allocate the
  `OwnedBinary` first, `sqlite3_blob_read` into its `as_mut_slice()`, drop the
  intermediate `Vec`.
- [S3] F-A12-3 (Run 11, A12, latent/OOM-only): TEXT column values (and column
  names, and all `String`/`&str` we hand back) cross via rustler's `str::encode`
  (`rustler-0.38.0/src/types/string.rs:30-42`), which `panic!("binary term
  allocation fail")`s if `OwnedBinary::new(len)` returns `None` on allocation
  failure — whereas OUR BLOB encoders degrade gracefully with
  `OwnedBinary::new(len).ok_or_else(InternalEncodingError)` (`util.rs:346,363`,
  `session.rs:132`, `nif.rs:1623`). The panic is CAUGHT by rustler's
  return-value-encode `catch_unwind` (Run 1: surfaces as `:nif_panicked`, never a
  VM crash), so it does not break the "will never crash the BEAM" claim, but it is
  inconsistent with the crate's graceful-degradation convention and is the same
  class as the fixed M8 (and the latent M10/M11). Reachability is OOM-only (a
  ~1 GB TEXT value near `SQLITE_MAX_LENGTH` on a memory-constrained box). Fixing
  only the two row-value TEXT sites (`encode_val` Value::Text + the SQLITE_TEXT
  arm of `sqlite_row_to_elixir_terms`) while column-names / schema strings still
  route through `str::encode` would be inconsistent — so this is really a
  crate-wide "encode all TEXT via a graceful OwnedBinary helper" consistency call.
  Cross-refs A1. Maintainer question: reimplement TEXT-value encoding to degrade
  like BLOB, or accept rustler's `str::encode` OOM-panic (caught → `:nif_panicked`)
  as the crate-wide behavior?
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
- [S3] F-A14-1 (Run 12, A14): the spurious-"out of memory" flake behind gotcha #1
  (parallel test files contending on the shared per-OS-process SQLite globals) was
  NOT reproduced at dev-box scale — `test_arch/run.sh` ran ~830k parallel isolated-DB
  ops (36×60 and 48×40 + 48×600 open/close churn) with 0 crash / 0 corruption / 0
  NOMEM, byte-for-byte equal to the serialized control (teeth: byte-smash →
  SQLITE_CORRUPT caught). The mechanism is graded PLAUSIBLE (not refuted): it is a
  RAM/environment-sensitive contention/flake class (a 7 GB GHA runner holding many
  async connections is a far tighter allocator than this box; true C-level
  concurrency is also scheduler-capped at ~10 dirty-IO schedulers, already
  saturated), and rusqlite#1860 is a real OPEN upstream issue in the class.
  `mix test.seq` remains the load-bearing mitigation regardless (it removes the
  shared-globals surface deterministically). **Deferred deciding probe:** re-run
  `test_arch/` under a cgroup RAM cap (e.g. `systemd-run --scope -p MemoryMax=1G`)
  mimicking a constrained runner to try to force the parallel-only NOMEM, which
  would upgrade the verdict from PLAUSIBLE to CONFIRMED. Repro: `bash
  test_arch/run.sh` (currently PASS = no repro).
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
- [S3] M10/M11 (Run 1): `explain_analyze.rs:380-490` (`map_put().unwrap()`
  ×24) and `nif.rs:2057` (`OwnedBinary::new(0).unwrap()`) use `unwrap`
  where the crate's graceful `map_err`/`ok_or_else` convention applies.
  Latent-only; consistency fix.
- [probe] M5 sub-issue (Run 1): `enif_send(NULL,…)` from a NORMAL
  scheduler (session_changeset/patchset path) vs the repo's dirty-only
  note — the busy_handler comment claims "any thread (OTP 26.1+)".
  Reconcile the comments and confirm against an assertion-enabled ERTS.
- [S3] Cancel token single-use footgun (Run 6, A5): the cancel flag is
  a set-once `Arc<AtomicBool>` with no reset path, so a signalled token
  reused on a later op aborts it immediately (`{:error,
  :operation_cancelled}`). Correct + tested behavior
  (`statement_cancel_test.exs:38`), but the user-facing
  `create_cancel_token/0` / `cancel_operation/1` docs (`lib/xqlite.ex`)
  never say "a signalled token is single-use — create a fresh token per
  operation"; only `XqliteNIF.cancel_operation/1` hints it ("the
  cancellation signal remains active for the token", `xqlitenif.ex:1063`).
  Doc-clarity only; no code change. Well-defined, not a crash/wrong-result.
  NOW documented user-facing in `guides/gotchas.md` ("Cancel tokens are
  single-use" — spells out "create a fresh token per cancellable
  operation"); the only residual is repeating the line in the inline
  `lib/xqlite.ex` docstrings.

## Closed

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
