defmodule Xqlite.NIF.StatementCancelTest do
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF

  # The recursion bound is a never-reached ceiling: the mid-flight test
  # cancels ~30ms in, and even the fastest CI runner cannot count to a
  # billion first (a 1M bound DID lose that race on macOS runners). If
  # cancellation ever breaks, the test fails loudly via ExUnit timeout
  # rather than silently completing.
  @slow_sql "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<1000000000) SELECT count(*) FROM n"

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
end
