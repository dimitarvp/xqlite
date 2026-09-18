defmodule Xqlite.ParameterCoverageLawTest do
  @moduledoc """
  Every door that takes parameters judges the list the same way, before a
  single value is bound.

  A plain list is positional: its length must be the statement's own
  parameter count, otherwise `{:invalid_parameter_count, %{expected: _,
  provided: _}}`. Both numbers are the same on every door, and every door
  measures the list before it binds anything, so `provided` is the list's
  own length even when the list is longer than the statement can take.

  A keyword list is named and must name every parameter of the statement,
  each exactly once. Three refusals, in this order: a key the statement does
  not have is `{:invalid_parameter_name, key}`, two keys naming the same
  parameter are `{:duplicate_parameter_name, key}`, and a parameter no key
  named is `{:missing_parameter, %{index: _, name: _}}` for the lowest such
  index, `name` being SQLite's own spelling of it and `nil` for a bare `?`,
  which no keyword list can name.

  SQLite itself complains about neither shape — a parameter nothing was
  bound to reads as NULL — so `UPDATE t SET v = ?1` handed an empty list,
  and `UPDATE t SET a = :a, b = :b` handed `[a: "x"]`, quietly write NULL.
  The statement under test is therefore an UPDATE and the stored row is the
  oracle: it moved exactly when the call ran, and it is untouched after
  every refusal.

  A key names a parameter by its own spelling when it already carries one of
  SQLite's three name prefixes, and by the `:` spelling otherwise: `[a: 1]`
  names `:a`, `[{:"@b", 1}]` names `@b` and `[{:"$c", 1}]` names `$c`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  @doors [
    :stream,
    :bind_step,
    :explain_analyze,
    :nif_stream_open,
    :nif_explain_analyze,
    :nif_stmt_bind,
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

  for_each_opener "the parameter list" do
    setup %{conn: conn} do
      assert {:ok, _} = NIF.set_pragma(conn, "journal_mode", "MEMORY")
      assert {:ok, _} = NIF.set_pragma(conn, "synchronous", "OFF")

      assert :ok =
               NIF.execute_batch(
                 conn,
                 """
                 CREATE TABLE count_rows (id INTEGER PRIMARY KEY, v TEXT);
                 INSERT INTO count_rows (id, v) VALUES (1, 'seed');
                 CREATE TABLE pair_rows (id INTEGER PRIMARY KEY, a TEXT, b TEXT);
                 INSERT INTO pair_rows (id, a, b) VALUES (1, 'keep_a', 'keep_b');
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

    test "a list two elements too long is refused, counted the same on every door",
         %{conn: conn} do
      sql = "UPDATE count_rows SET v = ?1"

      assert {:error, {:invalid_parameter_count, %{expected: 1, provided: 3}}} =
               Xqlite.stream(conn, sql, ["a", "b", "c"])

      assert {:error, {:invalid_parameter_count, %{expected: 1, provided: 3}}} =
               Xqlite.query(conn, sql, ["a", "b", "c"])

      assert {:error, {:invalid_parameter_count, %{expected: 1, provided: 3}}} =
               Xqlite.execute(conn, sql, ["a", "b", "c"])

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
            assert {:refused, expected, provided} == answer
            assert "seed" == stored(conn)
        end
      end
    end

    test "the anchor: a keyword list that leaves a name out writes nothing",
         %{conn: conn} do
      sql = "UPDATE pair_rows SET a = :a, b = :b WHERE id = 1"
      params = [a: "new_a"]

      assert {:error, {:missing_parameter, %{index: 2, name: ":b"}}} =
               Xqlite.query(conn, sql, params)

      assert ["keep_a", "keep_b"] == pair(conn)
    end

    test "a key that names the same parameter twice is refused", %{conn: conn} do
      sql = "UPDATE count_rows SET v = :a"
      params = [a: "one", a: "two"]

      assert {:error, {:duplicate_parameter_name, ":a"}} = Xqlite.query(conn, sql, params)
      assert "seed" == stored(conn)

      spelled = [{:a, "one"}, {:":a", "two"}]
      assert {:error, {:duplicate_parameter_name, ":a"}} = Xqlite.query(conn, sql, spelled)
      assert "seed" == stored(conn)
    end

    test "the same name twice in the SQL is one parameter with one value", %{conn: conn} do
      params = [a: 1]

      assert {:ok, %{rows: [[1, 1]]}} = Xqlite.query(conn, "SELECT :a, :a", params)
    end

    test "a parameter no keyword list can name is refused by its index", %{conn: conn} do
      params = [a: 1]

      assert {:error, {:missing_parameter, %{index: 1, name: nil}}} =
               Xqlite.query(conn, "SELECT ?, :a", params)

      assert {:error, {:missing_parameter, %{index: 2, name: "?2"}}} =
               Xqlite.query(conn, "SELECT :a, ?2, ?3", params)

      # A statement of nothing but unnamed parameters has no key to resolve
      # the list against, so the key is refused before anything is missing.
      assert {:error, {:invalid_parameter_name, ":a"}} =
               Xqlite.query(conn, "SELECT ?", params)
    end

    test "a key already carrying a name prefix is used as written", %{conn: conn} do
      covered = [a: 1, "@b": 2, "$c": 3]

      assert {:ok, %{rows: [[1, 2, 3]]}} =
               Xqlite.query(conn, "SELECT :a, @b, $c", covered)

      short = [a: 1, "$c": 3]

      assert {:error, {:missing_parameter, %{index: 2, name: "@b"}}} =
               Xqlite.query(conn, "SELECT :a, @b, $c", short)
    end

    test "a key the statement lacks is refused before a name that is missing",
         %{conn: conn} do
      sql = "UPDATE pair_rows SET a = :a, b = :b WHERE id = 1"

      assert {:error, {:invalid_parameter_name, ":z"}} = Xqlite.query(conn, sql, z: 1)

      assert {:error, {:invalid_parameter_name, ":z"}} =
               Xqlite.query(conn, sql, a: "new_a", z: 1)

      assert ["keep_a", "keep_b"] == pair(conn)
    end

    property "a keyword list is refused unless it names every parameter once",
             %{conn: conn} do
      check all(
              {prefixes, shape} <- named_case(),
              door <- member_of(@doors),
              max_runs: 2000
            ) do
        reseed(conn)
        names = names_for(prefixes)
        params = named_params(names, shape)
        answer = shape(call(door, conn, named_sql(names), params))

        assert named_expectation(names, shape) == answer
        assert named_stored(names, shape) == stored(conn)
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

  defp reseed(conn) do
    assert {:ok, _changes} = Xqlite.execute(conn, "UPDATE count_rows SET v = 'seed'", [])
  end

  defp stored(conn) do
    assert {:ok, %{rows: [[value]]}} =
             Xqlite.query(conn, "SELECT v FROM count_rows WHERE id = 1", [])

    value
  end

  defp pair(conn) do
    assert {:ok, %{rows: [[a, b]]}} =
             Xqlite.query(conn, "SELECT a, b FROM pair_rows WHERE id = 1", [])

    [a, b]
  end

  # A statement of 1 to 4 named parameters, each in one of SQLite's three
  # name spellings, and a keyword list for it: one that keeps some of the
  # names (`keeps`), or one that covers them all and names one twice.
  defp named_case do
    bind(list_of(member_of([":", "@", "$"]), length: 1..4), fn prefixes ->
      count = length(prefixes)

      one_of([
        map(list_of(boolean(), length: count), fn keeps -> {prefixes, {:keeps, keeps}} end),
        map(integer(1..count), fn position -> {prefixes, {:repeat, position}} end)
      ])
    end)
  end

  defp names_for(prefixes) do
    prefixes
    |> Enum.with_index(1)
    |> Enum.map(fn {prefix, position} -> prefix <> "p#{position}" end)
  end

  defp named_sql(names) do
    "UPDATE count_rows SET v = " <> Enum.join(names, " || ")
  end

  # A `:` name is written as the bare key the prefix rule completes; an `@`
  # or `$` name needs the key to carry the prefix itself.
  defp key_for(":" <> rest), do: String.to_atom(rest)
  defp key_for(name), do: String.to_atom(name)

  defp value_for(position), do: "v#{position}"

  defp named_params(names, {:keeps, keeps}) do
    names
    |> Enum.zip(keeps)
    |> Enum.with_index(1)
    |> Enum.filter(fn {{_name, keep}, _position} -> keep end)
    |> Enum.map(fn {{name, _keep}, position} -> {key_for(name), value_for(position)} end)
  end

  defp named_params(names, {:repeat, position}) do
    full = named_params(names, {:keeps, Enum.map(names, fn _name -> true end)})
    assert {:ok, name} = Enum.fetch(names, position - 1)
    full ++ [{key_for(name), value_for(position)}]
  end

  defp named_expectation(names, {:keeps, keeps}) do
    case Enum.find_index(keeps, fn keep -> not keep end) do
      nil -> :ran
      _dropped -> dropped_expectation(names, keeps)
    end
  end

  defp named_expectation(names, {:repeat, position}) do
    assert {:ok, name} = Enum.fetch(names, position - 1)
    {:duplicate, name}
  end

  # A keyword list that keeps nothing is an empty list, which every door
  # reads as zero parameters and counts.
  defp dropped_expectation(names, keeps) do
    case Enum.any?(keeps) do
      false ->
        {:refused, length(names), 0}

      true ->
        index = Enum.find_index(keeps, fn keep -> not keep end) + 1
        assert {:ok, name} = Enum.fetch(names, index - 1)
        {:missing, index, name}
    end
  end

  defp named_stored(names, {:keeps, keeps} = shape) do
    case named_expectation(names, shape) do
      :ran -> Enum.map_join(1..length(keeps), fn position -> value_for(position) end)
      _refused -> "seed"
    end
  end

  defp named_stored(_names, {:repeat, _position}), do: "seed"

  # The answers, stripped of everything a law must not depend on.
  defp shape(:ok), do: :ran
  defp shape({:ok, _payload}), do: :ran

  defp shape({:error, {:invalid_parameter_count, %{expected: expected, provided: provided}}}),
    do: {:refused, expected, provided}

  defp shape({:error, {:missing_parameter, %{index: index, name: name}}}),
    do: {:missing, index, name}

  defp shape({:error, {:duplicate_parameter_name, name}}), do: {:duplicate, name}

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
