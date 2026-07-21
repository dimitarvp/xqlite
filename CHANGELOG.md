# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Raised the minimum supported Elixir to `~> 1.17`, matching the CI
  test matrix (Elixir 1.17–1.20 × OTP 26–29). Elixir 1.15/1.16 were
  claimed but never exercised by CI.

## [0.10.0] - 2026-07-20

This release fixes several memory-safety and crash defects present in
0.9.0, and refines the error and streaming contracts. The error-tuple,
streaming, and NUL-handling changes are breaking — see **Changed**.

### Security

- **Memory-safety fixes in resource teardown.** Several defects that
  could crash or corrupt the BEAM were fixed: a use-after-move when an
  incremental-blob resource was dropped, plus use-after-free, leak, and
  panic residuals in the blob, session, and log-hook paths. Raw FFI
  callbacks (progress, WAL, busy) are now guarded so a panic can never
  unwind across the C boundary. Surfaced by an adversarial safety
  review of the code shipped in 0.9.0.

- **`Xqlite.stream/4` could abort the VM on a huge `batch_size`.** A
  validly-typed but pathological `batch_size` (e.g. `10^13`) triggered
  an eager multi-terabyte allocation that aborted the OS process before
  any row was read. The accumulator now grows on demand.

### Added

- **Security guide** documenting the threat model, the per-connection
  thread-safety model, and safe extension loading.
- **Gotchas guide** collecting user-facing footguns (sticky
  `changes/1`, single-writer behavior, busy-policy anchoring, memory
  and binaries, one-connection-per-process, and more).

### Changed

- **BREAKING: error tuples now carry the SQLite extended result code.**
  `:database_busy_or_locked`, `:read_only_database`, `:schema_changed`,
  and `:authorization_denied` are now the 3-tuple
  `{tag, extended_code, message}` (previously `{tag, message}`), so
  callers can tell e.g. `SQLITE_BUSY` from `SQLITE_LOCKED`. Other
  message-classified errors are unchanged.
- **BREAKING: `{:utf8_error, message}` is now
  `{:utf8_error, column, message}`**, carrying the byte column of the
  first invalid sequence.
- **BREAKING: `Xqlite.stream/4` no longer silently truncates on a
  mid-fetch error.** A new `:on_error` option chooses how a mid-stream
  failure (e.g. an invalid-UTF-8 TEXT value) is surfaced, and the
  stream's element shape follows the mode: `:raise` (the new default)
  raises `Xqlite.StreamError` carrying the structured reason; `:halt`
  keeps the previous stop-and-log behavior, now opt-in and documented
  as lossy; `:emit_error` yields a uniformly tagged stream of
  `{:ok, row}` elements followed by a terminal `{:error, reason}`. The
  old default silently dropped the remaining rows with no signal to the
  consumer, so a truncated read could not be told apart from a
  completed one.
- **BREAKING: interior NUL bytes in SQL text are rejected.** SQL passed
  to `query`, `execute`, and `execute_batch` containing an interior NUL
  now returns `{:error, :null_byte_in_string}` instead of being
  silently truncated at the NUL by SQLite's tokenizer. NUL bytes in
  bound parameter values still round-trip unchanged.

### Fixed

- **Non-finite floats no longer raise when read.** A stored or
  computed `±Inf` REAL now reads back as the sentinel atom
  `:positive_infinity` / `:negative_infinity` — and a `NaN`, which
  SQLite already stores as NULL, as `nil` — on every read path
  (`query`, `stream`, prepared `step`). Previously rustler's `f64`
  encoder posted a return-time `ArgumentError`, breaking the
  `{:ok, _}` / `{:error, _}` contract; the row-value encoders now
  guard finiteness the way the schema layer already did.

- **`query_with_changes/3` reports the correct affected-row count.** It
  now returns the true count for `INSERT/UPDATE/DELETE ... RETURNING`
  statements (previously `0`) and no longer leaks a stale prior-DML
  count after a DDL or PRAGMA statement.

- **`backup_with_progress/6` no longer loops forever** when given a
  non-positive `pages_per_step`; it returns
  `{:error, {:invalid_pages_per_step, n}}`.

