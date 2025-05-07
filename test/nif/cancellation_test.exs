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

  # Setup a table and a trigger that runs a slow query on insert
  @trigger_table_setup """
  CREATE TABLE cancel_trigger_test (id INTEGER PRIMARY KEY);
  CREATE TEMP TRIGGER slow_insert_trigger
    AFTER INSERT ON cancel_trigger_test
  BEGIN
    -- Slow operation executed for every insert
    -- Using the same RANDOMBLOB technique as @slow_query
    SELECT MAX(HEX(RANDOMBLOB(16)))
    FROM (
        WITH RECURSIVE cnt(x) AS (
            SELECT 1 UNION ALL SELECT x+1 FROM cnt LIMIT #{@rand_limit} -- Use limit from @slow_query
        )
        SELECT x FROM cnt
    );
  END;
  """

  @batch_cancel_statement_count 50_000
  @batch_cancel_sleep 1
  @batch_cancel_table "cancel_batch_test"
  @batch_cancel_setup "CREATE TABLE #{@batch_cancel_table} (id INTEGER PRIMARY KEY, data TEXT); INSERT INTO #{@batch_cancel_table} (id, data) VALUES (0, 'initial');"
  @await_timeout 5_000

  defp generate_long_batch(table_name, num_statements) do
    Enum.map_join(1..num_statements, ";", fn i ->
      "UPDATE #{table_name} SET data = 'batch_#{i}' WHERE id = 0"
    end) <> ";"
  end

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

      test "query_cancellable/4 successfully cancels a running query", %{
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

      test "query_cancellable/4 completes normally if token is not cancelled", %{
        conn: conn
      } do
        {:ok, token} = NIF.create_cancel_token()

        # Run the query cancellably, but don't trigger the token
        assert {:ok, %{rows: [[_result_string]]}} =
                 NIF.query_cancellable(conn, @slow_query, [], token)
      end

      test "normal query works after a cancelled query (handler unregistered)", %{
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

      test "normal query works after a completed cancellable query (handler unregistered)",
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

      test "execute_cancellable/4 successfully cancels a triggered slow operation",
           %{
             conn: conn
           } do
        # Create the table and trigger
        assert {:ok, true} = NIF.execute_batch(conn, @trigger_table_setup)
        {:ok, token} = NIF.create_cancel_token()

        # Start the INSERT (which triggers the slow query) in a Task
        task =
          Task.async(fn ->
            NIF.execute_cancellable(
              conn,
              "INSERT INTO cancel_trigger_test (id) VALUES (1);",
              [],
              token
            )
          end)

        # Give time for trigger to start
        Process.sleep(200)
        assert {:ok, true} = NIF.cancel_operation(token)

        result = Task.await(task, 3000)
        assert {:error, :operation_cancelled} == result
      end

      test "execute_cancellable/4 completes normally if token is not cancelled", %{
        conn: conn
      } do
        # Create the table and trigger
        assert {:ok, true} = NIF.execute_batch(conn, @trigger_table_setup)
        {:ok, token} = NIF.create_cancel_token()

        # Run the INSERT cancellably, but don't cancel
        # Expect 1 row affected by INSERT
        assert {:ok, 1} =
                 NIF.execute_cancellable(
                   conn,
                   "INSERT INTO cancel_trigger_test (id) VALUES (1);",
                   [],
                   token
                 )
      end

      test "normal execute works after a cancelled execute_cancellable (handler unregistered)",
           %{conn: conn} do
        # Create the table and trigger
        assert {:ok, true} = NIF.execute_batch(conn, @trigger_table_setup)

        # --- Part 1: Run and cancel an execute ---
        {:ok, token1} = NIF.create_cancel_token()

        task =
          Task.async(fn ->
            NIF.execute_cancellable(
              conn,
              "INSERT INTO cancel_trigger_test (id) VALUES (1);",
              [],
              token1
            )
          end)

        Process.sleep(200)
        assert {:ok, true} = NIF.cancel_operation(token1)
        assert {:error, :operation_cancelled} == Task.await(task, 3000)

        # --- Part 2: Run a normal, non-cancellable execute on the same connection ---
        # Insert into a different table to avoid the trigger
        assert {:ok, 0} = NIF.execute(conn, "CREATE TABLE normal_exec_test (id INT);", [])

        assert {:ok, 1} =
                 NIF.execute(conn, "INSERT INTO normal_exec_test (id) VALUES (1);", [])
      end

      test "execute_batch_cancellable/3 successfully cancels a running batch", %{
        conn: conn
      } do
        # Setup the table for this test
        assert {:ok, true} = NIF.execute_batch(conn, @batch_cancel_setup)
        {:ok, token} = NIF.create_cancel_token()
        # Generate batch using the larger count
        long_batch = generate_long_batch(@batch_cancel_table, @batch_cancel_statement_count)

        task =
          Task.async(fn ->
            NIF.execute_batch_cancellable(conn, long_batch, token)
          end)

        # Use the short sleep before cancelling
        # e.g., 10ms
        Process.sleep(@batch_cancel_sleep)
        assert {:ok, true} = NIF.cancel_operation(token)

        # Expect cancellation error
        result = Task.await(task, @await_timeout)
        assert {:error, :operation_cancelled} == result
      end

      test "execute_batch_cancellable/3 completes normally if token is not cancelled",
           %{conn: conn} do
        # Setup the table for this test
        assert {:ok, true} = NIF.execute_batch(conn, @batch_cancel_setup)
        {:ok, token} = NIF.create_cancel_token()
        # Use a much smaller batch that should complete quickly
        short_batch = generate_long_batch(@batch_cancel_table, 5)

        # Run the batch cancellably, but don't cancel
        assert {:ok, true} = NIF.execute_batch_cancellable(conn, short_batch, token)

        # Verify the last update from the short batch took effect
        assert {:ok, %{rows: [["batch_5"]]}} =
                 NIF.query(conn, "SELECT data FROM #{@batch_cancel_table} WHERE id = 0;", [])
      end

      test "normal batch works after a cancelled execute_batch_cancellable (handler unregistered)",
           %{conn: conn} do
        # Setup the table for this test
        assert {:ok, true} = NIF.execute_batch(conn, @batch_cancel_setup)

        # --- Part 1: Run and cancel a batch ---
        {:ok, token1} = NIF.create_cancel_token()
        # Use the larger batch count
        long_batch = generate_long_batch(@batch_cancel_table, @batch_cancel_statement_count)

        task =
          Task.async(fn ->
            NIF.execute_batch_cancellable(conn, long_batch, token1)
          end)

        # Use short sleep
        Process.sleep(@batch_cancel_sleep)
        assert {:ok, true} = NIF.cancel_operation(token1)
        # Expect cancellation error, even if timing is tight
        assert {:error, :operation_cancelled} == Task.await(task, @await_timeout)

        # --- Part 2: Run a normal, non-cancellable batch on the same connection ---
        # Verifies the progress handler was correctly unregistered by the RAII guard in Rust.
        normal_batch = "UPDATE #{@batch_cancel_table} SET data = 'normal_batch' WHERE id = 0;"
        assert {:ok, true} = NIF.execute_batch(conn, normal_batch)

        assert {:ok, %{rows: [["normal_batch"]]}} =
                 NIF.query(conn, "SELECT data FROM #{@batch_cancel_table} WHERE id = 0;", [])
      end
    end

    # end describe
  end

  # end for
end
