# Xqlite

[![Hex version](https://img.shields.io/hexpm/v/xqlite.svg?style=flat)](https://hex.pm/packages/xqlite)
[![Build Status](https://github.com/dimitarvp/xqlite/workflows/CI/badge.svg)](https://github.com/dimitarvp/xqlite/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Low-level, safe, and fast NIF bindings to SQLite 3 for Elixir, powered by Rust and the excellent [rusqlite](https://crates.io/crates/rusqlite) crate.

This library provides direct access to core SQLite functionality. For seamless Ecto 3.x integration (including connection pooling, migrations, and Ecto types), please see the planned [xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3) library (work in progress).

**Target Audience:** Developers needing direct, performant control over SQLite operations from Elixir, potentially as a foundation for higher-level libraries, or for those not interested in Ecto integration.

## Core design & thread safety

SQLite connections (`rusqlite::Connection`) are not inherently thread-safe for concurrent access ([`!Sync`](https://github.com/rusqlite/rusqlite/issues/342#issuecomment-592624109)). To safely expose connections to the concurrent Elixir environment, `xqlite` wraps each `rusqlite::Connection` within an `Arc<Mutex<_>>` managed by a `ResourceArc`.

- **Safety:** This ensures that only one Elixir process can access a specific SQLite connection handle at any given moment, preventing data races and ensuring compatibility with Rustler's `Resource` requirements (`Sync`).
- **Handles:** NIF functions return opaque, thread-safe resource handles representing individual SQLite connections.
- **Pooling:** This NIF layer **does not** implement connection pooling. Managing a pool of connections (e.g., using `DBConnection`) is the responsibility of the calling Elixir code or higher-level libraries like the planned `xqlite_ecto3`.

This library prioritizes compatibility with **modern SQLite versions** (>= 3.35.0 recommended). While it may work on older versions, explicit support or workarounds for outdated SQLite features are not a primary goal. **Notably, retrieving primary key values automatically after insertion into `WITHOUT ROWID` tables is only reliably supported via the `RETURNING` clause (available since SQLite 3.35.0). Using `WITHOUT ROWID` tables on older SQLite versions may require you to supply primary key values explicitly within your application, as `last_insert_rowid/1` cannot be used for these tables.**

## Current capabilities

The library provides two primary modules: `Xqlite` for a higher-level Elixir API, and `XqliteNIF` for direct, low-level access.

### High-level API (`Xqlite` and `Xqlite.Pragma` modules)

- **`Xqlite.stream/4`**: Creates an Elixir `Stream` to lazily fetch rows from a query. Rows are returned as maps with atom keys.
- **PRAGMA Helpers**: `Xqlite.Pragma.get/4` and `Xqlite.Pragma.put/3` provide a structured interface for interacting with SQLite PRAGMAs.
- **Convenience Helpers**: `Xqlite.enable_foreign_key_enforcement/1`, `Xqlite.enable_strict_mode/1`, etc.

### Low-level NIF API (`XqliteNIF` module)

- **Connection management:**
  - `open(path :: String.t())`: Opens a file-based database.
  - `open_in_memory()` or `open_in_memory(uri :: String.t())`: Opens an in-memory database.
  - `open_temporary()`: Opens a private, temporary on-disk database.
  - `close(conn)`: Closes the connection.

- **Query execution:**
  - `query(conn, sql :: String.t(), params :: list() | keyword())`: Executes `SELECT` or other row-returning statements.
  - `query_cancellable(conn, sql :: String.t(), params :: list() | keyword(), cancel_token)`: Cancellable version.
    - Returns `{:ok, %{columns: [String.t()], rows: [[term()]], num_rows: non_neg_integer()}}` or `{:error, reason}`.

- **Statement execution:**
  - `execute(conn, sql :: String.t(), params :: list())`: Executes non-row-returning statements (e.g., `INSERT`, `UPDATE`, `DDL`).
  - `execute_cancellable(conn, sql :: String.t(), params :: list(), cancel_token)`: Cancellable version.
  - `execute_batch(conn, sql_batch :: String.t())`: Executes multiple SQL statements. Returns `:ok` on success.
  - `execute_batch_cancellable(conn, sql_batch :: String.t(), cancel_token)`: Cancellable version. Returns `:ok` on success.
    - `execute` variants return `{:ok, affected_rows :: non_neg_integer()}`.
    - `execute_batch` variants return `:ok` on success or `{:error, reason}`.

- **Streaming primitives:**
  - `stream_open(conn, sql, params, opts)`: Prepares a query and returns a stream handle.
  - `stream_get_columns(stream_handle)`: Retrieves column names from the prepared stream.
  - `stream_fetch(stream_handle, batch_size)`: Fetches a batch of rows from the stream.
  - `stream_close(stream_handle)`: Closes the stream and finalizes the statement.

- **Operation cancellation:**
  - `create_cancel_token()`: Creates a token for signalling cancellation. Returns `{:ok, token_resource}`.
  - `cancel_operation(cancel_token)`: Signals an operation associated with the token to cancel. Returns `:ok` on success.

- **PRAGMA handling:**
  - `get_pragma(conn, pragma_name :: String.t())`: Reads a PRAGMA value.
  - `set_pragma(conn, pragma_name :: String.t(), value :: term())`: Sets a PRAGMA value. Returns `:ok` on success.

- **Transaction control:**
  - `begin(conn)`, `commit(conn)`, `rollback(conn)`
  - `savepoint(conn, name)`, `release_savepoint(conn, name)`, `rollback_to_savepoint(conn, name)`
  - All return `:ok` on success or `{:error, reason}`.

- **Inserted row ID:**
  - `last_insert_rowid(conn)`: Retrieves the `rowid` of the most recent `INSERT`.

- **Schema introspection:**
  - `schema_databases(conn)`
  - `schema_list_objects(conn, schema \\ nil)` (Returns `Xqlite.Schema.SchemaObjectInfo` with `:is_without_rowid` flag)
  - `schema_columns(conn, table_name)` (Returns `Xqlite.Schema.ColumnInfo` with `:hidden_kind` flag)
  - `schema_foreign_keys(conn, table_name)`
  - `schema_indexes(conn, table_name)`
  - `schema_index_columns(conn, index_name)`
  - `get_create_sql(conn, object_name)`

- **Error handling:**
  - Functions return `{:ok, result}`, `:ok` (for simple success), or `{:error, reason}`.
  - `reason` is a structured tuple (e.g., `{:sqlite_failure, code, extended_code, message}`, `{:operation_cancelled}`).

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
alias XqliteNIF
alias Xqlite # For helper functions

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

The following features are planned for the **`xqlite`** library:

1.  **Implement Extension Loading:** Add `load_extension/2` NIF.
2.  **Implement Online Backup API:** Add NIFs for SQLite's Online Backup API.
3.  **Implement Session Extension:** Add NIFs for SQLite's Session Extension.
4.  **(Lower Priority)** Implement Incremental Blob I/O.
5.  **(Optional)** Add SQLCipher Support (build feature).
6.  **(Lowest Priority / Tentative)** User-Defined Functions (UDFs).

The **`xqlite_ecto3`** library (separate project) will provide:

- Full Ecto 3.x adapter implementation.
- `DBConnection` integration.
- Type handling, migrations, structure dump/load.

## Future considerations (post core roadmap)

- Benchmark cancellation progress handler overhead.
- Report `UPPER(invalid_utf8)` panic behavior observed with SQLite to relevant projects if appropriate.

## Installation

This package is not yet published on hex.pm. To use it, add this to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:xqlite, github: "dimitarvp/xqlite"}
  ]
end
```

Ensure you have a compatible Rust toolchain installed.

## Contributing

Contributions are welcome! Please feel free to open issues or submit pull requests.

## License

This project is licensed under the terms of the MIT license. See the [`LICENSE.md`](LICENSE.md) file for details.
