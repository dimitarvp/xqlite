defmodule Xqlite do
  @moduledoc ~S"""
  This is the central module of this library. All SQLite operations can be performed from here.
  Note that they delegate to other modules which you can also use directly.
  """

  import Xqlite.Telemetry, only: [emit: 3, span_with_stop_metadata: 3]

  @type conn :: reference()
  @type stmt :: reference()

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

  @type storage_class :: :integer | :real | :text | :blob | nil

  @type constraint_details :: %{
          message: String.t(),
          table: String.t() | nil,
          columns: [String.t()],
          index_name: String.t() | nil,
          constraint_name: String.t() | nil,
          source_type: storage_class(),
          target_type: storage_class()
        }

  @type error_reason ::
          :connection_closed
          | :execute_returned_results
          | :multiple_statements
          | :null_byte_in_string
          | :operation_cancelled
          | :statement_finalized
          | :unsupported_atom
          | {:authorization_denied, String.t()}
          | {:cannot_convert_to_sqlite_value, String.t(), String.t()}
          | {:cannot_execute, String.t()}
          | {:cannot_execute_pragma, String.t(), String.t()}
          | {:cannot_open_database, String.t(), integer(), String.t()}
          | {:constraint_violation, constraint_kind(), constraint_details()}
          | {:database_busy_or_locked, String.t()}
          | {:expected_keyword_list, String.t()}
          | {:expected_keyword_tuple, String.t()}
          | {:expected_list, String.t()}
          | {:from_sql_conversion_failure, non_neg_integer(), atom(), String.t()}
          | {:index_exists, String.t()}
          | {:integral_value_out_of_range, non_neg_integer(), integer()}
          | {:internal_encoding_error, String.t()}
          | {:invalid_authorizer_action, atom()}
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
    start_md = %{path: path, mode: :file}

    span_with_stop_metadata [:xqlite, :open], start_md do
      result =
        with {:ok, validated} <- validate_open_opts(opts),
             {:ok, conn} <- XqliteNIF.open(path),
             :ok <- apply_pragmas(conn, validated) do
          {:ok, conn}
        end

      {result, open_stop_metadata(start_md, result)}
    end
  end

  @doc """
  Opens an in-memory database with opinionated defaults and validated options.

  Accepts the same options as `open/2`.
  """
  @spec open_in_memory(keyword()) :: {:ok, conn()} | error()
  def open_in_memory(opts \\ []) do
    start_md = %{path: ":memory:", mode: :memory}

    span_with_stop_metadata [:xqlite, :open], start_md do
      result =
        with {:ok, validated} <- validate_open_opts(opts),
             {:ok, conn} <- XqliteNIF.open_in_memory(":memory:"),
             :ok <- apply_pragmas(conn, validated) do
          {:ok, conn}
        end

      {result, open_stop_metadata(start_md, result)}
    end
  end

  @doc """
  Opens a read-only connection to an in-memory SQLite database.

  Useful for connecting to a named shared-cache in-memory database opened
  read-write by another connection — pass its URI as `uri`, or omit it to
  open a private (empty) read-only `:memory:` database.

  No PRAGMAs are applied; read-only databases can't persist most settings.
  """
  @spec open_in_memory_readonly(String.t()) :: {:ok, conn()} | error()
  def open_in_memory_readonly(uri \\ ":memory:") when is_binary(uri) do
    start_md = %{path: uri, mode: :memory_readonly}

    span_with_stop_metadata [:xqlite, :open], start_md do
      result = XqliteNIF.open_in_memory_readonly(uri)
      {result, open_stop_metadata(start_md, result)}
    end
  end

  defp open_stop_metadata(start_md, {:ok, _conn}),
    do: Map.merge(start_md, %{result_class: :ok, error_reason: nil})

  defp open_stop_metadata(start_md, {:error, reason}),
    do: Map.merge(start_md, %{result_class: :error, error_reason: reason})

  @doc """
  Opens a read-only connection to an existing database file.

  Fails with a structured error if the file does not exist — read-only
  opens never create. No PRAGMAs are applied; read-only databases
  can't persist most settings. Writes fail with
  `{:error, {:read_only_database, message}}`.

  Emits `[:xqlite, :open, :start | :stop]` telemetry with mode
  `:readonly`.
  """
  @spec open_readonly(String.t()) :: {:ok, conn()} | error()
  def open_readonly(path) when is_binary(path) do
    start_md = %{path: path, mode: :readonly}

    span_with_stop_metadata [:xqlite, :open], start_md do
      result = XqliteNIF.open_readonly(path)
      {result, open_stop_metadata(start_md, result)}
    end
  end

  @doc """
  Opens a connection to a private temporary on-disk database.

  SQLite backs it with an anonymous file it removes on close; the
  database has no path — `db_path/1` returns `{:ok, nil}`.

  Emits `[:xqlite, :open, :start | :stop]` telemetry with mode
  `:temp` and `path: nil`.
  """
  @spec open_temporary() :: {:ok, conn()} | error()
  def open_temporary do
    start_md = %{path: nil, mode: :temp}

    span_with_stop_metadata [:xqlite, :open], start_md do
      result = XqliteNIF.open_temporary()
      {result, open_stop_metadata(start_md, result)}
    end
  end

  @doc """
  Closes the connection, releasing the underlying SQLite handle.

  Idempotent: closing an already-closed connection returns `:ok`. Any
  operation on a closed connection returns
  `{:error, :connection_closed}`.

  Finalize outstanding prepared statements before closing — a
  connection closed while statements are outstanding keeps the
  underlying SQLite handle alive until the owning process exits (see
  `prepare/2`).

  Emits `[:xqlite, :close, :start | :stop]` telemetry.
  """
  @spec close(conn()) :: :ok
  def close(conn) do
    start_md = %{conn: conn, path: current_db_path(conn)}

    span_with_stop_metadata [:xqlite, :close], start_md do
      {XqliteNIF.close(conn), start_md}
    end
  end

  @doc """
  Returns the filesystem path of the connection's main database.

  `{:ok, path}` for file-backed databases, `{:ok, nil}` for in-memory
  and temporary databases (they have no backing file). No telemetry
  is emitted.
  """
  @spec db_path(conn()) :: {:ok, String.t() | nil} | error()
  def db_path(conn), do: XqliteNIF.db_path(conn)

  defp current_db_path(conn) do
    case XqliteNIF.db_path(conn) do
      {:ok, path} -> path
      {:error, _} -> nil
    end
  end

  defp validate_open_opts(opts) do
    allowed = allowed_open_opt_keys()

    case Enum.find(opts, fn {k, _v} -> k not in allowed end) do
      {unknown_key, _v} ->
        {:error,
         {:invalid_open_option,
          %{key: unknown_key, reason: :unknown_key, allowed: allowed, value: nil}}}

      nil ->
        case NimbleOptions.validate(opts, @open_opts_schema) do
          {:ok, _validated} = ok ->
            ok

          {:error, %NimbleOptions.ValidationError{} = err} ->
            {:error,
             {:invalid_open_option,
              %{
                key: err.key,
                reason: :invalid_value,
                value: err.value,
                message: Exception.message(err)
              }}}
        end
    end
  end

  @spec allowed_open_opt_keys() :: [atom()]
  defp allowed_open_opt_keys do
    Keyword.keys(@open_opts_schema.schema)
  end

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
         {:ok, create_sql} <- table_create_sql(conn, table) do
      rebuild_as_strict(conn, table, create_sql)
    end
  end

  defp reject_violations([]), do: :ok

  defp reject_violations(violations), do: {:error, {:strict_violations, violations}}

  defp table_create_sql(conn, table) do
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

  ## Options

    * `:type_extensions` — a list of `Xqlite.TypeExtension` modules.
      Parameters are encoded through the chain before binding and result
      rows are decoded through it after fetching (first match wins, same
      semantics as `stream/4`). Default: `[]` (values pass through
      untouched).
  """
  @spec query(conn(), String.t(), list() | keyword(), keyword()) ::
          {:ok, Xqlite.Result.t()} | error()
  def query(conn, sql, params \\ [], opts \\ []) do
    extensions = Keyword.get(opts, :type_extensions, [])
    bound_params = Xqlite.TypeExtension.encode_params(params, extensions)

    start_md = %{
      conn: conn,
      sql: sql,
      params_count: params_count(bound_params),
      cancellable?: false
    }

    span_with_stop_metadata [:xqlite, :query], start_md do
      case XqliteNIF.query_with_changes(conn, sql, bound_params) do
        {:ok, map} ->
          result =
            map
            |> Xqlite.Result.from_map()
            |> decode_result_rows(extensions)

          {{:ok, result},
           Map.merge(start_md, %{
             result_class: :ok,
             error_reason: nil,
             num_rows: result.num_rows,
             changes: result.changes
           })}

        {:error, reason} = err ->
          {err,
           Map.merge(start_md, %{
             result_class: :error,
             error_reason: reason,
             num_rows: nil,
             changes: nil
           })}
      end
    end
  end

  @doc """
  Executes a non-returning SQL statement and returns a `%Xqlite.Result{}`.

  For DML statements, `changes` contains the number of affected rows.

  ## Options

    * `:type_extensions` — a list of `Xqlite.TypeExtension` modules;
      parameters are encoded through the chain before binding (there are
      no result rows to decode). Default: `[]`.
  """
  @spec execute(conn(), String.t(), list() | keyword(), keyword()) ::
          {:ok, Xqlite.Result.t()} | error()
  def execute(conn, sql, params \\ [], opts \\ []) do
    extensions = Keyword.get(opts, :type_extensions, [])
    bound_params = Xqlite.TypeExtension.encode_params(params, extensions)

    start_md = %{
      conn: conn,
      sql: sql,
      params_count: params_count(bound_params),
      cancellable?: false
    }

    span_with_stop_metadata [:xqlite, :execute], start_md do
      case XqliteNIF.execute(conn, sql, bound_params) do
        {:ok, affected} ->
          result = %Xqlite.Result{
            columns: [],
            rows: [],
            num_rows: 0,
            changes: affected
          }

          {{:ok, result},
           Map.merge(start_md, %{
             result_class: :ok,
             error_reason: nil,
             affected_rows: affected
           })}

        {:error, reason} = err ->
          {err,
           Map.merge(start_md, %{
             result_class: :error,
             error_reason: reason,
             affected_rows: nil
           })}
      end
    end
  end

  defp decode_result_rows(%Xqlite.Result{} = result, []), do: result

  defp decode_result_rows(%Xqlite.Result{rows: rows} = result, extensions) do
    %{result | rows: Xqlite.TypeExtension.decode_rows(rows, extensions)}
  end

  @doc """
  Executes a SQL batch (multiple statements separated by semicolons).

  Wraps `XqliteNIF.execute_batch/2` and emits `[:xqlite, :execute_batch, :*]`
  telemetry. No parameter binding inside the batch.
  """
  @spec execute_batch(conn(), String.t()) :: :ok | error()
  def execute_batch(conn, sql_batch) when is_binary(sql_batch) do
    start_md = %{
      conn: conn,
      sql_batch_size_bytes: byte_size(sql_batch),
      cancellable?: false
    }

    span_with_stop_metadata [:xqlite, :execute_batch], start_md do
      case XqliteNIF.execute_batch(conn, sql_batch) do
        :ok = ok ->
          {ok, Map.merge(start_md, %{result_class: :ok, error_reason: nil})}

        {:error, reason} = err ->
          {err, Map.merge(start_md, %{result_class: :error, error_reason: reason})}
      end
    end
  end

  @doc """
  Runs a SQL statement and returns an `%Xqlite.ExplainAnalyze{}` report.

  The statement is executed in full (rows are fetched and discarded). The
  returned struct combines the static `EXPLAIN QUERY PLAN` tree with
  runtime counters from `sqlite3_stmt_scanstatus_v2` / `sqlite3_stmt_status`
  and a wall-clock measurement around the execution. See
  `Xqlite.ExplainAnalyze` for the field layout and how to interpret it.

  ## Examples

      iex> {:ok, conn} = Xqlite.open_in_memory()
      iex> XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t(name) VALUES ('a'), ('b');")
      :ok
      iex> {:ok, report} = Xqlite.explain_analyze(conn, "SELECT name FROM t WHERE name = ?", ["b"])
      iex> match?(%Xqlite.ExplainAnalyze{}, report)
      true
  """
  @spec explain_analyze(conn(), String.t(), list() | keyword()) ::
          {:ok, Xqlite.ExplainAnalyze.t()} | error()
  def explain_analyze(conn, sql, params \\ []) do
    start_md = %{conn: conn, sql: sql, params_count: params_count(params)}

    span_with_stop_metadata [:xqlite, :explain_analyze], start_md do
      case XqliteNIF.explain_analyze(conn, sql, params) do
        {:ok, map} ->
          report = Xqlite.ExplainAnalyze.from_map(map)

          {{:ok, report},
           Map.merge(start_md, %{
             result_class: :ok,
             error_reason: nil,
             wall_time_ns: report.wall_time_ns,
             rows_produced: report.rows_produced,
             scan_count: length(report.scans)
           })}

        {:error, reason} = err ->
          {err,
           Map.merge(start_md, %{
             result_class: :error,
             error_reason: reason,
             wall_time_ns: nil,
             rows_produced: nil,
             scan_count: nil
           })}
      end
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

      iex> {:ok, conn} = Xqlite.open_in_memory()
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
    batch_size = Keyword.get(opts, :batch_size, 500)

    start_md = %{
      conn: conn,
      sql: sql,
      batch_size: batch_size,
      type_extensions_count: length(type_extensions)
    }

    start_fun = &Xqlite.StreamResourceCallbacks.start_fun/1
    next_fun = &Xqlite.StreamResourceCallbacks.next_fun/1
    after_fun = &Xqlite.StreamResourceCallbacks.after_fun/1

    span_with_stop_metadata [:xqlite, :stream, :open], start_md do
      case start_fun.({conn, sql, encoded_params, opts}) do
        {:ok, acc} ->
          {Stream.resource(fn -> acc end, next_fun, after_fun),
           Map.merge(start_md, %{result_class: :ok, error_reason: nil})}

        {:error, reason} = error ->
          {error, Map.merge(start_md, %{result_class: :error, error_reason: reason})}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Manual statement lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Prepares a manually managed statement.

  The lifecycle is `prepare/2` → (`bind/2` → `step/1` / `multi_step/2` →
  `reset/1`)* → `finalize/1`. Preparing once and rebinding in a loop skips
  SQL parsing/planning on every iteration — the reason prepared statements
  exist. For one-shot calls, `query/3` and `execute/3` remain simpler.

  Exactly ONE statement is compiled: whitespace/comment-only SQL returns
  `{:error, {:cannot_execute, reason}}` and trailing statements after the
  first return `{:error, :multiple_statements}` — nothing is silently
  dropped.

  Finalize statements before closing their connection: a connection closed
  while statements are outstanding keeps the underlying SQLite handle alive
  until the process exits (abandoned statements are still finalized by
  garbage collection, and every operation on them after an explicit
  `Xqlite.close/1` returns `{:error, :connection_closed}`).

  Steps are not cancellable; for cancellation use `query_cancellable/4` and
  friends. No telemetry is emitted for statement-lifecycle operations.

  ## Examples

      iex> {:ok, conn} = Xqlite.open_in_memory()
      iex> {:ok, 0} = XqliteNIF.execute(conn, "CREATE TABLE pairs (a INTEGER, b TEXT)", [])
      iex> {:ok, stmt} = Xqlite.prepare(conn, "INSERT INTO pairs (a, b) VALUES (?1, ?2)")
      iex> for {a, b} <- [{1, "one"}, {2, "two"}] do
      ...>   :ok = Xqlite.bind(stmt, [a, b])
      ...>   :done = Xqlite.step(stmt)
      ...>   :ok = Xqlite.reset(stmt)
      ...> end
      [:ok, :ok]
      iex> Xqlite.finalize(stmt)
      :ok
      iex> {:ok, query} = Xqlite.prepare(conn, "SELECT a, b FROM pairs ORDER BY a")
      iex> Xqlite.step(query)
      {:row, [1, "one"]}
      iex> Xqlite.multi_step(query, 10)
      {:ok, %{rows: [[2, "two"]], done: true}}
      iex> Xqlite.column_names(query)
      {:ok, ["a", "b"]}
      iex> Xqlite.finalize(query)
      :ok
  """
  @spec prepare(conn(), String.t()) :: {:ok, stmt()} | error()
  def prepare(conn, sql) when is_binary(sql) do
    XqliteNIF.stmt_prepare(conn, sql)
  end

  @doc """
  Binds parameters to a prepared statement.

  Accepts a plain list for positional placeholders (`?1`, `?2`, …; the
  count must match, otherwise `{:error, {:invalid_parameter_count,
  %{provided: _, expected: _}}}`) or a keyword list for named placeholders.
  Once stepping has started, call `reset/1` before rebinding — SQLite
  rejects mid-run rebinds.
  """
  @spec bind(stmt(), list()) :: :ok | error()
  def bind(stmt, params) when is_list(params) do
    XqliteNIF.stmt_bind(stmt, params)
  end

  @doc """
  Advances a prepared statement one row.

  Returns `{:row, values}`, `:done` when exhausted, or `{:error, reason}`.
  Stepping past `:done` without a `reset/1` returns whatever SQLite reports
  for the re-step (a fresh automatic rerun on modern SQLite).
  """
  @spec step(stmt()) :: {:row, [sqlite_value()]} | :done | error()
  def step(stmt), do: XqliteNIF.stmt_step(stmt)

  @doc """
  Advances a prepared statement up to `batch_size` rows.

  Returns `{:ok, %{rows: rows, done: done?}}` — `done: true` means the
  statement exhausted within this batch (fewer than `batch_size` rows may
  be returned in that case) — or `{:error, reason}`.

  Calling again after `done: true` without a `reset/1` RERUNS the query
  from the top (v2-prepared statements auto-reset when stepped past done —
  SQLite semantics, same as `step/1`).
  """
  @spec multi_step(stmt(), pos_integer()) ::
          {:ok, %{rows: [[sqlite_value()]], done: boolean()}} | error()
  def multi_step(stmt, batch_size) when is_integer(batch_size) do
    XqliteNIF.stmt_multi_step(stmt, batch_size)
  end

  @doc """
  Like `multi_step/2` but cancellable.

  Accepts a single cancel token or a list (OR-semantics — any signalled
  token aborts with `{:error, :operation_cancelled}`). Cancellation rides
  the connection's progress handler, exactly like `query_cancellable/4`.
  After a cancellation, `reset/1` the statement before stepping it again.
  """
  @spec multi_step_cancellable(stmt(), pos_integer(), reference() | [reference()]) ::
          {:ok, %{rows: [[sqlite_value()]], done: boolean()}} | error()
  def multi_step_cancellable(stmt, batch_size, token_or_tokens) when is_integer(batch_size) do
    XqliteNIF.stmt_multi_step_cancellable(stmt, batch_size, List.wrap(token_or_tokens))
  end

  @doc """
  Resets a prepared statement so it can be stepped from the start again.

  Bindings are preserved (SQLite semantics); use `clear_bindings/1` to drop
  them to NULL. Always returns `:ok` for a live statement — `sqlite3_reset`'s
  return code echoes the most recent step error, not the reset itself.
  """
  @spec reset(stmt()) :: :ok | error()
  def reset(stmt), do: XqliteNIF.stmt_reset(stmt)

  @doc """
  Clears all parameter bindings on a prepared statement back to NULL.
  """
  @spec clear_bindings(stmt()) :: :ok | error()
  def clear_bindings(stmt), do: XqliteNIF.stmt_clear_bindings(stmt)

  @doc """
  Returns the result column names of a prepared statement.

  Live statements reflect SQLite's auto-reprepare after schema changes
  (e.g. `SELECT *` re-expansion); finalized statements answer with the
  prepare-time snapshot.
  """
  @spec column_names(stmt()) :: {:ok, [String.t()]} | error()
  def column_names(stmt), do: XqliteNIF.stmt_column_names(stmt)

  @doc """
  Finalizes a prepared statement, releasing its SQLite resources.

  Idempotent — repeated finalization returns `:ok`. Prefer explicit
  finalization over relying on garbage collection, and finalize before
  closing the owning connection (see `prepare/2`).
  """
  @spec finalize(stmt()) :: :ok | error()
  def finalize(stmt), do: XqliteNIF.stmt_finalize(stmt)

  # ---------------------------------------------------------------------------
  # Backup / serialize / deserialize
  # ---------------------------------------------------------------------------

  @doc """
  Serializes a database to a contiguous binary.

  Returns a binary snapshot of the entire database — an atomic, point-in-time
  copy. No pages are locked during serialization.

  `schema` identifies which attached database to serialize. Defaults to
  `"main"`. Use `"temp"` for the temp database or the name of an attached
  database.
  """
  @spec serialize(conn(), String.t()) :: {:ok, binary()} | error()
  def serialize(conn, schema \\ "main") when is_binary(schema) do
    start_md = %{conn: conn, schema: schema}

    span_with_stop_metadata [:xqlite, :serialize], start_md do
      case XqliteNIF.serialize(conn, schema) do
        {:ok, bin} = ok ->
          {ok,
           Map.merge(start_md, %{
             result_class: :ok,
             error_reason: nil,
             byte_size: byte_size(bin)
           })}

        {:error, reason} = err ->
          {err,
           Map.merge(start_md, %{
             result_class: :error,
             error_reason: reason,
             byte_size: nil
           })}
      end
    end
  end

  @doc """
  Deserializes a binary into a database, replacing its current contents.

  The binary must be a valid SQLite database image (as produced by
  `serialize/2`). After deserialization the connection operates on the new
  database entirely in memory.

  `schema` identifies which attached database to replace (default `"main"`).
  `read_only` marks the deserialized image as read-only (default `false`).
  """
  @spec deserialize(conn(), binary(), String.t(), boolean()) :: :ok | error()
  def deserialize(conn, data, schema \\ "main", read_only \\ false)
      when is_binary(data) and is_binary(schema) and is_boolean(read_only) do
    start_md = %{
      conn: conn,
      schema: schema,
      read_only?: read_only,
      byte_size: byte_size(data)
    }

    span_with_stop_metadata [:xqlite, :deserialize], start_md do
      case XqliteNIF.deserialize(conn, schema, data, read_only) do
        :ok = ok ->
          {ok, Map.merge(start_md, %{result_class: :ok, error_reason: nil})}

        {:error, reason} = err ->
          {err, Map.merge(start_md, %{result_class: :error, error_reason: reason})}
      end
    end
  end

  @doc """
  Backs up a schema to a file.

  Copies the named schema (default `"main"`) to the file at `dest_path`. The
  destination is created or overwritten. The source remains readable during
  the backup.
  """
  @spec backup(conn(), String.t(), String.t()) :: :ok | error()
  def backup(conn, dest_path, schema \\ "main")
      when is_binary(dest_path) and is_binary(schema) do
    start_md = %{conn: conn, schema: schema, dest_path: dest_path}

    span_with_stop_metadata [:xqlite, :backup], start_md do
      case XqliteNIF.backup(conn, schema, dest_path) do
        :ok = ok ->
          byte_size_after =
            case File.stat(dest_path) do
              {:ok, %File.Stat{size: s}} -> s
              _ -> nil
            end

          {ok,
           Map.merge(start_md, %{
             result_class: :ok,
             error_reason: nil,
             byte_size: byte_size_after
           })}

        {:error, reason} = err ->
          {err,
           Map.merge(start_md, %{
             result_class: :error,
             error_reason: reason,
             byte_size: nil
           })}
      end
    end
  end

  @doc """
  Restores a schema from a file.

  Replaces the named schema (default `"main"`) with the contents of the file
  at `src_path`. Existing data in that schema is overwritten.
  """
  @spec restore(conn(), String.t(), String.t()) :: :ok | error()
  def restore(conn, src_path, schema \\ "main")
      when is_binary(src_path) and is_binary(schema) do
    start_md = %{conn: conn, schema: schema, src_path: src_path}

    span_with_stop_metadata [:xqlite, :restore], start_md do
      case XqliteNIF.restore(conn, schema, src_path) do
        :ok = ok ->
          {ok, Map.merge(start_md, %{result_class: :ok, error_reason: nil})}

        {:error, reason} = err ->
          {err, Map.merge(start_md, %{result_class: :error, error_reason: reason})}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Extension loading
  # ---------------------------------------------------------------------------

  @doc """
  Loads a SQLite extension from the shared library at `path`.

  `entry_point` is the extension's init function name; pass `nil` (default)
  to let SQLite auto-detect. Extension loading must be enabled first via
  `enable_load_extension/2`.
  """
  @spec load_extension(conn(), String.t(), String.t() | nil) :: :ok | error()
  def load_extension(conn, path, entry_point \\ nil)
      when is_binary(path) and (is_binary(entry_point) or is_nil(entry_point)) do
    start_md = %{conn: conn, path: path, entry_point: entry_point}

    span_with_stop_metadata [:xqlite, :extension, :load], start_md do
      case XqliteNIF.load_extension(conn, path, entry_point) do
        :ok = ok ->
          {ok, Map.merge(start_md, %{result_class: :ok, error_reason: nil})}

        {:error, reason} = err ->
          {err, Map.merge(start_md, %{result_class: :error, error_reason: reason})}
      end
    end
  end

  @doc """
  Enables or disables extension loading on the connection.

  Defaults to `true`. Wraps `XqliteNIF.enable_load_extension/2` and emits
  `[:xqlite, :extension, :enable]` telemetry.
  """
  @spec enable_load_extension(conn(), boolean()) :: :ok | error()
  def enable_load_extension(conn, enabled \\ true) when is_boolean(enabled) do
    case XqliteNIF.enable_load_extension(conn, enabled) do
      :ok = ok ->
        emit(
          [:xqlite, :extension, :enable],
          %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
          %{conn: conn, enabled: enabled}
        )

        ok

      err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # WAL checkpoint
  # ---------------------------------------------------------------------------

  @doc """
  Performs a WAL checkpoint on the connection.

  `mode` is one of `:passive` (default), `:full`, `:restart`, or `:truncate`.
  `schema` is the attached-database name (default `"main"`).

  Returns `{:ok, %{log_pages, checkpointed_pages, busy?}}` on success.
  """
  @spec wal_checkpoint(conn(), atom(), String.t()) :: {:ok, map()} | error()
  def wal_checkpoint(conn, mode \\ :passive, schema \\ "main")
      when mode in [:passive, :full, :restart, :truncate] and is_binary(schema) do
    start_md = %{conn: conn, mode: mode, schema: schema}

    span_with_stop_metadata [:xqlite, :wal_checkpoint], start_md do
      case XqliteNIF.wal_checkpoint(conn, mode, schema) do
        {:ok, result} = ok ->
          {ok,
           Map.merge(start_md, %{
             result_class: :ok,
             error_reason: nil,
             log_pages: result.log_pages,
             checkpointed_pages: result.checkpointed_pages,
             busy?: result.busy
           })}

        {:error, reason} = err ->
          {err, Map.merge(start_md, %{result_class: :error, error_reason: reason})}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Pragma get / set
  # ---------------------------------------------------------------------------

  @doc """
  Reads a PRAGMA value from the connection.

  Wraps `XqliteNIF.get_pragma/2` and emits `[:xqlite, :pragma, :get]`.
  """
  @spec get_pragma(conn(), String.t() | atom()) :: {:ok, term()} | error()
  def get_pragma(conn, name) do
    name_str = to_string(name)

    case XqliteNIF.get_pragma(conn, name_str) do
      {:ok, _value} = ok ->
        emit(
          [:xqlite, :pragma, :get],
          %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
          %{conn: conn, name: name_str}
        )

        ok

      err ->
        err
    end
  end

  @doc """
  Sets a PRAGMA value on the connection.

  Wraps `XqliteNIF.set_pragma/3` and emits `[:xqlite, :pragma, :set]`.
  """
  @spec set_pragma(conn(), String.t() | atom(), term()) :: {:ok, term()} | error()
  def set_pragma(conn, name, value) do
    name_str = to_string(name)

    case XqliteNIF.set_pragma(conn, name_str, value) do
      {:ok, _new_value} = ok ->
        emit(
          [:xqlite, :pragma, :set],
          %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
          %{conn: conn, name: name_str, value: value}
        )

        ok

      err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Busy handler / busy timeout
  # ---------------------------------------------------------------------------

  @doc """
  Sets the busy retry POLICY on the connection.

  When SQLite encounters a locked database (another writer holds
  `RESERVED+`) the policy decides whether to retry or surface
  `SQLITE_BUSY` to the caller. The policy is single-slot by design — a
  retry decision cannot compose. To OBSERVE contention (telemetry,
  structured logging, adaptive backoff), register any number of
  subscribers with `register_busy_observer/2`; the two halves are
  independent.

  ## Options

    * `:max_retries` (non-negative integer, default `50`) — stop after this
      many retries and let the caller see `SQLITE_BUSY`.
    * `:max_elapsed_ms` (non-negative integer, default `5_000`) — absolute
      time ceiling in milliseconds from the busy slot's first installation.
    * `:sleep_ms` (non-negative integer, default `10`) — milliseconds to
      sleep between retries. Zero disables the pause (tight spin; rarely
      what you want).

  Replacing an existing policy is atomic; observers are unaffected.

  > #### Note — a busy sleep pins the connection {: .info}
  >
  > `sleep_ms` sleeps on the thread holding the connection mutex, so while
  > a retry waits, that connection is pinned: other operations on the
  > *same* connection block until the sleep-and-retry resolves. Different
  > connections are unaffected. Budget `sleep_ms` × `max_retries`
  > accordingly.

  > #### Warning — PRAGMA busy_timeout silently replaces the callback {: .warning}
  >
  > Running `PRAGMA busy_timeout = N` (or `XqliteNIF.set_pragma(conn,
  > "busy_timeout", ms)`) replaces our C callback with SQLite's built-in
  > sleep-and-retry one: the policy stops applying AND every busy
  > observer silently stops receiving `{:xqlite_busy, …}` messages. No
  > memory is leaked — the internal state is reclaimed on the next slot
  > mutation or connection close. To switch to plain-timeout semantics
  > without surprises, use `busy_timeout/2`.
  """
  @spec set_busy_policy(conn(), keyword()) :: :ok | error()
  def set_busy_policy(conn, opts \\ []) when is_list(opts) do
    max_retries = Keyword.get(opts, :max_retries, 50)
    max_elapsed_ms = Keyword.get(opts, :max_elapsed_ms, 5_000)
    sleep_ms = Keyword.get(opts, :sleep_ms, 10)
    XqliteNIF.set_busy_policy(conn, max_retries, max_elapsed_ms, sleep_ms)
  end

  @doc """
  Removes the busy retry policy from the connection.

  Observers registered with `register_busy_observer/2` keep receiving
  `{:xqlite_busy, …}` messages; without a policy SQLite surfaces
  `SQLITE_BUSY` immediately after they fire. Safe to call when no
  policy is installed.
  """
  @spec remove_busy_policy(conn()) :: :ok | error()
  def remove_busy_policy(conn), do: XqliteNIF.remove_busy_policy(conn)

  @doc """
  Registers a busy-contention observer on the connection.

  Every `SQLITE_BUSY` callback invocation sends

      {:xqlite_busy, retries_so_far, elapsed_ms}

  to `pid`. Any number of observers can be registered — each gets its
  own handle for `unregister_busy_observer/2` — and they fire whether
  or not a retry policy is installed. `Xqlite.Telemetry.bridge/2` can
  subscribe with `hooks: [:busy]` to re-emit deliveries as
  `[:xqlite, :hook, :busy]` telemetry.
  """
  @spec register_busy_observer(conn(), pid()) :: {:ok, non_neg_integer()} | error()
  def register_busy_observer(conn, pid) when is_pid(pid) do
    XqliteNIF.register_busy_observer(conn, pid)
  end

  @doc """
  Unregisters a busy-contention observer by handle.

  Idempotent — an unknown or already-removed handle is a no-op.
  """
  @spec unregister_busy_observer(conn(), non_neg_integer()) :: :ok | error()
  def unregister_busy_observer(conn, handle) when is_integer(handle) and handle >= 0 do
    XqliteNIF.unregister_busy_observer(conn, handle)
  end

  @doc """
  Sets a plain `sqlite3_busy_timeout` on the connection, replacing the
  xqlite busy slot cleanly.

  Calls `remove_busy_policy/1` first, then sets
  `PRAGMA busy_timeout = ms`. Note that the raw PRAGMA replaces the
  whole C callback: any registered busy observers stop receiving
  `{:xqlite_busy, …}` messages too — unregister them first if you want
  their state reclaimed eagerly rather than at connection close.

  Prefer this helper over reaching for `PRAGMA busy_timeout` directly:
  the raw PRAGMA silently replaces the callback at the SQLite level
  without clearing our internal slot. This function keeps both sides
  consistent.

  `ms` is the timeout in milliseconds. `0` disables the timeout entirely
  (SQLite returns `SQLITE_BUSY` immediately on contention).
  """
  @spec busy_timeout(conn(), non_neg_integer()) :: :ok | error()
  def busy_timeout(conn, ms) when is_integer(ms) and ms >= 0 do
    with :ok <- XqliteNIF.remove_busy_policy(conn),
         {:ok, _} <- XqliteNIF.set_pragma(conn, "busy_timeout", ms) do
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Authorizer (deny-list, single slot)
  # ---------------------------------------------------------------------------

  @doc """
  Installs a deny-list authorizer on the connection.

  SQLite consults an authorizer callback while *preparing* every statement.
  This installs one that denies a fixed set of action kinds: if a statement
  attempts any denied action, preparation fails and the call returns
  `{:error, {:authorization_denied, message}}`. Everything else is allowed.

  `denied_actions` is a list of action-kind atoms. The set mirrors SQLite's
  authorizer action codes — `:select`, `:read`, `:insert`, `:update`,
  `:delete`, `:transaction`, `:savepoint`, `:pragma`, `:attach`, `:detach`,
  `:alter_table`, `:reindex`, `:analyze`, `:function`, `:recursive`, the
  `create_*` / `drop_*` object verbs (`:create_table`, `:drop_index`,
  `:create_trigger`, `:create_view`, `:create_vtable`, `:drop_vtable`, …)
  including their `*_temp_*` variants, and `:unknown` for action codes a
  future SQLite reports that this build does not map. An unrecognized atom
  returns `{:error, {:invalid_authorizer_action, atom}}` and installs
  nothing — the list is validated in full before anything changes.

  Single slot per connection: a second call replaces the previous list, and
  `remove_authorizer/1` clears it. Both are idempotent.

  ## Limits (v1)

    * **Action-kind granularity only.** The decision is made purely on the
      action *kind*; the table, column, trigger and database arguments SQLite
      passes to the authorizer are ignored. You cannot (yet) deny `DELETE` on
      one table while allowing it on another.
    * **Deny-only.** An action is allowed or denied (SQLite's `DENY`). The
      `IGNORE` disposition (silently treat the access as a NULL/no-op) is not
      exposed.

  ## Caveat — denying `:pragma` disables `get_pragma`/`set_pragma`

  `XqliteNIF.get_pragma/2` and `set_pragma/3` run `PRAGMA` statements, which
  SQLite authorizes as the `:pragma` action; the schema-introspection helpers
  lean on PRAGMAs too. Denying `:pragma` therefore makes all of them fail with
  `{:error, {:authorization_denied, _}}`. Deny it only when you intend to lock
  those paths out as well.

  No telemetry is emitted for authorizer install/remove or for denials.

  ## Examples

      iex> {:ok, conn} = Xqlite.open_in_memory()
      iex> XqliteNIF.execute(conn, "CREATE TABLE t(id INTEGER)", [])
      {:ok, 0}
      iex> Xqlite.set_authorizer(conn, [:delete])
      :ok
      iex> match?({:error, {:authorization_denied, _}}, XqliteNIF.execute(conn, "DELETE FROM t", []))
      true
      iex> match?({:ok, _}, XqliteNIF.query(conn, "SELECT id FROM t", []))
      true
      iex> Xqlite.set_authorizer(conn, [:bogus])
      {:error, {:invalid_authorizer_action, :bogus}}
      iex> Xqlite.remove_authorizer(conn)
      :ok
      iex> XqliteNIF.execute(conn, "DELETE FROM t", [])
      {:ok, 0}
  """
  @spec set_authorizer(conn(), [atom()]) :: :ok | error()
  def set_authorizer(conn, denied_actions) when is_list(denied_actions) do
    XqliteNIF.set_authorizer(conn, denied_actions)
  end

  @doc """
  Removes any authorizer installed on the connection.

  Safe to call when none is installed (no-op). After removal, statement
  preparation is unrestricted again.

  No telemetry is emitted.
  """
  @spec remove_authorizer(conn()) :: :ok | error()
  def remove_authorizer(conn), do: XqliteNIF.remove_authorizer(conn)

  # ---------------------------------------------------------------------------
  # Progress hook (multi-subscriber on the progress_handler slot)
  # ---------------------------------------------------------------------------

  @doc """
  Registers a progress-tick subscriber on the connection.

  After every ~64 SQLite VM instructions × `every_n`, sends

      {:xqlite_progress, count, elapsed_ms}              # tag = nil
      {:xqlite_progress, tag, count, elapsed_ms}         # tag set

  to `pid`. `count` is the per-subscriber decimated counter; `elapsed_ms`
  is the wall time since this specific subscriber was registered.

  Multiple subscribers can coexist independently — each gets its own
  opaque handle, and unregistering one never affects another.

  ## Options

    * `:every_n` (positive integer, default `1000`) — emit every Nth
      progress callback fire. The progress callback fires every 8 SQLite
      VM instructions (currently fixed); `every_n` decimates further.
    * `:tag` (atom, default `nil`) — included in each emitted message
      as the second tuple element when set. Useful when a single
      listener process subscribes to multiple connections and needs to
      tell them apart without spawning a process per connection.

  Returns `{:ok, handle}` where `handle` is the value to pass to
  `unregister_progress_hook/2`. Returns `{:error, reason}` on failure.
  """
  @spec register_progress_hook(conn(), pid(), keyword()) ::
          {:ok, non_neg_integer()} | error()
  def register_progress_hook(conn, pid, opts \\ []) when is_pid(pid) and is_list(opts) do
    every_n = Keyword.get(opts, :every_n, 1000)
    tag_atom = Keyword.get(opts, :tag)

    tag =
      case tag_atom do
        nil -> nil
        a when is_atom(a) -> Atom.to_string(a)
      end

    XqliteNIF.register_progress_hook(conn, pid, every_n, tag)
  end

  @doc """
  Unregisters a progress-tick subscriber by handle.

  Idempotent — unregistering an unknown handle returns `:ok`. Returns
  `{:error, :connection_closed}` if the connection is closed.
  """
  @spec unregister_progress_hook(conn(), non_neg_integer()) :: :ok | error()
  def unregister_progress_hook(conn, handle) when is_integer(handle) do
    XqliteNIF.unregister_progress_hook(conn, handle)
  end

  # ---------------------------------------------------------------------------
  # Cancellable wrappers — accept either a single token or a list
  # ---------------------------------------------------------------------------

  @doc """
  Creates a cancellation token. Emits `[:xqlite, :cancel, :token_created]`.

  The token is an opaque reference passed into cancellable operations
  (`query_cancellable/4`, `execute_cancellable/4`, etc.). Signalling it via
  `cancel_operation/1` from any process interrupts in-flight cancellable
  operations holding the same token.
  """
  @spec create_cancel_token() :: {:ok, reference()} | error()
  def create_cancel_token do
    case XqliteNIF.create_cancel_token() do
      {:ok, token} = ok ->
        emit(
          [:xqlite, :cancel, :token_created],
          %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
          %{token: token}
        )

        ok

      err ->
        err
    end
  end

  @doc """
  Signals a cancellation token. Emits `[:xqlite, :cancel, :signalled]`.

  Idempotent at the SQLite level — signalling twice is the same as once.
  Telemetry fires on every call, so consumers see distinct signal events
  even from repeated signals.
  """
  @spec cancel_operation(reference()) :: :ok | error()
  def cancel_operation(token) when is_reference(token) do
    case XqliteNIF.cancel_operation(token) do
      :ok = ok ->
        emit(
          [:xqlite, :cancel, :signalled],
          %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
          %{token: token}
        )

        ok

      err ->
        err
    end
  end

  @doc """
  Cancellable `query/3`. Accepts either a single cancel token or a list of
  tokens; OR-semantics — any signalled token interrupts the query.

  See `XqliteNIF.query_cancellable/4` for the raw NIF (list form only).
  """
  @spec query_cancellable(
          conn(),
          String.t(),
          list() | keyword(),
          reference() | [reference()]
        ) :: {:ok, query_result()} | error()
  def query_cancellable(conn, sql, params, token_or_tokens) do
    tokens = List.wrap(token_or_tokens)
    start_md = %{conn: conn, sql: sql, params_count: params_count(params), cancellable?: true}

    span_with_stop_metadata [:xqlite, :query], start_md do
      case XqliteNIF.query_cancellable(conn, sql, params, tokens) do
        {:ok, result} ->
          {{:ok, result},
           Map.merge(start_md, %{
             result_class: :ok,
             error_reason: nil,
             num_rows: Map.get(result, :num_rows, 0),
             changes: nil
           })}

        {:error, :operation_cancelled} = err ->
          emit_cancel_honored(conn, :query, tokens)

          {err,
           Map.merge(start_md, %{
             result_class: :error,
             error_reason: :operation_cancelled,
             num_rows: nil,
             changes: nil
           })}

        {:error, reason} = err ->
          {err,
           Map.merge(start_md, %{
             result_class: :error,
             error_reason: reason,
             num_rows: nil,
             changes: nil
           })}
      end
    end
  end

  @doc """
  Cancellable `execute/3`. Accepts either a single cancel token or a list.
  """
  @spec execute_cancellable(
          conn(),
          String.t(),
          list(),
          reference() | [reference()]
        ) :: {:ok, non_neg_integer()} | error()
  def execute_cancellable(conn, sql, params, token_or_tokens) do
    tokens = List.wrap(token_or_tokens)
    start_md = %{conn: conn, sql: sql, params_count: params_count(params), cancellable?: true}

    span_with_stop_metadata [:xqlite, :execute], start_md do
      case XqliteNIF.execute_cancellable(conn, sql, params, tokens) do
        {:ok, affected} = ok ->
          {ok,
           Map.merge(start_md, %{
             result_class: :ok,
             error_reason: nil,
             affected_rows: affected
           })}

        {:error, :operation_cancelled} = err ->
          emit_cancel_honored(conn, :execute, tokens)

          {err,
           Map.merge(start_md, %{
             result_class: :error,
             error_reason: :operation_cancelled,
             affected_rows: nil
           })}

        {:error, reason} = err ->
          {err,
           Map.merge(start_md, %{
             result_class: :error,
             error_reason: reason,
             affected_rows: nil
           })}
      end
    end
  end

  @doc """
  Cancellable `execute_batch/2`. Accepts either a single cancel token or a list.
  """
  @spec execute_batch_cancellable(conn(), String.t(), reference() | [reference()]) ::
          :ok | error()
  def execute_batch_cancellable(conn, sql_batch, token_or_tokens) do
    tokens = List.wrap(token_or_tokens)

    start_md = %{
      conn: conn,
      sql_batch_size_bytes: byte_size(sql_batch),
      cancellable?: true
    }

    span_with_stop_metadata [:xqlite, :execute_batch], start_md do
      case XqliteNIF.execute_batch_cancellable(conn, sql_batch, tokens) do
        :ok = ok ->
          {ok, Map.merge(start_md, %{result_class: :ok, error_reason: nil})}

        {:error, :operation_cancelled} = err ->
          emit_cancel_honored(conn, :execute_batch, tokens)

          {err,
           Map.merge(start_md, %{result_class: :error, error_reason: :operation_cancelled})}

        {:error, reason} = err ->
          {err, Map.merge(start_md, %{result_class: :error, error_reason: reason})}
      end
    end
  end

  @doc """
  Cancellable `query_with_changes/3`. Accepts either a single cancel token or a list.
  """
  @spec query_with_changes_cancellable(
          conn(),
          String.t(),
          list() | keyword(),
          reference() | [reference()]
        ) :: {:ok, map()} | error()
  def query_with_changes_cancellable(conn, sql, params, token_or_tokens) do
    tokens = List.wrap(token_or_tokens)
    start_md = %{conn: conn, sql: sql, params_count: params_count(params), cancellable?: true}

    span_with_stop_metadata [:xqlite, :query_with_changes], start_md do
      case XqliteNIF.query_with_changes_cancellable(conn, sql, params, tokens) do
        {:ok, map} ->
          {{:ok, map},
           Map.merge(start_md, %{
             result_class: :ok,
             error_reason: nil,
             num_rows: Map.get(map, :num_rows, 0),
             changes: Map.get(map, :changes, 0)
           })}

        {:error, :operation_cancelled} = err ->
          emit_cancel_honored(conn, :query_with_changes, tokens)

          {err,
           Map.merge(start_md, %{
             result_class: :error,
             error_reason: :operation_cancelled,
             num_rows: nil,
             changes: nil
           })}

        {:error, reason} = err ->
          {err,
           Map.merge(start_md, %{
             result_class: :error,
             error_reason: reason,
             num_rows: nil,
             changes: nil
           })}
      end
    end
  end

  @doc """
  Online backup with progress messages and cancellation. Accepts either a
  single cancel token or a list (OR-semantics).

  Sends `{:xqlite_backup_progress, remaining, pagecount}` to `pid` after
  each `pages_per_step`-page step. Returns `{:error, :operation_cancelled}`
  if any token signals between steps.
  """
  @spec backup_with_progress(
          conn(),
          String.t(),
          String.t(),
          pid(),
          pos_integer(),
          reference() | [reference()]
        ) :: :ok | error()
  def backup_with_progress(conn, schema, dest_path, pid, pages_per_step, token_or_tokens) do
    XqliteNIF.backup_with_progress(
      conn,
      schema,
      dest_path,
      pid,
      pages_per_step,
      List.wrap(token_or_tokens)
    )
  end

  # ---------------------------------------------------------------------------
  # Transactions (telemetry-instrumented thin wrappers)
  # ---------------------------------------------------------------------------

  @doc """
  Begins a transaction in the given mode (`:deferred`, `:immediate`, or
  `:exclusive`). Emits `[:xqlite, :transaction, :begin]` telemetry.
  """
  @spec begin(conn(), :deferred | :immediate | :exclusive) :: :ok | error()
  def begin(conn, mode \\ :deferred) when mode in [:deferred, :immediate, :exclusive] do
    case XqliteNIF.begin(conn, mode) do
      :ok = ok ->
        emit(
          [:xqlite, :transaction, :begin],
          %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
          %{
            conn: conn,
            mode: mode
          }
        )

        ok

      err ->
        err
    end
  end

  @doc """
  Commits the current transaction. Emits `[:xqlite, :transaction, :commit]`.
  """
  @spec commit(conn()) :: :ok | error()
  def commit(conn) do
    case XqliteNIF.commit(conn) do
      :ok = ok ->
        emit(
          [:xqlite, :transaction, :commit],
          %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
          %{
            conn: conn
          }
        )

        ok

      err ->
        err
    end
  end

  @doc """
  Rolls back the current transaction. Emits
  `[:xqlite, :transaction, :rollback]` with `reason: :user_initiated`.

  SQLite-internal rollbacks (constraint violations, deferred-FK failures
  at commit time) surface as errors from `commit/1` rather than passing
  through here — those events come from the `register_rollback_hook/2`
  fan-out instead.
  """
  @spec rollback(conn()) :: :ok | error()
  def rollback(conn) do
    case XqliteNIF.rollback(conn) do
      :ok = ok ->
        emit(
          [:xqlite, :transaction, :rollback],
          %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
          %{
            conn: conn,
            reason: :user_initiated
          }
        )

        ok

      err ->
        err
    end
  end

  @doc """
  Creates a savepoint with the given name. Emits
  `[:xqlite, :savepoint, :create]`.
  """
  @spec savepoint(conn(), String.t()) :: :ok | error()
  def savepoint(conn, name) when is_binary(name) do
    case XqliteNIF.savepoint(conn, name) do
      :ok = ok ->
        emit(
          [:xqlite, :savepoint, :create],
          %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
          %{
            conn: conn,
            name: name
          }
        )

        ok

      err ->
        err
    end
  end

  @doc """
  Releases a savepoint. Emits `[:xqlite, :savepoint, :release]`.
  """
  @spec release_savepoint(conn(), String.t()) :: :ok | error()
  def release_savepoint(conn, name) when is_binary(name) do
    case XqliteNIF.release_savepoint(conn, name) do
      :ok = ok ->
        emit(
          [:xqlite, :savepoint, :release],
          %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
          %{
            conn: conn,
            name: name
          }
        )

        ok

      err ->
        err
    end
  end

  @doc """
  Rolls back to a savepoint without releasing it. Emits
  `[:xqlite, :savepoint, :rollback_to]`.

  Note: this does NOT invoke SQLite's `rollback_hook` — that fires only
  for outer-transaction rollbacks. Use `register_rollback_hook/2` for
  outer rollback observability; this telemetry event is what's
  available for partial-rollback observability.
  """
  @spec rollback_to_savepoint(conn(), String.t()) :: :ok | error()
  def rollback_to_savepoint(conn, name) when is_binary(name) do
    case XqliteNIF.rollback_to_savepoint(conn, name) do
      :ok = ok ->
        emit(
          [:xqlite, :savepoint, :rollback_to],
          %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
          %{
            conn: conn,
            name: name
          }
        )

        ok

      err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Transaction state
  # ---------------------------------------------------------------------------

  @doc """
  Returns whether the connection is currently inside a transaction.

  `{:ok, true}` after `begin/2` and before `commit/1` or
  `rollback/1`, `{:ok, false}` in autocommit mode. Wraps
  `XqliteNIF.transaction_status/1`. No telemetry is emitted.
  """
  @spec transaction_status(conn()) :: {:ok, boolean()} | error()
  def transaction_status(conn), do: XqliteNIF.transaction_status(conn)

  @doc """
  Returns `{:ok, true}` when the connection is in auto-commit mode
  (no active transaction), `{:ok, false}` otherwise.

  The inverse view of `transaction_status/1`, matching SQLite's
  `sqlite3_get_autocommit`. Wraps `XqliteNIF.autocommit/1`. No
  telemetry is emitted.
  """
  @spec autocommit(conn()) :: {:ok, boolean()} | error()
  def autocommit(conn), do: XqliteNIF.autocommit(conn)

  @doc """
  Returns the transaction state of a schema: `:none`, `:read`,
  `:write`, or `:unknown` (a future SQLite state not mapped yet).

  `schema` defaults to `nil`, meaning `"main"`. Wraps
  `XqliteNIF.txn_state/2` (see it for why there is no full five-state
  lock ladder). No telemetry is emitted.
  """
  @spec txn_state(conn(), String.t() | nil) ::
          {:ok, :none | :read | :write | :unknown} | error()
  def txn_state(conn, schema \\ nil) when is_binary(schema) or is_nil(schema),
    do: XqliteNIF.txn_state(conn, schema)

  # ---------------------------------------------------------------------------
  # Connection introspection
  # ---------------------------------------------------------------------------

  @doc """
  Returns the rowid of the most recent successful `INSERT` on this
  connection.

  Connection-specific and only updated by successful `INSERT`s. Does
  not work for `WITHOUT ROWID` tables — use `INSERT ... RETURNING`
  there. Wraps `XqliteNIF.last_insert_rowid/1`. No telemetry is
  emitted.
  """
  @spec last_insert_rowid(conn()) :: {:ok, integer()} | error()
  def last_insert_rowid(conn), do: XqliteNIF.last_insert_rowid(conn)

  @doc """
  Returns the number of rows changed by the most recently completed
  `INSERT`, `UPDATE`, or `DELETE` on this connection.

  The counter is sticky: non-DML statements (`SELECT`, DDL, PRAGMA)
  leave it untouched, so it reports the last DML's count rather than
  resetting to `0`. For an atomically captured count prefer `query/4`
  or `execute/4`, whose `t:Xqlite.Result.t/0` carries `changes` taken
  inside the connection lock. Wraps `XqliteNIF.changes/1`. No
  telemetry is emitted.
  """
  @spec changes(conn()) :: {:ok, non_neg_integer()} | error()
  def changes(conn), do: XqliteNIF.changes(conn)

  @doc """
  Returns the total number of rows changed by all `INSERT`, `UPDATE`,
  and `DELETE` statements since the connection was opened, including
  changes made by triggers. Wraps `XqliteNIF.total_changes/1`. No
  telemetry is emitted.
  """
  @spec total_changes(conn()) :: {:ok, non_neg_integer()} | error()
  def total_changes(conn), do: XqliteNIF.total_changes(conn)

  @doc """
  Returns a snapshot of the connection's `sqlite3_db_status` counters
  (lookaside, pager cache, schema and statement memory, cache
  hit/miss/spill, deferred foreign keys).

  See `XqliteNIF.connection_stats/1` for the full key list. Call
  repeatedly for time-series monitoring. No telemetry is emitted.
  """
  @spec connection_stats(conn()) :: {:ok, map()} | error()
  def connection_stats(conn), do: XqliteNIF.connection_stats(conn)

  @doc """
  Returns the compile-time options the linked SQLite library was
  built with, as a list of strings (`PRAGMA compile_options`).

  Useful to confirm features such as `ENABLE_FTS5` are present. Wraps
  `XqliteNIF.compile_options/1`. No telemetry is emitted.
  """
  @spec compile_options(conn()) :: {:ok, [String.t()]} | error()
  def compile_options(conn), do: XqliteNIF.compile_options(conn)

  @doc """
  Returns the version string of the linked SQLite C library.

  Needs no connection. Wraps `XqliteNIF.sqlite_version/0`. No
  telemetry is emitted.
  """
  @spec sqlite_version() :: {:ok, String.t()} | error()
  def sqlite_version, do: XqliteNIF.sqlite_version()

  # ---------------------------------------------------------------------------
  # Schema introspection
  # ---------------------------------------------------------------------------

  @doc """
  Lists all databases attached to the connection as
  `Xqlite.Schema.DatabaseInfo` structs (`PRAGMA database_list`).

  Wraps `XqliteNIF.schema_databases/1`. No telemetry is emitted.
  """
  @spec schema_databases(conn()) :: {:ok, [Xqlite.Schema.DatabaseInfo.t()]} | error()
  def schema_databases(conn), do: XqliteNIF.schema_databases(conn)

  @doc """
  Lists tables, views, and virtual tables as
  `Xqlite.Schema.SchemaObjectInfo` structs (`PRAGMA table_list`).

  `schema` defaults to `nil`; pass `"main"`, `"temp"`, or an attached
  database name for predictable results. Wraps
  `XqliteNIF.schema_list_objects/2`. No telemetry is emitted.
  """
  @spec schema_list_objects(conn(), String.t() | nil) ::
          {:ok, [Xqlite.Schema.SchemaObjectInfo.t()]} | error()
  def schema_list_objects(conn, schema \\ nil) when is_binary(schema) or is_nil(schema),
    do: XqliteNIF.schema_list_objects(conn, schema)

  @doc """
  Returns column details for a table or view as
  `Xqlite.Schema.ColumnInfo` structs (`PRAGMA table_xinfo`), or
  `{:ok, []}` when the table does not exist.

  Wraps `XqliteNIF.schema_columns/2`. No telemetry is emitted.
  """
  @spec schema_columns(conn(), String.t()) ::
          {:ok, [Xqlite.Schema.ColumnInfo.t()]} | error()
  def schema_columns(conn, table_name) when is_binary(table_name),
    do: XqliteNIF.schema_columns(conn, table_name)

  @doc """
  Returns the foreign keys defined on a table as
  `Xqlite.Schema.ForeignKeyInfo` structs (`PRAGMA foreign_key_list`).

  Wraps `XqliteNIF.schema_foreign_keys/2`. No telemetry is emitted.
  """
  @spec schema_foreign_keys(conn(), String.t()) ::
          {:ok, [Xqlite.Schema.ForeignKeyInfo.t()]} | error()
  def schema_foreign_keys(conn, table_name) when is_binary(table_name),
    do: XqliteNIF.schema_foreign_keys(conn, table_name)

  @doc """
  Returns all indexes on a table as `Xqlite.Schema.IndexInfo` structs
  (`PRAGMA index_list`), including those backing `PRIMARY KEY` and
  `UNIQUE` constraints.

  Wraps `XqliteNIF.schema_indexes/2`. No telemetry is emitted.
  """
  @spec schema_indexes(conn(), String.t()) ::
          {:ok, [Xqlite.Schema.IndexInfo.t()]} | error()
  def schema_indexes(conn, table_name) when is_binary(table_name),
    do: XqliteNIF.schema_indexes(conn, table_name)

  @doc """
  Returns the columns of an index as `Xqlite.Schema.IndexColumnInfo`
  structs (`PRAGMA index_xinfo`), ordered by position in the index.

  Wraps `XqliteNIF.schema_index_columns/2`. No telemetry is emitted.
  """
  @spec schema_index_columns(conn(), String.t()) ::
          {:ok, [Xqlite.Schema.IndexColumnInfo.t()]} | error()
  def schema_index_columns(conn, index_name) when is_binary(index_name),
    do: XqliteNIF.schema_index_columns(conn, index_name)

  @doc """
  Returns the `CREATE ...` SQL for a schema object as recorded in
  `sqlite_schema`, or `{:ok, nil}` when no object with that name
  exists.

  Wraps `XqliteNIF.get_create_sql/2`. No telemetry is emitted.
  """
  @spec get_create_sql(conn(), String.t()) :: {:ok, String.t() | nil} | error()
  def get_create_sql(conn, object_name) when is_binary(object_name),
    do: XqliteNIF.get_create_sql(conn, object_name)

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp params_count(params) when is_list(params), do: length(params)
  defp params_count(_), do: 0

  defp emit_cancel_honored(conn, operation, tokens) do
    emit(
      [:xqlite, :cancel, :honored],
      %{monotonic_time: Xqlite.Telemetry.monotonic_time()},
      %{conn: conn, operation: operation, tokens: tokens}
    )
  end
end
