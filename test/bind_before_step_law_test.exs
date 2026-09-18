defmodule Xqlite.BindBeforeStepLawTest do
  @moduledoc """
  A prepared statement that takes parameters runs only once something has set
  them.

  SQLite reads a parameter nothing was bound to as NULL, so a statement
  stepped straight after `prepare/2` writes NULL into every column it touches,
  and a bind the library refused binds nothing at all, which leaves the
  statement in exactly that state. Both are refused here instead: `step/1`,
  `multi_step/2` and `multi_step_cancellable/3` answer
  `{:error, {:parameters_unbound, %{expected: n}}}` until a bind succeeds or
  `clear_bindings/1` asks for NULLs on purpose.

  The rule, over a statement of `n` parameters:

    * a statement with no parameters runs at once;
    * a successful bind makes it runnable, and so does `clear_bindings/1`;
    * a refused bind changes nothing — an earlier successful bind stays in
      force and a statement that never had one stays unrunnable;
    * `reset/1` changes nothing either, SQLite keeping the bindings across it.

  The row the step reads back is the oracle: it holds the values of the last
  successful bind, or NULL in every column after `clear_bindings/1`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  @moduletag timeout: 300_000

  @doors [:step, :multi_step, :multi_step_cancellable]

  for_each_opener "a step before a bind" do
    test "the anchor: a statement that takes a parameter is refused", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
      assert {:error, {:parameters_unbound, %{expected: 1}}} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "the anchor: a statement that takes none runs at once", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT 'no_parameters'")
      assert {:row, ["no_parameters"]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "clear_bindings is how a caller asks for NULLs", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1, ?2")
      assert {:error, {:parameters_unbound, %{expected: 2}}} = Xqlite.step(stmt)
      assert :ok = Xqlite.clear_bindings(stmt)
      assert {:row, [nil, nil]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "a refused bind leaves an earlier successful one in force", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1, ?2")
      assert :ok = Xqlite.bind(stmt, [7, 8])
      assert {:error, {:invalid_parameter_count, _}} = Xqlite.bind(stmt, [1])
      assert {:row, [7, 8]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "an UPDATE refused at the step writes nothing", %{conn: conn} do
      assert :ok = Xqlite.execute_batch(conn, seed_sql())
      assert {:ok, stmt} = Xqlite.prepare(conn, "UPDATE step_rows SET v = ?1")
      assert {:error, {:unsupported_data_type, :tuple}} = Xqlite.bind(stmt, [{:no}])
      assert {:error, {:parameters_unbound, %{expected: 1}}} = Xqlite.multi_step(stmt, 2)
      assert :ok = Xqlite.finalize(stmt)
      assert ["seed"] == stored(conn)
    end

    property "a step answers the rule whatever came before it", %{conn: conn} do
      check all(
              count <- integer(0..4),
              actions <- actions(count),
              door <- member_of(@doors),
              max_runs: 2000
            ) do
        assert {:ok, stmt} = Xqlite.prepare(conn, sql_for(count))
        state = Enum.reduce(actions, new_state(count), &act(&1, stmt, count, &2))
        answer = shape(call(door, stmt))

        assert expected(state, count) == answer
        assert :ok = Xqlite.finalize(stmt)
      end
    end
  end

  # A statement of `count` positional parameters, and one that takes none.
  defp sql_for(0), do: "SELECT 'no_parameters'"

  defp sql_for(count) do
    "SELECT " <> Enum.map_join(1..count, ", ", fn index -> "?#{index}" end)
  end

  defp seed_sql do
    "CREATE TABLE step_rows (id INTEGER PRIMARY KEY, v TEXT); " <>
      "INSERT INTO step_rows (id, v) VALUES (1, 'seed');"
  end

  defp stored(conn) do
    assert {:ok, %{rows: [row]}} = Xqlite.query(conn, "SELECT v FROM step_rows WHERE id = 1")
    row
  end

  # Everything a caller can do to a prepared statement short of stepping it.
  # A statement with no parameters has no value that could fail to convert.
  defp actions(0) do
    [:bind_ok, :refuse_count, :clear, :reset]
    |> member_of()
    |> list_of(max_length: 4)
  end

  defp actions(_count) do
    [:bind_ok, :refuse_count, :refuse_value, :clear, :reset]
    |> member_of()
    |> list_of(max_length: 4)
  end

  defp new_state(count), do: %{set?: count == 0, bound: nil, round: 0}

  defp act(:bind_ok, stmt, count, state) do
    round = state.round + 1
    values = values_for(count, round)
    assert :ok = Xqlite.bind(stmt, values)
    %{state | set?: true, bound: values, round: round}
  end

  defp act(:refuse_count, stmt, count, state) do
    assert {:error, {:invalid_parameter_count, _details}} =
             Xqlite.bind(stmt, values_for(count + 1, 0))

    state
  end

  defp act(:refuse_value, stmt, count, state) do
    values = List.replace_at(values_for(count, 0), count - 1, {:no})
    assert {:error, {:unsupported_data_type, :tuple}} = Xqlite.bind(stmt, values)
    state
  end

  defp act(:clear, stmt, count, state) do
    assert :ok = Xqlite.clear_bindings(stmt)
    %{state | set?: true, bound: List.duplicate(nil, count)}
  end

  defp act(:reset, stmt, _count, state) do
    assert :ok = Xqlite.reset(stmt)
    state
  end

  defp values_for(count, round), do: Enum.map(1..count//1, fn index -> round * 10 + index end)

  defp expected(%{set?: false}, count), do: {:unbound, count}
  defp expected(_state, 0), do: {:row, ["no_parameters"]}
  defp expected(%{bound: nil}, count), do: {:row, List.duplicate(nil, count)}
  defp expected(%{bound: values}, _count), do: {:row, values}

  defp call(:step, stmt), do: Xqlite.step(stmt)
  defp call(:multi_step, stmt), do: Xqlite.multi_step(stmt, 1)
  defp call(:multi_step_cancellable, stmt), do: Xqlite.multi_step_cancellable(stmt, 1, [])

  # The answers of the three doors, stripped to what the law is about.
  defp shape({:row, row}), do: {:row, row}
  defp shape({:ok, %{rows: [row], done: _done}}), do: {:row, row}
  defp shape({:error, {:parameters_unbound, %{expected: count}}}), do: {:unbound, count}
  defp shape(other), do: {:unexpected, other}
end