- **`changeset_apply/3` with `:replace`** no longer fails with
  `SQLITE_MISUSE` on conflict types SQLite forbids replacing
  (`NOTFOUND`, `CONSTRAINT`, `FOREIGN_KEY`); the apply aborts cleanly.

- **Hexdocs stability and navigation.** `Xqlite.Telemetry`'s macro
  docs no longer depend on which compile-time telemetry flag was
  active when the docs were built (the disabled branch carried
  `@doc false`), and the docs sidebar now groups the previously
  ungrouped flagship modules: the type-extension family, the
  telemetry trio, `Xqlite.Result`, and `Xqlite.ExplainAnalyze`.

### Performance

- **Small blob values from `query` use a process-heap binary** instead
  of an off-heap reference-counted binary, cutting per-value overhead
  for reads of many small blobs. Large blobs keep the zero-copy
  reference-counted backing.

- **Slow session, blob, and changeset NIFs run on dirty schedulers**,
  so serializing or copying a large changeset or blob no longer
  occupies a normal BEAM scheduler.

## [0.9.0] - 2026-07-17

### Breaking

- **The busy handler is split into policy and observers.**
  `set_busy_handler/3` (pid + options) is gone; the retry decision
  and the observation are now independent halves of one busy slot:
  `Xqlite.set_busy_policy/2` / `remove_busy_policy/1` own the
  single-slot retry policy (a policy cannot compose), and any number
  of `Xqlite.register_busy_observer/2` subscribers receive
  `{:xqlite_busy, retries, elapsed_ms}` per contention callback —
  with or without a policy installed. `remove_busy_handler/1` is
  replaced by `remove_busy_policy/1` (observers survive it);
  `busy_timeout/2` now clears the policy and documents that the raw
  PRAGMA also silences observers.

### Added

- **Every raw introspection NIF now has an `Xqlite` wrapper.** The
  ergonomic surface gains transaction-state readers
  (`transaction_status/1`, `autocommit/1`, `txn_state/2`), counters
  (`last_insert_rowid/1`, `changes/1`, `total_changes/1`,
  `connection_stats/1`), build info (`compile_options/1`,
  `sqlite_version/0`), and the schema family (`schema_databases/1`,
  `schema_list_objects/2`, `schema_columns/2`,
  `schema_foreign_keys/2`, `schema_indexes/2`,
  `schema_index_columns/2`, `get_create_sql/2`) — all thin,
  telemetry-free delegations. Hooks, sessions, and blob I/O remain
  deliberately raw `XqliteNIF` APIs.

- **`Xqlite.Telemetry.OpenTelemetry`.** A pure, dependency-free
  mapping from xqlite's telemetry events to OpenTelemetry's stable
  database semantic-convention attributes (`db.system.name`,
  `db.query.text`, `db.operation.name`, `db.namespace`,
  `error.type`) plus a `span_name/2` suggestion — the vocabulary
  database-aware observability backends key off. Every mapped name
  is cited to its spec page in the module docs.

- **Two new hexdocs guides.** "Full-text search with FTS5" (virtual
  tables, external-content triggers, bm25 ranking,
  highlight/snippet, adapter usage) and the doc-first "Spatial data
  with SpatiaLite" (per-platform install, gated extension loading,
  geometry columns, spatial index pattern, honest caveats).

- **Busy observation joins the telemetry bridge.**
  `Xqlite.Telemetry.bridge/2` accepts `:busy` (included in the
  default `:all`), re-emitting contention deliveries as
  `[:xqlite, :hook, :busy]` with `retries` and nanosecond `elapsed`
  measurements.

- **`Xqlite.close/1` and `Xqlite.db_path/1`.** Connection close gets
  its ergonomic wrapper (idempotent — `:ok` even when already
  closed) and finally emits the `[:xqlite, :close, :start | :stop]`
  telemetry span the telemetry docs have promised since 0.7.0.
  `db_path/1` returns the main database's file path (`{:ok, nil}`
  for in-memory and temporary databases), with a matching raw
  `XqliteNIF.db_path/1` stub.

