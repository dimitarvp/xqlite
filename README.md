# Xqlite

[![Hex version](https://img.shields.io/hexpm/v/xqlite.svg?style=flat)](https://hex.pm/packages/xqlite)
[![Build Status](https://github.com/dimitarvp/xqlite/actions/workflows/ci.yml/badge.svg)](https://github.com/dimitarvp/xqlite/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Low-level, safe, and fast NIF bindings to SQLite 3 for Elixir, powered by Rust and the excellent [rusqlite](https://crates.io/crates/rusqlite) crate.

This library provides direct access to core SQLite functionality. For seamless Ecto 3.x integration (including connection pooling, migrations, and Ecto types), please see the planned [xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3) library (work in progress).

**Target Audience:** Developers needing direct, performant control over SQLite operations from Elixir, potentially as a foundation for higher-level libraries, or for those not interested in Ecto integration.

## Installation

Add `xqlite` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:xqlite, "~> 0.4.1"}
  ]
end
```

Precompiled NIF binaries are available for the following targets — no Rust toolchain required:

- `aarch64-apple-darwin` (Apple Silicon macOS)
- `x86_64-apple-darwin` (Intel macOS)
- `aarch64-unknown-linux-gnu`
- `aarch64-unknown-linux-musl`
- `x86_64-unknown-linux-gnu`
- `x86_64-unknown-linux-musl`
- `x86_64-pc-windows-msvc`
- `riscv64gc-unknown-linux-gnu`

To force compilation from source (requires a Rust toolchain):

```bash
XQLITE_BUILD=true mix deps.compile xqlite
```

## Core design & thread safety

SQLite connections (`rusqlite::Connection`) are not inherently thread-safe for concurrent access ([`!Sync`](https://github.com/rusqlite/rusqlite/issues/342#issuecomment-592624109)). To safely expose connections to the concurrent Elixir environment, `xqlite` wraps each `rusqlite::Connection` within an `Arc<Mutex<_>>` managed by a `ResourceArc`.

- **Safety:** This ensures that only one Elixir process can access a specific SQLite connection handle at any given moment, preventing data races and ensuring compatibility with Rustler's `Resource` requirements (`Sync`).
- **Handles:** NIF functions return opaque, thread-safe resource handles representing individual SQLite connections.
- **Pooling:** This NIF layer **does not** implement connection pooling. Managing a pool of connections (e.g., using `DBConnection`) is the responsibility of the calling Elixir code or higher-level libraries like the planned `xqlite_ecto3`.

This library prioritizes compatibility with **modern SQLite versions** (>= 3.35.0 recommended). While it may work on older versions, explicit support or workarounds for outdated SQLite features are not a primary goal. **Notably, retrieving primary key values automatically after insertion into `WITHOUT ROWID` tables is only reliably supported via the `RETURNING` clause (available since SQLite 3.35.0). Using `WITHOUT ROWID` tables on older SQLite versions may require you to supply primary key values explicitly within your application, as `last_insert_rowid/1` cannot be used for these tables.**

## Current capabilities

The library provides two primary modules: `Xqlite` for a higher-level Elixir API, and `XqliteNIF` for direct, low-level access. See [hexdocs](https://hexdocs.pm/xqlite) for full parameter and return type details.

### High-level API (`Xqlite` and `Xqlite.Pragma` modules)

- **`Xqlite.stream/4`**: Creates an Elixir `Stream` to lazily fetch rows from a query. Rows are returned as maps with atom keys.
- **PRAGMA Helpers**: `Xqlite.Pragma.get/4` and `Xqlite.Pragma.put/3` provide a structured interface for interacting with SQLite PRAGMAs.
- **Convenience Helpers**: `Xqlite.enable_foreign_key_enforcement/1`, `Xqlite.enable_strict_mode/1`, etc.

### Low-level NIF API (`XqliteNIF` module)

- **Connection:** `open/1`, `open_in_memory/0`, `open_temporary/0`, `close/1`
- **Queries:** `query/3`, `query_cancellable/4` — returns `%{columns, rows, num_rows}`
- **Execution:** `execute/3`, `execute_cancellable/4` — returns `{:ok, affected_rows}`; `execute_batch/2`, `execute_batch_cancellable/3` — returns `:ok`
- **Streaming:** `stream_open/4`, `stream_get_columns/1`, `stream_fetch/2`, `stream_close/1`
- **Cancellation:** `create_cancel_token/0`, `cancel_operation/1`
- **PRAGMAs:** `get_pragma/2`, `set_pragma/3`
- **Transactions:** `begin/1`, `commit/1`, `rollback/1`, `savepoint/2`, `release_savepoint/2`, `rollback_to_savepoint/2`
- **Row ID:** `last_insert_rowid/1`
- **Schema:** `schema_databases/1`, `schema_list_objects/2`, `schema_columns/2`, `schema_foreign_keys/2`, `schema_indexes/2`, `schema_index_columns/2`, `get_create_sql/2`
- **Diagnostics:** `compile_options/1`, `sqlite_version/0`
- **Errors:** `{:ok, result}` / `:ok` on success; `{:error, {reason_atom, ...}}` on failure with structured tuples (e.g., `{:sqlite_failure, code, extended_code, message}`)

## Known limitations and caveats

- **`last_insert_rowid/1`:**
  - Reflects the state of the specific connection handle. Avoid sharing handles for concurrent `INSERT`s outside a proper pooling mechanism.
  - Does not work for `WITHOUT ROWID` tables. Use `INSERT ... RETURNING`.
- **Operation Cancellation Performance:** The current cancellation mechanism uses SQLite's progress handler with a frequent check interval. This ensures testability but introduces overhead to cancellable operations. This will be benchmarked and potentially optimized in the future.
- **Generated Column `default_value` (Schema Introspection):** `Xqlite.Schema.ColumnInfo.default_value` will be `nil` for generated columns when using `XqliteNIF.schema_columns/2`. The generation expression is not directly available in the `dflt_value` column of `PRAGMA table_xinfo`. To get the full expression, parse the output of `XqliteNIF.get_create_sql/2`.
- **Invalid UTF-8 in TEXT Columns with SQL Functions:** Applying certain SQL text functions (e.g., `UPPER()`, `LOWER()`) to `TEXT` columns containing byte sequences that are not valid UTF-8 may cause the underlying SQLite C library to panic, leading to a NIF crash. Ensure data stored in `TEXT` columns intended for such processing is valid UTF-8, or avoid these functions on potentially corrupt data.
- **User-Defined Functions (UDFs):** Support for UDFs is of very low priority due to its significant implementation complexity and is not currently planned.

## Basic usage examples

```elixir
# --- Opening a connection ---
{:ok, conn} = XqliteNIF.open("my_database.db")

# --- Using Xqlite helpers ---
:ok = Xqlite.enable_foreign_key_enforcement(conn)
:ok = Xqlite.enable_strict_mode(conn)

# --- Executing a query (SELECT) ---
sql_select = "SELECT id, name FROM users WHERE id = ?1;"
params_select = [1]
IO.inspect(XqliteNIF.query(conn, sql_select, params_select), label: "Query Result")

# --- Executing a cancellable query ---
# (Assume `slow_query_sql` is a long-running SQL. See test/nif/cancellation_test.exs for examples)
{:ok, cancel_token} = XqliteNIF.create_cancel_token()
long_query_task = Task.async(fn ->
  XqliteNIF.query_cancellable(conn, slow_query_sql, [], cancel_token)
end)
Process.sleep(100)
:ok = XqliteNIF.cancel_operation(cancel_token)
IO.inspect(Task.await(long_query_task, 5000), label: "Cancelled Query Result")

# --- Querying Schema Information ---
{:ok, columns} = XqliteNIF.schema_columns(conn, "users")
IO.inspect(columns, label: "Columns for 'users' table")

# --- Using a transaction ---
case XqliteNIF.begin(conn) do
  :ok ->
    # ... perform operations ...
    case XqliteNIF.execute(conn, "UPDATE accounts SET balance = 0 WHERE id = 1", []) do
      {:ok, _affected_rows} ->
        :ok = XqliteNIF.commit(conn)
        IO.puts("Transaction committed.")
      {:error, reason_update} ->
        IO.inspect(reason_update, label: "Update failed, rolling back")
        :ok = XqliteNIF.rollback(conn)
    end
  {:error, reason_begin} ->
    IO.inspect(reason_begin, label: "Failed to begin transaction")
end
```

## Roadmap

Planned for **xqlite**:

1. Extension loading (`load_extension/2`)
2. Online Backup API
3. Session Extension
4. (Lower priority) Incremental Blob I/O
5. (Optional) SQLCipher support
6. (Lowest priority) User-Defined Functions

The **[xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3)** library (separate project) will provide full Ecto 3.x adapter, `DBConnection` integration, type handling, migrations, and structure dump/load.

Other future work: benchmark cancellation progress handler overhead; report `UPPER(invalid_utf8)` panic behavior to relevant projects.

## Contributing

Contributions are welcome! Please feel free to open issues or submit pull requests.

## License

This project is licensed under the terms of the MIT license. See the [`LICENSE.md`](LICENSE.md) file for details.
