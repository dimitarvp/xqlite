defmodule XqliteNIF do
  use Rustler, otp_app: :xqlite, crate: :xqlitenif, mode: :release

  def open(_path, _opts \\ []), do: err()
  def open_in_memory(_path \\ ":memory:"), do: err()
  def open_temporary(), do: err()
  def query(_conn, _sql, _params \\ []), do: err()
  def query_cancellable(_conn, _sql, _params, _cancel_token), do: err()
  def execute(_conn, _sql, _params \\ []), do: err()
  def execute_cancellable(_conn, _sql, _params, _cancel_token), do: err()
  def execute_batch(_conn, _sql), do: err()
  def execute_batch_cancellable(_conn, _sql_batch, _cancel_token), do: err()
  def close(_conn), do: err()
  def get_pragma(_conn, _name), do: err()
  def set_pragma(_conn, _name, _value), do: err()
  def begin(_conn), do: err()
  def commit(_conn), do: err()
  def rollback(_conn), do: err()
  def savepoint(_conn, _name), do: err()
  def rollback_to_savepoint(_conn, _name), do: err()
  def release_savepoint(_conn, _name), do: err()
  def schema_databases(_conn), do: err()
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

  defp err, do: :erlang.nif_error(:nif_not_loaded)
end
