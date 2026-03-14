defmodule Xqlite do
  @moduledoc ~S"""
  This is the central module of this library. All SQLite operations can be performed from here.
  Note that they delegate to other modules which you can also use directly.
  """

  @type conn :: reference()

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

  @doc false
  @spec int2bool(0 | 1) :: true | false
  def int2bool(0), do: false
  def int2bool(1), do: true

  @doc """
  Enables strict mode only for the lifetime of the given database connection.

  In strict mode, SQLite is less forgiving. For example, an attempt to insert
  a string into an INTEGER column of a `STRICT` table will result in an error,
  whereas in normal mode it might be coerced or stored as text.
  This setting only affects tables declared with the `STRICT` keyword.

  See: [STRICT Tables](https://www.sqlite.org/stricttables.html)
  """
  @spec enable_strict_mode(conn()) :: :ok | error()
  def enable_strict_mode(conn) do
    XqliteNIF.set_pragma(conn, "strict", :on)
  end

  @doc """
  Disables strict mode only for the lifetime given database connection (SQLite's default).

  See `enable_strict_mode/1` for details.
  """
  @spec disable_strict_mode(conn()) :: :ok | error()
  def disable_strict_mode(conn) do
    XqliteNIF.set_pragma(conn, "strict", :off)
  end

  @doc """
  Enables foreign key constraint enforcement for the given database connection.

  By default, SQLite parses foreign key constraints but does not enforce them.
  This function turns on enforcement.

  See: [SQLite PRAGMA foreign_keys](https://www.sqlite.org/pragma.html#pragma_foreign_keys)
  """
  @spec enable_foreign_key_enforcement(conn()) :: :ok | error()
  def enable_foreign_key_enforcement(conn) do
    XqliteNIF.set_pragma(conn, "foreign_keys", :on)
  end

  @doc """
  Disables foreign key constraint enforcement for the given database connection (default behavior).

  See `enable_foreign_key_enforcement/1` for details.
  """
  @spec disable_foreign_key_enforcement(conn()) :: :ok | error()
  def disable_foreign_key_enforcement(conn) do
    XqliteNIF.set_pragma(conn, "foreign_keys", :off)
  end

  @doc """
  Creates a stream that executes a query and emits rows as maps.

  This provides a high-level, idiomatic Elixir `Stream` for processing large
  result sets without loading them all into memory at once. Rows are fetched
  from the database in batches as the stream is consumed.

  ## Options

    * `:batch_size` (integer, default: `500`) - The maximum number of rows
      to fetch from the database in a single batch.

  ## Examples

      iex> {:ok, conn} = XqliteNIF.open_in_memory()
      iex> XqliteNIF.execute_batch(conn, "CREATE TABLE users(id, name); INSERT INTO users VALUES (1, 'Alice'), (2, 'Bob');")
      :ok
      iex> Xqlite.stream(conn, "SELECT id, name FROM users;") |> Enum.to_list()
      [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}]

  If the underlying query preparation or initial NIF stream setup fails, this
  function will return an `{:error, reason}` tuple directly instead of a stream.
  Errors that occur during stream consumption (e.g., database connection lost
  mid-stream) will be logged and will cause the stream to halt.
  """
  @spec stream(conn(), String.t(), list() | keyword(), keyword()) ::
          Enumerable.t() | error()
  def stream(conn, sql, params \\ [], opts \\ []) do
    start_fun = &Xqlite.StreamResourceCallbacks.start_fun/1
    next_fun = &Xqlite.StreamResourceCallbacks.next_fun/1
    after_fun = &Xqlite.StreamResourceCallbacks.after_fun/1

    # `Stream.resource/3` expects the start_fun to return {:ok, acc} or {:error, reason}.
    # If it returns {:error, reason}, Stream.resource will raise an error.
    # To align with our spec of returning {:error, reason} directly, we must
    # call start_fun ourselves first.

    case start_fun.({conn, sql, params, opts}) do
      {:ok, acc} ->
        # If setup is successful, build the stream resource.
        # The start function for Stream.resource now just returns the successful acc.
        Stream.resource(fn -> acc end, next_fun, after_fun)

      {:error, _reason} = error ->
        # If setup fails, return the error tuple directly.
        error
    end
  end
end
