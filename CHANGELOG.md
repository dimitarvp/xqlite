# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.6.0] - 2026-04-19

Sixteen commits since v0.5.2. Minor bump because one of them is a
user-facing breaking change in error shape; the rest are additive.

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
  `EXPLAIN (ANALYZE)`. Requires the bundled SQLite to be built with
  `SQLITE_ENABLE_STMT_SCANSTATUS` — now enabled by default via
  `LIBSQLITE3_FLAGS` in `native/xqlitenif/.cargo/config.toml`.
- **`XqliteNIF.autocommit/1`** — zero-cost wrapper around
  `sqlite3_get_autocommit`. Returns `{:ok, true}` in auto-commit mode,
  `{:ok, false}` inside a transaction.
- **`XqliteNIF.txn_state/2`** — zero-cost wrapper around
  `sqlite3_txn_state`. Returns `{:ok, :none | :read | :write}` for
  the named schema (defaults to `"main"`). The production-safe
  substitute for `SQLITE_FCNTL_LOCKSTATE` (which would require
  `SQLITE_DEBUG` and is unsuitable for production).
- **`Xqlite.open/2` and `Xqlite.open_in_memory/1`** — high-level
  open functions with validated options via
  [`nimble_options`](https://hex.pm/packages/nimble_options). Options
  are type-checked at the boundary and produce structured errors on
  misuse.
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

### Changed

- README reworked for the 0.6.0 audience: features list now fronts
  `Xqlite.explain_analyze/3` + per-operation cancellation +
  structured errors; roadmap restructured around observability,
  `:telemetry` integration, manual statement lifecycle, and optional
  SQLCipher.
- CI precommit now runs `cargo test` alongside `cargo fmt` / `cargo
  clippy`. Both `mix precommit` and `.github/workflows/ci.yml` invoke
  `cargo` with `cwd = native/xqlitenif` so the crate's
  `.cargo/config.toml` (which sets `LIBSQLITE3_FLAGS`) is honored.

### Internal

- Added `nimble_options` dependency.
- Consolidated module attribute declarations at the top of each
  module for readability.
- Test file rules: never assert on error message text (persisted as a
  project-level convention).

[0.6.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.6.0
