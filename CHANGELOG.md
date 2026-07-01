# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
