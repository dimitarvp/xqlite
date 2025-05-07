defmodule Xqlite.NIF.CancellationTest do
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF

  # Slow query using RANDOMBLOB (adjust LIMIT for desired slowness ~1-2s)
  @rand_limit 500_000
  @slow_query """
  SELECT MAX(HEX(RANDOMBLOB(16)))
  FROM (
      WITH RECURSIVE cnt(x) AS (
          SELECT 1 UNION ALL SELECT x+1 FROM cnt LIMIT #{@rand_limit}
      )
      SELECT x FROM cnt
  );
  """

  setup do
    {:ok, conn} = NIF.open_in_memory()
    on_exit(fn -> NIF.close(conn) end)
    {:ok, conn: conn}
  end

  test "create_cancel_token/0 returns a resource", %{conn: _conn} do
    assert {:ok, token} = NIF.create_cancel_token()
    assert is_reference(token)
  end

  test "query_cancellable/4 successfully cancels a running query", %{conn: conn} do
    {:ok, token} = NIF.create_cancel_token()

    task = Task.async(fn -> NIF.query_cancellable(conn, @slow_query, [], token) end)
    Process.sleep(200)

    assert {:ok, true} = NIF.cancel_operation(token)

    result = Task.await(task, 3000)
    assert {:error, :operation_cancelled} == result
  end

  test "query_cancellable/4 completes normally if token is not cancelled", %{conn: conn} do
    {:ok, token} = NIF.create_cancel_token()

    assert {:ok, %{rows: [[_result_string]]}} =
             NIF.query_cancellable(conn, @slow_query, [], token)
  end

  test "normal query works on connection after a cancelled query (handler unregistered)", %{
    conn: conn
  } do
    # --- Part 1: Run and cancel a query ---
    {:ok, token1} = NIF.create_cancel_token()
    task = Task.async(fn -> NIF.query_cancellable(conn, @slow_query, [], token1) end)
    Process.sleep(200)
    assert {:ok, true} = NIF.cancel_operation(token1)
    assert {:error, :operation_cancelled} = Task.await(task, 3000)

    # --- Part 2: Run a normal, non-cancellable query on the same connection ---
    assert {:ok, %{columns: ["1"], rows: [[1]], num_rows: 1}} =
             NIF.query(conn, "SELECT 1;", [])
  end

  test "normal query works on connection after a completed cancellable query (handler unregistered)",
       %{conn: conn} do
    # --- Part 1: Run a cancellable query to completion ---
    {:ok, token2} = NIF.create_cancel_token()

    assert {:ok, %{rows: [[_result_string]]}} =
             NIF.query_cancellable(conn, @slow_query, [], token2)

    # --- Part 2: Run a normal, non-cancellable query on the same connection ---
    assert {:ok, %{columns: ["1"], rows: [[1]], num_rows: 1}} =
             NIF.query(conn, "SELECT 1;", [])
  end

  test "cancel_operation/1 is idempotent", %{conn: _conn} do
    {:ok, token} = NIF.create_cancel_token()
    assert {:ok, true} = NIF.cancel_operation(token)
    assert {:ok, true} = NIF.cancel_operation(token)
  end
end
