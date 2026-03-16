# Xqlite

[![Hex version](https://img.shields.io/hexpm/v/xqlite.svg?style=flat)](https://hex.pm/packages/xqlite)
[![Build Status](https://github.com/dimitarvp/xqlite/actions/workflows/ci.yml/badge.svg)](https://github.com/dimitarvp/xqlite/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Low-level, safe, and fast NIF bindings to SQLite 3 for Elixir, powered by Rust and [rusqlite](https://crates.io/crates/rusqlite). Bundled SQLite — no native install required.

For Ecto 3.x integration see the planned [xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3) library (work in progress).

## Installation

```elixir
def deps do
  [
    {:xqlite, "~> 0.5.1"}
  ]
end
```

Precompiled NIF binaries ship for 8 targets (macOS, Linux, Windows, including ARM and RISC-V) — no Rust toolchain needed. To force source compilation:

```bash
XQLITE_BUILD=true mix deps.compile xqlite
```

## Thread safety

Each `rusqlite::Connection` is wrapped in `Arc<Mutex<_>>` via Rustler's `ResourceArc`. One Elixir process accesses a given connection at a time. Connection pooling belongs in higher layers (DBConnection / Ecto adapter).

SQLite is opened with `SQLITE_OPEN_NO_MUTEX` (rusqlite's default) — the Rust Mutex replaces SQLite's internal one, not the other way around.

## Capabilities

Two modules: `Xqlite` for high-level helpers, `XqliteNIF` for direct NIF access. See [hexdocs](https://hexdocs.pm/xqlite) for full API reference.

### High-level API

- **`Xqlite.stream/4`** — lazily fetch rows as string-keyed maps via `Stream.resource/3`; supports `:type_extensions` option for automatic encode/decode
- **`Xqlite.TypeExtension`** — behaviour for bidirectional Elixir↔SQLite type conversion. Built-in extensions: `DateTime`, `NaiveDateTime`, `Date`, `Time` (all ISO 8601)
- **`Xqlite.Result`** — query result struct implementing `Table.Reader` (works with Explorer, Kino, VegaLite)
- **`Xqlite.Pragma`** — typed PRAGMA schema with `get/4` and `put/4`, covering 68 PRAGMAs with validation
- **Convenience helpers** — `enable_foreign_key_enforcement/1`, `enable_strict_mode/1`, etc.

### Low-level NIF API (`XqliteNIF`)

- **Connection:** `open/1`, `open_in_memory/0`, `open_readonly/1`, `open_in_memory_readonly/0`, `open_temporary/0`, `close/1`
- **Queries:** `query/3`, `query_cancellable/4` — returns `%{columns, rows, num_rows}`
- **Execution:** `execute/3`, `execute_cancellable/4` — returns `{:ok, affected_rows}`; `execute_batch/2`, `execute_batch_cancellable/3`
- **Streaming:** `stream_open/4`, `stream_get_columns/1`, `stream_fetch/2`, `stream_close/1`
- **Cancellation:** `create_cancel_token/0`, `cancel_operation/1` — per-operation, progress-handler-based, fine-grained
- **PRAGMAs:** `get_pragma/2`, `set_pragma/3`
- **Transactions:** `begin/2` (`:deferred` / `:immediate` / `:exclusive`), `commit/1`, `rollback/1`, `transaction_status/1`, `savepoint/2`, `release_savepoint/2`, `rollback_to_savepoint/2`
- **Row ID:** `last_insert_rowid/1`
- **Changes:** `changes/1` — rows affected by last DML; `total_changes/1` — cumulative since connection opened
- **Schema:** `schema_databases/1`, `schema_list_objects/2`, `schema_columns/2`, `schema_foreign_keys/2`, `schema_indexes/2`, `schema_index_columns/2`, `get_create_sql/2`
- **Log hook:** `set_log_hook/1`, `remove_log_hook/0` — global SQLite diagnostic log forwarded to a PID as `{:xqlite_log, code, message}`
- **Update hook:** `set_update_hook/2`, `remove_update_hook/1` — per-connection change notifications as `{:xqlite_update, action, db_name, table, rowid}`
- **Serialize:** `serialize/1`, `serialize/2`, `deserialize/2`, `deserialize/4` — atomic database snapshots to/from contiguous binary
- **Extensions:** `enable_load_extension/2`, `load_extension/2`, `load_extension/3` — opt-in loading of SQLite extensions from shared libraries
- **Backup:** `backup/2`, `backup/3`, `restore/2`, `restore/3` — one-shot online backup/restore to/from file; `backup_with_progress/6` — incremental backup with progress messages and cancellation
- **Session:** `session_new/1`, `session_attach/2`, `session_changeset/1`, `session_patchset/1`, `session_is_empty/1`, `session_delete/1`, `changeset_apply/3`, `changeset_invert/1`, `changeset_concat/2` — change tracking, changeset capture/apply/invert/concat with conflict strategies
- **Blob I/O:** `blob_open/6`, `blob_read/3`, `blob_write/3`, `blob_size/1`, `blob_reopen/2`, `blob_close/1` — incremental read/write of large BLOBs without loading into memory
- **Diagnostics:** `compile_options/1`, `sqlite_version/0`

Errors are structured tuples: `{:error, {:constraint_violation, :constraint_foreign_key, msg}}`, `{:error, {:read_only_database, msg}}`, etc. 30+ typed reason variants including all 13 SQLite constraint subtypes.

## Usage

```elixir
# Open and configure
{:ok, conn} = XqliteNIF.open("my_database.db")
:ok = Xqlite.enable_foreign_key_enforcement(conn)

# Query
{:ok, result} = XqliteNIF.query(conn, "SELECT id, name FROM users WHERE id = ?1", [1])
# => %{columns: ["id", "name"], rows: [[1, "Alice"]], num_rows: 1}

# Use with Table.Reader (Explorer, Kino, etc.)
result |> Xqlite.Result.from_map() |> Table.to_rows()
# => [%{"id" => 1, "name" => "Alice"}]

# Stream large result sets
Xqlite.stream(conn, "SELECT * FROM events") |> Enum.take(100)

# Transaction with immediate lock
:ok = XqliteNIF.begin(conn, :immediate)
{:ok, 1} = XqliteNIF.execute(conn, "UPDATE accounts SET balance = 0 WHERE id = 1", [])
:ok = XqliteNIF.commit(conn)

# Cancel a long-running query from another process
{:ok, token} = XqliteNIF.create_cancel_token()
task = Task.async(fn -> XqliteNIF.query_cancellable(conn, slow_sql, [], token) end)
:ok = XqliteNIF.cancel_operation(token)
{:error, :operation_cancelled} = Task.await(task)

# Read-only connection (writes fail with {:error, {:read_only_database, _}})
{:ok, ro_conn} = XqliteNIF.open_readonly("my_database.db")

# Receive SQLite diagnostic events (auto-index warnings, schema changes, etc.)
{:ok, :ok} = XqliteNIF.set_log_hook(self())
# => receive {:xqlite_log, 284, "automatic index on ..."}

# Receive per-connection change notifications
:ok = XqliteNIF.set_update_hook(conn, self())
{:ok, 1} = XqliteNIF.execute(conn, "INSERT INTO users (name) VALUES ('Bob')", [])
# => receive {:xqlite_update, :insert, "main", "users", 2}

# Type extensions: automatic DateTime/Date/Time encoding and decoding
alias Xqlite.TypeExtension

extensions = [TypeExtension.DateTime, TypeExtension.Date, TypeExtension.Time]
params = TypeExtension.encode_params([~U[2024-01-15 10:30:00Z], ~D[2024-06-15]], extensions)
{:ok, 1} = XqliteNIF.execute(conn, "INSERT INTO events (ts, day) VALUES (?1, ?2)", params)

# Stream with automatic type decoding
Xqlite.stream(conn, "SELECT ts, day FROM events", [],
  type_extensions: [TypeExtension.DateTime, TypeExtension.Date])
|> Enum.to_list()
# => [%{"ts" => ~U[2024-01-15 10:30:00Z], "day" => ~D[2024-06-15]}]

# Serialize an in-memory database to a binary snapshot
{:ok, binary} = XqliteNIF.serialize(conn)

# Restore from a snapshot (e.g., transfer between connections, backups)
{:ok, conn2} = XqliteNIF.open_in_memory()
:ok = XqliteNIF.deserialize(conn2, binary)

# Read-only deserialization (writes will fail)
:ok = XqliteNIF.deserialize(conn2, "main", binary, true)

# Load a SQLite extension (e.g., spatialite, sqlean modules)
:ok = XqliteNIF.enable_load_extension(conn, true)
:ok = XqliteNIF.load_extension(conn, "/path/to/extension")
:ok = XqliteNIF.enable_load_extension(conn, false)

# Online backup to file, then restore into a new connection
:ok = XqliteNIF.backup(conn, "/path/to/backup.db")
{:ok, conn3} = XqliteNIF.open_in_memory()
:ok = XqliteNIF.restore(conn3, "/path/to/backup.db")

# Backup with progress reporting and cancellation
{:ok, token} = XqliteNIF.create_cancel_token()
:ok = XqliteNIF.backup_with_progress(conn, "main", "/path/to/backup.db", self(), 10, token)
# Receive {:xqlite_backup_progress, remaining, pagecount} messages
# Cancel from another process: XqliteNIF.cancel_operation(token)

# Track changes with sessions, then replicate to another database
{:ok, session} = XqliteNIF.session_new(conn)
:ok = XqliteNIF.session_attach(session, nil)
{:ok, 1} = XqliteNIF.execute(conn, "INSERT INTO users VALUES (1, 'alice')", [])
{:ok, changeset} = XqliteNIF.session_changeset(session)
:ok = XqliteNIF.session_delete(session)

# Apply changeset to replica (conflict strategies: :omit, :replace, :abort)
:ok = XqliteNIF.changeset_apply(replica_conn, changeset, :replace)

# Incremental blob I/O — read/write large BLOBs in chunks
{:ok, 1} = XqliteNIF.execute(conn, "INSERT INTO files VALUES (1, zeroblob(1048576))", [])
{:ok, blob} = XqliteNIF.blob_open(conn, "main", "files", "data", 1, false)
:ok = XqliteNIF.blob_write(blob, 0, chunk1)
:ok = XqliteNIF.blob_write(blob, byte_size(chunk1), chunk2)
{:ok, header} = XqliteNIF.blob_read(blob, 0, 64)
:ok = XqliteNIF.blob_close(blob)
```

## Known limitations

- **`last_insert_rowid/1`** does not work for `WITHOUT ROWID` tables. Use `INSERT ... RETURNING` (SQLite >= 3.35.0).
- **Generated column `default_value`** in `schema_columns/2` is `nil`. Use `get_create_sql/2` for the expression.
- **Invalid UTF-8 in TEXT columns** — applying SQL text functions (`UPPER()`, `LOWER()`) to non-UTF-8 data may crash the SQLite C library.
- **User-Defined Functions** — not planned due to implementation complexity across NIF boundaries.

## Design notes

### Backup API

xqlite provides two backup interfaces: one-shot (`backup/2`, `restore/2`) and incremental with progress (`backup_with_progress/6`).

The incremental variant runs the entire backup inside a single NIF call on a dirty I/O scheduler, sending `{:xqlite_backup_progress, remaining, pagecount}` messages to a PID after each step. A cancel token (the same one used for `query_cancellable/4`) allows another process to abort the backup at any time.

We chose this single-call design over exposing a step-by-step `Backup` resource handle because:

- **No double-connection risk.** SQLite's incremental backup API requires holding two connections simultaneously (source + destination). In Ecto/DBConnection pools, checking out two connections at once is a classic deadlock risk. Our API takes a file path as the destination, avoiding this entirely.
- **No manual lifecycle management.** A step-by-step API would require callers to explicitly close/finish the backup handle. Forgotten handles leak resources. Our approach creates, runs, and cleans up the backup in one call.
- **Cancellation and progress are already covered.** The cancel token + progress messages give callers everything they need for UI feedback and timeout enforcement without exposing low-level step control.

For use cases that genuinely require step-level control from Elixir (e.g., custom retry logic between steps), `serialize/1` and `deserialize/2` provide atomic database snapshots as binaries that can be chunked and managed in pure Elixir. If demand for a step-by-step backup resource materializes, it can be added in a future release.

### Affected row counts (`changes/1`)

`query/3` returns `%{columns, rows, num_rows}` where `num_rows` is the count of *result rows* — not SQLite's `sqlite3_changes()`. For SELECT statements these are the same thing. For DML (INSERT/UPDATE/DELETE without RETURNING), `query/3` returns `num_rows: 0` because there are no result rows, even though rows were affected.

To get the actual affected row count after DML, call `changes/1` immediately after the statement. This is a separate NIF call, not folded into `query/3`, because `sqlite3_changes()` is a connection-level function — it reflects the *last* completed statement, not a specific query handle. Folding it into `query/3` would report stale counts if a trigger or concurrent operation modified the connection state between the statement's completion and the changes read.

This matches how exqlite handles it (`Sqlite3.changes/1` after `step`), and how the `xqlite_ecto3` adapter wires it: DML → `query_cancellable` → `changes/1` → populate `num_rows`.

## Roadmap

Planned for **xqlite** core (before Ecto adapter work):

1. SQLCipher support (optional)
2. User-Defined Functions (extremely fiddly across NIF boundaries)
3. Manual statement lifecycle (prepare/bind/step/reset/release)

**Then:** [xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3) — full Ecto 3.x adapter with `DBConnection`, migrations, type handling.

## Contributing

Contributions are welcome. Please open issues or submit pull requests.

## License

MIT — see [`LICENSE.md`](LICENSE.md).