- **`Xqlite.open_readonly/1` and `Xqlite.open_temporary/0`.** The
  last two raw-only opens get their ergonomic wrappers, emitting the
  `[:xqlite, :open]` span with modes `:readonly` / `:temp`.

### Fixed

- **Connection open spans actually fire.** The telemetry docs have
  promised `[:xqlite, :open, :start | :stop]` since 0.7.0, but no
  open wrapper ever emitted them. `Xqlite.open/2`,
  `open_in_memory/1`, and `open_in_memory_readonly/1` now emit the
  span with the documented `%{path, mode, result_class,
  error_reason}` metadata.

## [0.8.0] - 2026-07-14

### Added

- **Manual statement lifecycle.** `Xqlite.prepare/2`, `bind/2`
  (positional list or keyword-named), `step/1` (`{:row, values}` /
  `:done`), `multi_step/2` (`{:ok, %{rows: rows, done: bool}}`),
  `reset/1` (bindings preserved), `clear_bindings/1`,
  `column_names/1`, `finalize/1` (idempotent) — plus the raw
  `XqliteNIF.stmt_*` stubs. Prepare once and rebind in a loop to skip
  re-parsing; consume partially without LIMIT rewrites. Exactly one
  statement per prepare: empty SQL and trailing statements are
  structured errors, never silently dropped. Positional bind
  validates the parameter count
  (`{:invalid_parameter_count, %{provided: _, expected: _}}`); using
  a finalized statement returns `{:error, :statement_finalized}`.
  Abandoned statements are finalized by garbage collection; finalize
  before closing the owning connection. Plain steps are not
  cancellable; `multi_step_cancellable/3` provides token-based
  cancellable batch stepping over the connection's progress handler
  (single token or OR-semantics list, like `query_cancellable/4`).
  No telemetry on statement operations (documented).

- **Deny-list authorizer.** `Xqlite.set_authorizer/2` and
  `remove_authorizer/1` (plus the raw `XqliteNIF` stubs) install a
  single-slot authorizer that rejects a chosen set of SQLite action
  kinds at statement-preparation time. Denied statements fail with
  `{:error, {:authorization_denied, message}}`; an unrecognized action
  atom returns `{:error, {:invalid_authorizer_action, atom}}` and
  installs nothing (the list is validated atomically). v1 is
  action-kind granularity only (no table/column filtering) and
  deny-only (no `IGNORE`). Denying `:pragma` also turns off
  `get_pragma`/`set_pragma`.

- **`:type_extensions` on `Xqlite.query/4` and `execute/4`.**
  Previously stream-only: the option now also encodes parameters and
  decodes result rows on the one-shot query/execute paths (same
  first-match chain semantics as `stream/4`; arity-3 calls are
  unchanged).

- **`Instant` and `Duration` type extensions.** Encode-only mirrors
  of the Ecto-layer types: `DateTime` → int64 epoch nanoseconds
  (`Instant` — the integer alternative to the ISO-text `DateTime`
  extension; pick one per chain) and exact-unit `Duration` → int64
  nanosecond spans (calendar units skip; Elixir 1.17+ gated like
  `Decimal`). No decode on either — a stored nanosecond count is
  indistinguishable from any other integer. Timezone-aware datetimes
  and arrays need no new modules: the `DateTime` extension already
  round-trips offsets and `JSON` already handles lists. This
  completes the core-layer type mirroring.

- **Three more built-in type extensions.**
  `Xqlite.TypeExtension.JSON` (plain maps/lists ↔ JSON text via
  `Jason`; structs and unencodable terms skip), `.UUID` (canonical
  hyphenated text ↔ the compact 16-byte value it encodes; decode is a
  16-byte heuristic that cannot tell a BLOB from a same-length TEXT),
  and `.Decimal` (encode-only, `Decimal` → exact TEXT). `Decimal`
  introduces xqlite's first optional dependency — a deliberate policy
  change: the module compiles only when `:decimal` is installed, so the
  core package stays dependency-light. Geo/spatial types remain out of
  scope for core.

### Breaking

