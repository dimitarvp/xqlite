defmodule Xqlite.StreamLifecycleLawTest do
  @moduledoc """
  A stream runs its statement once, and every fetch answers the next part of
  that one run: its rows, each once and in order, then `:done` or the error
  that ended it.

  A raw fetch of `k` answers up to `k` rows; the fetch that reaches the end
  answers the rows it read and leaves the end to the next fetch, and one that
  meets the end first answers it at once; after the end, and after a close,
  every fetch answers `:done`. Through `Xqlite.stream/4` each `:on_error`
  mode yields the rows before the error, then `:raise` raises it, `:halt`
  logs it and `:emit_error` yields it last; a pass that stops before the
  error never meets it, whatever the batch size. A write runs at the first
  fetch, once, and a close keeps it.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Xqlite.ConnCase

  @moduletag timeout: 300_000

  @overflow {:error, {:sqlite_failure, 1, 1}}
  @seed "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, v, w, x, n); DELETE FROM t; " <>
          "INSERT INTO t VALUES (1, 'a', 'a', 'a', 1), (2, 'b', 'b', 'b', 2), (3, 'c', 'c', 'c', 3);"
  @select %{0 => "id, abs(n), v", 1 => "id, :a, abs(n), v", 3 => "id, :a, :b, :c, abs(n), v"}
  @set %{0 => "v = v || '!'", 1 => "v = v || :a", 3 => "v = v || :a, w = w || :b, x = x || :c"}

  for_each_opener "a stream's one run" do
    property "raw fetches answer the run in order, once", %{conn: conn} do
      check all(
              {kind, n, trouble, params} <- statement(),
              actions <- list_of(action(), max_length: 6),
              max_runs: 2000
            ) do
        assert :ok = Xqlite.execute_batch(conn, @seed <> trouble_sql(trouble))
        assert {:ok, stream} = XqliteNIF.stream_open(conn, sql(kind, n), params)
        Enum.reduce(actions, {run(kind, n, trouble), nil}, &act(&1, stream, &2))
        assert :ok = XqliteNIF.stream_close(stream)
        assert_table(conn, kind, applied(kind, trouble, match?([{_, _} | _], actions), n))
      end
    end

    property "each :on_error mode answers the rows before the error, then the error",
             %{conn: conn} do
      check all(
              {kind, n, trouble, params} <- statement(),
              mode <- member_of([:raise, :halt, :emit_error]),
              batch_size <- member_of([1, 2, 10]),
              k <- integer(1..4),
              max_runs: 2000
            ) do
        assert :ok = Xqlite.execute_batch(conn, @seed <> trouble_sql(trouble))

        stream =
          Xqlite.stream(conn, sql(kind, n), params, on_error: mode, batch_size: batch_size)

        {rows, [ending]} = kind |> run(n, trouble) |> Enum.split_while(&is_list/1)
        pass(mode, stream, k, Enum.map(rows, &row_map(kind, n, &1)), ending)
        assert_table(conn, kind, applied(kind, trouble, true, n))
      end
    end
  end

  defp statement do
    gen all(
          kind <- member_of([:read, :write, :returning]),
          n <- member_of([0, 1, 3]),
          trouble <- member_of(troubles(kind)),
          params <- member_of(params(n))
        ) do
      {kind, n, trouble, params}
    end
  end

  defp troubles(:read), do: [:none, :overflow, :unreadable]
  defp troubles(_write), do: [:none, :overflow]

  defp params(0), do: [[], nil]
  defp params(n), do: [values(n), Enum.zip([:a, :b, :c], values(n))]

  defp values(n), do: Enum.take([11, 12, 13], n)

  defp action do
    one_of([
      constant(:close),
      tuple({member_of([:fetch, :cancellable]), member_of([1, 2, 10])})
    ])
  end

  defp trouble_sql(:none), do: ""
  defp trouble_sql(:overflow), do: "UPDATE t SET n = -9223372036854775808 WHERE id = 3;"
  defp trouble_sql(:unreadable), do: "UPDATE t SET v = CAST(X'FF' AS TEXT) WHERE id = 3;"

  defp sql(:read, n), do: "SELECT #{@select[n]} FROM t ORDER BY id"
  defp sql(:write, n), do: "UPDATE t SET #{@set[n]} WHERE abs(n) > 0"
  defp sql(:returning, n), do: sql(:write, n) <> " RETURNING id, v, w, x"

  defp run(:read, n, :none), do: read_rows(n, 3) ++ [:done]
  defp run(:read, n, :overflow), do: read_rows(n, 2) ++ [@overflow]
  defp run(:read, n, :unreadable), do: read_rows(n, 2) ++ [{:error, {:utf8_error, n + 2}}]
  defp run(_write, _n, :overflow), do: [@overflow]
  defp run(:write, _n, :none), do: [:done]
  defp run(:returning, n, :none), do: table(effect(n)) ++ [:done]

  defp read_rows(n, count),
    do: Enum.map(1..count, &([&1 | values(n)] ++ [&1, <<?a + &1 - 1>>]))

  defp act(:close, stream, _state) do
    assert :ok = XqliteNIF.stream_close(stream)
    {[], nil}
  end

  defp act({call, k}, stream, state) do
    {expected, next} = fetch(state, k)
    assert expected == shape(raw_fetch(call, stream, k))
    next
  end

  defp fetch({rest, nil}, k) do
    {batch, rest} = Enum.split(rest, k)
    {rows, ending} = Enum.split_while(batch, &is_list/1)
    fetched(rows, ending, rest)
  end

  defp fetch({[], pending}, _k), do: {pending, {[], nil}}

  defp fetched([], [], []), do: {:done, {[], nil}}
  defp fetched(rows, [], rest), do: {{:ok, %{rows: rows}}, {rest, nil}}
  defp fetched([], [ending], []), do: {ending, {[], nil}}
  defp fetched(rows, [:done], []), do: {{:ok, %{rows: rows}}, {[], nil}}
  defp fetched(rows, [error], []), do: {{:ok, %{rows: rows}}, {[], error}}

  defp raw_fetch(:fetch, stream, k), do: XqliteNIF.stream_fetch(stream, k)

  defp raw_fetch(:cancellable, stream, k),
    do: XqliteNIF.stream_fetch_cancellable(stream, k, [])

  defp pass(:raise, stream, k, rows, {:error, _reason} = error) when k > length(rows) do
    raised = assert_raise Xqlite.StreamError, fn -> Enum.take(stream, k) end
    assert error == shape({:error, raised.reason})
  end

  defp pass(:halt, stream, k, rows, {:error, _reason}) when k > length(rows) do
    assert {^rows, log} = with_log(fn -> Enum.take(stream, k) end)
    assert log != ""
  end

  defp pass(:emit_error, stream, k, rows, ending) do
    expected = Enum.map(rows, &{:ok, &1}) ++ List.delete([ending], :done)
    assert Enum.take(expected, k) == stream |> Enum.take(k) |> Enum.map(&shape/1)
  end

  defp pass(_mode, stream, k, rows, _ending),
    do: assert(Enum.take(rows, k) == Enum.take(stream, k))

  defp row_map(:read, n, row),
    do: @select[n] |> String.split(", ") |> Enum.zip(row) |> Map.new()

  defp row_map(:returning, _n, row), do: ~w(id v w x) |> Enum.zip(row) |> Map.new()

  defp applied(kind, :none, true, n) when kind != :read, do: effect(n)
  defp applied(_kind, _trouble, _ran?, _n), do: []

  defp effect(0), do: ["!"]
  defp effect(n), do: values(n)

  defp table(effect) do
    for {id, letter} <- [{1, "a"}, {2, "b"}, {3, "c"}] do
      [id | for(i <- 0..2, do: letter <> to_string(Enum.at(effect, i, "")))]
    end
  end

  defp assert_table(_conn, :read, _effect), do: :ok

  defp assert_table(conn, _write, effect) do
    assert {:ok, %{rows: rows}} = Xqlite.query(conn, "SELECT id, v, w, x FROM t ORDER BY id")
    assert table(effect) == rows
  end

  defp shape({:error, {:sqlite_failure, code, extended, _message}}),
    do: {:error, {:sqlite_failure, code, extended}}

  defp shape({:error, {:utf8_error, column, _reason}}), do: {:error, {:utf8_error, column}}
  defp shape(answer), do: answer
end
