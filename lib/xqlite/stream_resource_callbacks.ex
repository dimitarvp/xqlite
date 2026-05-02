defmodule Xqlite.StreamResourceCallbacks do
  @moduledoc false

  # Callbacks for implementing Xqlite.stream/4 via Stream.resource/3.
  # This module is not intended for direct use.

  alias XqliteNIF, as: NIF
  import Xqlite.Telemetry, only: [emit: 3]

  require Logger

  @type acc :: %{
          handle: reference(),
          columns: [String.t()],
          batch_size: pos_integer(),
          type_extensions: [module()],
          original_opts: keyword(),
          rows_total: non_neg_integer(),
          opened_at: integer()
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
            type_extensions = Keyword.get(opts, :type_extensions, [])

            acc = %{
              handle: handle,
              columns: columns,
              batch_size: batch_size,
              type_extensions: type_extensions,
              original_opts: opts,
              rows_total: 0,
              opened_at: Xqlite.Telemetry.monotonic_time()
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
    fetch_started_at = Xqlite.Telemetry.monotonic_time()

    case NIF.stream_fetch(acc.handle, acc.batch_size) do
      {:ok, %{rows: rows}} ->
        mapped_rows = map_rows_to_maps(rows, acc.columns, acc.type_extensions)
        rows_count = length(mapped_rows)
        new_acc = %{acc | rows_total: acc.rows_total + rows_count}
        now = Xqlite.Telemetry.monotonic_time()

        emit(
          [:xqlite, :stream, :fetch],
          %{monotonic_time: now, duration: now - fetch_started_at, rows_returned: rows_count},
          %{stream_handle: acc.handle, done?: false}
        )

        {mapped_rows, new_acc}

      :done ->
        now = Xqlite.Telemetry.monotonic_time()

        emit(
          [:xqlite, :stream, :fetch],
          %{monotonic_time: now, duration: now - fetch_started_at, rows_returned: 0},
          %{stream_handle: acc.handle, done?: true}
        )

        {:halt, acc}

      {:error, reason} ->
        # An error occurred while fetching. Log it and halt the stream.
        # Note: Stream.resource/3 does not propagate this error to the consumer.
        # Raising an exception is an alternative, but logging is safer for now.
        Logger.error("Error fetching from Xqlite stream: #{inspect(reason)}")
        now = Xqlite.Telemetry.monotonic_time()

        emit(
          [:xqlite, :stream, :fetch],
          %{monotonic_time: now, duration: now - fetch_started_at, rows_returned: 0},
          %{stream_handle: acc.handle, done?: true}
        )

        {:halt, acc}
    end
  end

  @spec after_fun(acc()) :: :ok
  def after_fun(acc) do
    close_result = NIF.stream_close(acc.handle)

    reason =
      case close_result do
        :ok ->
          :drained

        {:error, close_err} ->
          Logger.error("Error closing Xqlite stream handle: #{inspect(close_err)}")
          :errored
      end

    now = Xqlite.Telemetry.monotonic_time()

    emit(
      [:xqlite, :stream, :close],
      %{
        monotonic_time: now,
        total_duration: now - acc.opened_at,
        total_rows: acc.rows_total
      },
      %{stream_handle: acc.handle, reason: reason}
    )

    :ok
  end

  defp map_rows_to_maps(rows, columns, type_extensions) do
    rows
    |> Xqlite.TypeExtension.decode_rows(type_extensions)
    |> Enum.map(fn row_list -> Map.new(Enum.zip(columns, row_list)) end)
  end
end
