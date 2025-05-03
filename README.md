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

This library prioritizes compatibility with **modern SQLite versions** (>= 3.35.0 recommended). While it may work on older versions, explicit support or workarounds for outdated SQLite features are not a primary goal. **Notably, retrieving primary keys automatically after insertion into `WITHOUT ROWID` tables is only reliably supported via the `RETURNING` clause (available since SQLite 3.35.0). Using `WITHOUT ROWID` tables on older SQLite versions may require you to supply primary key values explicitly within your application, as `last_insert_rowid/1` cannot be used for these tables.**

## Current Capabilities

The `XqliteNIF` module provides the following low-level functions:

- **Connection Management:**
  - `raw_open(path :: String.t())`: Opens a file-based database.
  - `raw_open_in_memory(uri :: String.t())`: Opens an in-memory database (can use URI options like `cache=shared`).
  - `raw_open_temporary()`: Opens a private, temporary on-disk database.
  - `raw_close(conn :: ResourceArc<XqliteConn>)`: Conceptually closes the connection (relies on BEAM garbage collection of the resource handle for actual closing). Returns `{:ok, true}` immediately.
- **Query Execution:**
  - `raw_query(conn, sql :: String.t(), params :: list() | keyword())`: Executes `SELECT` or other row-returning statements (including `INSERT/UPDATE/DELETE ... RETURNING ...`).
    - Supports positional (`[1, "foo"]`) or named (`[val1: 1, val2: "foo"]`) parameters.
    - Returns `{:ok, %{columns: [String.t()], rows: [[term()]], num_rows: non_neg_integer()}}` or `{:error, reason}`.
- **Statement Execution:**
  - `raw_execute(conn, sql :: String.t(), params :: list())`: Executes standard `INSERT`, `UPDATE`, `DELETE`, DDL, etc., that do not return rows.
    - Supports positional parameters only (`[1, "foo"]`).
    - Returns `{:ok, affected_rows :: non_neg_integer()}` or `{:error, reason}`.
  - `raw_execute_batch(conn, sql_batch :: String.t())`: Executes multiple SQL statements separated by semicolons in a single string. Returns `{:ok, true}` on success.
- **PRAGMA Handling:**
  - `raw_pragma_write(conn, pragma_sql :: String.t())`: Executes a PRAGMA statement that modifies state (e.g., `PRAGMA journal_mode = WAL`). Returns affected rows (usually 0).
  - `raw_pragma_write_and_read(conn, pragma_name :: String.t(), value :: term())`: Sets a PRAGMA value and reads it back. Returns `{:ok, read_value}` or `{:ok, :no_value}`.
- **Transaction Control:**
  - `raw_begin(conn)`: Executes `BEGIN;`.
  - `raw_commit(conn)`: Executes `COMMIT;`.
  - `raw_rollback(conn)`: Executes `ROLLBACK;`.
  - `raw_savepoint(conn, name :: String.t())`: Creates a named transaction savepoint.
  - `raw_release_savepoint(conn, name :: String.t())`: Releases a named savepoint, incorporating its changes.
  - `raw_rollback_to_savepoint(conn, name :: String.t())`: Rolls back changes to a named savepoint.
- **Inserted Row ID:**
  - `last_insert_rowid(conn)`: Retrieves the integer `rowid` of the most recent successful `INSERT` into a standard rowid table on the given database connection. Returns `{:ok, rowid :: integer()}` or `{:error, reason}`.
    - **Important Caveats:**
      - This function reflects the state of the specific `conn` handle. If the _same handle_ is shared and used concurrently for `INSERT`s by multiple Elixir processes (which is discouraged), the returned value might belong to an `INSERT` from a different process than the one calling `last_insert_rowid`. Standard connection pooling (e.g., via `DBConnection`) avoids this issue by not sharing handles concurrently.
      - It **does not work** for tables created using the `WITHOUT ROWID` option.
      - It provides a fallback for retrieving generated IDs on **SQLite versions prior to 3.35.0**. For modern SQLite versions, using `INSERT ... RETURNING` via `raw_query/3` is the preferred and safer atomic method (see example below).
- **Schema Introspection:**
  - `raw_schema_databases(conn)`: Lists attached databases.
  - `raw_schema_list_objects(conn, schema \\ nil)`: Lists objects (tables, views, etc.) optionally filtered by schema name.
  - `raw_schema_columns(conn, table_name)`: Lists columns for a specific table.
  - `raw_schema_foreign_keys(conn, table_name)`: Lists foreign keys originating from a specific table.
  - `raw_schema_indexes(conn, table_name)`: Lists indexes defined on a specific table.
  - `raw_schema_index_columns(conn, index_name)`: Lists columns comprising a specific index.
  - `raw_get_create_sql(conn, object_name)`: Retrieves the original `CREATE` statement for an object.
  - These functions return `{:ok, list_of_structs} | {:ok, string | nil} | {:error, reason}`. The structs are defined in the `Xqlite.Schema.*` modules (e.g., `Xqlite.Schema.ColumnInfo`). Please refer to those modules or generated documentation for detailed field descriptions and typespecs.
