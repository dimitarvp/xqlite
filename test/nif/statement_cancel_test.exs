defmodule Xqlite.NIF.StatementCancelTest do
  use ExUnit.Case, async: true

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  # The recursion bound is a never-reached ceiling: the mid-flight test
  # cancels ~30ms in, and even the fastest CI runner cannot count to a
  # billion first (a 1M bound DID lose that race on macOS runners). If
  # cancellation ever breaks, the test fails loudly via ExUnit timeout
  # rather than silently completing.
  #
  # Deliberately a single hardcoded in-memory connection instead of the
  # connection_openers/0 loop: cancellation is timing-sensitive and
  # connection-mode-agnostic — multiplying opener modes would only
  # multiply the flake surface this file was deflaked to remove.
  @slow_sql "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT count(*) FROM n"
  @tables "CREATE TABLE swept (id INTEGER PRIMARY KEY, v TEXT); CREATE TABLE marks (id);"
  @seed "DELETE FROM swept; DELETE FROM marks; INSERT INTO swept VALUES (1, ''), (2, ''), (3, '');"
  @read_back "SELECT (SELECT count(*) FROM marks), v FROM swept"

  setup do
    {:ok, conn} = Xqlite.open_in_memory()
    on_exit(fn -> NIF.close(conn) end)
    {:ok, conn: conn}
  end

  test "a signalled token cancels a running multi_step", %{conn: conn} do
    {:ok, stmt} = Xqlite.prepare(conn, @slow_sql)
    {:ok, token} = NIF.create_cancel_token()

    spawn(fn ->
      Process.sleep(30)
      :ok = NIF.cancel_operation(token)
    end)

    assert {:error, :operation_cancelled} = Xqlite.multi_step_cancellable(stmt, 10, token)

    :ok = Xqlite.finalize(stmt)
  end

  test "an already-signalled token cancels before any stepping", %{conn: conn} do
    {:ok, stmt} = Xqlite.prepare(conn, @slow_sql)
    {:ok, token} = NIF.create_cancel_token()
    :ok = NIF.cancel_operation(token)

    assert {:error, :operation_cancelled} = Xqlite.multi_step_cancellable(stmt, 1, [token])

    :ok = Xqlite.finalize(stmt)
  end

  test "an empty token list behaves like plain multi_step", %{conn: conn} do
    {:ok, stmt} = Xqlite.prepare(conn, "SELECT 1 UNION ALL SELECT 2")

    assert {:ok, %{rows: [[1], [2]], done: true}} =
             Xqlite.multi_step_cancellable(stmt, 10, [])

    :ok = Xqlite.finalize(stmt)
  end

  test "after cancellation the statement resets and runs again", %{conn: conn} do
    # A completable bound: this test's pin is statement REUSE after a
    # cancel (mid-flight cancellation itself is pinned above), so the
    # cancel half uses a pre-signalled token — deterministic at any
    # query size — and the rerun half must actually finish.
    sql =
      "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<1000000) " <>
        "SELECT count(*) FROM n"

    {:ok, stmt} = Xqlite.prepare(conn, sql)
    {:ok, token} = NIF.create_cancel_token()
    :ok = NIF.cancel_operation(token)

    {:error, :operation_cancelled} = Xqlite.multi_step_cancellable(stmt, 1, [token])

    :ok = Xqlite.reset(stmt)

    assert {:ok, %{rows: [[1_000_001]], done: true}} =
             Xqlite.multi_step_cancellable(stmt, 2, [])

    :ok = Xqlite.finalize(stmt)
  end

  test "a finalized statement answers :statement_finalized", %{conn: conn} do
    {:ok, stmt} = Xqlite.prepare(conn, "SELECT 1")
    :ok = Xqlite.finalize(stmt)

    assert {:error, :statement_finalized} = Xqlite.multi_step_cancellable(stmt, 1, [])
  end

  # Earlier runs and rows stepped first move SQLite's progress checks, so a cancel
  # lands before the first step, after a row and after the end.
  for_each_opener "a signalled token around a RETURNING write" do
    test "a cancel undoes the running write, inside BEGIN the whole transaction", %{conn: conn} do
      assert :ok = Xqlite.execute_batch(conn, @tables)

      kinds =
        for mode <- [:autocommit, :explicit],
            prior <- 0..7,
            stepped <- 0..3,
            batch <- [1, 2, 10],
            side <- [0, 1],
            do: sweep(conn, {mode, prior, stepped, batch, side})

      assert {:cancelled, true} in kinds
      assert {:done, true} in kinds
    end
  end

  defp sweep(conn, {mode, prior, stepped, batch, side} = cell) do
    assert :ok = Xqlite.execute_batch(conn, @seed <> opening(mode))
    assert {:ok, stmt} = Xqlite.prepare(conn, "UPDATE swept SET v = v || '!' RETURNING id")
    assert {:ok, other} = Xqlite.prepare(conn, "SELECT id FROM swept")
    for _ <- 1..prior//1, do: assert({:ok, %{done: true}} = Xqlite.multi_step(stmt, 10))
    for _ <- 1..side//1, do: assert({:row, _} = Xqlite.step(other))
    for _ <- 1..stepped//1, do: assert({:row, _} = Xqlite.step(stmt))
    assert {:ok, token} = Xqlite.create_cancel_token()
    assert :ok = Xqlite.cancel_operation(token)
    kind = kind(Xqlite.multi_step_cancellable(stmt, batch, token))
    assert :ok = Xqlite.finalize(stmt)
    assert :ok = Xqlite.finalize(other)
    assert {:ok, autocommit} = Xqlite.autocommit(conn)
    commit(conn, autocommit)
    assert {:ok, %{rows: rows}} = Xqlite.query(conn, @read_back, [])
    assert {cell, expected(mode, kind, stepped, prior)} == {cell, {autocommit, rows}}
    {kind, stepped > 0}
  end

  defp opening(:explicit), do: "BEGIN; INSERT INTO marks VALUES (1);"
  defp opening(:autocommit), do: ""

  defp kind({:error, :operation_cancelled}), do: :cancelled
  defp kind({:ok, %{done: true}}), do: :done
  defp kind({:ok, %{done: false}}), do: :partial

  defp commit(_conn, true), do: :ok
  defp commit(conn, false), do: assert(:ok = Xqlite.execute_batch(conn, "COMMIT;"))

  # A run not cancelled stays written, `finalize/1` finishing one left mid-way.
  # A cancel read before the first step runs nothing and leaves an open
  # transaction as it was; one that stops the running write rolls it back, and
  # inside BEGIN the whole transaction.
  defp expected(:autocommit, :cancelled, _stepped, prior), do: {true, rows(0, prior)}
  defp expected(:autocommit, _finished, _stepped, prior), do: {true, rows(0, prior + 1)}
  defp expected(:explicit, :cancelled, 0, prior), do: {false, rows(1, prior)}
  defp expected(:explicit, :cancelled, _stepped, _prior), do: {true, rows(0, 0)}
  defp expected(:explicit, _finished, _stepped, prior), do: {false, rows(1, prior + 1)}

  defp rows(marks, runs), do: List.duplicate([marks, String.duplicate("!", runs)], 3)
end
