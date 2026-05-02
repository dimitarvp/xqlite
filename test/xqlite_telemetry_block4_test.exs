defmodule Xqlite.XqliteTelemetryBlock4Test do
  @moduledoc """
  Block 4 telemetry: cancel events + the hook → telemetry bridge.

  Cancel events:
    [:xqlite, :cancel, :token_created]
    [:xqlite, :cancel, :signalled]
    [:xqlite, :cancel, :honored]

  Bridge:
    [:xqlite, :hook, :wal | :commit | :rollback | :update | :progress | :log]
  """

  use ExUnit.Case, async: true

  alias Xqlite.Telemetry.Bridge

  setup do
    {:ok, conn} = Xqlite.open_in_memory()
    on_exit(fn -> XqliteNIF.close(conn) end)
    {:ok, conn: conn}
  end

  describe "cancel events" do
    test "create_cancel_token fires :token_created" do
      handler_id = "test-cancel-create-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :cancel, :token_created]])

      {:ok, token} = Xqlite.create_cancel_token()

      assert_receive {:telemetry_event, [:xqlite, :cancel, :token_created], _,
                      %{token: ^token}}

      :telemetry.detach(handler_id)
    end

    test "cancel_operation fires :signalled" do
      {:ok, token} = Xqlite.create_cancel_token()

      handler_id = "test-cancel-signal-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :cancel, :signalled]])

      :ok = Xqlite.cancel_operation(token)

      assert_receive {:telemetry_event, [:xqlite, :cancel, :signalled], _, %{token: ^token}}

      :telemetry.detach(handler_id)
    end

    test "cancellable query that gets interrupted fires :honored", %{conn: conn} do
      {:ok, token} = Xqlite.create_cancel_token()
      :ok = Xqlite.cancel_operation(token)

      handler_id = "test-cancel-honored-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :cancel, :honored]])

      {:error, :operation_cancelled} =
        Xqlite.query_cancellable(
          conn,
          "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT count(*) FROM n",
          [],
          token
        )

      assert_receive {:telemetry_event, [:xqlite, :cancel, :honored], _, metadata}
      assert metadata.conn == conn
      assert metadata.operation == :query
      assert is_list(metadata.tokens)
      assert token in metadata.tokens

      :telemetry.detach(handler_id)
    end

    test "cancellable query that completes normally does NOT fire :honored",
         %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
      {:ok, token} = Xqlite.create_cancel_token()

      handler_id = "test-cancel-no-honored-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :cancel, :honored]])

      {:ok, _} = Xqlite.query_cancellable(conn, "SELECT * FROM t", [], token)

      refute_receive {:telemetry_event, [:xqlite, :cancel, :honored], _, _}, 100

      :telemetry.detach(handler_id)
    end

    test "cancellable execute_batch / execute / query_with_changes all fire :honored on cancel",
         %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

      handler_id = "test-cancel-multi-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :cancel, :honored]])

      {:ok, t1} = Xqlite.create_cancel_token()
      :ok = Xqlite.cancel_operation(t1)

      slow =
        "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT count(*) FROM n"

      {:error, :operation_cancelled} = Xqlite.execute_cancellable(conn, slow, [], t1)

      assert_receive {:telemetry_event, [:xqlite, :cancel, :honored], _,
                      %{operation: :execute}}

      {:ok, t2} = Xqlite.create_cancel_token()
      :ok = Xqlite.cancel_operation(t2)

      {:error, :operation_cancelled} =
        Xqlite.execute_batch_cancellable(conn, "BEGIN; #{slow};", t2)

      assert_receive {:telemetry_event, [:xqlite, :cancel, :honored], _,
                      %{operation: :execute_batch}}

      {:ok, t3} = Xqlite.create_cancel_token()
      :ok = Xqlite.cancel_operation(t3)

      {:error, :operation_cancelled} =
        Xqlite.query_with_changes_cancellable(conn, slow, [], t3)

      assert_receive {:telemetry_event, [:xqlite, :cancel, :honored], _,
                      %{operation: :query_with_changes}}

      :telemetry.detach(handler_id)
    end
  end

  describe "Xqlite.Telemetry.bridge/2" do
    test "registers hooks and re-emits as telemetry", %{conn: conn} do
      {:ok, bridge} =
        Xqlite.Telemetry.bridge(conn, hooks: [:commit, :rollback], tag: :unit)

      assert %Bridge{pid: pid, scope: {:conn, ^conn}, tag: :unit} = bridge
      assert is_pid(pid) and Process.alive?(pid)

      handler_id = "test-bridge-cr-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :hook, :commit], [:xqlite, :hook, :rollback]])

      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
      assert_receive {:telemetry_event, [:xqlite, :hook, :commit], _, %{tag: :unit}}

      :ok = XqliteNIF.begin(conn, :deferred)
      :ok = XqliteNIF.rollback(conn)
      assert_receive {:telemetry_event, [:xqlite, :hook, :rollback], _, %{tag: :unit}}

      :ok = Xqlite.Telemetry.unbridge(bridge)
      :telemetry.detach(handler_id)
    end

    test "wal hook bridge re-emits with db_name + pages" do
      path =
        Path.join(System.tmp_dir!(), "xqlite_bridge_#{:erlang.unique_integer([:positive])}.db")

      on_exit(fn ->
        for ext <- ["", "-wal", "-shm"], do: File.rm(path <> ext)
      end)

      # Use the raw NIF + set journal_mode manually to avoid
      # `Xqlite.open/2`'s `wal_autocheckpoint` PRAGMA, which silently
      # replaces our master wal hook callback at the SQLite C level.
      # Documented in the WAL hook moduledoc warning.
      {:ok, conn} = XqliteNIF.open(path)
      on_exit(fn -> XqliteNIF.close(conn) end)
      {:ok, _} = XqliteNIF.set_pragma(conn, "journal_mode", "WAL")

      {:ok, bridge} = Xqlite.Telemetry.bridge(conn, hooks: [:wal])

      handler_id = "test-bridge-wal-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :hook, :wal]])

      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER);")

      assert_receive {:telemetry_event, [:xqlite, :hook, :wal], measurements, metadata}, 1_000
      assert measurements.pages >= 0
      assert metadata.db_name == "main"

      :ok = Xqlite.Telemetry.unbridge(bridge)
      :telemetry.detach(handler_id)
    end

    test "update hook bridge fires for INSERT/UPDATE/DELETE", %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);")
      {:ok, bridge} = Xqlite.Telemetry.bridge(conn, hooks: [:update])

      handler_id = "test-bridge-up-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :hook, :update]])

      {:ok, 1} = XqliteNIF.execute(conn, "INSERT INTO t VALUES (1, 'a')", [])

      assert_receive {:telemetry_event, [:xqlite, :hook, :update], _, metadata}
      assert metadata.action == :insert
      assert metadata.table == "t"
      assert metadata.rowid == 1

      :ok = Xqlite.Telemetry.unbridge(bridge)
      :telemetry.detach(handler_id)
    end

    test ":all expands to every per-conn hook", %{conn: conn} do
      {:ok, bridge} = Xqlite.Telemetry.bridge(conn, hooks: :all)

      assert length(bridge.hook_handles) == 5
      assert Enum.all?(bridge.hook_handles, fn {h, _} -> is_atom(h) end)

      :ok = Xqlite.Telemetry.unbridge(bridge)
    end

    test "rejects invalid hook names", %{conn: conn} do
      assert {:error, {:invalid_hook, :nonsense, valid: _}} =
               Xqlite.Telemetry.bridge(conn, hooks: [:nonsense])
    end

    test "unbridge stops the GenServer and unregisters hooks", %{conn: conn} do
      {:ok, bridge} = Xqlite.Telemetry.bridge(conn, hooks: [:commit])
      pid = bridge.pid

      assert Process.alive?(pid)
      :ok = Xqlite.Telemetry.unbridge(bridge)
      Process.sleep(50)
      refute Process.alive?(pid)

      # After unbridge, no more events should fire even if a commit occurs.
      handler_id = "test-bridge-after-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :hook, :commit]])

      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER);")
      refute_receive {:telemetry_event, [:xqlite, :hook, :commit], _, _}, 100

      :telemetry.detach(handler_id)
    end
  end

  describe "Xqlite.Telemetry.bridge_log/1" do
    test "registers global log hook + re-emits" do
      {:ok, bridge} = Xqlite.Telemetry.bridge_log(tag: :app)
      assert bridge.scope == :log
      assert bridge.tag == :app

      handler_id = "test-bridge-log-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :hook, :log]])

      # Trigger an autoindex warning to generate a log event.
      {:ok, conn} = Xqlite.open_in_memory()
      on_exit(fn -> XqliteNIF.close(conn) end)
      trigger_autoindex_warning(conn)

      assert_receive {:telemetry_event, [:xqlite, :hook, :log], _, metadata}, 2_000
      assert is_integer(metadata.code)
      assert is_binary(metadata.message)
      assert metadata.tag == :app

      :ok = Xqlite.Telemetry.unbridge(bridge)
      :telemetry.detach(handler_id)
    end
  end

  describe "subscription-API contract for the bridge" do
    test "bridge does not interfere with direct hook subscribers", %{conn: conn} do
      # Direct subscriber registers first.
      {:ok, _h_direct} = XqliteNIF.register_commit_hook(conn, self())

      # Bridge registers second.
      {:ok, bridge} = Xqlite.Telemetry.bridge(conn, hooks: [:commit])

      handler_id = "test-bridge-coexist-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :hook, :commit]])

      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER);")

      # Direct subscriber gets the raw message.
      assert_receive {:xqlite_commit}

      # Bridge re-emits as telemetry.
      assert_receive {:telemetry_event, [:xqlite, :hook, :commit], _, _}

      :ok = Xqlite.Telemetry.unbridge(bridge)
      :telemetry.detach(handler_id)
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

  defp trigger_autoindex_warning(conn) do
    :ok =
      XqliteNIF.execute_batch(conn, """
      CREATE TABLE IF NOT EXISTS log_a (a TEXT, b TEXT);
      CREATE TABLE IF NOT EXISTS log_b (x TEXT, y TEXT);
      """)

    for i <- 1..30 do
      {:ok, 1} =
        XqliteNIF.execute(conn, "INSERT INTO log_a VALUES (?1, ?2)", ["v#{i}", "d#{i}"])

      {:ok, 1} =
        XqliteNIF.execute(conn, "INSERT INTO log_b VALUES (?1, ?2)", ["v#{i}", "e#{i}"])
    end

    {:ok, _} =
      XqliteNIF.query(conn, "SELECT * FROM log_a, log_b WHERE log_a.a = log_b.x", [])
  end
end
