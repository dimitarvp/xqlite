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
    {:xqlite, "~> 0.4.1"}
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

- **`Xqlite.stream/4`** — lazily fetch rows as string-keyed maps via `Stream.resource/3`
- **`Xqlite.Result`** — query result struct implementing `Table.Reader` (works with Explorer, Kino, VegaLite)
- **`Xqlite.Pragma`** — typed PRAGMA schema with `get/4` and `put/4`, covering 60+ PRAGMAs with validation
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
- **Schema:** `schema_databases/1`, `schema_list_objects/2`, `schema_columns/2`, `schema_foreign_keys/2`, `schema_indexes/2`, `schema_index_columns/2`, `get_create_sql/2`
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
```

## Known limitations

- **`last_insert_rowid/1`** does not work for `WITHOUT ROWID` tables. Use `INSERT ... RETURNING` (SQLite >= 3.35.0).
- **Generated column `default_value`** in `schema_columns/2` is `nil`. Use `get_create_sql/2` for the expression.
- **Invalid UTF-8 in TEXT columns** — applying SQL text functions (`UPPER()`, `LOWER()`) to non-UTF-8 data may crash the SQLite C library.
- **User-Defined Functions** — not planned due to implementation complexity across NIF boundaries.

## Roadmap

Planned for **xqlite** core (before Ecto adapter work):

1. Extension loading (`load_extension/2`)
2. Serialize / deserialize database to binary
3. Change notification hooks (`set_update_hook/2`)
4. Online Backup API
5. Incremental Blob I/O

**Then:** [xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3) — full Ecto 3.x adapter with `DBConnection`, migrations, type handling.

## Contributing

Contributions are welcome. Please open issues or submit pull requests.

## License

MIT — see [`LICENSE.md`](LICENSE.md).
