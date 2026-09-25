defmodule Xqlite.NIF.CancellationTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

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

  @one_row "CREATE TABLE t (id INTEGER PRIMARY KEY, v); INSERT INTO t VALUES (1, 'a');"
  @writes ["UPDATE t SET v = 2 WHERE id = 1", "INSERT INTO t VALUES (2, 2)", "DELETE FROM t"]

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

  test "is_cancel_token/1 knows a token from any other term" do
    assert {:ok, token} = NIF.create_cancel_token()

    assert NIF.is_cancel_token(token)

    refute NIF.is_cancel_token(make_ref())
    refute NIF.is_cancel_token(:bogus)
    refute NIF.is_cancel_token(42)
    refute NIF.is_cancel_token("token")
    refute NIF.is_cancel_token(nil)
    refute NIF.is_cancel_token(self())
    refute NIF.is_cancel_token([token])
    refute NIF.is_cancel_token(%{token: token})
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

      test "is_cancel_token/1 refuses every other resource handle", %{conn: conn} do
        assert {:ok, stmt} = NIF.stmt_prepare(conn, "SELECT 1")
        assert {:ok, stream} = NIF.stream_open(conn, "SELECT 1", [])

        refute NIF.is_cancel_token(conn)
        refute NIF.is_cancel_token(stmt)
        refute NIF.is_cancel_token(stream)

        assert :ok = NIF.stmt_finalize(stmt)
        assert :ok = NIF.stream_close(stream)
      end

      test "query_cancellable/4 successfully cancels a running query", %{conn: conn} do
        assert_cancellation(conn, fn conn, token ->
          NIF.query_cancellable(conn, @slow_query, [], [token])
        end)
      end

      test "query_cancellable/4 completes normally if token is not cancelled", %{conn: conn} do
        {:ok, token} = NIF.create_cancel_token()

        # Run the query cancellably, but don't trigger the token
        assert {:ok, %{rows: [[_result]]}} =
                 NIF.query_cancellable(conn, @slow_query, [], [token])
      end

      test "normal query works after a cancelled query (handler unregistered)", %{conn: conn} do
        # --- Part 1: Run and cancel a query using the helper ---
        assert_cancellation(conn, fn conn, token ->
          NIF.query_cancellable(conn, @slow_query, [], [token])
        end)

        # --- Part 2: Run a normal, non-cancellable query on the same connection ---
        assert {:ok, %{columns: ["1"], rows: [[1]], num_rows: 1}} =
                 NIF.query(conn, "SELECT 1;", [])
      end

      test "normal query works after a completed cancellable query (handler unregistered)",
           %{conn: conn} do
        {:ok, token} = NIF.create_cancel_token()

        assert {:ok, %{rows: [[_result]]}} =
                 NIF.query_cancellable(conn, @slow_query, [], [token])

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
            [token]
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
                   [token]
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
            [token]
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
          NIF.execute_batch_cancellable(conn, long_batch, [token])
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
        assert :ok = NIF.execute_batch_cancellable(conn, short_batch, [token])

        assert {:ok, %{rows: [["batch_update"]]}} =
                 NIF.query(conn, "SELECT data FROM #{@batch_cancel_table} WHERE id = 0;", [])
      end

      test "normal batch works after a cancelled execute_batch_cancellable (handler unregistered)",
           %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, @batch_cancel_setup)
        long_batch = generate_long_batch(@batch_cancel_table)

        # --- Part 1: Run and cancel a batch ---
        assert_cancellation(conn, fn conn, token ->
          NIF.execute_batch_cancellable(conn, long_batch, [token])
        end)

        # --- Part 2: Run a normal, non-cancellable batch on the same connection ---
        normal_batch = "UPDATE #{@batch_cancel_table} SET data = 'normal_batch' WHERE id = 0;"
        assert :ok = NIF.execute_batch(conn, normal_batch)

        assert {:ok, %{rows: [["normal_batch"]]}} =
                 NIF.query(conn, "SELECT data FROM #{@batch_cancel_table} WHERE id = 0;", [])
      end

      test "the extension chain runs on a cancellable form a live token leaves alone", %{
        conn: conn
      } do
        exts = [type_extensions: [Xqlite.TypeExtension.Date]]
        :ok = NIF.execute_batch(conn, "CREATE TABLE cancel_ext_test (id INTEGER, day TEXT);")

        {:ok, insert_token} = NIF.create_cancel_token()

        assert {:ok, 1} =
                 Xqlite.execute_cancellable(
                   conn,
                   "INSERT INTO cancel_ext_test (id, day) VALUES (1, ?1)",
                   [~D[2026-02-03]],
                   insert_token,
                   exts
                 )

        {:ok, read_token} = NIF.create_cancel_token()

        assert {:ok, %{rows: [[~D[2026-02-03]]]}} =
                 Xqlite.query_cancellable(
                   conn,
                   "SELECT day FROM cancel_ext_test WHERE day = ?1",
                   [~D[2026-02-03]],
                   read_token,
                   exts
                 )
      end

      test "a signalled token still wins over the extension chain", %{conn: conn} do
        {:ok, token} = NIF.create_cancel_token()
        :ok = Xqlite.cancel_operation(token)

        assert {:error, :operation_cancelled} =
                 Xqlite.query_cancellable(conn, @slow_query, [], token,
                   type_extensions: [Xqlite.TypeExtension.Date]
                 )
      end

      test "a signalled token cancels a one-row write before it runs", %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, @one_row)
        {:ok, token} = NIF.create_cancel_token()
        :ok = NIF.cancel_operation(token)

        for sql <- @writes, {name, call} <- one_shot_calls() do
          assert {^name, ^sql, {:error, :operation_cancelled}, {:ok, %{rows: [[1, "a"]]}}} =
                   {name, sql, call.(conn, sql, [token]),
                    NIF.query(conn, "SELECT * FROM t", [])}
        end
      end
    end
  end

  defp one_shot_calls do
    [
      query_cancellable: &NIF.query_cancellable(&1, &2, [], &3),
      execute_cancellable: &NIF.execute_cancellable(&1, &2, [], &3),
      query_with_changes_cancellable: &NIF.query_with_changes_cancellable(&1, &2, [], &3),
      execute_batch_cancellable: &NIF.execute_batch_cancellable/3,
      stmt_multi_step_cancellable: &fresh_multi_step/3,
      stream_fetch_cancellable: &first_fetch/3
    ]
  end

  defp fresh_multi_step(conn, sql, tokens) do
    assert {:ok, stmt} = NIF.stmt_prepare(conn, sql)
    NIF.stmt_multi_step_cancellable(stmt, 10, tokens)
  end

  defp first_fetch(conn, sql, tokens) do
    assert {:ok, stream} = NIF.stream_open(conn, sql, [])
    NIF.stream_fetch_cancellable(stream, 10, tokens)
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

  # Signals once a progress tick shows the call running, never before it starts.
  defp assert_cancellation(conn, nif_fun) do
    {:ok, token} = NIF.create_cancel_token()
    {:ok, ticks} = NIF.register_progress_hook(conn, self(), 1_000_000, nil)
    task = Task.async(fn -> nif_fun.(conn, token) end)
    assert_receive {:xqlite_progress, _count, _elapsed_ms}, @await_timeout
    assert :ok = NIF.cancel_operation(token)
    assert {:error, :operation_cancelled} == Task.await(task, @await_timeout)
    assert :ok = NIF.unregister_progress_hook(conn, ticks)
  end
end
