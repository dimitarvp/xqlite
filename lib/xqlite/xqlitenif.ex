defmodule XqliteNIF do
  @moduledoc """
  Low-level Native Implemented Functions (NIFs) for interacting with SQLite.

  This module provides direct, performant access to SQLite operations, powered by
  Rust and the `rusqlite` crate. It forms the foundation of the `Xqlite` library.

  **Connection lifecycle:**
  1. Open a database connection using `open/2`, `open_in_memory/1`, or `open_temporary/0`.
     These return an opaque connection resource (`t:Xqlite.conn/0`).
  2. Perform operations (queries, executes, pragmas, etc.) using this resource.
  3. Conceptually close the connection with `close/1` when done.

  **Operation cancellation:**
  For long-running queries or executions, cancellable versions of NIFs are provided
  (e.g., `query_cancellable/4`, `execute_cancellable/4`):
  1. Create a `t:reference/0` token with `create_cancel_token/0`.
  2. Pass this token to a cancellable NIF.
  3. To interrupt the NIF, call `cancel_operation/1` with the token from another process.
     The NIF will then typically return `{:error, :operation_cancelled}`.

  **Error handling:**
  Most functions return `{:ok, value}` or `:ok` on success, and
  `{:error, reason_tuple}` on failure. The `reason_tuple` provides structured
  error information (e.g., `{:sqlite_failure, code, extended_code, message}`).

  **Usage note:**
  These are low-level functions. For more idiomatic Elixir usage, consider
  the helper functions in the `Xqlite` module or higher-level abstractions
  if available (e.g., an Ecto adapter). This module is intended for direct
  SQLite control or for building such abstractions.
  """

  @version Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :xqlite,
    crate: "xqlitenif",
    base_url: "https://github.com/dimitarvp/xqlite/releases/download/v#{@version}",
    version: @version,
    force_build: System.get_env("XQLITE_BUILD") in ["1", "true"],
    targets: ~w(
      aarch64-apple-darwin
      aarch64-unknown-linux-gnu
      aarch64-unknown-linux-musl
      riscv64gc-unknown-linux-gnu
      x86_64-apple-darwin
      x86_64-pc-windows-msvc
      x86_64-unknown-linux-gnu
      x86_64-unknown-linux-musl
    ),
    nif_versions: ["2.17"]

  @type stream_fetch_ok_result :: %{rows: [list(term())]}

  @doc """
  Opens a connection to an SQLite database file.

  `path` is the file path to the database. If the file does not exist,
  SQLite will attempt to create it. URI filenames are supported
  (e.g., "file:my_db.sqlite?mode=ro").

  Returns `{:ok, conn_resource}` on success, where `conn_resource` is an
  opaque reference to the database connection. Returns `{:error, reason}`
  on failure, e.g., if the path is invalid or permissions are insufficient.
  """
  @spec open(path :: String.t()) :: {:ok, Xqlite.conn()} | Xqlite.error()
  def open(_path), do: err()

  @doc """
  Opens a connection to an in-memory SQLite database identified by `uri`.

  Pass `":memory:"` for a private, temporary in-memory database, or a URI
  filename like `"file:memdb1?mode=memory&cache=shared"` to create a
  shared-cache in-memory database reachable from other connections in the
  same process.

  Returns `{:ok, conn_resource}` on success or `{:error, reason}` on failure.
  """
  @spec open_in_memory(uri :: String.t()) :: {:ok, Xqlite.conn()} | Xqlite.error()
  def open_in_memory(_uri), do: err()

  @doc """
  Opens a read-only connection to an SQLite database file.

  The database must already exist — SQLite will not create it.
  Write operations (INSERT, UPDATE, DELETE, CREATE TABLE, etc.) will fail
  with `{:error, {:read_only_database, message}}`.

  Uses `SQLITE_OPEN_READ_ONLY | SQLITE_OPEN_NO_MUTEX | SQLITE_OPEN_URI` flags.

  Returns `{:ok, conn_resource}` on success or `{:error, reason}` on failure.
  """
  @spec open_readonly(path :: String.t()) :: {:ok, Xqlite.conn()} | Xqlite.error()
  def open_readonly(_path), do: err()

  @doc """
  Opens a read-only connection to an in-memory SQLite database identified
  by `uri`.

  Typical use is connecting to a named shared-cache in-memory database
  opened read-write by another connection, e.g.
  `"file:memdb1?mode=memory&cache=shared"`. Pass `":memory:"` for a
  private, empty read-only database.

  Uses `SQLITE_OPEN_READ_ONLY | SQLITE_OPEN_NO_MUTEX | SQLITE_OPEN_MEMORY | SQLITE_OPEN_URI` flags.

  Returns `{:ok, conn_resource}` on success or `{:error, reason}` on failure.
  """
  @spec open_in_memory_readonly(uri :: String.t()) :: {:ok, Xqlite.conn()} | Xqlite.error()
  def open_in_memory_readonly(_uri), do: err()

  @doc """
  Opens a connection to a private, temporary on-disk SQLite database.

  The database file is created by SQLite in a temporary location and is
  automatically deleted when the connection is closed. Each call creates
  a new, independent temporary database.

  Returns `{:ok, conn_resource}` on success or `{:error, reason}` on failure.
  """
  @spec open_temporary() :: {:ok, Xqlite.conn()} | Xqlite.error()
  def open_temporary(), do: err()

  @doc """
  Executes a SQL query that returns rows (e.g., `SELECT`, `PRAGMA` that returns data, `INSERT ... RETURNING`).

  `conn` is the database connection resource.
  `sql` is the SQL query string.
  `params` is an optional list of positional parameters (`[val1, val2]`) or a
  keyword list of named parameters (`[name1: val1, name2: val2]`).
  Use an empty list `[]` if the query has no parameters.

  Supported Elixir parameter types are integers, floats, strings, `nil`,
  booleans (`true`/`false`), and binaries (blobs).

  Returns `{:ok, result_map}` on success or `{:error, reason}` on failure.
  The `result_map` is `%{columns: [String.t()], rows: [[term()]], num_rows: non_neg_integer()}`.
  `columns` is a list of column name strings.
  `rows` is a list of lists, where each inner list represents a row and contains
  Elixir terms corresponding to the SQLite values.
  `num_rows` is the count of rows fetched.

  If the query is an `INSERT ... RETURNING` statement, the `rows` will contain
  the returned values. For statements that do not return rows (e.g., a simple `INSERT`
  without `RETURNING`), this function will likely succeed but return an empty
  `rows` list and `num_rows: 0`, or potentially an error like `:execute_returned_results`
  if SQLite's API indicates results were returned unexpectedly for a non-query.
  It is generally recommended to use `execute/3` for non-row-returning statements.
  """
  @spec query(
          conn :: Xqlite.conn(),
          sql :: String.t(),
          params :: list() | keyword()
        ) :: {:ok, Xqlite.query_result()} | Xqlite.error()
  def query(_conn, _sql, _params \\ []), do: err()

  @doc """
  Executes a SQL query that returns rows, with support for cancellation.

  This is a cancellable version of `query/3`.
  See `query/3` for details on parameters, return values, and general behavior.

  `conn` is the database connection resource.
  `sql` is the SQL query string.
  `params` is an optional list of positional or keyword parameters.
  `cancel_tokens` is a list of resources created by `create_cancel_token/0`.
  If *any* token in the list is cancelled via `cancel_operation/1` while the
  query is executing, the query will be interrupted (OR-semantics — the
  earliest signal wins). Pass an empty list to run without cancellation.

  Use `Xqlite.query_cancellable/4` to pass either a single token or a list;
  this raw NIF accepts only the list form.

  Returns `{:ok, result_map}` on successful completion, where `result_map` is
  `%{columns: [...], rows: [...], num_rows: ...}`.
  Returns `{:error, :operation_cancelled}` if the operation was cancelled.
  Returns `{:error, other_reason}` for other types of failures.
  """
  @spec query_cancellable(
          conn :: Xqlite.conn(),
          sql :: String.t(),
          params :: list() | keyword(),
          cancel_tokens :: [reference()]
        ) :: {:ok, Xqlite.query_result()} | Xqlite.error()
  def query_cancellable(_conn, _sql, _params, _cancel_tokens), do: err()

  @doc """
  Executes a SQL query and returns results with the affected row count.

  Returns `{:ok, %{columns, rows, num_rows, changes}}` where `changes` is
  `sqlite3_changes()` captured atomically inside the connection lock. For
  SELECT statements (non-empty columns), `changes` is 0. For DML, it's the
  actual affected row count.

  This is the recommended function when you need reliable affected row counts.
  Unlike calling `query/3` then `changes/1` separately, the count is captured
  before the lock is released, so it cannot be stale.
  """
  @spec query_with_changes(
          conn :: Xqlite.conn(),
          sql :: String.t(),
          params :: list() | keyword()
        ) :: {:ok, map()} | Xqlite.error()
  def query_with_changes(_conn, _sql, _params), do: err()

  @doc """
  Cancellable version of `query_with_changes/3`.

  `cancel_tokens` is a list of references; OR-semantics on cancellation.
  """
  @spec query_with_changes_cancellable(
          conn :: Xqlite.conn(),
          sql :: String.t(),
          params :: list() | keyword(),
          cancel_tokens :: [reference()]
        ) :: {:ok, map()} | Xqlite.error()
  def query_with_changes_cancellable(_conn, _sql, _params, _cancel_tokens), do: err()

  @doc """
  Runs a SQL statement and returns a structured report of how SQLite executed it.

  Combines three sources:
    * `EXPLAIN QUERY PLAN <sql>` — SQLite's static query plan tree (under
      `:query_plan`).
    * `sqlite3_stmt_scanstatus_v2` — per-scan runtime stats (under `:scans`),
      one entry per loop in the executed plan.
    * `sqlite3_stmt_status` — statement-level counters (under `:stmt_counters`).

  Also reports wall-clock execution time and the number of rows produced. Rows
  themselves are discarded — use `query/3` if you need them.

  The feature requires SQLite to be built with `SQLITE_ENABLE_STMT_SCANSTATUS`,
  which `xqlite` enables in its bundled build.

  Returns `{:ok, report}` where `report` is a map with the shape:

      %{
        wall_time_ns: non_neg_integer(),
        rows_produced: non_neg_integer(),
        stmt_counters: %{
          fullscan_step: integer(),
          sort: integer(),
          autoindex: integer(),
          vm_step: integer(),
          reprepare: integer(),
          run: integer(),
          filter_miss: integer(),
          filter_hit: integer(),
          memused_bytes: integer()
        },
        scans: [%{
          loops: integer(),
          rows_visited: integer(),
          estimated_rows: float(),
          name: String.t(),
          explain: String.t(),
          selectid: integer(),
          parentid: integer()
        }],
        query_plan: [%{
          id: integer(),
          parent: integer(),
          detail: String.t()
        }]
      }
  """
  @spec explain_analyze(
          conn :: Xqlite.conn(),
          sql :: String.t(),
          params :: list() | keyword()
        ) :: {:ok, map()} | Xqlite.error()
  def explain_analyze(_conn, _sql, _params \\ []), do: err()

  @doc """
  Executes a SQL statement that does not return rows (e.g., `INSERT`, `UPDATE`, `DELETE`, DDL).

  `conn` is the database connection resource.
  `sql` is the SQL statement string.
  `params` is an optional list of positional parameters. Named parameters are not
  supported for `execute/3`; use `query/3` with `INSERT ... RETURNING` if named
  parameters and result retrieval are needed for DML.
  Use an empty list `[]` if the statement has no parameters.

  Supported Elixir parameter types are integers, floats, strings, `nil`,
  booleans (`true`/`false`), and binaries (blobs).

  Returns `{:ok, affected_rows}` on success, where `affected_rows` is a non-negative
  integer indicating the number of rows modified, inserted, or deleted. For DDL
  statements like `CREATE TABLE`, `affected_rows` is typically `0`.
  Returns `{:error, reason}` on failure. For example, `{:error, :execute_returned_results}`
  if a statement unexpectedly returns data (e.g., a `SELECT` statement or an
  `INSERT ... RETURNING` statement was passed).
  """
  @spec execute(conn :: Xqlite.conn(), sql :: String.t(), params :: list() | keyword()) ::
          {:ok, non_neg_integer()} | Xqlite.error()
  def execute(_conn, _sql, _params \\ []), do: err()

  @doc """
  Executes a SQL statement that does not return rows, with support for cancellation.

  This is a cancellable version of `execute/3`.
  See `execute/3` for details on parameters, return values, and general behavior.

  `cancel_tokens` is a list of references created by `create_cancel_token/0`;
  any signal cancels the operation (OR-semantics). Empty list = no
  cancellation.

  Returns `{:ok, affected_rows}` on successful completion.
  Returns `{:error, :operation_cancelled}` if any token was cancelled.
  Returns `{:error, other_reason}` for other types of failures.
  """
  @spec execute_cancellable(
          conn :: Xqlite.conn(),
          sql :: String.t(),
          params :: list(),
          cancel_tokens :: [reference()]
        ) ::
          {:ok, non_neg_integer()} | Xqlite.error()
  def execute_cancellable(_conn, _sql, _params, _cancel_tokens), do: err()

  @doc """
  Executes one or more SQL statements separated by semicolons.

  This function is useful for running multiple DDL statements, a series of DML
  statements without parameters, or other sequences of SQL operations.
  Parameters are not supported for statements within the batch.

  `conn` is the database connection resource.
  `sql_batch` is a string containing one or more SQL statements. SQLite executes
  the statements sequentially. If an error occurs in one statement, subsequent
  statements in the batch are typically not executed, and the function returns
  an error. The changes made by prior successful statements within the batch
  are usually persisted unless the batch execution occurs within an explicit
  transaction that is later rolled back.

  Returns `:ok` if all statements in the batch execute successfully.
  Returns `{:error, reason}` if any statement fails.
  """
  @spec execute_batch(conn :: Xqlite.conn(), sql_batch :: String.t()) ::
          :ok | Xqlite.error()
  def execute_batch(_conn, _sql), do: err()

  @doc """
  Executes one or more SQL statements separated by semicolons, with support for cancellation.

  This is a cancellable version of `execute_batch/2`.
  See `execute_batch/2` for details on parameters, return values, and general behavior.

  `cancel_tokens` is a list of references; any signal cancels (OR-semantics).
  Empty list = no cancellation.

  Returns `:ok` if all statements in the batch execute successfully.
  Returns `{:error, :operation_cancelled}` if any token was cancelled.
  Returns `{:error, other_reason}` for other types of failures.
  """
  @spec execute_batch_cancellable(
          conn :: Xqlite.conn(),
          sql_batch :: String.t(),
          cancel_tokens :: [reference()]
        ) ::
          :ok | Xqlite.error()
  def execute_batch_cancellable(_conn, _sql_batch, _cancel_tokens), do: err()

  @doc """
  Conceptually closes the database connection.

  After a connection is closed, any further attempts to use its resource handle
  with other NIF functions will likely result in errors.
  It is safe to call `close/1` multiple times on the same connection resource;
  subsequent calls are no-ops and will also return `:ok`.

  For on-disk temporary databases created with `open_temporary/0`, closing the
  connection also deletes the underlying temporary file.

  `conn` is the database connection resource.

  Returns `:ok`. This function is designed to always succeed from the Elixir perspective
  once a valid connection resource has been established, even if the underlying
  SQLite close operation might encounter an issue (which is rare and typically
  handled internally by `rusqlite`).
  """
  @spec close(conn :: Xqlite.conn()) :: :ok
  def close(_conn), do: err()

  @doc """
  Reads the current value of an SQLite PRAGMA.

  PRAGMA statements are used to modify the operation of the SQLite library or
  to query the library for internal data. See SQLite documentation for a list
  of available PRAGMAs.

  `conn` is the database connection resource.
  `name` is the string name of the PRAGMA to read (e.g., "user_version", "journal_mode").

  Returns `{:ok, value}` where `value` is the PRAGMA's current value, converted
  to an appropriate Elixir term (integer, string, boolean for some common 0/1 PRAGMAs).
  Returns `{:ok, :no_value}` if the PRAGMA does not return a value (e.g., `PRAGMA optimize`)
  or if the PRAGMA name is invalid/unknown to SQLite.
  Returns `{:error, reason}` for other failures.

  Note: Some PRAGMAs require an argument to read (e.g., `PRAGMA table_info(table_name)`).
  This function is for PRAGMAs that are read without an argument or whose argument is
  part of the `name` string itself if SQLite supports that syntax. For more complex
  PRAGMA queries, use `XqliteNIF.query/3`. The `Xqlite.Pragma` module provides
  higher-level helpers for many common PRAGMAs.
  """
  @spec get_pragma(conn :: Xqlite.conn(), name :: String.t()) ::
          {:ok, term() | :no_value} | Xqlite.error()
  def get_pragma(_conn, _name), do: err()

  @doc """
  Sets the value of an SQLite PRAGMA.

  `conn` is the database connection resource.
  `name` is the string name of the PRAGMA to set (e.g., "user_version", "foreign_keys").
  `value` is the Elixir term to set the PRAGMA to. Supported Elixir types include:
    - Integers
    - Strings
    - Booleans (`true` typically maps to `ON` or `1`, `false` to `OFF` or `0`)
    - Atoms that SQLite can interpret (e.g., `:on`, `:off`, `:wal`, `:delete`).
      Refer to SQLite documentation for valid values for specific PRAGMAs.

  The NIF attempts to format the Elixir `value` into a string literal suitable
  for the `PRAGMA name = value_literal;` SQL statement.

  Returns `{:ok, value}` where `value` is what SQLite echoed back from the
  PRAGMA assignment, or `nil` if the PRAGMA produced no output. For example,
  `PRAGMA journal_mode = wal` returns `{:ok, "wal"}` on success. Note that
  SQLite might silently ignore invalid PRAGMA names or invalid values for a
  valid PRAGMA. Returns `{:error, reason}` if there's an issue preparing or
  executing the PRAGMA statement (e.g., unsupported Elixir type for `value`,
  syntax error).

  The `Xqlite.Pragma` module provides higher-level helpers for setting many
  common PRAGMAs with more type safety.
  """
  @spec set_pragma(conn :: Xqlite.conn(), name :: String.t(), value :: term()) ::
          {:ok, term()} | Xqlite.error()
  def set_pragma(_conn, _name, _value), do: err()

  @type transaction_mode :: :deferred | :immediate | :exclusive

  @doc """
  Begins a new database transaction with the given mode.

  Modes:
  - `:deferred` — acquires locks lazily (default SQLite behavior)
  - `:immediate` — acquires a write lock immediately (fails fast on contention)
  - `:exclusive` — acquires an exclusive lock (blocks readers too)

  Returns `:ok` on success.
  Returns `{:error, reason}` if a transaction cannot be started (e.g., if one
  is already active on this connection, or due to other SQLite errors).
  Returns `{:error, :invalid_transaction_mode}` for unrecognized mode atoms.
  """
  @spec begin(conn :: Xqlite.conn(), mode :: transaction_mode()) :: :ok | Xqlite.error()
  def begin(_conn, _mode \\ :deferred), do: err()

  @doc """
  Commits the current database transaction.

  Equivalent to executing the SQL statement `COMMIT;` or `END TRANSACTION;`.
  All changes made within the transaction become permanent.

  `conn` is the database connection resource.

  Returns `:ok` on success.
  Returns `{:error, reason}` if the transaction cannot be committed (e.g., if
  no transaction is active, or due to other SQLite errors like deferred constraint
  violations).
  """
  @spec commit(conn :: Xqlite.conn()) :: :ok | Xqlite.error()
  def commit(_conn), do: err()

  @doc """
  Rolls back the current database transaction.

  Equivalent to executing the SQL statement `ROLLBACK;` or `ROLLBACK TRANSACTION;`.
  All changes made within the transaction since the last `COMMIT` or `SAVEPOINT`
  are discarded.

  `conn` is the database connection resource.

  Returns `:ok` on success.
  Returns `{:error, reason}` if the transaction cannot be rolled back (e.g., if
  no transaction is active, or due to other SQLite errors).
  """
  @spec rollback(conn :: Xqlite.conn()) :: :ok | Xqlite.error()
  def rollback(_conn), do: err()

  @doc """
  Creates a new savepoint within the current transaction.

  Equivalent to executing `SAVEPOINT 'name';`. Savepoints allow partial rollbacks
  of a transaction. If the current transaction is not a `DEFERRED` transaction,
  a `SAVEPOINT` command will implicitly start one.

  `conn` is the database connection resource.
  `name` is a string identifier for the savepoint. Savepoint names can be reused,
  and a new savepoint with an existing name will hide the older one.

  Returns `:ok` on success.
  Returns `{:error, reason}` on failure (e.g., if SQLite cannot create the savepoint).
  """
  @spec savepoint(conn :: Xqlite.conn(), name :: String.t()) ::
          :ok | Xqlite.error()
  def savepoint(_conn, _name), do: err()

  @doc """
  Rolls back the transaction to a named savepoint.

  Equivalent to executing `ROLLBACK TO SAVEPOINT 'name';`. Changes made after
  the specified savepoint are undone, but the savepoint itself remains active
  (it is not released). The transaction also remains active.

  `conn` is the database connection resource.
  `name` is the string identifier of an existing savepoint.

  Returns `:ok` on success.
  Returns `{:error, reason}` on failure (e.g., if the named savepoint does not
  exist, or other SQLite errors).
  """
  @spec rollback_to_savepoint(conn :: Xqlite.conn(), name :: String.t()) ::
          :ok | Xqlite.error()
  def rollback_to_savepoint(_conn, _name), do: err()

  @doc """
  Releases a named savepoint.

  Equivalent to executing `RELEASE SAVEPOINT 'name';` or simply `RELEASE 'name';`.
  This removes the specified savepoint and all savepoints established after it.
  The changes made since the savepoint was established are incorporated into the
  current transaction (i.e., they are not rolled back). The transaction remains active.

  `conn` is the database connection resource.
  `name` is the string identifier of an existing savepoint.

  Returns `:ok` on success.
  Returns `{:error, reason}` on failure (e.g., if the named savepoint does not
  exist, or other SQLite errors).
  """
  @spec release_savepoint(conn :: Xqlite.conn(), name :: String.t()) ::
          :ok | Xqlite.error()
  def release_savepoint(_conn, _name), do: err()

  @doc """
  Returns whether the connection is currently inside a transaction.

  Returns `{:ok, true}` if a transaction is active (i.e., after `begin/2`
  and before `commit/1` or `rollback/1`).
  Returns `{:ok, false}` if the connection is in autocommit mode.
  """
  @spec transaction_status(conn :: Xqlite.conn()) :: {:ok, boolean()} | Xqlite.error()
  def transaction_status(_conn), do: err()

  @doc """
  Retrieves information about all attached databases for the connection.

  Corresponds to the `PRAGMA database_list;` statement. Each active connection
  has at least a "main" database and often a "temp" database. Additional
  databases can be attached using the `ATTACH DATABASE` SQL command.

  `conn` is the database connection resource.

  Returns `{:ok, list_of_database_info}` on success, where `list_of_database_info`
  is a list of `Xqlite.Schema.DatabaseInfo` structs.
  Each struct contains:
    - `:name` (String.t()): The logical name of the database (e.g., "main", "temp", or attached name).
    - `:file` (String.t() | nil): The absolute path to the database file,
      or `nil` for in-memory databases, or an empty string for temporary databases
      opened with `XqliteNIF.open_temporary/0`.
  Returns `{:error, reason}` on failure.
  """
  @spec schema_databases(conn :: Xqlite.conn()) ::
          {:ok, [Xqlite.Schema.DatabaseInfo.t()]} | Xqlite.error()
  def schema_databases(_conn), do: err()

  @doc """
  Lists schema objects (tables, views, etc.) in a specified database schema.

  Corresponds to the `PRAGMA table_list;` statement, filtered by the optional
  `schema_name`. This PRAGMA primarily lists tables, views, and virtual tables.

  `conn` is the database connection resource.
  `schema_name` (optional String.t()): The name of the schema (e.g., "main", "temp",
  or an attached database name). If `nil` or omitted, information for all schemas
  accessible by the connection may be returned (behavior can depend on how `PRAGMA table_list`
  is implemented if no schema is specified, though SQLite typically defaults to "main" or all).
  It is recommended to specify a schema for predictable results.

  Returns `{:ok, list_of_object_info}` on success, where `list_of_object_info`
  is a list of `Xqlite.Schema.SchemaObjectInfo` structs for objects matching
  the specified schema.
  Each struct contains:
    - `:schema` (String.t()): Name of the schema containing the object.
    - `:name` (String.t()): Name of the object.
    - `:object_type` (atom): The type of object (e.g., `:table`, `:view`, `:virtual`).
    - `:column_count` (integer()): Number of columns (meaningful for tables/views).
    - `:is_without_rowid` (boolean()): `true` if the table was created with the `WITHOUT ROWID` optimization.
    - `:strict` (boolean()): `true` if the table was declared using `STRICT` mode.
  Returns `{:error, reason}` on failure.
  """
  @spec schema_list_objects(conn :: Xqlite.conn(), schema_name :: String.t() | nil) ::
          {:ok, [Xqlite.Schema.SchemaObjectInfo.t()]} | Xqlite.error()
  def schema_list_objects(_conn, _schema \\ nil), do: err()

  @doc """
  Retrieves detailed information about columns in a specific table or view.

  Corresponds to the `PRAGMA table_xinfo('table_name');` statement, which provides
  more details than `PRAGMA table_info`, including column hidden status.

  `conn` is the database connection resource.
  `table_name` (String.t()): The name of the table or view for which to retrieve
  column information. The name is case-sensitive based on SQLite's handling.

  Returns `{:ok, list_of_column_info}` on success, where `list_of_column_info`
  is a list of `Xqlite.Schema.ColumnInfo` structs, ordered by column ID.
  If the table does not exist, an empty list is returned within the `{:ok, []}` tuple.
  Each struct contains:
    - `:column_id` (integer()): 0-indexed ID of the column within the table.
    - `:name` (String.t()): Name of the column.
    - `:type_affinity` (atom): Resolved data type affinity (e.g., `:integer`, `:text`).
    - `:declared_type` (String.t()): Original data type string from `CREATE TABLE`.
    - `:nullable` (boolean()): `true` if the column allows NULL values.
    - `:default_value` (String.t() | nil): Default value expression as a string literal,
      or `nil`. For generated columns, this will be `nil` as the expression is not
      in this field from `PRAGMA table_xinfo`.
    - `:primary_key_index` (non_neg_integer()): 1-based index within the PK if part of it, else `0`.
    - `:hidden_kind` (atom): Indicates if/how a column is hidden/generated
      (e.g., `:normal`, `:stored_generated`, `:virtual_generated`).
  Returns `{:error, reason}` for other failures.
  """
  @spec schema_columns(conn :: Xqlite.conn(), table_name :: String.t()) ::
          {:ok, [Xqlite.Schema.ColumnInfo.t()]} | Xqlite.error()
  def schema_columns(_conn, _table_name), do: err()

  @doc """
  Retrieves information about foreign key constraints originating from a table.

  Corresponds to the `PRAGMA foreign_key_list('table_name');` statement.
  This lists foreign keys defined *on* the specified `table_name` that
  reference other tables.

  `conn` is the database connection resource.
  `table_name` (String.t()): The name of the table whose foreign key constraints
  are to be listed. Case-sensitive based on SQLite's handling.

  Returns `{:ok, list_of_foreign_key_info}` on success. `list_of_foreign_key_info`
  is a list of `Xqlite.Schema.ForeignKeyInfo` structs. If the table does not
  exist or has no foreign keys, an empty list is returned within the `{:ok, []}` tuple.
  Each struct contains:
    - `:id` (integer()): ID of the foreign key constraint (0-based index for the table).
    - `:column_sequence` (integer()): 0-based index of the column within the FK (for compound FKs).
    - `:target_table` (String.t()): Name of the table referenced by the foreign key.
    - `:from_column` (String.t()): Name of the column in the current table that is part of the FK.
    - `:to_column` (String.t() | nil): Name of the column in the target table referenced.
    - `:on_update` (atom): Action on update (e.g., `:cascade`, `:set_null`).
    - `:on_delete` (atom): Action on delete (e.g., `:restrict`, `:no_action`).
    - `:match_clause` (atom): The `MATCH` clause type (e.g., `:none`, `:simple`).
  Returns `{:error, reason}` for other failures.
  """
  @spec schema_foreign_keys(conn :: Xqlite.conn(), table_name :: String.t()) ::
          {:ok, [Xqlite.Schema.ForeignKeyInfo.t()]} | Xqlite.error()
  def schema_foreign_keys(_conn, _table_name), do: err()

  @doc """
  Retrieves information about all indexes associated with a table.

  Corresponds to the `PRAGMA index_list('table_name');` statement. This includes
  explicitly created indexes (`CREATE INDEX`) and indexes automatically created
  by SQLite for `PRIMARY KEY` and `UNIQUE` constraints.

  `conn` is the database connection resource.
  `table_name` (String.t()): The name of the table whose indexes are to be listed.
  Case-sensitive based on SQLite's handling.

  Returns `{:ok, list_of_index_info}` on success. `list_of_index_info` is a list
  of `Xqlite.Schema.IndexInfo` structs. If the table does not exist or has no
  indexes, an empty list is returned within the `{:ok, []}` tuple.
  Each struct contains:
    - `:name` (String.t()): Name of the index.
    - `:unique` (boolean()): `true` if the index enforces uniqueness.
    - `:origin` (atom): How the index was created (e.g., `:create_index`,
      `:unique_constraint`, `:primary_key_constraint`).
    - `:partial` (boolean()): `true` if the index is partial (has a `WHERE` clause).
  Returns `{:error, reason}` for other failures.
  """
  @spec schema_indexes(conn :: Xqlite.conn(), table_name :: String.t()) ::
          {:ok, [Xqlite.Schema.IndexInfo.t()]} | Xqlite.error()
  def schema_indexes(_conn, _table_name), do: err()

  @doc """
  Retrieves detailed information about the columns that make up a specific index.

  Corresponds to the `PRAGMA index_xinfo('index_name');` statement, which provides
  more details than `PRAGMA index_info`, including sort order, collation, and
  whether a column is a key or an included column.

  `conn` is the database connection resource.
  `index_name` (String.t()): The name of the index for which to retrieve column
  information. Index names are typically case-sensitive.

  Returns `{:ok, list_of_index_column_info}` on success. `list_of_index_column_info`
  is a list of `Xqlite.Schema.IndexColumnInfo` structs, ordered by their sequence
  within the index definition. If the index does not exist, an empty list is
  returned within the `{:ok, []}` tuple.
  Each struct contains:
    - `:index_column_sequence` (integer()): 0-based position of this column in the index key.
    - `:table_column_id` (integer()): ID of the column in the base table (`cid` from
      `PRAGMA table_info`). `-1` for expressions not directly on a table column,
      or for the rowid. `-2` is sometimes used by SQLite for expressions in `PRAGMA index_xinfo`.
    - `:name` (String.t() | nil): Name of the table column, or `nil` if the index is
      on an expression or rowid.
    - `:sort_order` (atom): Sort order (e.g., `:asc`, `:desc`).
    - `:collation` (String.t()): Name of the collation sequence used.
    - `:is_key_column` (boolean()): `true` if part of the primary index key, `false` if an
      "included" column (SQLite >= 3.9.0).
  Returns `{:error, reason}` for other failures.
  """
  @spec schema_index_columns(conn :: Xqlite.conn(), index_name :: String.t()) ::
          {:ok, [Xqlite.Schema.IndexColumnInfo.t()]} | Xqlite.error()
  def schema_index_columns(_conn, _index_name), do: err()

  @doc """
  Retrieves the original SQL text used to create a specific schema object.

  This function queries the `sqlite_schema` table (formerly `sqlite_master`)
  for the `sql` column corresponding to the given object name.

  `conn` is the database connection resource.
  `object_name` (String.t()): The name of the table, index, trigger, or view
  whose creation SQL is to be retrieved. Object names are typically case-sensitive.

  Returns `{:ok, sql_string}` on success if the object exists, where `sql_string`
  is the `CREATE ...` statement.
  Returns `{:ok, nil}` if no object with the given name is found in the schema.
  Returns `{:error, reason}` for other failures.
  """
  @spec get_create_sql(conn :: Xqlite.conn(), object_name :: String.t()) ::
          {:ok, String.t() | nil} | Xqlite.error()
  def get_create_sql(_conn, _object_name), do: err()

  @doc """
  Retrieves the rowid of the most recent successful `INSERT` into a rowid table.

  This function calls SQLite's `sqlite3_last_insert_rowid()` for the given
  connection. The value returned is the rowid of the last row inserted by an
  `INSERT` statement on that specific database connection.

  Important Considerations:
    - The value is connection-specific. Inserts on other connections do not affect it.
    - It is only updated by successful `INSERT` statements. Failed inserts, updates,
      deletes, or other SQL statements do not change its value.
    - **It does not work for `WITHOUT ROWID` tables.** For such tables, you must
      use the `INSERT ... RETURNING` clause to get the primary key values of
      inserted rows.
    - If no successful `INSERT`s have occurred on the connection since it was
      opened, this function typically returns `0`.
    - The rowid can be an alias for the `INTEGER PRIMARY KEY` column if one exists.

  `conn` is the database connection resource.

  Returns `{:ok, rowid_integer}` on success, where `rowid_integer` is the last
  inserted rowid.
  Returns `{:error, reason}` only in rare cases of severe connection failure, as
  the underlying SQLite C function itself doesn't typically return errors that
  map to common `Xqlite.error()` types beyond connection validity.
  """
  @spec last_insert_rowid(conn :: Xqlite.conn()) :: {:ok, integer()} | Xqlite.error()
  def last_insert_rowid(_conn), do: err()

  @doc """
  Returns the number of rows modified, inserted, or deleted by the most
  recently completed `INSERT`, `UPDATE`, or `DELETE` statement on this
  connection. Does not count changes from triggers or foreign key actions.
  """
  @spec changes(conn :: Xqlite.conn()) :: {:ok, non_neg_integer()} | Xqlite.error()
  def changes(_conn), do: err()

  @doc """
  Returns the total number of rows modified, inserted, or deleted by all
  `INSERT`, `UPDATE`, or `DELETE` statements since the connection was
  opened, including changes from triggers.
  """
  @spec total_changes(conn :: Xqlite.conn()) :: {:ok, non_neg_integer()} | Xqlite.error()
  def total_changes(_conn), do: err()

  @doc """
  Creates a new cancellation token resource.

  This token can be passed to cancellable NIF operations (e.g.,
  `query_cancellable/4`, `execute_cancellable/4`). To signal cancellation
  for operations associated with this token, call `cancel_operation/1`
  on the returned token resource.

  Each token is independent. Cancelling one token does not affect others.
  The token resource should be managed appropriately; it does not need explicit
  closing beyond normal Elixir garbage collection of the resource reference.

  Returns `{:ok, token_resource}` on success, where `token_resource` is an
  opaque reference representing the cancellation token.
  Returns `{:error, reason}` in the unlikely event of a resource allocation failure.
  """
  @spec create_cancel_token() :: {:ok, reference()} | Xqlite.error()
  def create_cancel_token(), do: err()

  @doc """
  Returns `true` when `conn` is in auto-commit mode (no active transaction),
  `false` otherwise.

  Equivalent to `sqlite3_get_autocommit`. Zero-cost; always available.
  """
  @spec autocommit(Xqlite.conn()) :: {:ok, boolean()} | Xqlite.error()
  def autocommit(_conn), do: err()

  @doc """
  Returns the transaction state for the given schema (defaults to `"main"`).

  Equivalent to `sqlite3_txn_state`. Zero-cost; always available.

  Possible values:

    * `:none` — no transaction active on this schema.
    * `:read` — a read transaction is active (SHARED lock).
    * `:write` — a write transaction is active (RESERVED+ lock).
    * `:unknown` — future variants (SQLite added a state we don't map yet).

  ## Why not a full 5-state lock ladder?

  `sqlite3_file_control(SQLITE_FCNTL_LOCKSTATE)` would give the full
  NONE / SHARED / RESERVED / PENDING / EXCLUSIVE picture, but it requires
  SQLite compiled with `SQLITE_DEBUG` — a build flag that enables every
  `assert()` inside SQLite with a real performance cost. We do not compile
  with it. `txn_state` is the honest production-safe substitute.
  """
  @spec txn_state(Xqlite.conn(), String.t() | nil) ::
          {:ok, :none | :read | :write | :unknown} | Xqlite.error()
  def txn_state(_conn, _schema \\ nil), do: err()

  @doc """
  Forces a WAL checkpoint. Equivalent to `sqlite3_wal_checkpoint_v2`.

  `mode` picks the checkpoint strategy:

    * `:passive` (default) — checkpoints as many pages as possible
      without blocking readers or writers. Never returns `busy: true`.
    * `:full` — waits for any concurrent writers to finish, then
      checkpoints all pages. Will set `busy: true` if readers prevent
      completion.
    * `:restart` — as `:full`, plus waits for existing readers to
      drain so the next writer can restart the WAL from the beginning.
    * `:truncate` — as `:restart`, plus truncates the WAL file on disk.

  `schema` is the attached-database name (defaults to `nil`, meaning the
  main database).

  Returns `{:ok, %{log_pages: n, checkpointed_pages: n, busy: bool}}`:

    * `log_pages` — size of the WAL log in pages after the checkpoint,
      or `-1` if WAL mode is not active.
    * `checkpointed_pages` — number of pages the checkpoint actually
      moved from the WAL into the main database, or `-1` if inactive.
    * `busy` — `true` if the checkpoint did not complete all of its work
      because other connections held back progress. `log_pages` /
      `checkpointed_pages` are still populated with partial data.
  """
  @spec wal_checkpoint(
          Xqlite.conn(),
          :passive | :full | :restart | :truncate,
          String.t() | nil
        ) :: {:ok, map()} | Xqlite.error()
  def wal_checkpoint(_conn, _mode \\ :passive, _schema \\ nil), do: err()

  @doc """
  Returns a structured snapshot of `sqlite3_db_status` counters for the
  connection.

  Returns `{:ok, %{…}}` with the following keys (all non-negative integers):

    * `:lookaside_used` — lookaside slots in use.
    * `:cache_used` — heap bytes in the pager cache.
    * `:schema_used` — heap bytes in the schema cache.
    * `:stmt_used` — heap bytes across prepared statements.
    * `:lookaside_hit` — count of lookaside allocations satisfied from
      the pool.
    * `:lookaside_miss_size` — count of allocations that bypassed
      lookaside because they were too big.
    * `:lookaside_miss_full` — count of allocations that bypassed
      lookaside because it was full.
    * `:cache_hit` — pager cache hit count.
    * `:cache_miss` — pager cache miss count.
    * `:cache_write` — count of dirty pages written.
    * `:deferred_fks` — pending deferred FK violations (only relevant
      under `PRAGMA defer_foreign_keys = ON`).
    * `:cache_used_shared` — heap bytes in the shared pager cache
      attributable to this connection.
    * `:cache_spill` — count of dirty-cache spills to disk.
    * `:tempbuf_spill` — count of `tempdb` spill events.

  All counters are "current" values; high-water marks are not exposed
  yet. Call repeatedly for time-series monitoring.
  """
  @spec connection_stats(Xqlite.conn()) :: {:ok, map()} | Xqlite.error()
  def connection_stats(_conn), do: err()

  @doc """
  Installs a busy handler on the connection (raw NIF).

  Most users want `Xqlite.set_busy_handler/3`, which accepts keyword
  options with sane defaults.

  When SQLite encounters a locked database (another writer holds
  `RESERVED+`) the handler decides whether to retry or surface
  `SQLITE_BUSY` to the caller. Each invocation is also forwarded to
  `pid` as

      {:xqlite_busy, retries_so_far, elapsed_ms}

  so callers can observe contention (telemetry, structured logging,
  adaptive backoff).

    * `max_retries` — stop after this many retries and let the caller
      see `SQLITE_BUSY`.
    * `max_elapsed_ms` — absolute time ceiling in milliseconds from the
      first busy event in the window.
    * `sleep_ms` — milliseconds to sleep between retries. Zero disables
      the pause.

  Replacing an existing handler is atomic: the previous handler's state
  is reclaimed before the new one takes effect.

  > #### Warning — PRAGMA busy_timeout silently replaces this handler {: .warning}
  >
  > `PRAGMA busy_timeout` / `sqlite3_busy_timeout` replaces the installed
  > handler at the SQLite C level without going through our atomic slot.
  > Messages stop flowing; no memory is leaked (the internal state is
  > reclaimed on the next `set_busy_handler/5` / `remove_busy_handler/1`
  > / connection close). Prefer `Xqlite.busy_timeout/2` to switch to
  > plain-timeout semantics.

  Returns `:ok`.
  """
  @spec set_busy_handler(
          conn :: Xqlite.conn(),
          pid :: pid(),
          max_retries :: non_neg_integer(),
          max_elapsed_ms :: non_neg_integer(),
          sleep_ms :: non_neg_integer()
        ) :: :ok | Xqlite.error()
  def set_busy_handler(_conn, _pid, _max_retries, _max_elapsed_ms, _sleep_ms),
    do: err()

  @doc """
  Removes any busy handler from the connection.

  Safe to call when no handler is installed (no-op on both sides). After
  removal, SQLite returns `SQLITE_BUSY` immediately on contention unless
  a `busy_timeout` is subsequently set.

  Returns `:ok`.
  """
  @spec remove_busy_handler(Xqlite.conn()) :: :ok | Xqlite.error()
  def remove_busy_handler(_conn), do: err()

  @doc """
  Signals an intent to cancel operations associated with a given cancellation token.

  When this function is called, any active SQLite operations (executed via
  cancellable NIFs like `query_cancellable/4` or `execute_cancellable/4`)
  that were started with the provided `token_resource` will be interrupted
  at the next opportunity (SQLite's progress handler check).

  `token_resource` is an opaque reference previously created by
  `create_cancel_token/0`.

  This function is idempotent; calling it multiple times on the same token
  has no additional effect after the first call. The cancellation signal
  remains active for the token.

  Returns `:ok`. This function indicates the signal has been set; it does not
  guarantee that the operation has already stopped. The cancellable NIF function
  will return `{:error, :operation_cancelled}` when it actually terminates due
  to the cancellation.
  Returns `{:error, reason}` if the provided `token_resource` is not a valid
  cancellation token resource (e.g., a different type of reference).
  """
  @spec cancel_operation(token_resource :: reference()) :: :ok | Xqlite.error()
  def cancel_operation(_token_resource), do: err()

  @doc """
  Prepares a SQL query for streaming and returns an opaque stream handle resource.

  This function does not execute the query immediately but prepares it for
  row-by-row fetching. The returned handle is opaque and must be used with
  other `stream_*` NIF functions or managed by a higher-level streaming abstraction
  like `Xqlite.stream/4`.

  `conn` is the database connection resource.
  `sql` is the SQL query string.
  `params` is a list of positional parameters or a keyword list of named parameters.
  `opts` is a keyword list for future stream-specific options (currently unused).

  Returns `{:ok, stream_handle_resource}` or `{:error, reason}`.
  The `stream_handle_resource` is an opaque reference.
  """
  @spec stream_open(
          conn :: Xqlite.conn(),
          sql :: String.t(),
          params :: list() | keyword(),
          opts :: keyword()
        ) ::
          {:ok, reference()} | Xqlite.error()
  def stream_open(_conn, _sql, _params, _opts \\ []), do: err()

  @doc """
  Retrieves the column names for an opened stream.

  `stream_handle` is the opaque resource returned by `stream_open/4`.

  Returns `{:ok, list_of_column_names}` where `list_of_column_names` is a list of strings,
  or `{:error, reason}` if the handle is invalid or another error occurs.
  The list of column names will be empty if the query yields no columns.
  """
  @spec stream_get_columns(stream_handle :: reference()) ::
          {:ok, [String.t()]} | Xqlite.error()
  def stream_get_columns(_stream_handle), do: err()

  @doc """
  Fetches a batch of rows from an active stream handle.

  `stream_handle` is the opaque resource obtained from `stream_open/4`.
  `batch_size` indicates the maximum number of rows to fetch in this call.
  A `batch_size` of `0` will return an empty list of rows without advancing
  the stream, unless the stream is already exhausted (in which case it returns `:done`).

  Returns:
    - `{:ok, %{rows: [[term()]]}}` if rows are fetched. The inner list represents a row,
      and the outer list is the batch of rows. The list of rows may be empty if
      `batch_size` was `0` and the stream is not yet done, or if the query itself
      yielded results but this particular fetch point encountered no more rows before
      hitting `SQLITE_DONE` or an error within the batch limit.
    - `:done` to indicate the end of the stream (all rows have been consumed).
    - `{:error, reason}` if an error occurs during fetching from SQLite.
  """
  @spec stream_fetch(stream_handle :: reference(), batch_size :: pos_integer()) ::
          {:ok, stream_fetch_ok_result()} | :done | Xqlite.error()
  def stream_fetch(_stream_handle, _batch_size), do: err()

  @doc """
  Closes an active stream and releases its underlying SQLite statement resources.

  This function should be called when a stream is no longer needed, either
  after all rows have been consumed or if the stream needs to be abandoned
  prematurely. It is safe to call this function multiple times on the same handle;
  subsequent calls after the first will be no-ops.

  `stream_handle` is the opaque resource returned by `stream_open/4`.

  Returns `:ok` if successful, or `{:error, reason}` if the handle is invalid
  or an error occurs during finalization (rare).
  """
  @spec stream_close(stream_handle :: reference()) :: :ok | Xqlite.error()
  def stream_close(_stream_handle), do: err()

  @doc """
  Retrieves the compile-time options the linked SQLite C library was built with.

  Corresponds to the `PRAGMA compile_options;` statement. This is useful for
  diagnosing which features (e.g., `THREADSAFE`, `ENABLE_FTS5`) are available.

  `conn` is the database connection resource.

  Returns `{:ok, list_of_options}` on success, where `list_of_options` is a
  list of strings (e.g., `["COMPILER=clang-14.0.3", "ENABLE_FTS5", "THREADSAFE=1"]`).
  Returns `{:error, reason}` on failure.
  """
  @spec compile_options(conn :: Xqlite.conn()) ::
          {:ok, [String.t()]} | Xqlite.error()
  def compile_options(_conn), do: err()

  @doc """
  Returns the version string of the underlying SQLite C library.

  This is a runtime check and does not require an active database connection.
  It is useful for diagnostics to confirm which version of SQLite the NIF
  was linked against.
  """
  @spec sqlite_version() :: {:ok, String.t()} | Xqlite.error()
  def sqlite_version(), do: err()

  @doc """
  Registers a PID to receive SQLite diagnostic log events.

  SQLite's global log callback (`sqlite3_config(SQLITE_CONFIG_LOG)`) sends
  diagnostic messages for events like auto-index creation, schema changes,
  and warnings that don't surface as errors.

  The registered PID receives messages in the form:
  `{:xqlite_log, error_code, message}` where `error_code` is a SQLite
  result code (integer) and `message` is a string.

  This is a **global, per-process** setting — only one PID can receive log
  events at a time. Calling `set_log_hook/1` again replaces the previous
  listener. Use `remove_log_hook/0` to unregister.

  Returns `{:ok, :ok}` on success or `{:error, reason}` on failure.
  """
  @spec set_log_hook(pid :: pid()) :: {:ok, :ok} | {:error, String.t()}
  def set_log_hook(_pid), do: err()

  @doc """
  Unregisters the global SQLite log hook.

  After calling this, no PID will receive `{:xqlite_log, ...}` messages.

  Returns `{:ok, :ok}` on success or `{:error, reason}` on failure.
  """
  @spec remove_log_hook() :: {:ok, :ok} | {:error, String.t()}
  def remove_log_hook(), do: err()

  @doc """
  Registers a PID to receive change notifications for this connection.

  The registered PID receives messages in the form:
  `{:xqlite_update, action, db_name, table_name, rowid}` where:
  - `action` is `:insert`, `:update`, or `:delete`
  - `db_name` is the database name (e.g., `"main"`, `"temp"`)
  - `table_name` is the table that was modified
  - `rowid` is the rowid of the affected row

  This is a **per-connection** setting. Each connection can have at most one
  update hook. Calling `set_update_hook/2` again replaces the previous hook.

  The callback fires before the change is committed — if the enclosing
  transaction rolls back, you will have already received the notification.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec set_update_hook(conn :: Xqlite.conn(), pid :: pid()) :: :ok | Xqlite.error()
  def set_update_hook(_conn, _pid), do: err()

  @doc """
  Removes the change notification hook from this connection.

  After calling this, the connection will no longer send
  `{:xqlite_update, ...}` messages to any PID.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec remove_update_hook(conn :: Xqlite.conn()) :: :ok | Xqlite.error()
  def remove_update_hook(_conn), do: err()

  @doc """
  Installs a WAL hook on the connection.

  After each commit in WAL mode, SQLite invokes the hook with the
  attached database name and the number of frames in the WAL log. We
  forward

      {:xqlite_wal, db_name, pages}

  to `pid` — `db_name` is a binary (`"main"`, `"temp"`, or an attached
  database name), `pages` is a non-negative integer.

  Useful for WAL-size monitoring and triggering manual checkpoints when
  the log grows past a threshold.

  Only one WAL hook per connection. Replacing it atomically reclaims the
  previous state.

  > #### Warning — PRAGMA wal_autocheckpoint replaces this hook {: .warning}
  >
  > SQLite's `wal_autocheckpoint` PRAGMA and the
  > `sqlite3_wal_autocheckpoint` C function both register their own
  > internal WAL hook, silently replacing any previously installed one.
  > Same memory-safety guarantees as `set_busy_handler/5`: no leak,
  > messages just stop. Install this hook *after* any
  > `wal_autocheckpoint` configuration, or switch to
  > `wal_checkpoint/3` for explicit checkpointing.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec set_wal_hook(conn :: Xqlite.conn(), pid :: pid()) :: :ok | Xqlite.error()
  def set_wal_hook(_conn, _pid), do: err()

  @doc """
  Removes the WAL hook from this connection.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec remove_wal_hook(conn :: Xqlite.conn()) :: :ok | Xqlite.error()
  def remove_wal_hook(_conn), do: err()

  @doc """
  Installs a commit hook on the connection.

  Immediately before each commit (regardless of journal mode), forwards

      {:xqlite_commit}

  to `pid`. The hook is observation-only — it never vetoes the commit.

  Only one commit hook per connection. Replacing it is atomic.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec set_commit_hook(conn :: Xqlite.conn(), pid :: pid()) :: :ok | Xqlite.error()
  def set_commit_hook(_conn, _pid), do: err()

  @doc """
  Removes the commit hook from this connection.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec remove_commit_hook(conn :: Xqlite.conn()) :: :ok | Xqlite.error()
  def remove_commit_hook(_conn), do: err()

  @doc """
  Installs a rollback hook on the connection.

  After each rollback (whether user-initiated or forced by a
  constraint / deferred-FK failure at commit), forwards

      {:xqlite_rollback}

  to `pid`.

  Only one rollback hook per connection. Replacing it is atomic.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec set_rollback_hook(conn :: Xqlite.conn(), pid :: pid()) :: :ok | Xqlite.error()
  def set_rollback_hook(_conn, _pid), do: err()

  @doc """
  Removes the rollback hook from this connection.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec remove_rollback_hook(conn :: Xqlite.conn()) :: :ok | Xqlite.error()
  def remove_rollback_hook(_conn), do: err()

  @doc """
  Registers a progress-tick subscriber on the connection.

  After every ~64 SQLite VM instructions (8 ops × `every_n` callback
  invocations), forwards

      {:xqlite_progress, count, elapsed_ms}              # tag = nil
      {:xqlite_progress, tag, count, elapsed_ms}         # tag != nil

  to `pid`. `count` is the per-subscriber decimated counter (starts at
  0, incremented every callback fire, emit when divisible by `every_n`).
  `elapsed_ms` is the wall time since this subscriber was registered.

  Multiple subscribers can coexist on the same connection — each gets a
  unique handle. Subscribers are independent: registering or
  unregistering one never affects another. The registration handle is
  the value returned in `{:ok, handle}` and is what `unregister_progress_hook/2`
  expects.

  `every_n` must be `>= 1`. `tag` is a string (typically
  `Atom.to_string(:my_atom)` from the `Xqlite.register_progress_hook/3`
  wrapper) used to disambiguate messages from multiple subscribers
  inside the same listener process; pass `nil` to omit the tag.

  This subscriber-list shares the SQLite progress-handler slot with
  cancellation. Both compose: cancel signals interrupt the query
  *before* tick emission. Tick subscribers do not affect cancellation
  latency beyond a handful of nanoseconds per fire.

  Returns `{:ok, handle}` on success or `{:error, reason}` on failure.
  """
  @spec register_progress_hook(
          conn :: Xqlite.conn(),
          pid :: pid(),
          every_n :: pos_integer(),
          tag :: String.t() | nil
        ) :: {:ok, non_neg_integer()} | Xqlite.error()
  def register_progress_hook(_conn, _pid, _every_n, _tag), do: err()

  @doc """
  Unregisters a progress-tick subscriber by its handle.

  Idempotent — passing an unknown handle (already-unregistered, or
  never registered on this connection) is a no-op and returns `:ok`.

  Returns `:ok` on success or `{:error, :connection_closed}` if the
  connection has been closed.
  """
  @spec unregister_progress_hook(conn :: Xqlite.conn(), handle :: non_neg_integer()) ::
          :ok | Xqlite.error()
  def unregister_progress_hook(_conn, _handle), do: err()

  @doc """
  Serializes an attached database to a contiguous binary.

  Atomic, point-in-time snapshot. Use `Xqlite.serialize/1` for a default
  `"main"` schema.

  Returns `{:ok, binary}` on success or `{:error, reason}` on failure.
  """
  @spec serialize(conn :: Xqlite.conn(), schema :: String.t()) ::
          {:ok, binary()} | Xqlite.error()
  def serialize(_conn, _schema), do: err()

  @doc """
  Deserializes a binary into the named schema, replacing its contents.

  The binary must be a valid SQLite database image (as produced by
  `serialize/2`). After deserialization the connection operates on the
  new database entirely in memory.

  When `read_only` is `true`, write operations on the schema fail with
  `{:error, {:read_only_database, _}}`. When `false` it is writable and
  may grow as needed.

  Use `Xqlite.deserialize/4` for defaulted `schema`/`read_only`.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec deserialize(
          conn :: Xqlite.conn(),
          schema :: String.t(),
          data :: binary(),
          read_only :: boolean()
        ) :: :ok | Xqlite.error()
  def deserialize(_conn, _schema, _data, _read_only), do: err()

  # ---------------------------------------------------------------------------
  # Extension Loading
  # ---------------------------------------------------------------------------

  @doc """
  Enables or disables extension loading for the given connection.

  Extension loading is disabled by default for security. You must call
  `enable_load_extension(conn, true)` before calling `load_extension/2` or
  `load_extension/3`. Call `enable_load_extension(conn, false)` when done
  loading to re-lock the connection.
  """
  @spec enable_load_extension(conn :: Xqlite.conn(), enabled :: boolean()) ::
          :ok | Xqlite.error()
  def enable_load_extension(_conn, _enabled), do: err()

  @doc """
  Loads a SQLite extension from the shared library at `path`.

  Pass `nil` for `entry_point` to let SQLite auto-detect. Extension
  loading must be enabled first via `enable_load_extension/2`.

  Use `Xqlite.load_extension/2` for a defaulted `entry_point` of `nil`.
  """
  @spec load_extension(
          conn :: Xqlite.conn(),
          path :: String.t(),
          entry_point :: String.t() | nil
        ) :: :ok | Xqlite.error()
  def load_extension(_conn, _path, _entry_point), do: err()

  # ---------------------------------------------------------------------------
  # Online Backup
  # ---------------------------------------------------------------------------

  @doc """
  Backs up the named schema to a file at `dest_path`.

  The destination file is created or overwritten. The source database
  remains readable during the backup.

  Use `Xqlite.backup/2` for a defaulted `"main"` schema.
  """
  @spec backup(
          conn :: Xqlite.conn(),
          schema :: String.t(),
          dest_path :: String.t()
        ) :: :ok | Xqlite.error()
  def backup(_conn, _schema, _dest_path), do: err()

  @doc """
  Restores the named schema from a file at `src_path`.

  The connection's existing data in that schema is overwritten.

  Use `Xqlite.restore/2` for a defaulted `"main"` schema.
  """
  @spec restore(
          conn :: Xqlite.conn(),
          schema :: String.t(),
          src_path :: String.t()
        ) :: :ok | Xqlite.error()
  def restore(_conn, _schema, _src_path), do: err()

  @doc """
  Backs up a database to a file with progress reporting and cancellation.

  Copies `pages_per_step` pages at a time, sending
  `{:xqlite_backup_progress, remaining, pagecount}` messages to `pid`
  after each step. Between steps, all of `cancel_tokens` are polled —
  if *any* is signalled, returns `{:error, :operation_cancelled}`
  (OR-semantics). Pass an empty list for no-cancellation.

  Use `create_cancel_token/0` to create tokens and `cancel_operation/1`
  from another process to signal one.
  """
  @spec backup_with_progress(
          conn :: Xqlite.conn(),
          schema :: String.t(),
          dest_path :: String.t(),
          pid :: pid(),
          pages_per_step :: pos_integer(),
          cancel_tokens :: [reference()]
        ) :: :ok | Xqlite.error()
  def backup_with_progress(_conn, _schema, _dest_path, _pid, _pages_per_step, _cancel_tokens),
    do: err()

  # ---------------------------------------------------------------------------
  # Session Extension
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new change-tracking session on the connection.

  Returns an opaque session handle. Attach tables to track with
  `session_attach/2` before making changes.
  """
  @spec session_new(conn :: Xqlite.conn()) :: {:ok, reference()} | Xqlite.error()
  def session_new(_conn), do: err()

  @doc """
  Attaches a table to be tracked by the session.

  Pass a table name to track that table, or `nil` to track all tables.
  """
  @spec session_attach(session :: reference(), table :: String.t() | nil) ::
          :ok | Xqlite.error()
  def session_attach(_session, _table), do: err()

  @doc """
  Captures a changeset from the session.

  Returns a binary containing all INSERT/UPDATE/DELETE operations
  recorded since the session was created or the last changeset capture.
  """
  @spec session_changeset(session :: reference()) :: {:ok, binary()} | Xqlite.error()
  def session_changeset(_session), do: err()

  @doc """
  Captures a patchset from the session.

  Like `session_changeset/1` but the patchset format is more compact —
  it omits original primary key values for UPDATE operations.
  """
  @spec session_patchset(session :: reference()) :: {:ok, binary()} | Xqlite.error()
  def session_patchset(_session), do: err()

  @doc """
  Returns true if the session has recorded no changes.
  """
  @spec session_is_empty(session :: reference()) :: boolean()
  def session_is_empty(_session), do: err()

  @doc """
  Deletes the session, releasing its resources.

  The session handle must not be used after this call.
  """
  @spec session_delete(session :: reference()) :: :ok | Xqlite.error()
  def session_delete(_session), do: err()

  @doc """
  Applies a changeset binary to a connection.

  `conflict_strategy` determines behavior on conflicts:
  - `:omit` — skip conflicting changes
  - `:replace` — overwrite with the changeset's values
  - `:abort` — abort the entire apply operation
  """
  @spec changeset_apply(
          conn :: Xqlite.conn(),
          changeset :: binary(),
          conflict_strategy :: :omit | :replace | :abort
        ) :: :ok | Xqlite.error()
  def changeset_apply(_conn, _changeset, _conflict_strategy), do: err()

  @doc """
  Inverts a changeset binary.

  INSERT becomes DELETE, DELETE becomes INSERT, UPDATE values are swapped.
  """
  @spec changeset_invert(changeset :: binary()) :: {:ok, binary()} | Xqlite.error()
  def changeset_invert(_changeset), do: err()

  @doc """
  Concatenates two changeset binaries into one.
  """
  @spec changeset_concat(a :: binary(), b :: binary()) :: {:ok, binary()} | Xqlite.error()
  def changeset_concat(_a, _b), do: err()

  # ---------------------------------------------------------------------------
  # Incremental Blob I/O
  # ---------------------------------------------------------------------------

  @doc """
  Opens a BLOB for incremental I/O.

  Returns an opaque blob handle for reading/writing chunks of a BLOB
  value without loading the entire thing into memory.

  - `db` — database name (typically `"main"`)
  - `table` — table name
  - `column` — column name containing the BLOB
  - `row_id` — rowid of the row
  - `read_only` — `true` for read-only access, `false` for read-write
  """
  @spec blob_open(
          conn :: Xqlite.conn(),
          db :: String.t(),
          table :: String.t(),
          column :: String.t(),
          row_id :: integer(),
          read_only :: boolean()
        ) :: {:ok, reference()} | Xqlite.error()
  def blob_open(_conn, _db, _table, _column, _row_id, _read_only), do: err()

  @doc """
  Reads `length` bytes from the blob starting at `offset`.
  """
  @spec blob_read(blob :: reference(), offset :: non_neg_integer(), length :: pos_integer()) ::
          {:ok, binary()} | Xqlite.error()
  def blob_read(_blob, _offset, _length), do: err()

  @doc """
  Writes `data` to the blob starting at `offset`.

  Cannot change the blob size — the data must fit within the existing
  blob. Use `zeroblob()` in SQL to pre-allocate the desired size.
  """
  @spec blob_write(blob :: reference(), offset :: non_neg_integer(), data :: binary()) ::
          :ok | Xqlite.error()
  def blob_write(_blob, _offset, _data), do: err()

  @doc """
  Returns the size of the blob in bytes.
  """
  @spec blob_size(blob :: reference()) :: {:ok, non_neg_integer()} | Xqlite.error()
  def blob_size(_blob), do: err()

  @doc """
  Moves the blob handle to a different row in the same table/column.

  More efficient than closing and re-opening for sequential row access.
  """
  @spec blob_reopen(blob :: reference(), row_id :: integer()) :: :ok | Xqlite.error()
  def blob_reopen(_blob, _row_id), do: err()

  @doc """
  Closes the blob handle, releasing its resources.
  """
  @spec blob_close(blob :: reference()) :: :ok | Xqlite.error()
  def blob_close(_blob), do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
