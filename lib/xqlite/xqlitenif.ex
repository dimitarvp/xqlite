defmodule XqliteNIF do
  use Rustler, otp_app: :xqlite, crate: :xqlitenif, mode: :release

  @type stream_fetch_ok_result :: %{rows: [list(term())]}

  @doc """
  Opens a connection to an SQLite database file.

  `path` is the file path to the database. If the file does not exist,
  SQLite will attempt to create it. URI filenames are supported
  (e.g., "file:my_db.sqlite?mode=ro").

  `opts` is a keyword list for future options (currently unused at the NIF level).

  Returns `{:ok, conn_resource}` on success, where `conn_resource` is an
  opaque reference to the database connection. Returns `{:error, reason}`
  on failure, e.g., if the path is invalid or permissions are insufficient.
  """
  @spec open(path :: String.t(), opts :: keyword()) ::
          {:ok, Xqlite.conn()} | {:error, Xqlite.error()}
  def open(_path, _opts \\ []), do: err()

  @doc """
  Opens a connection to an in-memory SQLite database.

  `uri` is typically `":memory:"` for a private, temporary in-memory database.
  It can also be a URI filename like `"file:memdb1?mode=memory&cache=shared"`
  to create a named in-memory database that can be shared across connections
  in the same process.

  Returns `{:ok, conn_resource}` on success or `{:error, reason}` on failure.
  """
  @spec open_in_memory(uri :: String.t()) ::
          {:ok, Xqlite.conn()} | {:error, Xqlite.error()}
  def open_in_memory(_path \\ ":memory:"), do: err()

  @doc """
  Opens a connection to a private, temporary on-disk SQLite database.

  The database file is created by SQLite in a temporary location and is
  automatically deleted when the connection is closed. Each call creates
  a new, independent temporary database.

  Returns `{:ok, conn_resource}` on success or `{:error, reason}` on failure.
  """
  @spec open_temporary() :: {:ok, Xqlite.conn()} | {:error, Xqlite.error()}
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
        ) ::
          {:ok,
           %{
             columns: [String.t()],
             rows: [list(term())],
             num_rows: non_neg_integer()
           }}
          | {:error, Xqlite.error()}
  def query(_conn, _sql, _params \\ []), do: err()

  @doc """
  Executes a SQL query that returns rows, with support for cancellation.

  This is a cancellable version of `query/3`.
  See `query/3` for details on parameters, return values, and general behavior.

  `conn` is the database connection resource.
  `sql` is the SQL query string.
  `params` is an optional list of positional or keyword parameters.
  `cancel_token` is a resource created by `create_cancel_token/0`. If this token
  is cancelled via `cancel_operation/1` while the query is executing, the
  query will be interrupted.

  Returns `{:ok, result_map}` on successful completion, where `result_map` is
  `%{columns: [...], rows: [...], num_rows: ...}`.
  Returns `{:error, :operation_cancelled}` if the operation was cancelled.
  Returns `{:error, other_reason}` for other types of failures.
  """
  @spec query_cancellable(
          conn :: Xqlite.conn(),
          sql :: String.t(),
          params :: list() | keyword(),
          cancel_token :: reference()
        ) ::
          {:ok,
           %{
             columns: [String.t()],
             rows: [list(term())],
             num_rows: non_neg_integer()
           }}
          | {:error, Xqlite.error()}
  def query_cancellable(_conn, _sql, _params, _cancel_token), do: err()

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
  @spec execute(conn :: Xqlite.conn(), sql :: String.t(), params :: list()) ::
          {:ok, non_neg_integer()} | {:error, Xqlite.error()}
  def execute(_conn, _sql, _params \\ []), do: err()

  @doc """
  Executes a SQL statement that does not return rows, with support for cancellation.

  This is a cancellable version of `execute/3`.
  See `execute/3` for details on parameters, return values, and general behavior.

  `conn` is the database connection resource.
  `sql` is the SQL statement string.
  `params` is an optional list of positional parameters.
  `cancel_token` is a resource created by `create_cancel_token/0`. If this token
  is cancelled via `cancel_operation/1` while the statement is executing, the
  operation will be interrupted.

  Returns `{:ok, affected_rows}` on successful completion.
  Returns `{:error, :operation_cancelled}` if the operation was cancelled.
  Returns `{:error, other_reason}` for other types of failures.
  """
  @spec execute_cancellable(
          conn :: Xqlite.conn(),
          sql :: String.t(),
          params :: list(),
          cancel_token :: reference()
        ) ::
          {:ok, non_neg_integer()} | {:error, Xqlite.error()}
  def execute_cancellable(_conn, _sql, _params, _cancel_token), do: err()

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
          :ok | {:error, Xqlite.error()}
  def execute_batch(_conn, _sql), do: err()

  @doc """
  Executes one or more SQL statements separated by semicolons, with support for cancellation.

  This is a cancellable version of `execute_batch/2`.
  See `execute_batch/2` for details on parameters, return values, and general behavior.

  `conn` is the database connection resource.
  `sql_batch` is a string containing one or more SQL statements.
  `cancel_token` is a resource created by `create_cancel_token/0`. If this token
  is cancelled via `cancel_operation/1` while the batch is executing, the
  operation will be interrupted.

  Returns `:ok` if all statements in the batch execute successfully.
  Returns `{:error, :operation_cancelled}` if the operation was cancelled.
  Returns `{:error, other_reason}` for other types of failures.
  """
  @spec execute_batch_cancellable(
          conn :: Xqlite.conn(),
          sql_batch :: String.t(),
          cancel_token :: reference()
        ) ::
          :ok | {:error, Xqlite.error()}
  def execute_batch_cancellable(_conn, _sql_batch, _cancel_token), do: err()

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
          {:ok, term() | :no_value} | {:error, Xqlite.error()}
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

  Returns `:ok` if SQLite accepts the PRAGMA assignment. Note that SQLite
  might silently ignore invalid PRAGMA names or invalid values for a valid PRAGMA,
  still resulting in an `:ok` return from this function. To verify the change,
  subsequently call `get_pragma/2` or query the relevant state.
  Returns `{:error, reason}` if there's an issue preparing or executing the
  PRAGMA statement (e.g., unsupported Elixir type for `value`, syntax error).

  The `Xqlite.Pragma` module provides higher-level helpers for setting many
  common PRAGMAs with more type safety.
  """
  @spec set_pragma(conn :: Xqlite.conn(), name :: String.t(), value :: term()) ::
          :ok | {:error, Xqlite.error()}
  def set_pragma(_conn, _name, _value), do: err()

  @doc """
  Begins a new database transaction.

  Equivalent to executing the SQL statement `BEGIN;` or `BEGIN TRANSACTION;`.
  By default, SQLite transactions are `DEFERRED`.

  `conn` is the database connection resource.

  Returns `:ok` on success.
  Returns `{:error, reason}` if a transaction cannot be started (e.g., if one
  is already active on this connection, or due to other SQLite errors).
  """
  @spec begin(conn :: Xqlite.conn()) :: :ok | {:error, Xqlite.error()}
  def begin(_conn), do: err()

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
  @spec commit(conn :: Xqlite.conn()) :: :ok | {:error, Xqlite.error()}
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
  @spec rollback(conn :: Xqlite.conn()) :: :ok | {:error, Xqlite.error()}
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
          :ok | {:error, Xqlite.error()}
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
          :ok | {:error, Xqlite.error()}
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
          :ok | {:error, Xqlite.error()}
  def release_savepoint(_conn, _name), do: err()

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
          {:ok, [Xqlite.Schema.DatabaseInfo.t()]} | {:error, Xqlite.error()}
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
    - `:is_writable` (boolean()): `true` if data can be modified in this object.
    - `:strict` (boolean()): `true` if the table was declared using `STRICT` mode.
  Returns `{:error, reason}` on failure.
  """
  @spec schema_list_objects(conn :: Xqlite.conn(), schema_name :: String.t() | nil) ::
          {:ok, [Xqlite.Schema.SchemaObjectInfo.t()]} | {:error, Xqlite.error()}
  def schema_list_objects(_conn, _schema \\ nil), do: err()

  def schema_columns(_conn, _table_name), do: err()
  def schema_foreign_keys(_conn, _table_name), do: err()
  def schema_indexes(_conn, _table_name), do: err()
  def schema_index_columns(_conn, _index_name), do: err()
  def get_create_sql(_conn, _object_name), do: err()
  def last_insert_rowid(_conn), do: err()
  def create_cancel_token(), do: err()
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
          {:ok, reference()} | {:error, Xqlite.error()}
  def stream_open(_conn, _sql, _params, _opts \\ []), do: err()

  @doc """
  Retrieves the column names for an opened stream.

  `stream_handle` is the opaque resource returned by `stream_open/4`.

  Returns `{:ok, list_of_column_names}` where `list_of_column_names` is a list of strings,
  or `{:error, reason}` if the handle is invalid or another error occurs.
  The list of column names will be empty if the query yields no columns.
  """
  @spec stream_get_columns(stream_handle :: reference()) ::
          {:ok, [String.t()]} | {:error, Xqlite.error()}
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
  @spec stream_fetch(stream_handle :: reference(), batch_size :: non_neg_integer()) ::
          {:ok, stream_fetch_ok_result()} | :done | {:error, Xqlite.error()}
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
  @spec stream_close(stream_handle :: reference()) :: :ok | {:error, Xqlite.error()}
  def stream_close(_stream_handle), do: err()

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
