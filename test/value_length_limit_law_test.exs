defmodule Xqlite.ValueLengthLimitLawTest do
  @moduledoc """
  A connection carries a limit on how long one TEXT or BLOB value may be
  (`Xqlite.limit/3` with `:length`, SQLite's `SQLITE_LIMIT_LENGTH`), and the
  library judges every value against it before it binds anything.

  The law: every door that takes parameters refuses a value longer than the
  connection's limit with
  `{:error, {:value_too_large, %{byte_size: bytes, limit: limit}}}`, wherever
  in the list that value sits, and nothing is bound and nothing runs — the
  stored row is the oracle. A value shorter than the limit binds like any
  other.

  A value of exactly the limit binds, and is still not the end of the story:
  SQLite checks the same limit again while it runs, against the row it builds,
  so a statement that stores a value at the limit answers
  `{:error, {:too_big, 18, message}}` at the step. That is SQLite's own
  refusal of a row, not the library's refusal of a parameter, and the two tags
  say which is which.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  # SQLite raises a `:length` under 30 to 30 behind the caller's back, so the
  # generated limits start there.
  @lowest_limit 30

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

  @writing_doors [:query, :execute, :nif_query_with_changes]

  for_each_opener "a value longer than the connection's limit" do
    setup %{conn: conn} do
      assert :ok =
               Xqlite.execute_batch(
                 conn,
                 "CREATE TABLE len_rows (id INTEGER PRIMARY KEY, v); " <>
                   "INSERT INTO len_rows (id, v) VALUES (1, 'seed');"
               )

      :ok
    end

    test "the anchor: one byte over the limit is refused and nothing is written",
         %{conn: conn} do
      assert {:ok, _previous} = Xqlite.limit(conn, :length, 64)

      assert {:error, {:value_too_large, %{byte_size: 65, limit: 64}}} =
               Xqlite.execute(conn, "UPDATE len_rows SET v = ?1 || ?2", [
                 1,
                 String.duplicate("x", 65)
               ])

      assert "seed" == stored(conn)
    end

    test "the anchor: a value under the limit binds and is stored", %{conn: conn} do
      assert {:ok, _previous} = Xqlite.limit(conn, :length, 64)

      assert {:ok, %{changes: 1}} =
               Xqlite.execute(conn, "UPDATE len_rows SET v = ?1", [String.duplicate("x", 20)])

      assert String.duplicate("x", 20) == stored(conn)
    end

    test "a value of exactly the limit binds, and the row it builds does not fit",
         %{conn: conn} do
      assert {:ok, _previous} = Xqlite.limit(conn, :length, 64)
      assert {:ok, stmt} = Xqlite.prepare(conn, "UPDATE len_rows SET v = ?1")

      assert :ok = Xqlite.bind(stmt, [String.duplicate("x", 64)])
      assert {:error, {:too_big, 18, message}} = Xqlite.step(stmt)
      assert is_binary(message)
      assert :ok = Xqlite.finalize(stmt)
      assert "seed" == stored(conn)
    end

    test "a BLOB is judged by its bytes like a TEXT value", %{conn: conn} do
      assert {:ok, _previous} = Xqlite.limit(conn, :length, 64)

      assert {:error, {:value_too_large, %{byte_size: 70, limit: 64}}} =
               Xqlite.query(conn, "SELECT ?1", [%Xqlite.Blob{bytes: :binary.copy(<<0>>, 70)}])
    end

    property "every door refuses a value over the limit, wherever it sits",
             %{conn: conn} do
      check all(
              limit <- integer(@lowest_limit..256),
              over <- integer(1..8),
              count <- integer(1..4),
              position <- integer(1..count),
              shape <- member_of([:positional, :named]),
              door <- member_of(@doors),
              max_runs: 2000
            ) do
        reseed(conn)
        assert {:ok, _previous} = Xqlite.limit(conn, :length, limit)
        byte_size = limit + over
        value = String.duplicate("x", byte_size)
        sql = sql_for(shape, count)
        params = params_for(shape, count, position, value)

        assert {door, {:error, {:value_too_large, %{byte_size: byte_size, limit: limit}}}} ==
                 {door, call(door, conn, sql, params)}

        assert "seed" == stored(conn)
      end
    end

    property "a value under the limit binds, and the row is what it concatenates",
             %{conn: conn} do
      check all(
              limit <- integer(@lowest_limit..256),
              count <- integer(1..4),
              position <- integer(1..count),
              shape <- member_of([:positional, :named]),
              door <- member_of(@writing_doors),
              max_runs: 2000
            ) do
        reseed(conn)
        assert {:ok, _previous} = Xqlite.limit(conn, :length, limit)
        # A third of the limit leaves the row it builds room to fit too.
        value = String.duplicate("x", div(limit, 3))
        sql = sql_for(shape, count)
        params = params_for(shape, count, position, value)

        assert {door, true} == {door, accepted?(call(door, conn, sql, params))}
        assert concatenated(count, position, value) == stored(conn)
      end
    end
  end

  defp sql_for(:positional, count) do
    "UPDATE len_rows SET v = " <> Enum.map_join(1..count, " || ", fn i -> "?#{i}" end)
  end

  defp sql_for(:named, count) do
    "UPDATE len_rows SET v = " <> Enum.map_join(1..count, " || ", fn i -> ":p#{i}" end)
  end

  defp params_for(:positional, count, position, value) do
    Enum.map(1..count, fn index -> value_at(index, position, value) end)
  end

  defp params_for(:named, count, position, value) do
    Enum.map(1..count, fn index -> {:"p#{index}", value_at(index, position, value)} end)
  end

  defp value_at(index, index, value), do: value
  defp value_at(index, _position, _value), do: index

  defp concatenated(count, position, value) do
    1..count
    |> Enum.map(fn index -> value_at(index, position, value) end)
    |> Enum.map_join("", &to_string/1)
  end

  defp accepted?(:ok), do: true
  defp accepted?({:ok, _answer}), do: true
  defp accepted?(_other), do: false

  defp reseed(conn) do
    assert {:ok, _previous} = Xqlite.limit(conn, :length, 2_147_483_647)
    assert {:ok, _changes} = Xqlite.execute(conn, "UPDATE len_rows SET v = 'seed'", [])
  end

  defp stored(conn) do
    assert {:ok, %{rows: [[value]]}} =
             Xqlite.query(conn, "SELECT v FROM len_rows WHERE id = 1")

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
