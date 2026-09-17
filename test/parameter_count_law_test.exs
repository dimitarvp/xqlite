defmodule Xqlite.ParameterCountLawTest do
  @moduledoc """
  Every door that takes a list of positional parameters counts it the same
  way: a list whose length differs from the statement's own parameter count
  is refused with `{:invalid_parameter_count, %{expected: _, provided: _}}`
  before a single value is bound.

  SQLite itself never complains about a short list — a parameter nothing was
  bound to reads as NULL — so `UPDATE t SET v = ?1` handed an empty list
  quietly writes NULL over every row. The statement under test is therefore
  an UPDATE and the stored row is the oracle: it moved exactly when the call
  ran, and it is untouched after every refusal.

  The `expected` number is the same on every door. The `provided` number is
  not, for a list two or more elements too long: a door binding through
  rusqlite stops at the first index the statement does not have and reports
  that index, while a door binding through the raw C API measures the list
  and reports its length.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  # The doors split by who counts the list. A door that binds through
  # rusqlite stops at the first parameter index the statement does not have,
  # so a list two or more elements too long is reported as one element too
  # long; a door that binds through the raw C API counts the list itself and
  # reports its real length. Both refuse, and both name the same `expected`.
  @counted_whole [
    :stream,
    :bind_step,
    :explain_analyze,
    :nif_stream_open,
    :nif_explain_analyze,
    :nif_stmt_bind
  ]

  @counted_until_first_extra [
    :query,
    :execute,
    :query_cancellable,
    :execute_cancellable,
    :query_with_changes_cancellable,
    :nif_query,
    :nif_execute,
    :nif_query_with_changes,
    :nif_query_cancellable,
    :nif_execute_cancellable,
    :nif_query_with_changes_cancellable
  ]

  @doors @counted_whole ++ @counted_until_first_extra

  for_each_opener "the positional parameter count" do
    setup %{conn: conn} do
      assert {:ok, _} = NIF.set_pragma(conn, "journal_mode", "MEMORY")
      assert {:ok, _} = NIF.set_pragma(conn, "synchronous", "OFF")

      assert :ok =
               NIF.execute_batch(
                 conn,
                 """
                 CREATE TABLE count_rows (id INTEGER PRIMARY KEY, v TEXT);
                 INSERT INTO count_rows (id, v) VALUES (1, 'seed');
                 """
               )

      :ok
    end

    test "the anchor: a list one element short through a stream writes nothing",
         %{conn: conn} do
      sql = "UPDATE count_rows SET v = ?2 WHERE id = ?1"

      assert {:error, {:invalid_parameter_count, %{expected: 2, provided: 1}}} =
               Xqlite.stream(conn, sql, [1])

      assert "seed" == stored(conn)
    end

    test "an empty list on a statement that takes one parameter is refused everywhere",
         %{conn: conn} do
      sql = "UPDATE count_rows SET v = ?1"

      for door <- @doors do
        reseed(conn)

        assert {:refused, 1, 0} == shape(call(door, conn, sql, [])),
               "door #{inspect(door)} accepted an empty list"

        assert "seed" == stored(conn)
      end
    end

    test "a list two elements too long is refused, counted the door's own way",
         %{conn: conn} do
      sql = "UPDATE count_rows SET v = ?1"

      assert {:error, {:invalid_parameter_count, %{expected: 1, provided: 3}}} =
               Xqlite.stream(conn, sql, ["a", "b", "c"])

      assert {:error, {:invalid_parameter_count, %{expected: 1, provided: 2}}} =
               Xqlite.query(conn, sql, ["a", "b", "c"])

      assert "seed" == stored(conn)
    end

    property "a list of the wrong length is refused by every door, and nothing moves",
             %{conn: conn} do
      check all(
              expected <- integer(0..3),
              provided <- integer(0..4),
              door <- member_of(@doors),
              max_runs: 2000
            ) do
        reseed(conn)
        values = values_for(provided)
        answer = shape(call(door, conn, sql_for(expected), values))

        case provided == expected do
          true ->
            assert :ran == answer
            assert ran_value(expected, values) == stored(conn)

          false ->
            assert {:refused, expected, reported(door, expected, provided)} == answer
            assert "seed" == stored(conn)
        end
      end
    end
  end

  # An UPDATE whose new value is built out of exactly `count` positional
  # parameters, so SQLite's own parameter count for the statement is `count`.
  defp sql_for(0), do: "UPDATE count_rows SET v = 'ran'"

  defp sql_for(count) do
    placeholders = Enum.map_join(1..count, " || ", fn index -> "?#{index}" end)
    "UPDATE count_rows SET v = " <> placeholders
  end

  defp values_for(count), do: Enum.map(1..count//1, fn index -> "v#{index}" end)

  defp ran_value(0, _values), do: "ran"
  defp ran_value(_count, values), do: Enum.join(values)

  # How many values the refusal says it was given.
  defp reported(door, expected, provided) do
    case door in @counted_whole do
      true -> provided
      false -> min(provided, expected + 1)
    end
  end

  defp reseed(conn) do
    assert {:ok, _changes} = Xqlite.execute(conn, "UPDATE count_rows SET v = 'seed'", [])
  end

  defp stored(conn) do
    assert {:ok, %{rows: [[value]]}} =
             Xqlite.query(conn, "SELECT v FROM count_rows WHERE id = 1", [])

    value
  end

  # The answers, stripped of everything a law must not depend on.
  defp shape(:ok), do: :ran
  defp shape({:ok, _payload}), do: :ran

  defp shape({:error, {:invalid_parameter_count, %{expected: expected, provided: provided}}}),
    do: {:refused, expected, provided}

  defp shape(other), do: {:unexpected, other}

  defp call(:query, conn, sql, params), do: Xqlite.query(conn, sql, params)
  defp call(:execute, conn, sql, params), do: Xqlite.execute(conn, sql, params)
  defp call(:explain_analyze, conn, sql, params), do: Xqlite.explain_analyze(conn, sql, params)
  defp call(:nif_query, conn, sql, params), do: NIF.query(conn, sql, params)
  defp call(:nif_execute, conn, sql, params), do: NIF.execute(conn, sql, params)

  defp call(:nif_query_with_changes, conn, sql, params),
    do: NIF.query_with_changes(conn, sql, params)

  defp call(:nif_explain_analyze, conn, sql, params),
    do: NIF.explain_analyze(conn, sql, params)

  defp call(:query_cancellable, conn, sql, params),
    do: Xqlite.query_cancellable(conn, sql, params, new_token())

  defp call(:execute_cancellable, conn, sql, params),
    do: Xqlite.execute_cancellable(conn, sql, params, new_token())

  defp call(:query_with_changes_cancellable, conn, sql, params),
    do: Xqlite.query_with_changes_cancellable(conn, sql, params, new_token())

  defp call(:nif_query_cancellable, conn, sql, params),
    do: NIF.query_cancellable(conn, sql, params, [new_token()])

  defp call(:nif_execute_cancellable, conn, sql, params),
    do: NIF.execute_cancellable(conn, sql, params, [new_token()])

  defp call(:nif_query_with_changes_cancellable, conn, sql, params),
    do: NIF.query_with_changes_cancellable(conn, sql, params, [new_token()])

  defp call(:stream, conn, sql, params) do
    conn
    |> Xqlite.stream(sql, params)
    |> consume_stream()
  end

  defp call(:nif_stream_open, conn, sql, params) do
    conn
    |> NIF.stream_open(sql, params)
    |> drain_stream()
  end

  defp call(:bind_step, conn, sql, params) do
    assert {:ok, stmt} = Xqlite.prepare(conn, sql)
    answer = step_after_bind(stmt, Xqlite.bind(stmt, params))
    assert :ok = Xqlite.finalize(stmt)
    answer
  end

  defp call(:nif_stmt_bind, conn, sql, params) do
    assert {:ok, stmt} = NIF.stmt_prepare(conn, sql)
    answer = step_after_bind(stmt, NIF.stmt_bind(stmt, params))
    assert :ok = NIF.stmt_finalize(stmt)
    answer
  end

  defp step_after_bind(stmt, :ok) do
    assert :done = Xqlite.step(stmt)
    :ok
  end

  defp step_after_bind(_stmt, {:error, _reason} = error), do: error

  # An UPDATE runs when its stream is consumed, not when it is opened.
  defp consume_stream({:error, _reason} = error), do: error

  defp consume_stream(stream) do
    assert [] == Enum.to_list(stream)
    :ok
  end

  defp drain_stream({:error, _reason} = error), do: error

  defp drain_stream({:ok, handle}) do
    assert :done = NIF.stream_fetch(handle, 10)
    assert :ok = NIF.stream_close(handle)
    :ok
  end

  defp new_token do
    assert {:ok, token} = Xqlite.create_cancel_token()
    token
  end
end
