defmodule Xqlite.StreamResourceCallbacks do
  @moduledoc false

  # Callbacks for implementing Xqlite.stream/4 via Stream.resource/3.
  # This module is not intended for direct use.

  import Xqlite.Telemetry, only: [emit: 3]

  alias XqliteNIF, as: NIF

  require Logger

  @type acc :: %{
          handle: reference(),
          columns: [String.t()],
          batch_size: pos_integer(),
          type_extensions: [module()],
          original_opts: keyword(),
          rows_total: non_neg_integer(),
          opened_at: integer(),
          on_error: Xqlite.stream_on_error(),
          errored?: boolean()
        }

  @valid_on_error [:raise, :halt, :emit_error]

  @spec start_fun({Xqlite.conn(), String.t(), list() | keyword(), keyword()}) ::
          {:ok, acc()} | {:error, Xqlite.error_reason()}
  def start_fun({conn, sql, params, opts}) do
    case validate_on_error(opts) do
      {:ok, on_error} -> open_stream(conn, sql, params, opts, on_error)
      {:error, _reason} = error -> error
    end
  end

  defp validate_on_error(opts) do
    case Keyword.get(opts, :on_error, :raise) do
      mode when mode in @valid_on_error -> {:ok, mode}
      other -> {:error, {:invalid_on_error, other}}
    end
  end

  defp open_stream(conn, sql, params, opts, on_error) do
    case NIF.stream_open(conn, sql, params, []) do
      {:ok, handle} ->
        # stream_open succeeded, now try to get columns.
        case NIF.stream_get_columns(handle) do
          {:ok, columns} ->
            {:ok, build_acc(handle, columns, opts, on_error)}

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

  defp build_acc(handle, columns, opts, on_error) do
    %{
      handle: handle,
      columns: columns,
      batch_size: Keyword.get(opts, :batch_size, 500),
      type_extensions: Keyword.get(opts, :type_extensions, []),
      original_opts: opts,
      rows_total: 0,
      opened_at: Xqlite.Telemetry.monotonic_time(),
      on_error: on_error,
      errored?: false
    }
  end

  @spec next_fun(acc()) ::
          {[map() | {:ok, map()} | {:error, Xqlite.error_reason()}], acc()} | {:halt, acc()}
  def next_fun(%{on_error: :emit_error, errored?: true} = acc) do
    # The terminal {:error, reason} element was already emitted; stop without
    # touching the (now errored) statement again.
    {:halt, acc}
  end

  def next_fun(acc) do
    fetch_started_at = Xqlite.Telemetry.monotonic_time()

    case NIF.stream_fetch(acc.handle, acc.batch_size) do
      {:ok, %{rows: rows}} ->
        mapped_rows = map_rows_to_maps(rows, acc.columns, acc.type_extensions)
        rows_count = length(mapped_rows)
        new_acc = %{acc | rows_total: acc.rows_total + rows_count}
        emit_fetch_telemetry(fetch_started_at, rows_count, acc.handle, false)
        {shape_rows(mapped_rows, acc.on_error), new_acc}

      :done ->
        emit_fetch_telemetry(fetch_started_at, 0, acc.handle, true)
        {:halt, acc}

      {:error, reason} ->
        emit_fetch_telemetry(fetch_started_at, 0, acc.handle, true)
        handle_fetch_error(reason, acc)
    end
  end

  defp shape_rows(mapped_rows, :emit_error), do: Enum.map(mapped_rows, &{:ok, &1})
  defp shape_rows(mapped_rows, _on_error), do: mapped_rows

  # :raise (default) — surface the structured reason as an exception so a
  # mid-fetch failure cannot masquerade as a completed stream.
  defp handle_fetch_error(reason, %{on_error: :raise}) do
    raise Xqlite.StreamError, reason: reason
  end

  # :halt (opt-in, LOSSY) — Stream.resource/3 cannot hand the error to the
  # consumer, so log and silently truncate the result set.
  defp handle_fetch_error(reason, %{on_error: :halt} = acc) do
    Logger.error("Error fetching from Xqlite stream: #{inspect(reason)}")
    {:halt, acc}
  end

  # :emit_error — yield a terminal tagged error, then halt on the next callback.
  defp handle_fetch_error(reason, %{on_error: :emit_error} = acc) do
    {[{:error, reason}], %{acc | errored?: true}}
  end

  defp emit_fetch_telemetry(started_at, rows_returned, handle, done?) do
    now = Xqlite.Telemetry.monotonic_time()

    emit(
      [:xqlite, :stream, :fetch],
      %{monotonic_time: now, duration: now - started_at, rows_returned: rows_returned},
      %{stream_handle: handle, done?: done?}
    )
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
