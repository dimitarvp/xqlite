defmodule Xqlite.Telemetry.TestSupport do
  @moduledoc """
  Test helpers for asserting on `:telemetry` events emitted by xqlite
  (and downstream by `xqlite_ecto3`).

  Usage:

      defmodule MyTest do
        use ExUnit.Case, async: true
        import Xqlite.Telemetry.TestSupport

        test "...", do
          handler_id = attach_capture([
            [:xqlite, :query, :start],
            [:xqlite, :query, :stop]
          ])

          {:ok, _} = Xqlite.query(conn, "SELECT 1", [])

          assert_emitted [:xqlite, :query, :start]
          assert_emitted [:xqlite, :query, :stop], metadata: %{result_class: :ok}

          detach(handler_id)
        end
      end

  All helpers are zero-dependency on internals — they wrap
  `:telemetry.attach_many/4` and the test-process mailbox.

  Per-test handler ids are random integers so two async tests can
  attach to the same event names without colliding. Always call
  `detach/1` (or rely on the ExUnit teardown — failure to detach
  leaks a handler but does not crash).
  """

  @doc """
  Attaches a capture handler to the given list of events. Each
  emission is forwarded to the calling process as
  `{:telemetry_event, name, measurements, metadata}`.

  Returns the handler id (a string) — pass it to `detach/1` to
  unsubscribe.
  """
  @spec attach_capture([list(atom())]) :: String.t()
  def attach_capture(events) when is_list(events) do
    handler_id = "xqlite-test-capture-#{:erlang.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )

    handler_id
  end

  @doc """
  Detaches a capture handler. Idempotent — detaching an unknown
  handler is a no-op.
  """
  @spec detach(String.t()) :: :ok
  def detach(handler_id) when is_binary(handler_id) do
    :telemetry.detach(handler_id)
    :ok
  end

  @doc """
  Asserts that the given event was emitted. Optionally checks that
  measurements / metadata contain the given keys.

  ## Options

    * `:measurements` — map of expected key/value pairs to match
      (subset match — extra keys in the actual measurements are
      ignored).
    * `:metadata` — same, for metadata.
    * `:timeout` — milliseconds to wait, default `100`.

  Returns the matched `{name, measurements, metadata}` triple.
  """
  defmacro assert_emitted(event, opts \\ []) do
    quote do
      event = unquote(event)
      opts = unquote(opts)
      timeout = Keyword.get(opts, :timeout, 100)

      received =
        receive do
          {:telemetry_event, ^event, measurements, metadata} ->
            {event, measurements, metadata}
        after
          timeout ->
            ExUnit.Assertions.flunk(
              "Expected event #{inspect(event)} to be emitted within #{timeout}ms, but it wasn't."
            )
        end

      {_, actual_measurements, actual_metadata} = received

      case Keyword.get(opts, :measurements) do
        nil ->
          :ok

        expected ->
          for {k, v} <- expected do
            actual = Map.get(actual_measurements, k)

            unless actual == v do
              ExUnit.Assertions.flunk(
                "Expected event #{inspect(event)} measurement #{inspect(k)} to be #{inspect(v)}, " <>
                  "got #{inspect(actual)} (full measurements: #{inspect(actual_measurements)})"
              )
            end
          end
      end

      case Keyword.get(opts, :metadata) do
        nil ->
          :ok

        expected ->
          for {k, v} <- expected do
            actual = Map.get(actual_metadata, k)

            unless actual == v do
              ExUnit.Assertions.flunk(
                "Expected event #{inspect(event)} metadata #{inspect(k)} to be #{inspect(v)}, " <>
                  "got #{inspect(actual)} (full metadata: #{inspect(actual_metadata)})"
              )
            end
          end
      end

      received
    end
  end

  @doc """
  Asserts that a span (`:start` + `:stop`) fired for the given
  prefix. Convenient for spanned operations where consumers usually
  attach to both events.

  Looks for events `prefix ++ [:start]` then `prefix ++ [:stop]`
  in order. Returns `{start_metadata, stop_metadata}`.
  """
  defmacro assert_span(prefix, opts \\ []) do
    quote do
      prefix = unquote(prefix)
      opts = unquote(opts)
      timeout = Keyword.get(opts, :timeout, 100)
      start_event = prefix ++ [:start]
      stop_event = prefix ++ [:stop]

      start_md =
        receive do
          {:telemetry_event, ^start_event, _, metadata} -> metadata
        after
          timeout ->
            ExUnit.Assertions.flunk(
              "Expected start event #{inspect(start_event)} within #{timeout}ms, none seen."
            )
        end

      stop_md =
        receive do
          {:telemetry_event, ^stop_event, _, metadata} -> metadata
        after
          timeout ->
            ExUnit.Assertions.flunk(
              "Expected stop event #{inspect(stop_event)} within #{timeout}ms, none seen."
            )
        end

      {start_md, stop_md}
    end
  end

  @doc """
  Drains all pending telemetry events from the mailbox and returns
  them as a list of `{name, measurements, metadata}` triples in
  arrival order. Stops at the first non-telemetry message or when
  the mailbox is empty for `timeout` ms.

  Useful when you don't know how many events fired and want to
  inspect them all.
  """
  @spec drain_events(non_neg_integer()) :: [{list(atom()), map(), map()}]
  def drain_events(timeout \\ 50) do
    do_drain([], timeout)
  end

  defp do_drain(acc, timeout) do
    receive do
      {:telemetry_event, name, measurements, metadata} ->
        do_drain([{name, measurements, metadata} | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
