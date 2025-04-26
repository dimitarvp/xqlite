# Xqlite

[![Hex version](https://img.shields.io/hexpm/v/xqlite.svg?style=flat)](https://hex.pm/packages/xqlite)
[![Build Status](https://github.com/dimitarvp/xqlite/workflows/CI/badge.svg)](https://github.com/dimitarvp/xqlite/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Low-level, safe, and fast NIF bindings to SQLite 3 for Elixir, powered by Rust and the excellent [rusqlite](https://crates.io/crates/rusqlite) crate.

This library provides direct access to core SQLite functionality. For seamless Ecto 3.x integration (including connection pooling, migrations, and Ecto types), please see the planned [xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3) library (work in progress).

**Target Audience:** Developers needing direct, performant control over SQLite operations from Elixir, potentially as a foundation for higher-level libraries, or for those not interested in Ecto integration.

## Core Design & Thread Safety

SQLite connections (`rusqlite::Connection`) are not inherently thread-safe for concurrent access ([`!Sync`](https://github.com/rusqlite/rusqlite/issues/342#issuecomment-592624109)). To safely expose connections to the concurrent Elixir environment, `xqlite` wraps each `rusqlite::Connection` within an `Arc<Mutex<_>>` managed by a `ResourceArc`.

- **Safety:** This ensures that only one Elixir process can access a specific SQLite connection handle at any given moment, preventing data races and ensuring compatibility with Rustler's `Resource` requirements (`Sync`).
- **Handles:** NIF functions return opaque, thread-safe resource handles (`ResourceArc<XqliteConn>`) representing individual SQLite connections.
- **Pooling:** This NIF layer **does not** implement connection pooling. Managing a pool of connections (e.g., using `DBConnection`) is the responsibility of the calling Elixir code or higher-level libraries like the planned `xqlite_ecto3`.

This library prioritizes compatibility with **modern SQLite versions**. While it may work on older versions, explicit support or workarounds for outdated SQLite features are not a primary goal.

## Current Capabilities

The `XqliteNIF` module provides the following low-level functions:

- **Connection Management:**
  - `raw_open(path :: String.t())`: Opens a file-based database.
  - `raw_open_in_memory(uri :: String.t())`: Opens an in-memory database (can use URI options like `cache=shared`).
  - `raw_open_temporary()`: Opens a private, temporary on-disk database.
  - `raw_close(conn :: ResourceArc<XqliteConn>)`: Conceptually closes the connection (relies on BEAM garbage collection of the resource handle for actual closing). Returns `{:ok, true}` immediately.
- **Query Execution:**
  - `raw_query(conn, sql :: String.t(), params :: list() | keyword())`: Executes `SELECT` or other row-returning statements.
    - Supports positional (`[1, "foo"]`) or named (`[val1: 1, val2: "foo"]`) parameters.
    - Returns `{:ok, %{columns: [String.t()], rows: [[term()]], num_rows: non_neg_integer()}}` or `{:error, reason}`.
- **Statement Execution:**
  - `raw_execute(conn, sql :: String.t(), params :: list())`: Executes `INSERT`, `UPDATE`, `DELETE`, DDL, etc.
    - Supports positional parameters only (`[1, "foo"]`).
    - Returns `{:ok, affected_rows :: non_neg_integer()}` or `{:error, reason}`.
- **PRAGMA Handling:**
  - `raw_pragma_write(conn, pragma_sql :: String.t())`: Executes a PRAGMA statement that modifies state (e.g., `PRAGMA journal_mode = WAL`). Returns affected rows (usually 0).
  - `raw_pragma_write_and_read(conn, pragma_name :: String.t(), value :: term())`: Sets a PRAGMA value and reads it back. Returns `{:ok, read_value}` or `{:ok, :no_value}`.
- **Transaction Control:**
  - `raw_begin(conn)`: Executes `BEGIN;`.
  - `raw_commit(conn)`: Executes `COMMIT;`.
  - `raw_rollback(conn)`: Executes `ROLLBACK;`.
- **Error Handling:**
  - All functions return `{:ok, result}` or `{:error, reason}` tuples.
  - `reason` provides structured information about the error (e.g., `{:sqlite_failure, code, extended_code, message}`, `{:constraint_violation, kind, message}`, `{:invalid_parameter_count, %{expected: _, provided: _}}`, etc.). See `XqliteError` in Rust code for details.

## Basic Usage Examples

```elixir
# --- Opening a connection ---
case XqliteNIF.raw_open("my_database.db") do
  {:ok, conn} ->
    IO.puts("Connection opened successfully.")
    # Use conn...
    # Remember to eventually let conn go out of scope or call raw_close
    # XqliteNIF.raw_close(conn) # Optional, GC handles it

  {:error, reason} ->
    IO.inspect(reason, label: "Failed to open database")
end

# --- Executing a query (SELECT) ---
sql_select = "SELECT id, name FROM users WHERE id = ?1;"
params_select = [1]

case XqliteNIF.raw_query(conn, sql_select, params_select) do
  {:ok, %{columns: cols, rows: rows, num_rows: num}} ->
    IO.puts("Query successful:")
    IO.inspect(cols, label: "Columns")
    IO.inspect(rows, label: "Rows")
    IO.inspect(num, label: "Num Rows")

  {:error, reason} ->
    IO.inspect(reason, label: "Query failed")
end

# --- Executing a statement (INSERT) ---
sql_insert = "INSERT INTO users (name, email) VALUES (?1, ?2);"
params_insert = ["Alice", "alice@example.com"]

case XqliteNIF.raw_execute(conn, sql_insert, params_insert) do
  {:ok, affected_rows} ->
    IO.puts("Insert successful. Rows affected: #{affected_rows}")

  {:error, reason} ->
    IO.inspect(reason, label: "Insert failed")
    # Example: {:error, {:constraint_violation, :constraint_unique, "UNIQUE constraint failed: users.email"}}
end

# --- Using a transaction ---
case XqliteNIF.raw_begin(conn) do
  {:ok, true} ->
    # Perform operations within the transaction
    case XqliteNIF.raw_execute(conn, "UPDATE accounts SET balance = balance - 100 WHERE id = 1", []) do
      {:ok, 1} ->
        case XqliteNIF.raw_execute(conn, "UPDATE accounts SET balance = balance + 100 WHERE id = 2", []) do
          {:ok, 1} ->
            # Commit if both succeed
            XqliteNIF.raw_commit(conn)
            IO.puts("Transaction committed.")
          {:error, reason_2} ->
            IO.inspect(reason_2, label: "Second update failed, rolling back")
            XqliteNIF.raw_rollback(conn)
        end
      {:error, reason_1} ->
        IO.inspect(reason_1, label: "First update failed, rolling back")
        XqliteNIF.raw_rollback(conn)
    end
  {:error, reason_begin} ->
    IO.inspect(reason_begin, label: "Failed to begin transaction")
end

```

## Roadmap

The following features are planned for the **`xqlite`** (NIF) library:

- [ ] **Schema Introspection:** Add NIFs to query schema details using `PRAGMA` commands (`table_list`, `table_info`, `foreign_key_list`, `index_xinfo`, etc.) and fetch raw `CREATE` SQL from `sqlite_schema`.
- [ ] **Batch Execution:** Add `raw_execute_batch/2` NIF for executing multiple SQL statements in a single string (useful for `structure.sql` loading).
- [ ] **Savepoints:** Add NIFs for managing transaction savepoints (`raw_savepoint`, `raw_rollback_to_savepoint`, `raw_release_savepoint`).
- [ ] **Last Insert RowID:** Add `last_insert_rowid/1` NIF.

The **`xqlite_ecto3`** library (separate project) will provide:

- [ ] Full Ecto 3.x adapter implementation (`use Ecto.Adapters.SQL`).
- [ ] Integration with `DBConnection` for connection pooling.
- [ ] Type handling (`dumpers`/`loaders`) for mapping Ecto types to SQLite storage (including Date/Time, Decimals, Binaries).
- [ ] Migration support.
- [ ] Structure dump/load (`mix ecto.dump`, `mix ecto.load`).

Further future possibilities include exploring SQLite's Session Extension and potentially a "Strict Mode".

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

Contributions are welcome! Please feel free to open issues or submit pull requests. Focus on testing any new code added. Rely only on the public Elixir API provided by the `XqliteNIF` module, as internal Rust implementation details may change.

## License

This project is licensed under the terms of the MIT license. See the [`LICENSE.md`](LICENSE.md) file for details.
