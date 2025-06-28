defmodule Xqlite.NIF.CancellationTest do
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF
  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  # Use a CPU-intensive, low-memory query for predictable "slowness".
  @cpu_intensive_limit 5_000_000
  @slow_query """
  WITH RECURSIVE cnt(x) AS (
    SELECT 1
    UNION ALL
    SELECT x + 1 FROM cnt
    LIMIT #{@cpu_intensive_limit}
  )
  SELECT SUM(x) FROM cnt;
  """

  # Setup a table and a trigger that runs the slow query on insert.
  @trigger_table_setup """
  CREATE TABLE cancel_trigger_test (id INTEGER PRIMARY KEY);
  CREATE TEMP TRIGGER slow_insert_trigger
    AFTER INSERT ON cancel_trigger_test
  BEGIN
    WITH RECURSIVE cnt(x) AS (
        SELECT 1 UNION ALL SELECT x+1 FROM cnt LIMIT #{@cpu_intensive_limit}
    )
    SELECT SUM(x) FROM cnt;
  END;
  """

  @batch_cancel_table "cancel_batch_test"
  @batch_cancel_setup "CREATE TABLE #{@batch_cancel_table} (id INTEGER PRIMARY KEY, data TEXT); INSERT INTO #{@batch_cancel_table} (id, data) VALUES (0, 'initial');"
  @await_timeout 5_000

  # Test token creation separately, doesn't need the loop/connection setup.
  test "create_cancel_token/0 returns a resource" do
    assert {:ok, token} = NIF.create_cancel_token()
    assert is_reference(token)
  end

  test "cancel_operation/1 is idempotent" do
    {:ok, token} = NIF.create_cancel_token()
    assert :ok = NIF.cancel_operation(token)
    # Calling again is safe
    assert :ok = NIF.cancel_operation(token)
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

      test "query_cancellable/4 successfully cancels a running query", %{conn: conn} do
        assert_cancellation(conn, fn conn, token ->
          NIF.query_cancellable(conn, @slow_query, [], token)
        end)
      end

      test "query_cancellable/4 completes normally if token is not cancelled", %{conn: conn} do
        {:ok, token} = NIF.create_cancel_token()

        # Run the query cancellably, but don't trigger the token
        assert {:ok, %{rows: [[_result]]}} =
                 NIF.query_cancellable(conn, @slow_query, [], token)
      end

      test "normal query works after a cancelled query (handler unregistered)", %{conn: conn} do
        # --- Part 1: Run and cancel a query using the helper ---
        assert_cancellation(conn, fn conn, token ->
          NIF.query_cancellable(conn, @slow_query, [], token)
        end)

        # --- Part 2: Run a normal, non-cancellable query on the same connection ---
        assert {:ok, %{columns: ["1"], rows: [[1]], num_rows: 1}} =
                 NIF.query(conn, "SELECT 1;", [])
      end

      test "normal query works after a completed cancellable query (handler unregistered)",
           %{conn: conn} do
        {:ok, token} = NIF.create_cancel_token()

        assert {:ok, %{rows: [[_result]]}} =
                 NIF.query_cancellable(conn, @slow_query, [], token)

        assert {:ok, %{columns: ["1"], rows: [[1]], num_rows: 1}} =
                 NIF.query(conn, "SELECT 1;", [])
      end

      test "execute_cancellable/4 successfully cancels a triggered slow operation",
           %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, @trigger_table_setup)

        assert_cancellation(conn, fn conn, token ->
          NIF.execute_cancellable(
            conn,
            "INSERT INTO cancel_trigger_test (id) VALUES (1);",
            [],
            token
          )
        end)
      end

      test "execute_cancellable/4 completes normally if token is not cancelled", %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, @trigger_table_setup)
        {:ok, token} = NIF.create_cancel_token()

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
        assert :ok = NIF.execute_batch(conn, @trigger_table_setup)

        # --- Part 1: Run and cancel an execute ---
        assert_cancellation(conn, fn conn, token ->
          NIF.execute_cancellable(
            conn,
            "INSERT INTO cancel_trigger_test (id) VALUES (1);",
            [],
            token
          )
        end)

        # --- Part 2: Run a normal, non-cancellable execute on the same connection ---
        assert {:ok, 0} = NIF.execute(conn, "CREATE TABLE normal_exec_test (id INT);", [])

        assert {:ok, 1} =
                 NIF.execute(conn, "INSERT INTO normal_exec_test (id) VALUES (1);", [])
      end

      test "execute_batch_cancellable/3 successfully cancels a running batch", %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, @batch_cancel_setup)

        long_batch = generate_long_batch(@batch_cancel_table)

        assert_cancellation(conn, fn conn, token ->
          NIF.execute_batch_cancellable(conn, long_batch, token)
        end)

        # Add an assertion to prove the batch was cancelled *during* execution.
        # The 'batch_started' update should have run, but the 'batch_finished' should not have.
        assert {:ok, %{rows: [["batch_started"]]}} =
                 NIF.query(conn, "SELECT data FROM #{@batch_cancel_table} WHERE id = 0;", [])
      end

      test "execute_batch_cancellable/3 completes normally if token is not cancelled",
           %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, @batch_cancel_setup)
        {:ok, token} = NIF.create_cancel_token()

        # Use a much smaller batch that completes quickly
        short_batch = "UPDATE #{@batch_cancel_table} SET data = 'batch_update' WHERE id=0;"
        assert :ok = NIF.execute_batch_cancellable(conn, short_batch, token)

        assert {:ok, %{rows: [["batch_update"]]}} =
                 NIF.query(conn, "SELECT data FROM #{@batch_cancel_table} WHERE id = 0;", [])
      end

      test "normal batch works after a cancelled execute_batch_cancellable (handler unregistered)",
           %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, @batch_cancel_setup)
        long_batch = generate_long_batch(@batch_cancel_table)

        # --- Part 1: Run and cancel a batch ---
        assert_cancellation(conn, fn conn, token ->
          NIF.execute_batch_cancellable(conn, long_batch, token)
        end)

        # --- Part 2: Run a normal, non-cancellable batch on the same connection ---
        normal_batch = "UPDATE #{@batch_cancel_table} SET data = 'normal_batch' WHERE id = 0;"
        assert :ok = NIF.execute_batch(conn, normal_batch)

        assert {:ok, %{rows: [["normal_batch"]]}} =
                 NIF.query(conn, "SELECT data FROM #{@batch_cancel_table} WHERE id = 0;", [])
      end
    end
  end

  defp generate_long_batch(table_name) do
    # This batch does a quick update, then runs our reliably slow query,
    # then attempts another update that should not be reached if cancelled.
    """
    UPDATE #{table_name} SET data = 'batch_started' WHERE id = 0;
    #{@slow_query}
    UPDATE #{table_name} SET data = 'batch_finished' WHERE id = 0;
    """
  end

  # Helper function to assert cancellation in a deterministic way.
  defp assert_cancellation(conn, nif_fun) do
    {:ok, token} = NIF.create_cancel_token()
    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:nif_started, self()})
        # The provided function is called here with the conn and token
        nif_fun.(conn, token)
      end)

    # Wait for the task to signal it has started the NIF call
    receive do
      {:nif_started, _task_pid} ->
        :ok
    after
      # Use a reasonable timeout in case the task fails to start
      1000 -> flunk("Test process did not receive :nif_started message from task")
    end

    # As soon as we get the signal, we cancel
    assert :ok = NIF.cancel_operation(token)

    result = Task.await(task, @await_timeout)
    assert {:error, :operation_cancelled} == result
  end
end
