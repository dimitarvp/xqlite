defmodule Xqlite do
  @moduledoc ~S"""
  This is the central module of this library. All SQLite operations can be performed from here.
  Note that they delegate to other modules which you can also use directly.
  """

  @type conn :: reference()

  # ---------------------------------------------------------------------------
  # Connection options (validated via NimbleOptions)
  # ---------------------------------------------------------------------------

  @open_opts_schema NimbleOptions.new!(
                      journal_mode: [
                        type: {:in, [:wal, :delete, :truncate, :memory, :off]},
                        default: :wal,
                        doc:
                          "SQLite journal mode. `:wal` enables concurrent readers with a single writer."
                      ],
                      busy_timeout: [
                        type: :timeout,
                        default: 5_000,
                        doc:
                          "Milliseconds to wait when the database is locked. `:infinity` waits forever."
                      ],
                      foreign_keys: [
                        type: :boolean,
                        default: true,
                        doc:
                          "Enable foreign key constraint enforcement. SQLite defaults to OFF."
                      ],
                      synchronous: [
                        type: {:in, [:off, :normal, :full, :extra]},
                        default: :normal,
                        doc:
                          "Synchronous mode. `:normal` is safe with WAL and significantly faster than `:full`."
                      ],
                      cache_size: [
                        type: :integer,
                        default: -64_000,
                        doc:
                          "Page cache size. Negative values mean KB (e.g., `-64000` = 64MB). SQLite default is 2MB."
                      ],
                      temp_store: [
                        type: {:in, [:default, :file, :memory]},
                        default: :memory,
                        doc: "Where to store temporary tables and indices."
                      ],
                      wal_autocheckpoint: [
                        type: :non_neg_integer,
                        default: 1000,
                        doc:
                          "WAL auto-checkpoint threshold in pages. 0 disables auto-checkpoint."
                      ],
                      mmap_size: [
                        type: :non_neg_integer,
                        default: 0,
                        doc: "Memory-mapped I/O size in bytes. 0 disables mmap."
                      ],
                      auto_vacuum: [
                        type: {:in, [:none, :full, :incremental]},
                        default: :none,
                        doc: "Auto-vacuum mode. Must be set before creating any tables."
                      ]
                    )

  # ---------------------------------------------------------------------------
  # SQLite value types
  # ---------------------------------------------------------------------------

  @type sqlite_value :: integer() | float() | binary() | nil

  # ---------------------------------------------------------------------------
  # Query / execute result types
  # ---------------------------------------------------------------------------

  @type query_result :: %{
          columns: [String.t()],
          rows: [[sqlite_value()]],
          num_rows: non_neg_integer()
        }

  # ---------------------------------------------------------------------------
  # Error reason types (the inner value of {:error, reason})
  # ---------------------------------------------------------------------------

  @type constraint_kind ::
          :constraint_check
          | :constraint_commit_hook
          | :constraint_datatype
          | :constraint_foreign_key
          | :constraint_function
          | :constraint_not_null
          | :constraint_pinned
          | :constraint_primary_key
          | :constraint_rowid
          | :constraint_trigger
          | :constraint_unique
          | :constraint_vtab
          | nil

  @type sql_input_error :: %{
          code: integer(),
          message: String.t(),
          sql: String.t(),
          offset: integer()
        }

  @type error_reason ::
          :connection_closed
          | :execute_returned_results
          | :multiple_statements
          | :null_byte_in_string
          | :operation_cancelled
          | :unsupported_atom
          | {:cannot_convert_to_sqlite_value, String.t(), String.t()}
          | {:cannot_execute, String.t()}
          | {:cannot_execute_pragma, String.t(), String.t()}
          | {:cannot_fetch_row, String.t()}
          | {:cannot_open_database, String.t(), integer(), String.t()}
          | {:constraint_violation, constraint_kind(), String.t()}
          | {:database_busy_or_locked, String.t()}
          | {:expected_keyword_list, String.t()}
          | {:expected_keyword_tuple, String.t()}
          | {:expected_list, String.t()}
          | {:from_sql_conversion_failure, non_neg_integer(), atom(), String.t()}
          | {:index_exists, String.t()}
          | {:integral_value_out_of_range, non_neg_integer(), integer()}
          | {:internal_encoding_error, String.t()}
          | {:invalid_column_index, non_neg_integer()}
          | {:invalid_column_name, String.t()}
          | {:invalid_column_type, non_neg_integer(), String.t(), atom()}
          | {:invalid_parameter_count,
             %{provided: non_neg_integer(), expected: non_neg_integer()}}
          | {:invalid_parameter_name, String.t()}
          | {:invalid_pragma_name, String.t()}
          | {:invalid_stream_handle, String.t()}
          | {:lock_error, String.t()}
          | {:no_such_index, String.t()}
          | {:no_such_table, String.t()}
          | {:read_only_database, String.t()}
          | {:schema_changed, String.t()}
          | {:schema_parsing_error, String.t(), {:unexpected_value, String.t()}}
          | {:sql_input_error, sql_input_error()}
          | {:sqlite_failure, integer(), integer(), String.t() | nil}
          | {:table_exists, String.t()}
          | {:to_sql_conversion_failure, String.t()}
          | {:unsupported_data_type, atom()}
          | {:utf8_error, String.t()}

  @type error :: {:error, error_reason()}

  # ---------------------------------------------------------------------------
  # Connection opening with validated options
  # ---------------------------------------------------------------------------

  @doc """
  Opens a database connection with opinionated defaults and validated options.

  All PRAGMAs are applied on the same connection immediately after opening,
  with no window for another process to observe an unconfigured state.

  ## Options

  #{NimbleOptions.docs(@open_opts_schema)}

  ## Examples

      {:ok, conn} = Xqlite.open("my.db")
      {:ok, conn} = Xqlite.open("my.db", journal_mode: :delete, busy_timeout: 10_000)

  """
  @spec open(String.t(), keyword()) :: {:ok, conn()} | error()
  def open(path, opts \\ []) do
    with {:ok, validated} <- validate_open_opts(opts),
         {:ok, conn} <- XqliteNIF.open(path),
         :ok <- apply_pragmas(conn, validated) do
      {:ok, conn}
    end
  end

  @doc """
  Opens an in-memory database with opinionated defaults and validated options.

  Accepts the same options as `open/2`.
  """
  @spec open_in_memory(keyword()) :: {:ok, conn()} | error()
  def open_in_memory(opts \\ []) do
    with {:ok, validated} <- validate_open_opts(opts),
         {:ok, conn} <- XqliteNIF.open_in_memory(),
         :ok <- apply_pragmas(conn, validated) do
      {:ok, conn}
    end
  end

  defp validate_open_opts(opts) do
    case NimbleOptions.validate(opts, @open_opts_schema) do
      {:ok, _validated} = ok ->
        ok

      {:error, %NimbleOptions.ValidationError{} = err} ->
        {:error, {:invalid_open_option, Exception.message(err)}}
    end
  end

  @pragma_order [
    :busy_timeout,
    :journal_mode,
    :auto_vacuum,
    :foreign_keys,
    :synchronous,
    :cache_size,
    :temp_store,
    :wal_autocheckpoint,
    :mmap_size
  ]

  defp apply_pragmas(conn, validated) do
    Enum.reduce_while(@pragma_order, :ok, fn key, :ok ->
      value = Keyword.fetch!(validated, key)

      case set_pragma_value(conn, key, value) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp set_pragma_value(conn, :busy_timeout, :infinity),
    do: XqliteNIF.set_pragma(conn, "busy_timeout", 2_147_483_647)

  defp set_pragma_value(conn, :busy_timeout, ms),
    do: XqliteNIF.set_pragma(conn, "busy_timeout", ms)

  defp set_pragma_value(conn, :foreign_keys, true),
    do: XqliteNIF.set_pragma(conn, "foreign_keys", :on)

  defp set_pragma_value(conn, :foreign_keys, false),
    do: XqliteNIF.set_pragma(conn, "foreign_keys", :off)

  defp set_pragma_value(conn, :auto_vacuum, :none),
    do: XqliteNIF.set_pragma(conn, "auto_vacuum", 0)

  defp set_pragma_value(conn, :auto_vacuum, :full),
    do: XqliteNIF.set_pragma(conn, "auto_vacuum", 1)

  defp set_pragma_value(conn, :auto_vacuum, :incremental),
    do: XqliteNIF.set_pragma(conn, "auto_vacuum", 2)

  defp set_pragma_value(conn, :temp_store, :default),
    do: XqliteNIF.set_pragma(conn, "temp_store", 0)

  defp set_pragma_value(conn, :temp_store, :file),
    do: XqliteNIF.set_pragma(conn, "temp_store", 1)

  defp set_pragma_value(conn, :temp_store, :memory),
    do: XqliteNIF.set_pragma(conn, "temp_store", 2)

  defp set_pragma_value(conn, key, value),
    do: XqliteNIF.set_pragma(conn, Atom.to_string(key), value)

  # ---------------------------------------------------------------------------
  # STRICT table operations
  # ---------------------------------------------------------------------------

  @doc """
  Checks an existing table for values that would violate STRICT typing rules.

  Returns `{:ok, []}` if the table is clean, or `{:ok, violations}` where each
  violation is a map with `:rowid`, `:column`, `:actual_type`, and `:expected_type`.

  This is a read-only check — it does not modify the table.
  """
  @spec check_strict_violations(conn(), String.t()) ::
          {:ok, [map()]} | error()
  def check_strict_violations(conn, table) when is_binary(table) do
    with {:ok, columns} <- get_typed_columns(conn, table) do
      violation_queries =
        columns
        |> Enum.map(fn {col_name, col_type} ->
          allowed = strict_allowed_types(col_type)
          type_list = Enum.map_join(allowed, ", ", &"'#{&1}'")

          "SELECT rowid, '#{col_name}' AS col, typeof(\"#{col_name}\") AS actual_type, " <>
            "'#{String.upcase(Atom.to_string(col_type))}' AS expected_type " <>
            "FROM \"#{table}\" WHERE typeof(\"#{col_name}\") NOT IN (#{type_list})"
        end)

      case violation_queries do
        [] ->
          {:ok, []}

        queries ->
          union_sql = Enum.join(queries, " UNION ALL ")

          with {:ok, result} <- XqliteNIF.query(conn, union_sql, []) do
            violations =
              Enum.map(result.rows, fn [rowid, col, actual, expected] ->
                %{rowid: rowid, column: col, actual_type: actual, expected_type: expected}
              end)

            {:ok, violations}
          end
      end
    end
  end

  @doc """
  Converts an existing table to STRICT mode via table rebuild.

  This creates a new STRICT table, copies all data, drops the original, and
  renames the new table — all inside a transaction.

  If existing data violates STRICT typing rules, the operation fails with
  `{:error, {:strict_violations, violations}}` where `violations` is a list
  of maps from `check_strict_violations/2`. The original table is left untouched.

  ## Options

  None currently.

  ## Examples

      :ok = Xqlite.enable_strict_table(conn, "users")

  """
  @spec enable_strict_table(conn(), String.t()) :: :ok | {:error, term()}
  def enable_strict_table(conn, table) when is_binary(table) do
    with {:ok, violations} <- check_strict_violations(conn, table),
         :ok <- reject_violations(violations),
         {:ok, create_sql} <- get_create_sql(conn, table) do
      rebuild_as_strict(conn, table, create_sql)
    end
  end

  defp reject_violations([]), do: :ok

  defp reject_violations(violations),
    do: {:error, {:strict_violations, violations}}

  defp get_create_sql(conn, table) do
    sql = "SELECT sql FROM sqlite_master WHERE type='table' AND name=?"

    case XqliteNIF.query(conn, sql, [table]) do
      {:ok, %{rows: [[create_sql]]}} -> {:ok, create_sql}
      {:ok, %{rows: []}} -> {:error, {:no_such_table, table}}
      {:error, _} = err -> err
    end
  end

  defp get_typed_columns(conn, table) do
    case XqliteNIF.query(conn, "PRAGMA table_info(\"#{table}\")", []) do
      {:ok, %{rows: []}} ->
        {:error, {:no_such_table, table}}

      {:ok, %{rows: rows}} ->
        columns =
          rows
          |> Enum.map(fn [_cid, name, type | _rest] ->
            parsed_type = parse_column_type(type)
            {name, parsed_type}
          end)
          |> Enum.reject(fn {_name, type} -> type == :any end)

        {:ok, columns}

      {:error, _} = err ->
        err
    end
  end

  defp parse_column_type(type) when is_binary(type) do
    case String.downcase(type) do
      "integer" -> :integer
      "int" -> :integer
      "real" -> :real
      "text" -> :text
      "blob" -> :blob
      _ -> :any
    end
  end

  defp parse_column_type(_), do: :any

  defp strict_allowed_types(:integer), do: ["integer", "null"]
  defp strict_allowed_types(:real), do: ["real", "integer", "null"]
  defp strict_allowed_types(:text), do: ["text", "integer", "real", "null"]
  defp strict_allowed_types(:blob), do: ["blob", "null"]
  defp strict_allowed_types(:any), do: ["integer", "real", "text", "blob", "null"]

  defp rebuild_as_strict(conn, table, original_create_sql) do
    tmp_table = "#{table}_xqlite_strict_rebuild"

    # The CREATE SQL from sqlite_master uses the original table name
    # (quoted or unquoted). Replace all forms: bare, double-quoted, backtick-quoted.
    strict_sql =
      original_create_sql
      |> String.replace(~r/\)\s*(STRICT)?\s*$/, ") STRICT")
      |> String.replace(
        ~r/\bCREATE TABLE\s+(?:"#{table}"|`#{table}`|#{table})\b/,
        "CREATE TABLE \"#{tmp_table}\""
      )

    with {:ok, index_sqls} <- get_index_sqls(conn, table),
         :ok <- exec(conn, "BEGIN IMMEDIATE"),
         :ok <- exec(conn, strict_sql),
         :ok <- exec(conn, "INSERT INTO \"#{tmp_table}\" SELECT * FROM \"#{table}\""),
         :ok <- exec(conn, "DROP TABLE \"#{table}\""),
         :ok <- exec(conn, "ALTER TABLE \"#{tmp_table}\" RENAME TO \"#{table}\""),
         :ok <- recreate_indexes(conn, index_sqls),
         :ok <- exec(conn, "COMMIT") do
      :ok
    else
      {:error, _} = err ->
        exec(conn, "ROLLBACK")
        err
    end
  end

  defp get_index_sqls(conn, table) do
    sql = "SELECT sql FROM sqlite_master WHERE type='index' AND tbl_name=? AND sql IS NOT NULL"

    case XqliteNIF.query(conn, sql, [table]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [s] -> s end)}
      {:error, _} = err -> err
    end
  end

  defp recreate_indexes(_conn, []), do: :ok

  defp recreate_indexes(conn, [sql | rest]) do
    case exec(conn, sql) do
      :ok -> recreate_indexes(conn, rest)
      {:error, _} = err -> err
    end
  end

  defp exec(conn, sql) do
    case XqliteNIF.execute(conn, sql) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Enables strict mode only for the lifetime of the given database connection.

  In strict mode, SQLite is less forgiving. For example, an attempt to insert
  a string into an INTEGER column of a `STRICT` table will result in an error,
  whereas in normal mode it might be coerced or stored as text.
  This setting only affects tables declared with the `STRICT` keyword.

  See: [STRICT Tables](https://www.sqlite.org/stricttables.html)
  """
  @spec enable_strict_mode(conn()) :: {:ok, term()} | error()
  def enable_strict_mode(conn) do
    XqliteNIF.set_pragma(conn, "strict", :on)
  end

  @doc """
  Disables strict mode only for the lifetime given database connection (SQLite's default).

  See `enable_strict_mode/1` for details.
  """
  @spec disable_strict_mode(conn()) :: {:ok, term()} | error()
  def disable_strict_mode(conn) do
    XqliteNIF.set_pragma(conn, "strict", :off)
  end

  @doc """
  Enables foreign key constraint enforcement for the given database connection.

  By default, SQLite parses foreign key constraints but does not enforce them.
  This function turns on enforcement.

  See: [SQLite PRAGMA foreign_keys](https://www.sqlite.org/pragma.html#pragma_foreign_keys)
  """
  @spec enable_foreign_key_enforcement(conn()) :: {:ok, term()} | error()
  def enable_foreign_key_enforcement(conn) do
    XqliteNIF.set_pragma(conn, "foreign_keys", :on)
  end

  @doc """
  Disables foreign key constraint enforcement for the given database connection (default behavior).

  See `enable_foreign_key_enforcement/1` for details.
  """
  @spec disable_foreign_key_enforcement(conn()) :: {:ok, term()} | error()
  def disable_foreign_key_enforcement(conn) do
    XqliteNIF.set_pragma(conn, "foreign_keys", :off)
  end

  @doc """
  Executes a SQL query and returns a `%Xqlite.Result{}` struct.

  For SELECT queries, `num_rows` is the count of returned rows and `changes`
  is 0. For DML (INSERT/UPDATE/DELETE), `num_rows` is 0 (no result rows)
  and `changes` is the number of affected rows.

  Uses `XqliteNIF.query_with_changes/3` which captures the affected row count
  atomically inside the connection lock. For zero-overhead access without the
  changes field, use `XqliteNIF.query/3` directly.
  """
  @spec query(conn(), String.t(), list() | keyword()) ::
          {:ok, Xqlite.Result.t()} | error()
  def query(conn, sql, params \\ []) do
    with {:ok, map} <- XqliteNIF.query_with_changes(conn, sql, params) do
      {:ok, Xqlite.Result.from_map(map)}
    end
  end

  @doc """
  Executes a non-returning SQL statement and returns a `%Xqlite.Result{}`.

  For DML statements, `changes` contains the number of affected rows.
  """
  @spec execute(conn(), String.t(), list() | keyword()) ::
          {:ok, Xqlite.Result.t()} | error()
  def execute(conn, sql, params \\ []) do
    with {:ok, affected} <- XqliteNIF.execute(conn, sql, params) do
      {:ok,
       %Xqlite.Result{
         columns: [],
         rows: [],
         num_rows: 0,
         changes: affected
       }}
    end
  end

  @doc """
  Creates a stream that executes a query and emits rows as string-keyed maps.

  This provides a high-level, idiomatic Elixir `Stream` for processing large
  result sets without loading them all into memory at once. Rows are fetched
  from the database in batches as the stream is consumed.

  ## Options

    * `:batch_size` (integer, default: `500`) - The maximum number of rows
      to fetch from the database in a single batch.
    * `:type_extensions` (list of modules, default: `[]`) - A list of modules
      implementing the `Xqlite.TypeExtension` behaviour. Parameters are encoded
      before binding, and result values are decoded as rows are fetched.
      Extensions are applied in list order; the first match wins.

  ## Examples

      iex> {:ok, conn} = XqliteNIF.open_in_memory()
      iex> XqliteNIF.execute_batch(conn, "CREATE TABLE users(id, name); INSERT INTO users VALUES (1, 'Alice'), (2, 'Bob');")
      :ok
      iex> Xqlite.stream(conn, "SELECT id, name FROM users;") |> Enum.to_list()
      [%{"id" => 1, "name" => "Alice"}, %{"id" => 2, "name" => "Bob"}]

  Returns an `Enumerable.t()` on success or `{:error, reason}` on setup failure.
  Callers must pattern-match the result before piping — this is intentional,
  as returning a stream that silently errors on first consume would hide
  setup failures (e.g., invalid SQL, closed connection).

  Errors that occur *during* stream consumption (e.g., database connection lost
  mid-stream) will be logged and will cause the stream to halt.
  """
  @spec stream(conn(), String.t(), list() | keyword(), keyword()) ::
          Enumerable.t() | error()
  def stream(conn, sql, params \\ [], opts \\ []) do
    type_extensions = Keyword.get(opts, :type_extensions, [])
    encoded_params = Xqlite.TypeExtension.encode_params(params, type_extensions)

    start_fun = &Xqlite.StreamResourceCallbacks.start_fun/1
    next_fun = &Xqlite.StreamResourceCallbacks.next_fun/1
    after_fun = &Xqlite.StreamResourceCallbacks.after_fun/1

    case start_fun.({conn, sql, encoded_params, opts}) do
      {:ok, acc} ->
        Stream.resource(fn -> acc end, next_fun, after_fun)

      {:error, _reason} = error ->
        error
    end
  end
end
