# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.6.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.6.0
