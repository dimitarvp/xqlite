defmodule XqliteNIF do
  @moduledoc """
  Low-level Native Implemented Functions (NIFs) for interacting with SQLite.

  This module provides direct, performant access to SQLite operations, powered by
  Rust and the `rusqlite` crate. It forms the foundation of the `Xqlite` library.

  **Connection lifecycle:**
  1. Open a database connection using `open/1`, `open_in_memory/1`, or `open_temporary/0`.
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

  A term of the wrong TYPE raises where it is met: `ArgumentError` on a raw
  stub here, from the native argument decoding, and `FunctionClauseError` at
  an `Xqlite` function that guards the argument. A value of the right type
  that this library refuses is an `{:error, reason}` answer instead — a
  binary that is not UTF-8 where text was meant included, which answers
  `{:error, :invalid_utf8_in_string}`, and one holding a NUL byte, which
  answers `{:error, :null_byte_in_string}`.

  Three kinds of argument answer for a wrong type instead of raising, because
  the function takes the term and judges it:

    * a PRAGMA name (`get_pragma/2`, `set_pragma/3`) is judged as bytes and
      answers `{:error, {:invalid_pragma_name, name}}` with the bytes as
      given, whatever kind of term it was;
    * every argument read as a list — parameters, cancel tokens, the
      authorizer's actions — answers `{:error, {:expected_list, _}}`,
      `{:error, {:expected_keyword_list, _}}` or
      `{:error, {:invalid_cancel_tokens, _}}`, naming what stopped the walk;
    * the batch size of `stream_fetch/2` and `stream_fetch_cancellable/3`
      answers `{:error, {:invalid_batch_size, %{provided: term, minimum: 1}}}`
      with the caller's own term. The statement doors (`stmt_multi_step/2`
      and its cancellable twin) take an integer argument, so anything else
      raises there — that is what keeps a huge batch size out.

  **Schema names:**
  A function that takes a schema name judges it under the connection lock
  before SQLite is asked, with SQLite's own lookup: `temp` is always known,
  ASCII case is folded, and no SQL runs, so no authorizer can deny it. A
  name that is not attached answers `{:error, {:no_such_schema, name}}` before
  anything is changed or any file is opened, and `""`, which SQLite reads as
  every database, `{:error, {:invalid_schema_name, ""}}`. `txn_state/2` and
  `schema_list_objects/2` take `:all` for every attached database.

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
  with `{:error, {:read_only_database, extended_code, message}}`.

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
  booleans (`true`/`false`), and binaries. A binary is stored as `TEXT` when
  its bytes are valid UTF-8 and as a `BLOB` otherwise; wrap it as
  `%Xqlite.Blob{bytes: bytes}` to store a `BLOB` whatever the bytes are.

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

  A string holding a second statement after the first is refused with
  `{:error, :multiple_statements}` and nothing runs. `execute_batch/2` is the
  exception: it exists to run several statements, one at a time, and keeps
  the ones that ran before a failure.

  Parameters, one rule on every door: a plain list is positional (`?1`, `?2`,
  …) and its length must be the statement's own parameter count, otherwise
  `{:error, {:invalid_parameter_count, %{expected: _, provided: _}}}` before a
  value is bound — `[]` and `nil` count as zero. A keyword list is named and
  must name every parameter once: a key the statement lacks is
  `{:error, {:invalid_parameter_name, name}}`, two keys on one parameter are
  `{:error, {:duplicate_parameter_name, name}}`, and a parameter no key named
  is `{:error, {:missing_parameter, %{index: _, name: _}}}` — `nil` there for
  a bare `?`, and a statement holding `?` or `?3` takes a positional list
  only. A key starting with `:`, `@` or `$` names that parameter as written;
  every other key gets the `:` prefix, so `[a: 1]` names `:a` and
  `[{:"@b", 1}]` names `@b`. The first two refusals carry the name the
  key resolved to that way, never the key itself: `[c: 1]` answers `":c"`.
  `:missing_parameter` carries SQLite's own spelling of the parameter no key
  named, read from the statement. A statement of more than 2 048 parameters
  refuses any keyword list with `{:error, {:too_many_named_parameters, _}}`.
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

  Parameters, one rule on every door: a plain list is positional (`?1`, `?2`,
  …) and its length must be the statement's own parameter count, otherwise
  `{:error, {:invalid_parameter_count, %{expected: _, provided: _}}}` before a
  value is bound — `[]` and `nil` count as zero. A keyword list is named and
  must name every parameter once: a key the statement lacks is
  `{:error, {:invalid_parameter_name, name}}`, two keys on one parameter are
  `{:error, {:duplicate_parameter_name, name}}`, and a parameter no key named
  is `{:error, {:missing_parameter, %{index: _, name: _}}}` — `nil` there for
  a bare `?`, and a statement holding `?` or `?3` takes a positional list
  only. A key starting with `:`, `@` or `$` names that parameter as written;
  every other key gets the `:` prefix, so `[a: 1]` names `:a` and
  `[{:"@b", 1}]` names `@b`. The first two refusals carry the name the
  key resolved to that way, never the key itself: `[c: 1]` answers `":c"`.
  `:missing_parameter` carries SQLite's own spelling of the parameter no key
  named, read from the statement. A statement of more than 2 048 parameters
  refuses any keyword list with `{:error, {:too_many_named_parameters, _}}`.
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
  `sqlite3_changes()` captured atomically inside the connection lock. The
  count is reported only when `sqlite3_total_changes()` moved across this
  statement, and is 0 otherwise: DML reports its real affected row count
  (with or without `RETURNING`), while SELECT, DDL, and PRAGMA report 0
  instead of the previous DML's sticky count. Result columns play no part
  in the decision.

  This is the recommended function when you need reliable affected row counts.
  Unlike calling `query/3` then `changes/1` separately, the count is captured
  before the lock is released, so it cannot be stale.

  Parameters, one rule on every door: a plain list is positional (`?1`, `?2`,
  …) and its length must be the statement's own parameter count, otherwise
  `{:error, {:invalid_parameter_count, %{expected: _, provided: _}}}` before a
  value is bound — `[]` and `nil` count as zero. A keyword list is named and
  must name every parameter once: a key the statement lacks is
  `{:error, {:invalid_parameter_name, name}}`, two keys on one parameter are
  `{:error, {:duplicate_parameter_name, name}}`, and a parameter no key named
  is `{:error, {:missing_parameter, %{index: _, name: _}}}` — `nil` there for
  a bare `?`, and a statement holding `?` or `?3` takes a positional list
  only. A key starting with `:`, `@` or `$` names that parameter as written;
  every other key gets the `:` prefix, so `[a: 1]` names `:a` and
  `[{:"@b", 1}]` names `@b`. The first two refusals carry the name the
  key resolved to that way, never the key itself: `[c: 1]` answers `":c"`.
  `:missing_parameter` carries SQLite's own spelling of the parameter no key
  named, read from the statement. A statement of more than 2 048 parameters
  refuses any keyword list with `{:error, {:too_many_named_parameters, _}}`.
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

  Parameters, one rule on every door: a plain list is positional (`?1`, `?2`,
  …) and its length must be the statement's own parameter count, otherwise
  `{:error, {:invalid_parameter_count, %{expected: _, provided: _}}}` before a
  value is bound — `[]` and `nil` count as zero. A keyword list is named and
  must name every parameter once: a key the statement lacks is
  `{:error, {:invalid_parameter_name, name}}`, two keys on one parameter are
  `{:error, {:duplicate_parameter_name, name}}`, and a parameter no key named
  is `{:error, {:missing_parameter, %{index: _, name: _}}}` — `nil` there for
  a bare `?`, and a statement holding `?` or `?3` takes a positional list
  only. A key starting with `:`, `@` or `$` names that parameter as written;
  every other key gets the `:` prefix, so `[a: 1]` names `:a` and
  `[{:"@b", 1}]` names `@b`. The first two refusals carry the name the
  key resolved to that way, never the key itself: `[c: 1]` answers `":c"`.
  `:missing_parameter` carries SQLite's own spelling of the parameter no key
  named, read from the statement. A statement of more than 2 048 parameters
  refuses any keyword list with `{:error, {:too_many_named_parameters, _}}`.
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

  The statement runs for real, so a positional list whose length is not the
  statement's own parameter count is `{:invalid_parameter_count, %{expected:
  _, provided: _}}` and nothing runs; `[]` and `nil` count as zero
  parameters.

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

  Parameters follow `query/3`'s rule: a plain list is positional and its
  length must be the statement's own parameter count, a keyword list is named
  and must name every parameter of the statement exactly once. See `query/3`
  for the three refusals, the 2 048 cap and how a key names a parameter.
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
  `params` is an optional list of positional parameters or a keyword list of
  named ones. Use an empty list `[]` if the statement has no parameters.

  Supported Elixir parameter types are integers, floats, strings, `nil`,
  booleans (`true`/`false`), and binaries. A binary is stored as `TEXT` when
  its bytes are valid UTF-8 and as a `BLOB` otherwise; wrap it as
  `%Xqlite.Blob{bytes: bytes}` to store a `BLOB` whatever the bytes are.

  Returns `{:ok, affected_rows}` on success, where `affected_rows` is a non-negative
  integer indicating the number of rows modified, inserted, or deleted. For DDL
  statements like `CREATE TABLE`, `affected_rows` is typically `0`.
  Returns `{:error, reason}` on failure. For example, `{:error, :execute_returned_results}`
  if a statement unexpectedly returns data (e.g., a `SELECT` statement or an
  `INSERT ... RETURNING` statement was passed).

  A string holding a second statement after the first is refused with
  `{:error, :multiple_statements}` and nothing runs. `execute_batch/2` is the
  exception: it exists to run several statements, one at a time, and keeps
  the ones that ran before a failure.

  Parameters, one rule on every door: a plain list is positional (`?1`, `?2`,
  …) and its length must be the statement's own parameter count, otherwise
  `{:error, {:invalid_parameter_count, %{expected: _, provided: _}}}` before a
  value is bound — `[]` and `nil` count as zero. A keyword list is named and
  must name every parameter once: a key the statement lacks is
  `{:error, {:invalid_parameter_name, name}}`, two keys on one parameter are
  `{:error, {:duplicate_parameter_name, name}}`, and a parameter no key named
  is `{:error, {:missing_parameter, %{index: _, name: _}}}` — `nil` there for
  a bare `?`, and a statement holding `?` or `?3` takes a positional list
  only. A key starting with `:`, `@` or `$` names that parameter as written;
  every other key gets the `:` prefix, so `[a: 1]` names `:a` and
  `[{:"@b", 1}]` names `@b`. The first two refusals carry the name the
  key resolved to that way, never the key itself: `[c: 1]` answers `":c"`.
  `:missing_parameter` carries SQLite's own spelling of the parameter no key
  named, read from the statement. A statement of more than 2 048 parameters
  refuses any keyword list with `{:error, {:too_many_named_parameters, _}}`.
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

  Parameters, one rule on every door: a plain list is positional (`?1`, `?2`,
  …) and its length must be the statement's own parameter count, otherwise
  `{:error, {:invalid_parameter_count, %{expected: _, provided: _}}}` before a
  value is bound — `[]` and `nil` count as zero. A keyword list is named and
  must name every parameter once: a key the statement lacks is
  `{:error, {:invalid_parameter_name, name}}`, two keys on one parameter are
  `{:error, {:duplicate_parameter_name, name}}`, and a parameter no key named
  is `{:error, {:missing_parameter, %{index: _, name: _}}}` — `nil` there for
  a bare `?`, and a statement holding `?` or `?3` takes a positional list
  only. A key starting with `:`, `@` or `$` names that parameter as written;
  every other key gets the `:` prefix, so `[a: 1]` names `:a` and
  `[{:"@b", 1}]` names `@b`. The first two refusals carry the name the
  key resolved to that way, never the key itself: `[c: 1]` answers `":c"`.
  `:missing_parameter` carries SQLite's own spelling of the parameter no key
  named, read from the statement. A statement of more than 2 048 parameters
  refuses any keyword list with `{:error, {:too_many_named_parameters, _}}`.
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
  `sql_batch` is a string containing one or more SQL statements. SQLite runs
  them one at a time. The first failure stops the batch and returns that
  error; the statements that already ran stay applied. There is no implicit
  transaction around a batch — a batch may open and close its own — so wrap
  the statements in your own `BEGIN` / `COMMIT` when the batch has to be
  all-or-nothing.

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
  Closes the database connection and frees its SQLite handle.

  Closing first finalizes every prepared statement, stream and incremental
  blob still open on the connection, so the handle is freed whatever order
  the caller tore things down in. Those child handles stay usable as terms:
  an operation on one returns `{:error, :connection_closed}`, and
  `stmt_finalize/1`, `stream_close/1` and `blob_close/1` return `:ok`. A
  session is not covered — call `session_delete/1` before closing.

  It is safe to call `close/1` multiple times on the same connection resource;
  subsequent calls are no-ops and will also return `:ok`.

  For on-disk temporary databases created with `open_temporary/0`, closing the
  connection also deletes the underlying temporary file.

  `conn` is the database connection resource.

  Returns `:ok`. SQLite can refuse to free the handle, which answers
  `{:error, {:database_busy_or_locked, code, message}}`. The children are
  finalized before the handle is freed, so that answer never means "nothing
  happened": every statement, stream and blob is gone, and the connection —
  still open — can be closed again. No state this library can reach makes
  SQLite refuse today; the answer is SQLite's own, passed on rather than
  discarded.

  The other error is `{:error, {:lock_error, message}}`, after a thread panicked inside the NIF
  while holding a lock the close needs (Rust marks such a lock broken for
  good). Two locks can produce it and they leave different states behind: the
  connection's own lock, where the SQLite handle is never freed and the
  connection is abandoned; and the lock over the statements, streams and blobs
  opened on it, which close takes first, so the connection stays open, stays
  usable, and every later close repeats the same error. Neither is reachable
  today, and a broken lock is never repaired — after a panic SQLite's own
  state may be half written and must not be touched.
  """
  @spec close(conn :: Xqlite.conn()) :: :ok | Xqlite.error()
  def close(_conn), do: err()

  @doc """
  Returns the filesystem path of the connection's main database.

  `{:ok, path}` for file-backed databases. `{:ok, nil}` for databases
  that have no backing file — in-memory and temporary databases
  (SQLite reports an empty filename for those; it is normalized to
  `nil` here).
  """
  @spec db_path(conn :: Xqlite.conn()) :: {:ok, String.t() | nil} | Xqlite.error()
  def db_path(_conn), do: err()

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

  The value is the first row's first column, so a PRAGMA that answers several
  rows is cut down to its first one: `compile_options` read here gives the
  first compile option, not the whole list. A PRAGMA that answers a list is
  read through `Xqlite.Pragma.get/2,3`, which knows which ones do, or through
  `XqliteNIF.query/3` with the PRAGMA as its SQL, which gives the rows
  unchanged.

  Note: Some PRAGMAs require an argument to read (e.g., `PRAGMA table_info(table_name)`).
  This function cannot read those: a name may hold only letters, digits and
  underscores, so there is nowhere to write the argument. Use
  `Xqlite.Pragma.get/3` or `XqliteNIF.query/3` for them. The `Xqlite.Pragma`
  module provides higher-level helpers for many common PRAGMAs.

  Reading `wal_autocheckpoint` reports xqlite's emulated threshold rather
  than issuing the PRAGMA: SQLite only reports a threshold while its own
  internal WAL hook occupies the hook slot, which xqlite's master callback
  holds (see `register_wal_hook/2`). A raw `PRAGMA wal_autocheckpoint;`
  query would always report `0` on an xqlite connection.
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

  Setting `busy_timeout` while a busy policy or a busy observer is
  installed returns `{:error, {:busy_timeout_write_refused, %{policy:
  boolean, observers: count}}}`: the PRAGMA would replace xqlite's busy
  callback. `Xqlite.busy_timeout/2` changes the wait instead.

  Setting `wal_autocheckpoint` through this function additionally repairs
  the WAL hook slot: the PRAGMA installs SQLite's internal autocheckpoint
  callback in place of xqlite's master WAL callback, so this NIF
  re-installs the master and mirrors the new threshold into its emulated
  autocheckpoint (see `register_wal_hook/2`). Raw-SQL `PRAGMA` statements
  get no such repair.

  This function checks one value only: an integer `busy_timeout` above
  `2_147_483_647`, which SQLite would read as `0`, returns
  `{:error, {:invalid_pragma_value, %{pragma: :busy_timeout, value: ms}}}`.
  Any other value is formatted and handed to SQLite, which parses what it can
  of it and reports success even when it stored its own fallback instead. `Xqlite.set_pragma/3` and `Xqlite.Pragma.put/4`
  check the value against the PRAGMA's definition first and refuse what it
  cannot take; use one of them unless you mean to reach SQLite unchecked.
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
  Returns `{:error, {:invalid_transaction_mode, mode}}` for any other atom.
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

  Corresponds to `PRAGMA "schema_name".table_list`, or to the bare
  `PRAGMA table_list` over every attached database for `:all`. This PRAGMA
  primarily lists tables, views, and virtual tables.

  `conn` is the database connection resource.
  `schema_name` (String.t() | :all): a schema such as "main", "temp" or an
  attached database's name, in any ASCII case.

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
  @spec schema_list_objects(conn :: Xqlite.conn(), schema_name :: String.t() | :all) ::
          {:ok, [Xqlite.Schema.SchemaObjectInfo.t()]} | Xqlite.error()
  def schema_list_objects(_conn, _schema), do: err()

  @doc """
  Retrieves detailed information about columns in a specific table or view.

  Corresponds to the `PRAGMA table_xinfo('table_name');` statement, which provides
  more details than `PRAGMA table_info`, including column hidden status.

  `conn` is the database connection resource.
  `table_name` (String.t()): The name of the table or view for which to retrieve
  column information. The name is case-sensitive based on SQLite's handling.

  Returns `{:ok, list_of_column_info}` on success, where `list_of_column_info`
  is a list of `Xqlite.Schema.ColumnInfo` structs, ordered by column ID.
  A name no table or view carries answers `{:error, {:no_such_table, table_name}}`.
  Each struct contains:
    - `:column_id` (integer()): 0-indexed ID of the column within the table.
    - `:name` (String.t()): Name of the column.
    - `:type_affinity` (atom): Resolved data type affinity (e.g., `:integer`, `:text`).
    - `:declared_type` (String.t()): Original data type string from `CREATE TABLE`.
    - `:nullable` (boolean()): `true` if the column allows NULL values.
    - `:default_value` (`t:Xqlite.Schema.ColumnInfo.default_value/0`): the
      column default, classified — `:none`, `{:literal, value}`,
      `{:blob, binary}`, `{:current, :time | :date | :timestamp}`, or
      `{:expr, sql}`. For generated columns this is `:none`; their
      expression is not exposed by `PRAGMA table_xinfo`.
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
  is a list of `Xqlite.Schema.ForeignKeyInfo` structs, `[]` for a table without
  any; a name no table or view carries answers `{:error, {:no_such_table, table_name}}`.
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
  of `Xqlite.Schema.IndexInfo` structs, `[]` for a table without any; a name no
  table or view carries answers `{:error, {:no_such_table, table_name}}`.
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
  within the index definition, or the key columns of a WITHOUT ROWID table of that
  name. A name that is neither answers `{:error, {:no_such_index, index_name}}`.
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

  This function reads the `sql` column of main's `sqlite_schema` table (formerly
  `sqlite_master`) for the row whose name is exactly the given one: an object in
  `temp` or an attached database is not looked for, and the case must match.

  `conn` is the database connection resource.
  `object_name` (String.t()): The name of the table, index, trigger, or view
  whose creation SQL is to be retrieved.

  Returns `{:ok, sql_string}` on success if the object exists, where `sql_string`
  is the `CREATE ...` statement, and `{:ok, nil}` for an automatic index, which
  has none. A name no row carries answers `{:error, {:no_such_object, object_name}}`,
  whichever kind of object was meant.
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
  Returns `true` when `term` is a token from `create_cancel_token/0`.

  Every other term answers `false`, including a plain `make_ref/0`, a
  connection, statement, stream or blob handle, and anything that is not a
  reference at all. Takes the term undecoded, so it answers rather than
  raising — it is what `Xqlite` asks before handing tokens to a cancellable
  operation.
  """
  @spec is_cancel_token(term :: term()) :: boolean()
  def is_cancel_token(_term), do: err()

  @doc """
  Returns `true` when `conn` is in auto-commit mode (no active transaction),
  `false` otherwise.

  Equivalent to `sqlite3_get_autocommit`. Zero-cost; always available.
  """
  @spec autocommit(Xqlite.conn()) :: {:ok, boolean()} | Xqlite.error()
  def autocommit(_conn), do: err()

  @doc """
  Reads one of the connection's limits (raw NIF); see `Xqlite.get_limit/2`.
  A term that is no atom raises `ArgumentError`.
  """
  @spec get_limit(conn :: Xqlite.conn(), category :: atom()) ::
          {:ok, non_neg_integer()} | Xqlite.error()
  def get_limit(_conn, _category), do: err()

  @doc """
  Sets one of the connection's limits and answers the value now in force (raw
  NIF); see `Xqlite.put_limit/3`. A number outside signed 64 bits, or a term
  of the wrong kind, raises `ArgumentError`.
  """
  @spec put_limit(conn :: Xqlite.conn(), category :: atom(), value :: integer()) ::
          {:ok, non_neg_integer()} | Xqlite.error()
  def put_limit(_conn, _category, _value), do: err()

  @doc """
  Returns the transaction state of the named schema, or the highest over every
  attached database for `:all`.

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
  @spec txn_state(Xqlite.conn(), String.t() | :all) ::
          {:ok, :none | :read | :write | :unknown} | Xqlite.error()
  def txn_state(_conn, _schema), do: err()

  @doc """
  Forces a WAL checkpoint. Equivalent to `sqlite3_wal_checkpoint_v2`.

  `mode` picks the checkpoint strategy:

    * `:passive` — checkpoints as many pages as possible
      without blocking readers or writers.
    * `:full` — waits for any concurrent writers to finish, then
      checkpoints all pages. Will set `busy: true` if readers prevent
      completion.
    * `:restart` — as `:full`, plus waits for existing readers to
      drain so the next writer can restart the WAL from the beginning.
    * `:truncate` — as `:restart`, plus truncates the WAL file on disk.

  `schema` names the one database to checkpoint; checkpoint each by name, as
  SQLite's every-database form reports the first database's counts alone.

  Returns `{:ok, %{log_pages: n, checkpointed_pages: n, busy: bool}}`:

    * `log_pages` — size of the WAL log in pages after the checkpoint.
    * `checkpointed_pages` — number of pages the checkpoint actually
      moved from the WAL into the database.
    * `busy` — `true` if the checkpoint did not complete all of its work
      because other connections held back progress.

  A `schema` whose database is not in WAL mode as this connection
  sees it returns `{:error, :not_in_wal_mode}`, and so does a WAL database
  this connection has not read yet. A checkpoint lock another connection
  holds returns `{:error, {:database_busy_or_locked, 5, message}}`. Any other
  atom as `mode` returns `{:error, {:invalid_checkpoint_mode, mode}}`.
  """
  @spec wal_checkpoint(
          Xqlite.conn(),
          :passive | :full | :restart | :truncate,
          String.t()
        ) :: {:ok, map()} | Xqlite.error()
  def wal_checkpoint(_conn, _mode, _schema), do: err()

  @doc """
  Returns a structured snapshot of `sqlite3_db_status` counters for the
  connection.

  Returns `{:ok, %{…}}` with the following keys. SQLite answers a (current,
  high-water) pair per counter and defines one half of it; each key reports
  that half. The three lookaside counts are the high-water half, a running
  total since the connection opened; every other integer is the current half.

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
    * `:deferred_fks?` — `true` while a foreign key violation is pending:
      under `PRAGMA defer_foreign_keys = ON`, and for a key declared
      `DEFERRABLE INITIALLY DEFERRED` with the PRAGMA off.
    * `:cache_used_shared` — heap bytes in the shared pager cache
      attributable to this connection.
    * `:cache_spill` — count of dirty-cache spills to disk.
    * `:tempbuf_spill` — bytes written to temporary files that more memory
      would have kept in memory.

  Call repeatedly for time-series monitoring.
  """
  @spec connection_stats(Xqlite.conn()) :: {:ok, map()} | Xqlite.error()
  def connection_stats(_conn), do: err()

  @doc """
  Sets the busy retry POLICY on the connection (raw NIF).

  Most users want `Xqlite.set_busy_policy/2`, which accepts keyword
  options with sane defaults.

  When SQLite encounters a locked database (another writer holds
  `RESERVED+`) the policy decides whether to retry or surface
  `SQLITE_BUSY` to the caller. The policy is single-slot by design —
  a retry decision cannot compose. For OBSERVING contention, register
  any number of subscribers with `register_busy_observer/2`.

    * `max_retries` — stop after this many retries and let the caller
      see `SQLITE_BUSY`.
    * `max_elapsed_ms` — the wall-time ceiling in milliseconds for a
      single busy event; the clock resets at the first callback of each
      fresh contention, like `max_retries`.
    * `sleep_ms` — milliseconds to sleep between retries. Zero disables
      the pause.

  Replacing an existing policy is atomic; observers are unaffected.

  > #### Note — a raw PRAGMA busy_timeout write is rejected here {: .info}
  >
  > While the policy is installed, a statement writing `busy_timeout` —
  > raw SQL in any spelling, or `set_pragma(conn, "busy_timeout", ms)` —
  > fails as it is prepared with `{:error, {:busy_timeout_write_refused,
  > %{policy: boolean, observers: count}}}`. It would otherwise replace
  > the installed callback at the SQLite C level and the policy would
  > stop applying. Use `Xqlite.busy_timeout/2` to switch to a plain
  > timeout.

  Returns `:ok`.
  """
  @spec set_busy_policy(
          conn :: Xqlite.conn(),
          max_retries :: non_neg_integer(),
          max_elapsed_ms :: non_neg_integer(),
          sleep_ms :: non_neg_integer()
        ) :: :ok | Xqlite.error()
  def set_busy_policy(_conn, _max_retries, _max_elapsed_ms, _sleep_ms),
    do: err()

  @doc """
  Removes the busy retry policy from the connection.

  Observers keep receiving `{:xqlite_busy, …}` messages; without a
  policy the connection waits up to the `busy_timeout` that was in
  effect when the busy slot was taken, then surfaces `SQLITE_BUSY`.
  Safe to call when no policy is installed.

  Returns `:ok`.
  """
  @spec remove_busy_policy(Xqlite.conn()) :: :ok | Xqlite.error()
  def remove_busy_policy(_conn), do: err()

  @doc """
  Registers a busy-contention observer on the connection (raw NIF).

  Every `SQLITE_BUSY` callback invocation sends

      {:xqlite_busy, retries_so_far, elapsed_ms}

  to `pid`. Any number of observers can be registered; each returns a
  handle for `unregister_busy_observer/2`. Observers fire whether or
  not a retry policy is installed. With no policy, the connection waits
  up to the `busy_timeout` that was in effect when the busy slot was
  taken (5000 ms unless you set it) before surfacing `SQLITE_BUSY`;
  unregistering the last observer puts that timeout back. While the
  slot is held, a statement writing `busy_timeout` is rejected with
  `{:error, {:busy_timeout_write_refused, %{policy: boolean, observers:
  count}}}`. See `Xqlite.register_busy_observer/2` for the full slot
  rules.

  Returns `{:ok, handle}`.
  """
  @spec register_busy_observer(conn :: Xqlite.conn(), pid :: pid()) ::
          {:ok, non_neg_integer()} | Xqlite.error()
  def register_busy_observer(_conn, _pid), do: err()

  @doc """
  Unregisters a busy-contention observer by handle.

  Idempotent — an unknown or already-removed handle is a no-op.

  Returns `:ok`.
  """
  @spec unregister_busy_observer(conn :: Xqlite.conn(), handle :: non_neg_integer()) ::
          :ok | Xqlite.error()
  def unregister_busy_observer(_conn, _handle), do: err()

  @doc """
  Sets the connection's busy timeout through the busy slot (raw NIF).

  Most users want `Xqlite.busy_timeout/2`.

  Removes the retry policy first. With busy observers registered, the
  slot stays theirs and carries the new timeout: observers keep
  receiving `{:xqlite_busy, …}` messages, and unregistering the last
  one keeps this timeout. With no observers, SQLite's own timeout
  handler takes the slot. `0` disables waiting.

  This is the one way to change the wait while the slot is held: it
  calls `sqlite3_busy_timeout` directly, so no authorizer is consulted,
  while a `busy_timeout` write in SQL is rejected (see
  `set_busy_policy/4`).

  Returns `:ok`. A value above `2_147_483_647`, which SQLite cannot store,
  returns `{:error, {:invalid_pragma_value, %{pragma: :busy_timeout, value:
  ms}}}` and changes nothing.
  """
  @spec set_busy_timeout(conn :: Xqlite.conn(), ms :: non_neg_integer()) ::
          :ok | Xqlite.error()
  def set_busy_timeout(_conn, _ms), do: err()

  @doc """
  Installs a deny-list authorizer on the connection (raw NIF).

  Most users want `Xqlite.set_authorizer/2`.

  SQLite consults the authorizer while *preparing* every statement.
  `denied_actions` is a list of action-kind atoms (e.g. `[:delete,
  :drop_table]`); any statement whose action kind is in the list fails at
  preparation with `{:error, {:authorization_denied, extended_code, message}}`.
  Everything else is allowed. Granularity is the action kind only (table/column
  arguments are ignored) and the only disposition is deny.

  The list is validated in full before anything is installed: an
  unrecognized atom returns `{:error, {:invalid_authorizer_action, atom}}`
  and installs nothing. Single slot per connection — a second call replaces
  the previous list.

  xqlite shares that slot: while a busy policy or a busy observer is
  installed the connection carries one authorizer holding your list plus
  two rules of xqlite's own. See `Xqlite.set_authorizer/2`.

  Returns `:ok`.
  """
  @spec set_authorizer(conn :: Xqlite.conn(), denied_actions :: [atom()]) ::
          :ok | Xqlite.error()
  def set_authorizer(_conn, _denied_actions), do: err()

  @doc """
  Removes any authorizer from the connection (raw NIF).

  Safe to call when none is installed (no-op). After removal, statement
  preparation is unrestricted again.

  Returns `:ok`.
  """
  @spec remove_authorizer(Xqlite.conn()) :: :ok | Xqlite.error()
  def remove_authorizer(_conn), do: err()

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
  A term that is not a cancellation token raises `ArgumentError`, the kind a
  term of the wrong type gets on a raw NIF; `Xqlite.cancel_operation/1` asks
  `is_cancel_token/1` first and answers
  `{:error, {:invalid_cancel_tokens, refusal}}` instead.
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

  Returns `{:ok, stream_handle_resource}` or `{:error, reason}`.
  The `stream_handle_resource` is an opaque reference.

  Compiles exactly ONE SQL statement, by the same rule as `stmt_prepare/2`:
  SQL holding no statement at all is `:no_statement` and a second
  statement after the first is `:multiple_statements`, so no stream is ever
  opened over half a string. A trailing comment, extra semicolons and
  whitespace are accepted.

  A positional list whose length is not the statement's own parameter count
  is `{:invalid_parameter_count, %{expected: _, provided: _}}` and no stream
  is opened; `[]` and `nil` count as zero parameters. A keyword list must name
  every parameter of the statement exactly once — see `query/3` for the three
  refusals, the 2 048 cap and for how a key names a parameter — and no stream is opened for
  any of them either.
  """
  @spec stream_open(
          conn :: Xqlite.conn(),
          sql :: String.t(),
          params :: list() | keyword()
        ) ::
          {:ok, reference()} | Xqlite.error()
  def stream_open(_conn, _sql, _params), do: err()

  @doc """
  Retrieves the column names for an opened stream.

  `stream_handle` is the opaque resource returned by `stream_open/3`.

  Returns `{:ok, list_of_column_names}` where `list_of_column_names` is a list of strings,
  or `{:error, reason}` if the handle is invalid or another error occurs.
  The list of column names will be empty if the query yields no columns.
  """
  @spec stream_get_columns(stream_handle :: reference()) ::
          {:ok, [String.t()]} | Xqlite.error()
  def stream_get_columns(_stream_handle), do: err()

  @doc """
  Fetches a batch of rows from an active stream handle.

  `stream_handle` is the opaque resource obtained from `stream_open/3`.
  `batch_size` is the largest number of rows this call may read; it must be
  at least 1. Anything else, 0 and a term that is no integer included, is
  rejected with
  `{:error, {:invalid_batch_size, %{provided: term, minimum: 1}}}` before the
  stream is touched, `provided` being the caller's own term, and is never
  clamped.

  Returns:
    - `{:ok, %{rows: [[term()]]}}` when rows were read. The inner list is one
      row, the outer list the batch.
    - `:done` once the stream is exhausted. The underlying SQLite statement
      is finalized at that moment, so every later fetch also answers `:done`.
    - `{:ok, %{rows: [[term()]]}}` with fewer rows than asked for when a read
      failed part-way through the batch: the rows read before the failing one
      come back now and the error is answered by the next fetch. The statement
      is finalized either way, so no row is ever read twice and no row from the
      failing one on is read at all.
    - `{:error, reason}` when a read fails with no row of that batch in hand,
      and on the fetch after a partial batch. Such a failure finalizes the
      statement too, so the fetch after the error is `:done` — except
      `:connection_closed`: closing the connection finalizes the stream, every
      later fetch answers `:connection_closed`, `stream_close/1` answers `:ok`
      without changing that, and `stream_get_columns/1` answers the names
      captured at open. `stream_close/1` drops a held-back error, so a fetch
      after the close answers `:done`.

  `Xqlite.stream/4` drives all of this; use it unless you are stepping the
  stream by hand.
  """
  @spec stream_fetch(stream_handle :: reference(), batch_size :: pos_integer()) ::
          {:ok, stream_fetch_ok_result()} | :done | Xqlite.error()
  def stream_fetch(_stream_handle, _batch_size), do: err()

  @doc """
  Fetches a batch of rows from an active stream handle, cancellable (raw NIF).

  Takes the same arguments as `stream_fetch/2` plus a list of cancellation
  tokens from `create_cancel_token/0`, and has the same return shapes, the
  same batch-size rejection (checked first, before any token is registered)
  and the same `:connection_closed` behaviour. The tokens are registered for
  this one batch only and unregistered before the call returns.

  Any signalled token in the list ends the fetch with
  `{:error, :operation_cancelled}` — OR-semantics across the list — and
  finalizes the statement, so the next fetch is `:done` and
  `stream_close/1` still answers `:ok`. Rows read before the cancel in the
  same batch are discarded with it; a cancellation is the one failure that
  throws rows away, while every other mid-batch error hands them back first.
  A token signalled before the call cancels during the first batch. Tokens
  are single-use, so a signalled token ends every stream it is handed to.

  An empty list behaves exactly like `stream_fetch/2`.

  Cancellation is checked every 8 SQLite VM instructions, so a statement
  whose whole run is cheaper than that finishes before the first check.

  Most users want `Xqlite.stream/4` and its `:cancel_tokens` option.
  """
  @spec stream_fetch_cancellable(
          stream_handle :: reference(),
          batch_size :: pos_integer(),
          tokens :: [reference()]
        ) :: {:ok, stream_fetch_ok_result()} | :done | Xqlite.error()
  def stream_fetch_cancellable(_stream_handle, _batch_size, _tokens), do: err()

  @doc """
  Closes an active stream and releases its underlying SQLite statement resources.

  This function should be called when a stream is no longer needed, either
  after all rows have been consumed or if the stream needs to be abandoned
  prematurely. It is safe to call this function multiple times on the same handle;
  subsequent calls after the first will be no-ops.

  `stream_handle` is the opaque resource returned by `stream_open/3`.

  Returns `:ok` if successful, or `{:error, reason}` if the handle is invalid
  or an error occurs during finalization (rare).
  """
  @spec stream_close(stream_handle :: reference()) :: :ok | Xqlite.error()
  def stream_close(_stream_handle), do: err()

  @doc """
  Prepares a manually managed statement (raw NIF).

  Most users want `Xqlite.prepare/2`. Compiles exactly ONE SQL statement:
  SQL holding no statement at all and a second statement after the first are
  structured errors (`:no_statement` / `:multiple_statements`), and a
  syntax error is `{:sql_input_error, %{sql: _, offset: _, code: _, message:
  _}}` carrying the byte offset SQLite reports — no silent partial
  compilation. Text after the first statement counts as a second statement
  only when it compiles to one, so a trailing comment, extra semicolons and
  whitespace are accepted; `query/3`, `execute/3`, `stream_open/3` and
  `explain_analyze/3` apply the same rule. The returned handle must
  eventually be finalized via `stmt_finalize/1` (garbage collection also
  finalizes abandoned handles).
  """
  @spec stmt_prepare(conn :: Xqlite.conn(), sql :: String.t()) ::
          {:ok, Xqlite.stmt()} | Xqlite.error()
  def stmt_prepare(_conn, _sql), do: err()

  @doc """
  Binds parameters to a prepared statement (raw NIF).

  Most users want `Xqlite.bind/2`. Accepts a plain list (positional `?1`,
  `?2`, … — the count must match or `{:error, {:invalid_parameter_count,
  %{provided: _, expected: _}}}` is returned) or a keyword list (named
  parameters). `[]` and `nil` both mean no parameters and count as zero, so
  a statement that takes any refuses them. A keyword list must name every
  parameter of the statement exactly once — see `query/3` for the three
  refusals, the 2 048 cap and for how a key names a parameter — so one call
  hands over one complete list; two partial binds in a row no longer add up. A
  statement that takes parameters and is mid-run (see `stmt_clear_bindings/1`)
  answers `{:error, :statement_mid_run}` and keeps its values; once the run is
  over the bind resets the statement, so the next step takes the new values.

  A binary value is stored as `TEXT` when its bytes are valid UTF-8 and as a
  `BLOB` otherwise; wrap it as `%Xqlite.Blob{bytes: bytes}` to store a `BLOB`
  whatever the bytes are.

  A bind the library refused — the count, the names, a value it cannot
  convert, a value longer than the connection's length limit — binds nothing
  at all, so it leaves the statement as it found it and an earlier successful
  bind stays in force. A bind SQLite itself refused after it had taken values
  leaves the values before the failing one bound and that one NULL, so the
  statement cannot be stepped until a bind succeeds or
  `stmt_clear_bindings/1` runs.
  """
  @spec stmt_bind(stmt :: Xqlite.stmt(), params :: list() | keyword()) ::
          :ok | Xqlite.error()
  def stmt_bind(_stmt, _params), do: err()

  @doc """
  Advances a prepared statement one row (raw NIF).

  Most users want `Xqlite.step/1`. Returns `{:row, values}` for a produced
  row, `:done` when the statement is exhausted, or `{:error, reason}`.

  A step that fails outright — a locked database, an I/O error, a runtime
  error in the SQL, a trigger's `RAISE`, a cancellation — is answered at
  once. No row was stepped past, so the statement is left where SQLite left
  it and the next step is SQLite's own rerun from the top, which meets the
  same failure; `stmt_reset/1` changes nothing about that. The exception is
  a step refused as busy while taking or committing its lock, whose run
  SQLite keeps for a retry, so the next step carries on. A row that came
  back and could not be read — a TEXT column holding bytes that are not
  valid UTF-8 — is different: SQLite has already stepped past it, so the
  error is held back and answered by the next call that reads a row, and the
  statement carries on at the row after it.

  A statement that takes parameters is refused with
  `{:error, {:parameters_unbound, %{expected: n}}}` until a bind succeeds or
  `stmt_clear_bindings/1` runs. A bind the library refused binds nothing, so
  it leaves that state as it found it; a bind SQLite itself refused after it
  had taken values puts the statement back into it. The check sits behind the
  lifecycle ones, so a finalized statement still answers
  `{:error, :statement_finalized}` and one on a closed connection
  `{:error, :connection_closed}`.
  """
  @spec stmt_step(stmt :: Xqlite.stmt()) ::
          {:row, [Xqlite.sqlite_value()]} | :done | Xqlite.error()
  def stmt_step(_stmt), do: err()

  @doc """
  Advances a prepared statement up to `batch_size` rows (raw NIF).

  Most users want `Xqlite.multi_step/2`. Returns
  `{:ok, %{rows: rows, done: boolean}}` — `done: true` means the statement
  exhausted within this batch — or `{:error, reason}`.

  A step that fails outright — a locked database, an I/O error, a runtime
  error in the SQL, a trigger's `RAISE`, a cancellation — is answered at once
  and this batch's rows go with it. No row was stepped past, so the statement
  is left where SQLite left it and the next step is SQLite's own rerun from
  the top, which meets the same failure; `stmt_reset/1` changes nothing about
  that. The exception is a step refused as busy while taking or committing
  its lock, whose run SQLite keeps for a retry, so the next step carries on.
  A row that came back and could not be read — a TEXT column holding
  bytes that are not valid UTF-8 — is different: the rows read before it come
  back now with `done: false`, the error waits, and the next call that reads
  a row answers it; the statement carries on at the row after the bad one.

  A statement that takes parameters is refused with
  `{:error, {:parameters_unbound, %{expected: n}}}` until a bind succeeds or
  `stmt_clear_bindings/1` runs. A bind the library refused binds nothing, so
  it leaves that state as it found it; a bind SQLite itself refused after it
  had taken values puts the statement back into it. The check sits behind the
  lifecycle ones, so a finalized statement still answers
  `{:error, :statement_finalized}` and one on a closed connection
  `{:error, :connection_closed}`.
  """
  @spec stmt_multi_step(stmt :: Xqlite.stmt(), batch_size :: pos_integer()) ::
          {:ok, %{rows: [[Xqlite.sqlite_value()]], done: boolean()}} | Xqlite.error()
  def stmt_multi_step(_stmt, _batch_size), do: err()

  @doc """
  Advances a prepared statement up to `batch_size` rows, cancellable (raw NIF).

  Most users want `Xqlite.multi_step_cancellable/3`. Same return shape as
  `stmt_multi_step/2`; any signalled token in the list aborts the loop with
  `{:error, :operation_cancelled}` (OR-semantics; an empty list means plain
  stepping). The unbound-parameter refusal of `stmt_multi_step/2` applies
  here too.
  """
  @spec stmt_multi_step_cancellable(
          stmt :: Xqlite.stmt(),
          batch_size :: pos_integer(),
          tokens :: [reference()]
        ) :: {:ok, %{rows: [[Xqlite.sqlite_value()]], done: boolean()}} | Xqlite.error()
  def stmt_multi_step_cancellable(_stmt, _batch_size, _tokens), do: err()

  @doc """
  Resets a prepared statement so it can be stepped again (raw NIF).

  Most users want `Xqlite.reset/1`. Bindings are preserved (SQLite
  semantics) — use `stmt_clear_bindings/1` to drop them — so a statement
  that was bound stays runnable across a reset. The return code of
  `sqlite3_reset` echoes the most recent step error rather than reporting
  the reset itself, so this returns `:ok` for any live statement.
  """
  @spec stmt_reset(stmt :: Xqlite.stmt()) :: :ok | Xqlite.error()
  def stmt_reset(_stmt), do: err()

  @doc """
  Clears all parameter bindings on a prepared statement back to NULL (raw NIF).

  Most users want `Xqlite.clear_bindings/1`. This is also the one way to ask
  for a statement that runs with NULL in every parameter: a statement that
  takes parameters and has never had a successful bind refuses to step until
  this has run.

  A statement that takes parameters and is mid-run — a step has answered a
  row, or was refused as busy while taking or committing its lock (SQLite
  keeps that run for a retry), and neither `:done`, another failure nor
  `stmt_reset/1` has followed — answers
  `{:error, :statement_mid_run}` and keeps its values, because SQLite would
  release them in place and leave every row still to come reading NULL.
  A statement that takes no parameters has nothing to release and answers
  `:ok` wherever it is.
  """
  @spec stmt_clear_bindings(stmt :: Xqlite.stmt()) :: :ok | Xqlite.error()
  def stmt_clear_bindings(_stmt), do: err()

  @doc """
  Returns the result column names of a prepared statement (raw NIF).

  Most users want `Xqlite.column_names/1`. Live statements read the names
  directly, so SQLite's auto-reprepare after schema changes (e.g. `SELECT *`
  re-expansion) is reflected; finalized statements answer with the
  prepare-time snapshot.
  """
  @spec stmt_column_names(stmt :: Xqlite.stmt()) :: {:ok, [String.t()]} | Xqlite.error()
  def stmt_column_names(_stmt), do: err()

  @doc """
  Finalizes a prepared statement, releasing its SQLite resources (raw NIF).

  Most users want `Xqlite.finalize/1`. Idempotent — finalizing an
  already-finalized statement returns `:ok`. Abandoned statements are also
  finalized when garbage-collected, but explicit finalization frees the
  handle at once. Closing the connection finalizes every statement still
  open on it: every later step, bind, reset and clear answers
  `{:error, :connection_closed}`, this answers `:ok`, and
  `stmt_column_names/1` answers the names captured at prepare.
  """
  @spec stmt_finalize(stmt :: Xqlite.stmt()) :: :ok | Xqlite.error()
  def stmt_finalize(_stmt), do: err()

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
  Registers a PID to receive SQLite diagnostic log events. Multi-subscriber.

  SQLite's global log callback (`sqlite3_config(SQLITE_CONFIG_LOG)`) sends
  diagnostic messages for events like auto-index creation, schema changes,
  and warnings that don't surface as errors. Each registered PID receives
  messages in the form `{:xqlite_log, error_code, message}`.

  This is a **global, per-process** subscription — but multiple PIDs can
  subscribe independently. The first call installs the master callback;
  subsequent calls just add to the subscriber list. Use the returned
  `handle` to unregister this specific subscriber via
  `unregister_log_hook/1`.

  Returns `{:ok, handle}` on success or `{:error, reason}` on failure.
  """
  @spec register_log_hook(pid :: pid()) ::
          {:ok, non_neg_integer()} | Xqlite.error()
  def register_log_hook(_pid), do: err()

  @doc """
  Unregisters a log subscriber by handle. Idempotent — unknown handles
  are no-ops.
  """
  @spec unregister_log_hook(handle :: non_neg_integer()) ::
          :ok | Xqlite.error()
  def unregister_log_hook(_handle), do: err()

  @doc """
  Registers a PID to receive change notifications for this connection.
  Multi-subscriber.

  Each registered PID receives messages in the form:
  `{:xqlite_update, action, db_name, table_name, rowid}` where:
  - `action` is `:insert`, `:update`, or `:delete`
  - `db_name` is the database name (e.g., `"main"`, `"temp"`)
  - `table_name` is the table that was modified
  - `rowid` is the rowid of the affected row

  Multiple subscribers can coexist on the same connection — each gets a
  unique handle. The callback fires for every subscriber on every
  update. Use the returned handle to unregister via
  `unregister_update_hook/2`.

  The callback fires before the change is committed — if the enclosing
  transaction rolls back, every subscriber will have already received
  the notification.

  Returns `{:ok, handle}` on success or `{:error, reason}` on failure.
  """
  @spec register_update_hook(conn :: Xqlite.conn(), pid :: pid()) ::
          {:ok, non_neg_integer()} | Xqlite.error()
  def register_update_hook(_conn, _pid), do: err()

  @doc """
  Unregisters an update subscriber by handle. Idempotent — unknown
  handles are no-ops.
  """
  @spec unregister_update_hook(conn :: Xqlite.conn(), handle :: non_neg_integer()) ::
          :ok | Xqlite.error()
  def unregister_update_hook(_conn, _handle), do: err()

  @doc """
  Registers a PID to receive WAL events on the connection. Multi-subscriber.

  After each commit in WAL mode, every registered subscriber receives

      {:xqlite_wal, db_name, pages}

  — `db_name` is a binary (`"main"`, `"temp"`, or attached database
  name), `pages` is a non-negative integer (number of frames in the WAL
  log).

  Useful for WAL-size monitoring and triggering manual checkpoints when
  the log grows past a threshold. Multiple subscribers register
  independently; each gets a unique handle.

  WAL subscribers coexist with automatic checkpointing: SQLite's
  wal_hook slot and its built-in autocheckpoint are mutually exclusive
  at the C level, so xqlite's master callback emulates the
  autocheckpoint itself (passive checkpoint once the WAL reaches the
  `wal_autocheckpoint` threshold, default 1000 pages). Changing the
  threshold through `set_pragma/3` keeps both behaviors intact.

  > #### Warning — raw-SQL `PRAGMA wal_autocheckpoint` {: .warning}
  >
  > Issuing `PRAGMA wal_autocheckpoint = N` through `query/3`,
  > `execute/3`, or `execute_batch/2` installs SQLite's internal WAL
  > hook in place of ours: subscribers silently stop receiving events
  > (no memory is leaked). Only `set_pragma/3` repairs the slot —
  > always set this PRAGMA through it.

  Returns `{:ok, handle}` on success or `{:error, reason}` on failure.
  """
  @spec register_wal_hook(conn :: Xqlite.conn(), pid :: pid()) ::
          {:ok, non_neg_integer()} | Xqlite.error()
  def register_wal_hook(_conn, _pid), do: err()

  @doc """
  Unregisters a WAL subscriber by handle. Idempotent.
  """
  @spec unregister_wal_hook(conn :: Xqlite.conn(), handle :: non_neg_integer()) ::
          :ok | Xqlite.error()
  def unregister_wal_hook(_conn, _handle), do: err()

  @doc """
  Registers a PID to receive commit events on the connection.
  Multi-subscriber.

  Immediately before each commit (regardless of journal mode), every
  registered subscriber receives

      {:xqlite_commit}

  Observation-only — the master callback never vetoes the commit.
  """
  @spec register_commit_hook(conn :: Xqlite.conn(), pid :: pid()) ::
          {:ok, non_neg_integer()} | Xqlite.error()
  def register_commit_hook(_conn, _pid), do: err()

  @doc """
  Unregisters a commit subscriber by handle. Idempotent.
  """
  @spec unregister_commit_hook(conn :: Xqlite.conn(), handle :: non_neg_integer()) ::
          :ok | Xqlite.error()
  def unregister_commit_hook(_conn, _handle), do: err()

  @doc """
  Registers a PID to receive rollback events on the connection.
  Multi-subscriber.

  After each rollback (whether user-initiated or forced by a constraint
  / deferred-FK failure at commit), every registered subscriber
  receives

      {:xqlite_rollback}

  Note: SQLite does not invoke this callback for `ROLLBACK TO
  SAVEPOINT` operations — only for outer-transaction rollbacks.
  """
  @spec register_rollback_hook(conn :: Xqlite.conn(), pid :: pid()) ::
          {:ok, non_neg_integer()} | Xqlite.error()
  def register_rollback_hook(_conn, _pid), do: err()

  @doc """
  Unregisters a rollback subscriber by handle. Idempotent.
  """
  @spec unregister_rollback_hook(conn :: Xqlite.conn(), handle :: non_neg_integer()) ::
          :ok | Xqlite.error()
  def unregister_rollback_hook(_conn, _handle), do: err()

  @doc """
  Registers a progress-tick subscriber on the connection.

  After every `8 × every_n` SQLite VM instructions (the handler runs every
  8 of them, and one message goes out per `every_n` runs), forwards

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

  `every_n` of `0` returns `{:error, {:invalid_hook_option, %{key: :every_n,
  value: 0, reason: :invalid_value}}}`. `tag` is a string (typically
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
  `{:error, {:read_only_database, _, _}}`. When `false` it is writable and
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
  `{:xqlite_backup_progress, %{remaining: r, total: t, status: s}}` to `pid`
  after each step: `status` is `:copied`, or `:busy` when a lock blocked the
  step, which is then retried every 100 ms. A `:busy` message before the first
  copied step carries `remaining: 0, total: 0`. Between steps, all of
  `cancel_tokens` are polled —
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

  @doc """
  Creates a new change-tracking session on the connection.

  Returns an opaque session handle. Attach tables to track with
  `session_attach/2` before making changes.
  """
  @spec session_new(conn :: Xqlite.conn()) :: {:ok, reference()} | Xqlite.error()
  def session_new(_conn), do: err()

  @doc """
  Attaches a table to be tracked by the session.

  Pass a table name to track that table, `""` included, or `:all` to track all
  tables.
  """
  @spec session_attach(session :: reference(), table :: String.t() | :all) ::
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
  Returns `{:ok, true}` if the session has recorded no changes.
  """
  @spec session_is_empty(session :: reference()) :: {:ok, boolean()} | Xqlite.error()
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
  - `:replace` — overwrite with the changeset's values. SQLite only permits
    replacement for `DATA` and `CONFLICT` conflicts; for a `NOTFOUND`,
    `CONSTRAINT`, or `FOREIGN_KEY` conflict there is nothing to overwrite, so
    the entire apply is aborted and rolled back, returning an error. The
    offending change is not silently skipped — that is `:omit`, not `:replace`.
  - `:abort` — abort the entire apply operation

  Any other atom returns `{:error, {:invalid_conflict_strategy, strategy}}`.
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
  Reads up to `length` bytes from the blob, starting at `offset`.

  The read is a window over the bytes that are there: it answers fewer bytes
  than asked for when the blob ends first, and `{:ok, ""}` when `offset` is at
  or past the end, without asking SQLite anything. A short answer therefore
  means the blob ended, not that the read failed — a caller that wants the
  size asks `blob_size/1`. A `length` of zero answers `{:ok, ""}` too.

  A negative `offset` or `length` raises `ArgumentError`: the arguments are
  unsigned on the native side, so the decoding refuses them.

  A write is not a window: `blob_write/3` rejects a write past the end with
  `{:error, {:blob_write_out_of_bounds, _}}` rather than writing the part
  that fits.
  """
  @spec blob_read(
          blob :: reference(),
          offset :: non_neg_integer(),
          length :: non_neg_integer()
        ) ::
          {:ok, binary()} | Xqlite.error()
  def blob_read(_blob, _offset, _length), do: err()

  @doc """
  Writes `data` to the blob starting at `offset`.

  Cannot change the blob size — the data must fit within the existing
  blob. Use `zeroblob()` in SQL to pre-allocate the desired size. A write that
  would run past the end writes nothing and returns `{:error,
  {:blob_write_out_of_bounds, %{offset: offset, byte_size: byte_size(data),
  blob_size: size}}}`, where a read of the same range answers the bytes that
  are there.
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