- **Error Handling:**
  - All functions return `{:ok, result}` or `{:error, reason}` tuples.
  - `reason` provides structured information about the error (e.g., `{:sqlite_failure, code, extended_code, message}`, `{:constraint_violation, kind, message}`, `{:invalid_parameter_count, %{expected: _, provided: _}}`, `{:schema_parsing_error, context, detail}`, etc.). See `XqliteError` in the Rust code for details.

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
# Use this when you don't need the inserted ID back immediately,
# or when using SQLite < 3.35.0 with standard rowid tables.
sql_insert = "INSERT INTO users (name, email) VALUES (?1, ?2);"
params_insert = ["Alice", "alice@example.com"]

case XqliteNIF.raw_execute(conn, sql_insert, params_insert) do
  {:ok, affected_rows} ->
    IO.puts("Insert successful. Rows affected: #{affected_rows}")
    # Optionally call last_insert_rowid immediately after (see Caveats)
    # case XqliteNIF.last_insert_rowid(conn) do
    #   {:ok, id} -> IO.puts("Last insert ID (non-atomic): #{id}")
    #   {:error, err} -> IO.inspect(err, label: "Failed to get last row ID")
    # end

  {:error, reason} ->
    IO.inspect(reason, label: "Insert failed")
    # Example: {:error, {:constraint_violation, :constraint_unique, "UNIQUE constraint failed: users.email"}}
end

# --- Executing an INSERT and retrieving ID atomically (SQLite >= 3.35.0) ---
# This is the PREFERRED method on modern SQLite versions.
sql_insert_return = "INSERT INTO users (name, email) VALUES (?1, ?2) RETURNING id;"
params_insert_return = ["Bob", "bob@example.com"]

# Note: Use raw_query because INSERT...RETURNING returns rows/columns
case XqliteNIF.raw_query(conn, sql_insert_return, params_insert_return) do
  {:ok, %{columns: ["id"], rows: [[inserted_id]], num_rows: 1}} ->
    IO.puts("Insert successful. Atomically retrieved ID: #{inserted_id}")

  {:error, reason} ->
    IO.inspect(reason, label: "Insert/Returning failed")
end

# --- Querying Schema Information ---
# Example: Get column info for a table
case XqliteNIF.raw_schema_columns(conn, "users") do
  {:ok, [%Schema.ColumnInfo{name: first_col_name, type_affinity: first_col_affinity} | _rest]} ->
    IO.puts("First column in 'users': #{first_col_name} (Affinity: #{first_col_affinity})")
  {:ok, []} ->
    IO.puts("Table 'users' not found or has no columns.")
  {:error, reason} ->
     IO.inspect(reason, label: "Failed to get columns for 'users'")
end

# Example: Get the CREATE statement for an object
case XqliteNIF.raw_get_create_sql(conn, "users") do
  {:ok, create_sql} when is_binary(create_sql) ->
     IO.puts("CREATE SQL for 'users' starts with: #{String.slice(create_sql, 0, 50)}...")
  {:ok, nil} ->
     IO.puts("Object 'users' not found.")
  {:error, reason} ->
     IO.inspect(reason, label: "Failed to get CREATE SQL for 'users'")
end
# Other schema functions (raw_schema_list_objects, raw_schema_indexes, etc.) exist too.

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

The following features and enhancements are planned for the **`xqlite`** (NIF) library, prioritized roughly as follows:

- [ ] **Query Cancellation:** Implement an explicit cancellation mechanism (using a `CancelToken` resource, `cancel/1` NIF, and `_cancellable` NIF variants) allowing long-running queries/statements to be interrupted. _Crucial for robust timeout handling in Ecto/DBConnection._
- [ ] **Streaming Results:** Add NIFs to fetch large query results incrementally in chunks, rather than loading everything into memory at once. _Essential for supporting `Repo.stream/2` and handling large datasets efficiently._
- [ ] **Online Backup API:** Add NIFs to interact with SQLite's Online Backup API for performing live backups of the database. _Fundamental for operational reliability._
- [ ] **Session Extension:** Add NIFs to support SQLite's Session Extension for tracking and managing database changes (changesets/patchsets).
- [ ] **Extension Loading:** Add a `load_extension/2` NIF to enable loading SQLite runtime extensions (e.g., FTS, JSON1, SpatiaLite, custom extensions) provided as shared libraries. _Key for unlocking advanced SQLite capabilities._
- [ ] **Incremental Blob I/O:** Add NIFs to support reading and writing large BLOB values incrementally, avoiding high memory usage.
- [ ] **User-Defined Functions:** Investigate and implement support for registering custom SQL functions, aggregates, and potentially window functions (UDFs) from Elixir/Rust.
- [ ] **Optional: SQLCipher Support (build feature):** Investigate adding optional build-time support for SQLCipher database encryption via `rusqlite` Cargo features.

The **`xqlite_ecto3`** library (separate project) will provide:

- [ ] Full Ecto 3.x adapter implementation (`use Ecto.Adapters.SQL`).
- [ ] Integration with `DBConnection` for connection pooling (using WAL and `busy_timeout` for concurrency).
- [ ] Type handling (`dumpers`/`loaders`) for mapping Ecto types to SQLite storage (including Date/Time, Decimals, Binaries, JSON).
- [ ] Migration support (including migration locking).
- [ ] Structure dump/load (`mix ecto.dump`, `mix ecto.load`).

Further future possibilities include exploring a high-level "Strict Mode" helper and other advanced SQLite features.

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