- **`ColumnInfo.default_value` is now classified, not raw text.**
  Previously the verbatim `dflt_value` string from
  `PRAGMA table_xinfo` (or `nil`); now a typed classification:
  `:none` (no default — distinct from explicit `DEFAULT NULL`),
  `{:literal, nil | boolean | integer | float | String.t()}` (with
  SQLite's `''` string escaping undone, hex integers as 64-bit
  two's complement, `TRUE`/`FALSE` as booleans),
  `{:blob, binary}` (`x'...'` hex-decoded, may be any bytes),
  `{:current, :time | :date | :timestamp}`, or `{:expr, sql}`
  verbatim for everything else (SQLite strips expression defaults'
  outer parentheses; nothing is constant-folded; integer-shaped
  values beyond 64 bits and non-finite floats land here).
  Parsing happens in Rust at the NIF boundary. Date/time-looking
  strings remain strings — no type divination at the schema layer.

- **`mix precommit` is now `mix verify`.** Same checks, same
  fast-to-slow order, new name. The task module ships in the
  package, so the old task name is gone.

### Fixed

- **Raw statement/stream binding accepts text with interior NUL
  bytes.** The shared FFI binder built a `CString` for TEXT values
  and rejected legitimate NUL-containing payloads with
  `:null_byte_in_string`; it now binds pointer+length, matching the
  one-shot query path (SQLite stores such TEXT fine).

- **Statement column metadata is read live, not snapshotted.**
  `SELECT *` through a prepared statement now re-expands after a
  schema change (SQLite's v2 auto-reprepare); previously the row
  width and `column_names` were frozen at prepare time. Finalized
  statements still answer `column_names` from the prepare-time
  snapshot.

- **Finalizing after a failed step no longer reports a phantom
  error.** `sqlite3_finalize` echoes the statement's most recent
  evaluation error (e.g. `SQLITE_INTERRUPT` after a cancelled step)
  even though the statement is destroyed regardless; `stream_close/1`
  and `Xqlite.finalize/1` treated that echo as a cleanup failure.
  Cleanup now always succeeds — the evaluation error was already
  surfaced at step/fetch time.

### Changed

- Upgraded rusqlite 0.39 → 0.40.1 (bundled SQLite 3.51.3 → 3.53.2)
  and rustler 0.37 → 0.38. No API changes on the xqlite surface.

## [0.7.0] - 2026-06-12

### Breaking

- **Fan-out hooks renamed and made multi-subscriber.** Every hook that
  fans out events to a subscriber pid (update, wal, commit, rollback,
  log) now uses the `register_X_hook` / `unregister_X_hook(handle)`
  verbs and returns an opaque integer handle. Multiple subscribers can
  coexist independently on the same connection (or globally for
  `log_hook`); each registration is independent. Migrations:
  - `set_update_hook(conn, pid)` (returned `:ok`) →
    `register_update_hook(conn, pid)` (returns `{:ok, handle}`)
  - `remove_update_hook(conn)` →
    `unregister_update_hook(conn, handle)` (idempotent on unknown
    handles)
  - Same shape for: `wal_hook`, `commit_hook`, `rollback_hook`,
    `log_hook` (the latter is `register_log_hook(pid)` /
    `unregister_log_hook(handle)` since it's global).
  - `busy_handler` keeps the `set_busy_handler` / `remove_busy_handler`
    verbs because its callback returns a policy decision and
    multi-subscriber composition has no clean rule. A future
    `register_busy_observer/1` will offer fan-out observation
    alongside the single policy slot
    (see `project_busy_handler_observer_split` design notes).
- **Cancellable NIFs now take a list of tokens instead of a single
  token.** `XqliteNIF.query_cancellable/4`,
  `query_with_changes_cancellable/4`, `execute_cancellable/4`,
  `execute_batch_cancellable/3`, and `backup_with_progress/6` now expect
  the trailing argument to be `[reference()]` (possibly empty) rather
  than `reference()`. OR-semantics: any signalled token cancels the
  operation. Single-token callers wrap as `[token]`. The new
  `Xqlite.query_cancellable/4` (and friends) plus
  `Xqlite.backup_with_progress/6` accept either a single token or a list
  and normalise via `List.wrap/1`.
- **`XqliteNIF` is now the raw NIF boundary only.** Every function in
  `XqliteNIF` is a bare NIF stub; all ergonomic wrappers moved to the
  user-facing `Xqlite` module. Migrations:
  - `XqliteNIF.open_in_memory/0` → `Xqlite.open_in_memory/0`
    (or `XqliteNIF.open_in_memory(":memory:")` to stay at the NIF layer)
  - `XqliteNIF.open_in_memory_readonly/0` → `Xqlite.open_in_memory_readonly/0`
  - `XqliteNIF.serialize/1` → `Xqlite.serialize/1`
  - `XqliteNIF.deserialize/2` → `Xqlite.deserialize/2`
  - `XqliteNIF.load_extension/2` → `Xqlite.load_extension/2`
  - `XqliteNIF.backup/2` → `Xqlite.backup/2`
  - `XqliteNIF.restore/2` → `Xqlite.restore/2`
  - `XqliteNIF.set_busy_handler/3` (keyword-opts form) →
    `Xqlite.set_busy_handler/3`; the raw NIF stays as
    `XqliteNIF.set_busy_handler/5`

### Added

- **Opt-in `:telemetry` instrumentation** across the whole API surface.
  Compile-time flag (`config :xqlite, :telemetry_enabled, true` +
  recompile); when disabled (the default) no telemetry call exists in
  the bytecode at all. Span events (`:start`/`:stop` with integer-
  nanosecond `monotonic_time`/`duration`) for query / execute /
  execute_batch / explain_analyze and their cancellable variants,
  transactions and savepoints, streams (open / per-batch fetch /
  close), backup, wal_checkpoint, serialize / deserialize, extension
  loading, and pragma get/set. Cancellation lifecycle events:
  `[:xqlite, :cancel, :token_created | :signalled | :honored]`.
- **`Xqlite.Telemetry.bridge/2` + `bridge_log/1`** — forward the
  multi-subscriber hook fan-outs (update / wal / commit / rollback /
  progress, plus the global log hook) as `[:xqlite, :hook, :*]`
  telemetry events. New "Wiring xqlite telemetry" ExDoc guide covers
  conventions, the full event surface, and sample handlers.
- **Connection observability NIFs** — `Xqlite.wal_checkpoint/3`
  (`:passive` / `:full` / `:restart` / `:truncate`, returns structured
  busy / log-pages / checkpointed-pages), `XqliteNIF.connection_stats/1`,
  `XqliteNIF.autocommit/1`, and `XqliteNIF.txn_state/2`.
- **`Xqlite.busy_timeout/2`** — sets a plain `sqlite3_busy_timeout` while
  cleanly reclaiming any xqlite-installed busy handler first. Prefer this
  over `PRAGMA busy_timeout`, which silently replaces the busy handler at
  the SQLite C level and stops `{:xqlite_busy, …}` delivery without
  removing our internal slot.
- Busy-handler PRAGMA-replacement warning front-and-center in the module
  docs and README.
- **WAL hook**: `XqliteNIF.register_wal_hook/2` +
  `unregister_wal_hook/2`. Sends `{:xqlite_wal, db_name, pages}` to
  each subscriber after each commit in WAL mode. Coexists with
  automatic checkpointing (see the slot-conflict fix below); only
  raw-SQL `PRAGMA wal_autocheckpoint` still steals the hook slot.
- **Commit hook**: `XqliteNIF.register_commit_hook/2` +
  `unregister_commit_hook/2`. Sends `{:xqlite_commit}` to each
  subscriber immediately before each commit. Observation-only — never
  vetoes the commit.
- **Rollback hook**: `XqliteNIF.register_rollback_hook/2` +
  `unregister_rollback_hook/2`. Sends `{:xqlite_rollback}` to each
  subscriber after each rollback.
- **Progress hook (multi-subscriber)**:
  `XqliteNIF.register_progress_hook/4` +
  `XqliteNIF.unregister_progress_hook/2` plus
  `Xqlite.register_progress_hook/3` /
  `Xqlite.unregister_progress_hook/2`. Multiple processes can subscribe
  independently to the same connection; each receives
  `{:xqlite_progress, count, elapsed_ms}` (or
  `{:xqlite_progress, tag, count, elapsed_ms}` if a tag is supplied),
  decimated by the per-subscriber `every_n` knob. Coexists with
  cancellation on the single SQLite progress-handler slot — cancel
  signals interrupt before tick emission.
- **Multi-token cancellation**: cancellable NIFs and
  `backup_with_progress` accept a list of tokens; any signal cancels
  (OR-semantics). The high-level `Xqlite.query_cancellable/4` family
  accepts either a single token or a list.

### Fixed

- **WAL hook ↔ `wal_autocheckpoint` slot conflict.** SQLite implements
  automatic checkpointing *as* a wal_hook, so the two share one C-level
  slot and silently disable each other. Both directions affected the
  in-development hook work: `Xqlite.open/2`'s default
  `wal_autocheckpoint` pragma evicted the master WAL callback (no
  subscriber ever received events), and on raw `XqliteNIF.open`
  connections the master callback itself disabled autocheckpointing
  (unbounded WAL growth). The master callback now owns the slot and
  emulates the autocheckpoint — a passive checkpoint once the WAL
  reaches the configured threshold (default 1000 pages, mirroring
  SQLite) — and the `set_pragma` NIF re-installs the master callback
  and syncs the threshold whenever `wal_autocheckpoint` is set.
  Remaining caveat (documented): issuing `PRAGMA wal_autocheckpoint`
  through raw SQL (`query`, `execute`, `execute_batch`) bypasses the
  repair and still steals the slot.

### Internal

- New `progress_dispatch` Rust module multiplexes the single SQLite
  `sqlite3_progress_handler` slot between cancellation checkers (per
  cancellable-query lifetime) and tick subscribers (per-conn lifetime),
  via two `HookList<T>`s. The C callback is registered eagerly at
  connection open and stays for the lifetime of the connection;
  subscriber install/uninstall is lock-free atomic-swap-and-reclaim.
- New `HookList<T>` primitive in `hook_util`: lock-free copy-on-write
  list of subscribers. Reads (in callbacks) are wait-free atomic loads;
  writes (under the conn Mutex) clone the Vec, mutate the clone, and
  atomic-swap. Vec is the proof-of-concept choice; ring buffer / lock-
  free structures are tracked as a benchmark-gated future optimisation.
- `cancel.rs::ProgressHandlerGuard` no longer touches FFI — it pushes
  one `CancelSubscriber` per token onto the dispatch and unregisters
  them on drop. Holds the owning `Arc<AtomicBool>` for each subscriber
  so the raw pointer stays valid for the registration's lifetime.
- Shared `hook_util` Rust module deduplicates term-construction
  (`make_atom` / `make_binary`) and atomic-slot lifecycle
  (`install_hook` / `uninstall_hook` / `drop_hook`) across the FFI-based
  hooks (busy_handler, wal_hook) and the rusqlite-closure hooks
  (update_hook, commit_hook, rollback_hook).

## [0.6.0] - 2026-04-19

### Breaking

- **Constraint errors are now structured.** `:cannot_fetch_row` has been
  removed as an outcome; constraint-violating statements now raise
  `{:constraint_violation, subtype, details}` with `subtype` as one of
  13 typed atoms (`:constraint_unique`, `:constraint_foreign_key`,
  `:constraint_check`, `:constraint_not_null`, `:constraint_primary_key`,
  `:constraint_trigger`, `:constraint_commit_hook`,
  `:constraint_function`, `:constraint_rowid`, `:constraint_pinned`,
  `:constraint_datatype`, `:constraint_vtab`, and the generic
  `:constraint_violation` fallback) and `details` carrying structured
  `table`, `columns`, `index_name`, `constraint_name` fields where
  applicable. Regex matching on error message strings is no longer
  needed. Callers catching `{:error, {:cannot_fetch_row, _}}` must
  update to match the new structured form.

### Added

- **`Xqlite.explain_analyze/3`** — structured execution report combining
  `EXPLAIN QUERY PLAN`, per-scan runtime counters from
  `sqlite3_stmt_scanstatus_v2` (loops, rows visited, estimated rows,
  name, parent, selectid), statement-level counters from
  `sqlite3_stmt_status` (vm_step, sort, fullscan_step, memused, etc.),
  and wall-clock execution time. SQLite's closest analog to PostgreSQL's
  `EXPLAIN (ANALYZE)`.
- **`Xqlite.open/2` and `Xqlite.open_in_memory/1`** — high-level open
  functions with validated options. Options are type-checked at the
  boundary and produce structured errors on misuse.
- **`Xqlite.enable_strict_table/2`** — converts an existing table to
  STRICT mode via the canonical SQLite rewrite dance.
- **`Xqlite.check_strict_violations/2`** — pre-scans a table for rows
  that would fail STRICT-mode type enforcement, so callers can fix
  data before flipping the switch.
- **Structured STRICT datatype violations.** When a STRICT table
  rejects a write, the error carries `source_type` and `target_type`
  atoms (`:integer`, `:real`, `:text`, `:blob`, `:null`) so callers
  can reason about the mismatch without parsing messages.
- **Structured invalid-option errors** from the option-validation
  layer; no regex on error text.

## [0.5.2] - 2026-03-16

### Added

- **`XqliteNIF.query_with_changes/3`** and **`query_with_changes_cancellable/4`**
  — return rows plus the `sqlite3_changes()` count in one atomic call,
  captured inside the connection Mutex so the count cannot be stolen by
  an intervening statement. Zero for non-DML results (detected by empty
  column list).
- **`Xqlite.query/3`** high-level wrapper that returns an
  `%Xqlite.Result{}` with a populated `changes` field.
- `Xqlite.Result` gained a `changes` field.

## [0.5.1] - 2026-03-16

### Added

- **`XqliteNIF.changes/1`** — returns the row count affected by the most
  recent DML (wraps `sqlite3_changes()`).
- **`XqliteNIF.total_changes/1`** — cumulative row count across the
  connection's lifetime (wraps `sqlite3_total_changes()`).

## [0.5.0] - 2026-03-16

Major feature release. Substantial surface added; several subtle
behavioral changes worth noting on upgrade.

### Added

- **Online backup API.** `XqliteNIF.backup/2` + `restore/2` (one-shot),
  plus `backup_with_progress/6` (page-by-page with progress messages to
  a PID, cancel-token support).
- **Session extension.** `session_new`, `session_attach`, `session_changeset`,
  `session_delete`, `changeset_invert`, `changeset_concat`,
  `changeset_apply` with conflict strategies (`:omit`, `:replace`,
  `:abort`).
- **Incremental blob I/O.** `blob_open`, `blob_read`, `blob_write`,
  `blob_close`. Read and write multi-GB column values without loading
  them into memory.
- **Extension loading.** `enable_load_extension/2` and
  `load_extension/2,3`. Opt-in; disabled by default.
- **Serialize / deserialize.** `serialize/1` captures the entire live
  database as a single binary byte-for-byte identical to its on-disk
  form; `deserialize/2` loads it back.
- **Log hook and update hook** via raw `enif_send`. Per-connection
  update notifications as `{:xqlite_update, action, db, table, rowid}`;
  global log hook as `{:xqlite_log, code, message}`.
- **Type extension behaviour.** `Xqlite.TypeExtension` for bidirectional
  Elixir↔SQLite conversion. Built-ins shipped for `DateTime`, `Date`,
  `Time`, `NaiveDateTime`.
- **`Xqlite.Result`** struct implementing the `Table.Reader` protocol —
  consumable directly by Explorer, Kino, VegaLite.
- **`XqliteNIF.transaction_status/1`** — structured query of the
  current connection's transaction state.
- **Read-only opens.** `open_readonly/1` and `open_in_memory_readonly/1`.
- **Transaction modes.** `deferred`, `immediate`, `exclusive`.
- **Schema-prefixed PRAGMAs.** `:db_name` option for PRAGMAs that accept
  a database name parameter.

### Changed

- **PRAGMA schema reworked** from a keyword list to `Xqlite.PragmaSpec`
  structs. Public shape change for anyone introspecting PRAGMA
  metadata.
- **PRAGMA SET now returns the echoed value** instead of discarding it,
  matching the `{:ok, echoed_value}` shape of the rest of the API.
- **`XqliteNIF.close/1` eagerly releases the underlying SQLite
  connection** rather than waiting for Elixir GC.
- **rusqlite upgraded 0.38 → 0.39.** UTF-8 errors now carry the column
  index of the offending value.

### Fixed

- Stream finalization data race where `sqlite3_finalize` could run
  without the connection Mutex held — a BEAM-segfault-class bug.
- `stream_fetch` now holds the Mutex for the entire fetch loop (was
  dropping it between steps).
- TOCTOU race in the `with_conn` closed-flag check.
- Atom-table exhaustion protection: user input no longer becomes atoms
  unconditionally.
- SQL length overflow guard in `stream_open`.
- Integer-truncation guard for FFI bind calls.
- Identifier quoting: single quotes → double quotes for SQLite spec
  compliance.
- PRAGMA name validation against SQL injection (reject non-identifier
  PRAGMA names).
- PRAGMA validation catch-all for unknown names and corrected numeric
  ranges.
- Interruption detection, cancel ordering, and error-code mapping.

## [0.4.1] - 2026-03-13

### Fixed

- Documentation, README, CI badge, and stale version references
  reconciled across the project.

## [0.4.0] - 2026-03-13

Promotes `v0.4.0-rc.1` to stable. No additional changes since rc.1.

## [0.4.0-rc.1] - 2026-03-13

### Added

- **Precompiled NIFs via `rustler_precompiled`.** No Rust toolchain is
  required to install from Hex. 8 targets covered:
  `aarch64-apple-darwin`, `x86_64-apple-darwin`,
  `aarch64-unknown-linux-gnu`, `x86_64-unknown-linux-gnu`,
  `aarch64-unknown-linux-musl`, `x86_64-unknown-linux-musl`,
  `riscv64gc-unknown-linux-gnu`, `x86_64-pc-windows-msvc`.

### Changed

- Rust edition upgraded 2018 → 2024.

## [0.3.1] - 2025-12-06

### Changed

- Dependencies refreshed.

## [0.3.0] - 2025-11-24

Initial public release. The supported SQLite functionality:

- **Bundled SQLite** — no system install required.
- **Queries, execution, and parameter binding** (positional and named).
- **Transactions** with named savepoints (nested-transaction support).
- **Streaming** row iteration compatible with `Stream.resource/3`.
- **Per-operation cancellation.** Progress-handler-based; any process
  can cancel an in-progress operation without holding the connection
  handle.
- **Typed PRAGMA system** with validated get/set.
- **Schema introspection** via `PRAGMA table_xinfo`, `index_list`,
  `index_xinfo`, `foreign_key_list`, etc. — surfaced as structured
  data, including generated and hidden columns.
- **STRICT table support.**
- **Read-only database opens.**
- **Structured error surface** — constraint violations and failure
  categories mapped to typed atoms (no string parsing needed by
  callers).
- **SQLite introspection** — `compile_options` and `sqlite_version`.

[0.10.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.10.0
[0.9.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.9.0
[0.8.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.8.0
[0.7.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.7.0
[0.6.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.6.0
[0.5.2]: https://github.com/dimitarvp/xqlite/releases/tag/v0.5.2
[0.5.1]: https://github.com/dimitarvp/xqlite/releases/tag/v0.5.1
[0.5.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.5.0
[0.4.1]: https://github.com/dimitarvp/xqlite/releases/tag/v0.4.1
[0.4.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.4.0
[0.4.0-rc.1]: https://github.com/dimitarvp/xqlite/releases/tag/v0.4.0-rc.1
[0.3.1]: https://github.com/dimitarvp/xqlite/releases/tag/v0.3.1
[0.3.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.3.0
