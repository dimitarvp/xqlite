defmodule Xqlite.BindPartwayTest do
  @moduledoc """
  A bind SQLite rejects after it has taken some of the values leaves the
  statement unrunnable: a step answers `{:parameters_unbound, %{expected: n}}`
  until a bind succeeds or `clear_bindings/1` runs, and nothing is written.
  SQLite rejects here a text over the process's heap limit but under the
  connection's `:length`; after `:done` the bind resets first and fails the
  same way. `PRAGMA hard_heap_limit` holds for the whole OS process and only
  goes down, so it lives in this file alone: `mix test.seq` gives each file
  its own process.
  """

  use ExUnit.Case, async: true

  import Xqlite.ConnCase

  @heap_limit 16_000_000
  @seed "CREATE TABLE t (id INTEGER PRIMARY KEY, v, w, x); " <>
          "INSERT INTO t VALUES (1, 'a', 'a', 'a'), (2, 'b', 'b', 'b');"

  for_each_opener "a bind SQLite rejects part-way" do
    setup %{conn: conn} do
      assert {:ok, @heap_limit} = Xqlite.Pragma.put(conn, :hard_heap_limit, @heap_limit)
      assert :ok = Xqlite.execute_batch(conn, @seed)
      assert {:ok, stmt} = Xqlite.prepare(conn, "UPDATE t SET v = :a, w = :b, x = :c")
      assert :ok = Xqlite.bind(stmt, ["P", "Q", "R"])
      %{stmt: stmt}
    end

    test "the anchor: a list rejected at its last value leaves nothing to run",
         %{conn: conn, stmt: stmt} do
      assert {:error, {:sqlite_failure, 7, 7, _nomem}} =
               Xqlite.bind(stmt, ["S", "T", too_big()])

      assert {:error, {:parameters_unbound, %{expected: 3}}} = Xqlite.step(stmt)
      assert [["a", "a", "a"], ["b", "b", "b"]] == stored(conn)
      assert :ok = Xqlite.bind(stmt, ["S", "T", "U"])
      assert :done = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
      assert [["S", "T", "U"], ["S", "T", "U"]] == stored(conn)
    end

    test "a keyword list rejected at its first value, then a clear", %{conn: conn, stmt: stmt} do
      assert {:error, {:sqlite_failure, 7, 7, _nomem}} =
               Xqlite.bind(stmt, c: too_big(), a: "S", b: "T")

      assert {:error, {:parameters_unbound, %{expected: 3}}} = Xqlite.step(stmt)
      assert [["a", "a", "a"], ["b", "b", "b"]] == stored(conn)
      assert :ok = Xqlite.clear_bindings(stmt)
      assert :done = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
      assert [[nil, nil, nil], [nil, nil, nil]] == stored(conn)
    end

    test "after :done a rejected bind leaves the last run's writes and nothing to run",
         %{conn: conn, stmt: stmt} do
      assert :done = Xqlite.step(stmt)

      assert {:error, {:sqlite_failure, 7, 7, _nomem}} =
               Xqlite.bind(stmt, ["S", "T", too_big()])

      assert {:error, {:parameters_unbound, %{expected: 3}}} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
      assert [["P", "Q", "R"], ["P", "Q", "R"]] == stored(conn)
    end
  end

  defp too_big, do: :binary.copy("z", 2 * @heap_limit)

  defp stored(conn) do
    assert {:ok, %{rows: rows}} = Xqlite.query(conn, "SELECT v, w, x FROM t ORDER BY id")
    rows
  end
end
