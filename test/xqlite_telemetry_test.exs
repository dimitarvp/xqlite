defmodule Xqlite.XqliteTelemetryTest do
  @moduledoc """
  Validates that every instrumented operation in `Xqlite` emits the
  documented `:telemetry` events with the documented measurement keys
  and metadata keys.

  Test bar (per `feedback_subscription_api_test_bar` memory + the
  T2.2 plan): for every event we wire in Block 2, this file must
  cover the happy path, the error path, and any operation-specific
  invariants (cancellation outcome, transaction reasons, etc.).

  Tests are isolated by attaching unique-handler-id-per-test handlers
  to a small set of events; we detach in each test rather than rely
  on `on_exit` because async tests may run interleaved.
  """

  use ExUnit.Case, async: true

  setup do
    {:ok, conn} = Xqlite.open_in_memory()

    on_exit(fn ->
      XqliteNIF.close(conn)
    end)

    {:ok, conn: conn}
  end

  describe "Xqlite.query/3 telemetry" do
    test "fires :start and :stop on success", %{conn: conn} do
      :ok =
        XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);")

      :ok =
        XqliteNIF.execute_batch(
          conn,
          "INSERT INTO t VALUES (1, 'a'), (2, 'b'), (3, 'c');"
        )

      handler_id = "test-query-success-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite, :query, :start],
        [:xqlite, :query, :stop],
        [:xqlite, :query, :exception]
      ])

      {:ok, %Xqlite.Result{}} = Xqlite.query(conn, "SELECT * FROM t", [])

      assert_receive {:telemetry_event, [:xqlite, :query, :start], measurements_start,
                      metadata_start}

      assert is_integer(measurements_start.monotonic_time)
      assert is_integer(measurements_start.system_time)
      assert metadata_start.conn == conn
      assert metadata_start.sql == "SELECT * FROM t"
      assert metadata_start.params_count == 0
      assert metadata_start.cancellable? == false

      assert_receive {:telemetry_event, [:xqlite, :query, :stop], measurements_stop,
                      metadata_stop}

      assert is_integer(measurements_stop.duration) and measurements_stop.duration >= 0
      assert metadata_stop.result_class == :ok
      assert metadata_stop.error_reason == nil
      assert metadata_stop.num_rows == 3

      :telemetry.detach(handler_id)
    end

    test "fires :stop with :error on bad SQL", %{conn: conn} do
      handler_id = "test-query-error-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite, :query, :start],
        [:xqlite, :query, :stop]
      ])

      {:error, _} = Xqlite.query(conn, "SELECT * FROM nonexistent", [])

      assert_receive {:telemetry_event, [:xqlite, :query, :start], _, _}

      assert_receive {:telemetry_event, [:xqlite, :query, :stop], _measurements, metadata}

      assert metadata.result_class == :error
      assert metadata.error_reason != nil
      assert metadata.num_rows == nil

      :telemetry.detach(handler_id)
    end

    test "params_count reflects actual list length", %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
      handler_id = "test-query-params-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [[:xqlite, :query, :start]])

      Xqlite.query(conn, "SELECT * FROM t WHERE id IN (?, ?, ?)", [1, 2, 3])

      assert_receive {:telemetry_event, [:xqlite, :query, :start], _, %{params_count: 3}}

      :telemetry.detach(handler_id)
    end
  end

  describe "Xqlite.execute/3 telemetry" do
    test "fires :stop with affected_rows on success", %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
      handler_id = "test-exec-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite, :execute, :start],
        [:xqlite, :execute, :stop]
      ])

      {:ok, %Xqlite.Result{}} = Xqlite.execute(conn, "INSERT INTO t VALUES (1)", [])

      assert_receive {:telemetry_event, [:xqlite, :execute, :start], _, _}

      assert_receive {:telemetry_event, [:xqlite, :execute, :stop], _measurements, metadata}

      assert metadata.result_class == :ok
      assert metadata.affected_rows == 1
      assert metadata.cancellable? == false

      :telemetry.detach(handler_id)
    end

    test "fires :stop with :error on constraint violation", %{conn: conn} do
      :ok =
        XqliteNIF.execute_batch(
          conn,
          "CREATE TABLE t(id INTEGER PRIMARY KEY); INSERT INTO t VALUES (1);"
        )

      handler_id = "test-exec-constraint-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :execute, :stop]])

      # Duplicate primary key — constraint violation.
      {:error, _} = Xqlite.execute(conn, "INSERT INTO t VALUES (1)", [])

      assert_receive {:telemetry_event, [:xqlite, :execute, :stop], _, metadata}

      assert metadata.result_class == :error
      assert metadata.error_reason != nil

      :telemetry.detach(handler_id)
    end
  end

  describe "Xqlite.execute_batch/2 telemetry" do
    test "fires with sql_batch_size_bytes", %{conn: conn} do
      handler_id = "test-batch-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite, :execute_batch, :start],
        [:xqlite, :execute_batch, :stop]
      ])

      sql = "CREATE TABLE t(id INTEGER); INSERT INTO t VALUES (1);"
      :ok = Xqlite.execute_batch(conn, sql)

      assert_receive {:telemetry_event, [:xqlite, :execute_batch, :start], _, metadata}
      assert metadata.sql_batch_size_bytes == byte_size(sql)
      assert metadata.cancellable? == false

      assert_receive {:telemetry_event, [:xqlite, :execute_batch, :stop], _,
                      %{result_class: :ok}}

      :telemetry.detach(handler_id)
    end
  end

  describe "Xqlite.explain_analyze/3 telemetry" do
    test "fires with wall_time_ns, rows_produced, scan_count on success", %{conn: conn} do
      :ok =
        XqliteNIF.execute_batch(
          conn,
          "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT); INSERT INTO t VALUES (1, 'a'), (2, 'b');"
        )

      handler_id = "test-ea-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :explain_analyze, :stop]])

      {:ok, %Xqlite.ExplainAnalyze{}} =
        Xqlite.explain_analyze(conn, "SELECT * FROM t", [])

      assert_receive {:telemetry_event, [:xqlite, :explain_analyze, :stop], _measurements,
                      metadata}

      assert metadata.result_class == :ok
      assert is_integer(metadata.wall_time_ns) and metadata.wall_time_ns >= 0
      assert is_integer(metadata.rows_produced) and metadata.rows_produced >= 0
      assert is_integer(metadata.scan_count) and metadata.scan_count >= 0

      :telemetry.detach(handler_id)
    end
  end

  describe "Xqlite.query_cancellable/4 telemetry" do
    test "fires with cancellable?: true on success", %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
      :ok = XqliteNIF.execute_batch(conn, "INSERT INTO t VALUES (1), (2);")

      {:ok, token} = XqliteNIF.create_cancel_token()

      handler_id = "test-qc-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite, :query, :start],
        [:xqlite, :query, :stop]
      ])

      {:ok, _} = Xqlite.query_cancellable(conn, "SELECT * FROM t", [], token)

      assert_receive {:telemetry_event, [:xqlite, :query, :start], _, %{cancellable?: true}}

      assert_receive {:telemetry_event, [:xqlite, :query, :stop], _,
                      %{cancellable?: true, result_class: :ok}}

      :telemetry.detach(handler_id)
    end

    test "fires :stop with error_reason: :operation_cancelled on cancel", %{conn: conn} do
      {:ok, token} = XqliteNIF.create_cancel_token()
      :ok = XqliteNIF.cancel_operation(token)

      handler_id = "test-qc-cancel-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :query, :stop]])

      {:error, :operation_cancelled} =
        Xqlite.query_cancellable(
          conn,
          "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT count(*) FROM n",
          [],
          token
        )

      assert_receive {:telemetry_event, [:xqlite, :query, :stop], _, metadata}
      assert metadata.cancellable? == true
      assert metadata.result_class == :error
      assert metadata.error_reason == :operation_cancelled

      :telemetry.detach(handler_id)
    end
  end

  describe "transaction telemetry" do
    setup %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE tx(id INTEGER PRIMARY KEY);")
      :ok
    end

    test "begin / commit fire single events with metadata", %{conn: conn} do
      handler_id = "test-tx-bc-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite, :transaction, :begin],
        [:xqlite, :transaction, :commit]
      ])

      :ok = Xqlite.begin(conn, :immediate)
      :ok = Xqlite.commit(conn)

      assert_receive {:telemetry_event, [:xqlite, :transaction, :begin], measurements,
                      metadata}

      assert is_integer(measurements.monotonic_time)
      assert metadata.conn == conn
      assert metadata.mode == :immediate

      assert_receive {:telemetry_event, [:xqlite, :transaction, :commit], _, %{conn: ^conn}}

      :telemetry.detach(handler_id)
    end

    test "rollback fires with reason: :user_initiated", %{conn: conn} do
      handler_id = "test-tx-rb-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [[:xqlite, :transaction, :rollback]])

      :ok = Xqlite.begin(conn, :deferred)
      {:ok, _} = XqliteNIF.execute(conn, "INSERT INTO tx VALUES (1)", [])
      :ok = Xqlite.rollback(conn)

      assert_receive {:telemetry_event, [:xqlite, :transaction, :rollback], _,
                      %{conn: ^conn, reason: :user_initiated}}

      :telemetry.detach(handler_id)
    end

    test "savepoint create / rollback_to / release fire with name", %{conn: conn} do
      handler_id = "test-sp-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite, :savepoint, :create],
        [:xqlite, :savepoint, :rollback_to],
        [:xqlite, :savepoint, :release]
      ])

      :ok = Xqlite.begin(conn, :deferred)
      :ok = Xqlite.savepoint(conn, "sp1")
      :ok = Xqlite.rollback_to_savepoint(conn, "sp1")
      :ok = Xqlite.release_savepoint(conn, "sp1")
      :ok = Xqlite.commit(conn)

      assert_receive {:telemetry_event, [:xqlite, :savepoint, :create], _, %{name: "sp1"}}
      assert_receive {:telemetry_event, [:xqlite, :savepoint, :rollback_to], _, %{name: "sp1"}}
      assert_receive {:telemetry_event, [:xqlite, :savepoint, :release], _, %{name: "sp1"}}

      :telemetry.detach(handler_id)
    end

    test "begin/commit on failure does NOT emit (event only fires on :ok)", %{conn: conn} do
      handler_id = "test-tx-fail-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite, :transaction, :begin],
        [:xqlite, :transaction, :commit]
      ])

      # Try to commit when no transaction is active — should error and not emit.
      {:error, _} = Xqlite.commit(conn)
      refute_receive {:telemetry_event, [:xqlite, :transaction, :commit], _, _}, 100

      :telemetry.detach(handler_id)
    end
  end

  describe "telemetry-disabled mode (smoke)" do
    test "Xqlite.Telemetry.enabled?() reflects test config" do
      # In test env we set :telemetry_enabled to true. Confirms the
      # rest of this file's assertions are exercising the enabled path.
      assert Xqlite.Telemetry.enabled?() == true
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp attach_capture(handler_id, events) do
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )
  end
end
