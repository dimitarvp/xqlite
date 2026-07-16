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

  import Xqlite.Telemetry.TestSupport, only: [attach_capture: 1, detach: 1]

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

      handler_id =
        attach_capture([
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

      detach(handler_id)
    end

    test "fires :stop with :error on bad SQL", %{conn: conn} do
      handler_id =
        attach_capture([
          [:xqlite, :query, :start],
          [:xqlite, :query, :stop]
        ])

      {:error, _} = Xqlite.query(conn, "SELECT * FROM nonexistent", [])

      assert_receive {:telemetry_event, [:xqlite, :query, :start], _, _}

      assert_receive {:telemetry_event, [:xqlite, :query, :stop], _measurements, metadata}

      assert metadata.result_class == :error
      assert metadata.error_reason != nil
      assert metadata.num_rows == nil

      detach(handler_id)
    end

    test "params_count reflects actual list length", %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
      handler_id = attach_capture([[:xqlite, :query, :start]])

      Xqlite.query(conn, "SELECT * FROM t WHERE id IN (?, ?, ?)", [1, 2, 3])

      assert_receive {:telemetry_event, [:xqlite, :query, :start], _, %{params_count: 3}}

      detach(handler_id)
    end
  end

  describe "Xqlite.execute/3 telemetry" do
    test "fires :stop with affected_rows on success", %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

      handler_id =
        attach_capture([
          [:xqlite, :execute, :start],
          [:xqlite, :execute, :stop]
        ])

      {:ok, %Xqlite.Result{}} = Xqlite.execute(conn, "INSERT INTO t VALUES (1)", [])

      assert_receive {:telemetry_event, [:xqlite, :execute, :start], _, _}

      assert_receive {:telemetry_event, [:xqlite, :execute, :stop], _measurements, metadata}

      assert metadata.result_class == :ok
      assert metadata.affected_rows == 1
      assert metadata.cancellable? == false

      detach(handler_id)
    end

    test "fires :stop with :error on constraint violation", %{conn: conn} do
      :ok =
        XqliteNIF.execute_batch(
          conn,
          "CREATE TABLE t(id INTEGER PRIMARY KEY); INSERT INTO t VALUES (1);"
        )

      handler_id = attach_capture([[:xqlite, :execute, :stop]])

      # Duplicate primary key — constraint violation.
      {:error, _} = Xqlite.execute(conn, "INSERT INTO t VALUES (1)", [])

      assert_receive {:telemetry_event, [:xqlite, :execute, :stop], _, metadata}

      assert metadata.result_class == :error
      assert metadata.error_reason != nil

      detach(handler_id)
    end
  end

  describe "Xqlite.execute_batch/2 telemetry" do
    test "fires with sql_batch_size_bytes", %{conn: conn} do
      handler_id =
        attach_capture([
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

      detach(handler_id)
    end
  end

  describe "Xqlite.explain_analyze/3 telemetry" do
    test "fires with wall_time_ns, rows_produced, scan_count on success", %{conn: conn} do
      :ok =
        XqliteNIF.execute_batch(
          conn,
          "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT); INSERT INTO t VALUES (1, 'a'), (2, 'b');"
        )

      handler_id = attach_capture([[:xqlite, :explain_analyze, :stop]])

      {:ok, %Xqlite.ExplainAnalyze{}} =
        Xqlite.explain_analyze(conn, "SELECT * FROM t", [])

      assert_receive {:telemetry_event, [:xqlite, :explain_analyze, :stop], _measurements,
                      metadata}

      assert metadata.result_class == :ok
      assert is_integer(metadata.wall_time_ns) and metadata.wall_time_ns >= 0
      assert is_integer(metadata.rows_produced) and metadata.rows_produced >= 0
      assert is_integer(metadata.scan_count) and metadata.scan_count >= 0

      detach(handler_id)
    end
  end

  describe "Xqlite.query_cancellable/4 telemetry" do
    test "fires with cancellable?: true on success", %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
      :ok = XqliteNIF.execute_batch(conn, "INSERT INTO t VALUES (1), (2);")

      {:ok, token} = XqliteNIF.create_cancel_token()

      handler_id =
        attach_capture([
          [:xqlite, :query, :start],
          [:xqlite, :query, :stop]
        ])

      {:ok, _} = Xqlite.query_cancellable(conn, "SELECT * FROM t", [], token)

      assert_receive {:telemetry_event, [:xqlite, :query, :start], _, %{cancellable?: true}}

      assert_receive {:telemetry_event, [:xqlite, :query, :stop], _,
                      %{cancellable?: true, result_class: :ok}}

      detach(handler_id)
    end

    test "fires :stop with error_reason: :operation_cancelled on cancel", %{conn: conn} do
      {:ok, token} = XqliteNIF.create_cancel_token()
      :ok = XqliteNIF.cancel_operation(token)

      handler_id = attach_capture([[:xqlite, :query, :stop]])

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

      detach(handler_id)
    end
  end

  describe "transaction telemetry" do
    setup %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE tx(id INTEGER PRIMARY KEY);")
      :ok
    end

    test "begin / commit fire single events with metadata", %{conn: conn} do
      handler_id =
        attach_capture([
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

      detach(handler_id)
    end

    test "rollback fires with reason: :user_initiated", %{conn: conn} do
      handler_id = attach_capture([[:xqlite, :transaction, :rollback]])

      :ok = Xqlite.begin(conn, :deferred)
      {:ok, _} = XqliteNIF.execute(conn, "INSERT INTO tx VALUES (1)", [])
      :ok = Xqlite.rollback(conn)

      assert_receive {:telemetry_event, [:xqlite, :transaction, :rollback], _,
                      %{conn: ^conn, reason: :user_initiated}}

      detach(handler_id)
    end

    test "savepoint create / rollback_to / release fire with name", %{conn: conn} do
      handler_id =
        attach_capture([
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

      detach(handler_id)
    end

    test "begin/commit on failure does NOT emit (event only fires on :ok)", %{conn: conn} do
      handler_id =
        attach_capture([
          [:xqlite, :transaction, :begin],
          [:xqlite, :transaction, :commit]
        ])

      # Try to commit when no transaction is active — should error and not emit.
      {:error, _} = Xqlite.commit(conn)
      refute_receive {:telemetry_event, [:xqlite, :transaction, :commit], _, _}, 100

      detach(handler_id)
    end
  end

  describe "Xqlite.close/1 telemetry" do
    test "fires :start and :stop with conn and path metadata", %{conn: conn} do
      handler_id =
        attach_capture([
          [:xqlite, :close, :start],
          [:xqlite, :close, :stop]
        ])

      assert :ok = Xqlite.close(conn)

      assert_receive {:telemetry_event, [:xqlite, :close, :start], start_measurements,
                      start_metadata}

      assert is_integer(start_measurements.monotonic_time)
      assert is_integer(start_measurements.system_time)
      assert start_metadata.conn == conn
      assert start_metadata.path == nil

      assert_receive {:telemetry_event, [:xqlite, :close, :stop], stop_measurements,
                      stop_metadata}

      assert is_integer(stop_measurements.duration)
      assert stop_metadata.conn == conn
      assert stop_metadata.path == nil

      detach(handler_id)
    end

    test "closing an already-closed connection still spans", %{conn: conn} do
      assert :ok = Xqlite.close(conn)

      handler_id = attach_capture([[:xqlite, :close, :stop]])

      assert :ok = Xqlite.close(conn)

      assert_receive {:telemetry_event, [:xqlite, :close, :stop], _measurements, metadata}
      assert metadata.path == nil

      detach(handler_id)
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
end
