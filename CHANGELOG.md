# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Breaking

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

- **`Xqlite.busy_timeout/2`** — sets a plain `sqlite3_busy_timeout` while
  cleanly reclaiming any xqlite-installed busy handler first. Prefer this
  over `PRAGMA busy_timeout`, which silently replaces the busy handler at
  the SQLite C level and stops `{:xqlite_busy, …}` delivery without
  removing our internal slot.
- Busy-handler PRAGMA-replacement warning front-and-center in the module
  docs and README.
- **WAL hook**: `XqliteNIF.set_wal_hook/2` + `remove_wal_hook/1`. Sends
  `{:xqlite_wal, db_name, pages}` to a pid after each commit in WAL mode.
  Front-and-center warning about `PRAGMA wal_autocheckpoint` silently
  replacing the hook (same semantics as busy_handler).
- **Commit hook**: `XqliteNIF.set_commit_hook/2` + `remove_commit_hook/1`.
  Sends `{:xqlite_commit}` to a pid immediately before each commit.
  Observation-only — never vetoes the commit.
- **Rollback hook**: `XqliteNIF.set_rollback_hook/2` +
  `remove_rollback_hook/1`. Sends `{:xqlite_rollback}` to a pid after
  each rollback.

### Internal

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

[0.6.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.6.0
[0.5.2]: https://github.com/dimitarvp/xqlite/releases/tag/v0.5.2
[0.5.1]: https://github.com/dimitarvp/xqlite/releases/tag/v0.5.1
[0.5.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.5.0
[0.4.1]: https://github.com/dimitarvp/xqlite/releases/tag/v0.4.1
[0.4.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.4.0
[0.4.0-rc.1]: https://github.com/dimitarvp/xqlite/releases/tag/v0.4.0-rc.1
[0.3.1]: https://github.com/dimitarvp/xqlite/releases/tag/v0.3.1
[0.3.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.3.0
