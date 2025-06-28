defmodule Xqlite.StreamResourceCallbacks do
  @moduledoc false

  # Callbacks for implementing Xqlite.stream/4 via Stream.resource/3.
  # This module is not intended for direct use.

  alias XqliteNIF, as: NIF

  require Logger

  @type acc :: %{
          handle: reference(),
          columns: [String.t()],
          batch_size: pos_integer(),
          original_opts: keyword()
        }

  @spec start_fun({Xqlite.conn(), String.t(), list() | keyword(), keyword()}) ::
          {:ok, acc()} | {:error, Xqlite.error()}
  def start_fun({conn, sql, params, opts}) do
    case NIF.stream_open(conn, sql, params, []) do
      {:ok, handle} ->
        # stream_open succeeded, now try to get columns.
        case NIF.stream_get_columns(handle) do
          {:ok, columns} ->
            # Both NIF calls succeeded. Build the accumulator.
            batch_size = Keyword.get(opts, :batch_size, 500)

            acc = %{
              handle: handle,
              columns: columns,
              batch_size: batch_size,
              original_opts: opts
            }

            {:ok, acc}

          {:error, _reason} = error ->
            # stream_get_columns failed. We MUST close the handle we just opened.
            NIF.stream_close(handle)
            error
        end

      {:error, _reason} = error ->
        # stream_open failed. Nothing to clean up, just return the error.
        error
    end
  end

  @spec next_fun(acc()) :: {[map()], acc()} | {:halt, acc()}
  def next_fun(acc) do
    # Fetch the next batch of rows from the NIF.
    case NIF.stream_fetch(acc.handle, acc.batch_size) do
      {:ok, %{rows: rows}} ->
        # Successfully fetched rows. Map them into Elixir maps.
        mapped_rows = map_rows_to_structs(rows, acc.columns)
        {mapped_rows, acc}

      :done ->
        # The stream is exhausted. Halt the stream.
        {:halt, acc}

      {:error, reason} ->
        # An error occurred while fetching. Log it and halt the stream.
        # Note: Stream.resource/3 does not propagate this error to the consumer.
        # Raising an exception is an alternative, but logging is safer for now.
        Logger.error("Error fetching from Xqlite stream: #{inspect(reason)}")
        {:halt, acc}
    end
  end

  @spec after_fun(acc()) :: any()
  def after_fun(acc) do
    # Ensure the underlying NIF stream resource is closed.
    # The return value of this function is ignored by Stream.resource/3,
    # but we can still handle a potential error case by logging it.
    case NIF.stream_close(acc.handle) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Error closing Xqlite stream handle: #{inspect(reason)}")
        # Still return :ok, as the stream is finished regardless
        :ok
    end
  end

  defp map_rows_to_structs(rows, columns) do
    # Convert column names (strings) to atoms once for efficiency.
    column_atoms = Enum.map(columns, &String.to_atom/1)

    Enum.map(rows, fn row_list ->
      # Combine atom keys with row values into a map.
      Map.new(Enum.zip(column_atoms, row_list))
    end)
  end
end
