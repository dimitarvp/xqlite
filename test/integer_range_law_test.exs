defmodule Xqlite.IntegerRangeLawTest do
  @moduledoc """
  SQLite stores an integer in 64 signed bits, and Elixir's integers have no
  size at all, so a parameter can be a number SQLite has no room for.

  The law: every door that takes parameters refuses such a number with
  `{:error, {:integer_out_of_range, %{position: n}}}`, `n` being the value's
  one-based place in the list the caller passed, whether the list is
  positional or a keyword list. Nothing is bound and nothing runs. The raw
  PRAGMA setter judges a single value rather than a list, so its answer is
  the same tag with an empty map.

  The boundaries themselves are inside the range and bind like any other
  number: `-9223372036854775808` and `9223372036854775807`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  @min_integer -9_223_372_036_854_775_808
  @max_integer 9_223_372_036_854_775_807

  @doors [
    :query,
    :execute,
    :bind,
    :stream,
    :nif_query_with_changes,
    :nif_stmt_bind,
    :nif_stream_open,
    :nif_explain_analyze
  ]

  for_each_opener "an integer SQLite has no room for" do
    setup %{conn: conn} do
      assert :ok =
               Xqlite.execute_batch(
                 conn,
                 "CREATE TABLE int_rows (id INTEGER PRIMARY KEY, v); " <>
                   "INSERT INTO int_rows (id, v) VALUES (1, 'seed');"
               )

      :ok
    end

    test "the anchor: a number one past the top is refused by its position",
         %{conn: conn} do
      assert {:error, {:integer_out_of_range, %{position: 2}}} =
               Xqlite.query(conn, "SELECT ?1, ?2", [1, @max_integer + 1])

      assert {:error, {:integer_out_of_range, %{position: 1}}} =
               Xqlite.query(conn, "SELECT ?1", [@min_integer - 1])

      assert {:error, {:integer_out_of_range, %{position: 1}}} =
               Xqlite.query(conn, "SELECT :a", a: 10 ** 40)
    end

    test "the anchor: both boundaries bind", %{conn: conn} do
      assert {:ok, %{rows: [[@min_integer, @max_integer]]}} =
               Xqlite.query(conn, "SELECT ?1, ?2", [@min_integer, @max_integer])
    end

    test "the raw PRAGMA setter answers without a position", %{conn: conn} do
      assert {:error, {:integer_out_of_range, details}} =
               NIF.set_pragma(conn, "user_version", @max_integer + 1)

      assert %{} == details
      assert {:ok, _value} = NIF.set_pragma(conn, "user_version", 7)
    end

    test "nothing is written when a value in the middle is out of range",
         %{conn: conn} do
      sql = "UPDATE int_rows SET v = ?1 || ?2 || ?3"

      assert {:error, {:integer_out_of_range, %{position: 2}}} =
               Xqlite.execute(conn, sql, [1, @max_integer + 1, 3])

      assert "seed" == stored(conn)
    end

    property "every parameter door refuses it by its position", %{conn: conn} do
      check all(
              count <- integer(1..4),
              position <- integer(1..count),
              value <- out_of_range(),
              shape <- member_of([:positional, :named]),
              door <- member_of(@doors),
              max_runs: 2000
            ) do
        reseed(conn)
        sql = sql_for(shape, count)
        params = params_for(shape, count, position, value)

        assert {door, {:error, {:integer_out_of_range, %{position: position}}}} ==
                 {door, call(door, conn, sql, params)}

        assert "seed" == stored(conn)
      end
    end

    property "the raw PRAGMA setter refuses it whatever the number", %{conn: conn} do
      check all(value <- out_of_range(), max_runs: 2000) do
        assert {:error, {:integer_out_of_range, %{}}} =
                 NIF.set_pragma(conn, "user_version", value)
      end
    end
  end

  # Just past each end of the range, and powers of two far beyond both.
  defp out_of_range do
    one_of([
      map(integer(0..1_000_000), fn step -> @max_integer + 1 + step end),
      map(integer(0..1_000_000), fn step -> @min_integer - 1 - step end),
      map(integer(64..512), fn bits -> 1 <<< bits end),
      map(integer(64..512), fn bits -> -(1 <<< bits) end)
    ])
  end

  defp sql_for(:positional, count) do
    "UPDATE int_rows SET v = " <> Enum.map_join(1..count, " || ", fn i -> "?#{i}" end)
  end

  defp sql_for(:named, count) do
    "UPDATE int_rows SET v = " <> Enum.map_join(1..count, " || ", fn i -> ":p#{i}" end)
  end

  defp params_for(:positional, count, position, value) do
    Enum.map(1..count, fn index -> value_at(index, position, value) end)
  end

  defp params_for(:named, count, position, value) do
    Enum.map(1..count, fn index -> {:"p#{index}", value_at(index, position, value)} end)
  end

  defp value_at(index, index, value), do: value
  defp value_at(index, _position, _value), do: index

  defp reseed(conn) do
    assert {:ok, _changes} = Xqlite.execute(conn, "UPDATE int_rows SET v = 'seed'", [])
  end

  defp stored(conn) do
    assert {:ok, %{rows: [[value]]}} =
             Xqlite.query(conn, "SELECT v FROM int_rows WHERE id = 1")

    value
  end

  defp call(:query, conn, sql, params), do: Xqlite.query(conn, sql, params)
  defp call(:execute, conn, sql, params), do: Xqlite.execute(conn, sql, params)
  defp call(:stream, conn, sql, params), do: Xqlite.stream(conn, sql, params)

  defp call(:nif_query_with_changes, conn, sql, params),
    do: NIF.query_with_changes(conn, sql, params)

  defp call(:nif_stream_open, conn, sql, params), do: NIF.stream_open(conn, sql, params)

  defp call(:nif_explain_analyze, conn, sql, params),
    do: NIF.explain_analyze(conn, sql, params)

  defp call(:bind, conn, sql, params) do
    assert {:ok, stmt} = Xqlite.prepare(conn, sql)
    answer = Xqlite.bind(stmt, params)
    assert :ok = Xqlite.finalize(stmt)
    answer
  end

  defp call(:nif_stmt_bind, conn, sql, params) do
    assert {:ok, stmt} = NIF.stmt_prepare(conn, sql)
    answer = NIF.stmt_bind(stmt, params)
    assert :ok = NIF.stmt_finalize(stmt)
    answer
  end
end
