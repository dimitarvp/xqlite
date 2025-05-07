defmodule Xqlite.NIF.CancellationTest do
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF
  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  # Slow query using RANDOMBLOB (adjust LIMIT for desired slowness ~1-2s if needed)
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

  # Test token creation separately, doesn't need the loop/connection setup.
  test "create_cancel_token/0 returns a resource" do
    assert {:ok, token} = NIF.create_cancel_token()
    assert is_reference(token)
  end

  test "cancel_operation/1 is idempotent" do
    {:ok, token} = NIF.create_cancel_token()
    assert {:ok, true} = NIF.cancel_operation(token)
    # Calling again is safe
    assert {:ok, true} = NIF.cancel_operation(token)
  end

  # --- Shared test code (generated via `for` loop) ---
  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      # Setup for each connection type
      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # --- Cancellation Tests ---

      test "#{prefix} - query_cancellable/4 successfully cancels a running query", %{
        conn: conn
      } do
        {:ok, token} = NIF.create_cancel_token()

        # Start the slow query in a separate process (Task)
        task = Task.async(fn -> NIF.query_cancellable(conn, @slow_query, [], token) end)

        # Give the query a little time to start
        # Adjust if needed, might need longer for file DBs
        Process.sleep(200)

        assert {:ok, true} = NIF.cancel_operation(token)

        # Await the task result, expect cancellation error
        # Generous timeout
        result = Task.await(task, 3000)
        assert {:error, :operation_cancelled} == result
      end

      test "#{prefix} - query_cancellable/4 completes normally if token is not cancelled", %{
        conn: conn
      } do
        {:ok, token} = NIF.create_cancel_token()

        # Run the query cancellably, but don't trigger the token
        assert {:ok, %{rows: [[_result_string]]}} =
                 NIF.query_cancellable(conn, @slow_query, [], token)
      end

      test "#{prefix} - normal query works after a cancelled query (handler unregistered)", %{
        conn: conn
      } do
        # --- Part 1: Run and cancel a query ---
        {:ok, token1} = NIF.create_cancel_token()
        task = Task.async(fn -> NIF.query_cancellable(conn, @slow_query, [], token1) end)
        Process.sleep(200)
        assert {:ok, true} = NIF.cancel_operation(token1)
        assert {:error, :operation_cancelled} == Task.await(task, 3000)

        # --- Part 2: Run a normal, non-cancellable query on the same connection ---
        # Verifies the progress handler was correctly unregistered by the RAII guard in Rust.
        assert {:ok, %{columns: ["1"], rows: [[1]], num_rows: 1}} =
                 NIF.query(conn, "SELECT 1;", [])
      end

      test "#{prefix} - normal query works after a completed cancellable query (handler unregistered)",
           %{conn: conn} do
        # --- Part 1: Run a cancellable query to completion ---
        {:ok, token2} = NIF.create_cancel_token()

        assert {:ok, %{rows: [[_result_string]]}} =
                 NIF.query_cancellable(conn, @slow_query, [], token2)

        # --- Part 2: Run a normal, non-cancellable query on the same connection ---
        # Verifies the progress handler was correctly unregistered by the RAII guard in Rust.
        assert {:ok, %{columns: ["1"], rows: [[1]], num_rows: 1}} =
                 NIF.query(conn, "SELECT 1;", [])
      end
    end

    # end describe
  end

  # end for
end
