defmodule Xqlite.NIF.RollbackHookTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "rollback hook using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "register / unregister returns handle and is idempotent", %{conn: conn} do
        assert {:ok, h} = NIF.register_rollback_hook(conn, self())
        assert is_integer(h) and h > 0
        assert :ok = NIF.unregister_rollback_hook(conn, h)
        assert :ok = NIF.unregister_rollback_hook(conn, h)
        assert :ok = NIF.unregister_rollback_hook(conn, 999_999)
      end

      test "single subscriber fires on explicit rollback", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        {:ok, h} = NIF.register_rollback_hook(conn, self())

        :ok = NIF.begin(conn, :deferred)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])
        :ok = NIF.rollback(conn)

        assert_receive {:xqlite_rollback}, 500

        :ok = NIF.unregister_rollback_hook(conn, h)
      end

      test "does not fire on commit", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        {:ok, h} = NIF.register_rollback_hook(conn, self())

        :ok = NIF.begin(conn, :deferred)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])
        :ok = NIF.commit(conn)

        refute_receive {:xqlite_rollback}, 100

        :ok = NIF.unregister_rollback_hook(conn, h)
      end

      test "unregister stops delivery to that subscriber", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        {:ok, h} = NIF.register_rollback_hook(conn, self())

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)
        assert_receive {:xqlite_rollback}, 500

        :ok = NIF.unregister_rollback_hook(conn, h)

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)
        refute_receive {:xqlite_rollback}, 100
      end

      test "multiple sequential rollbacks each fire exactly once per subscriber",
           %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        collector = spawn_collector()
        {:ok, h} = NIF.register_rollback_hook(conn, collector)

        for i <- 1..5 do
          :ok = NIF.begin(conn, :deferred)
          {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (?1)", [i])
          :ok = NIF.rollback(conn)
        end

        assert length(get_collected(collector)) == 5

        :ok = NIF.unregister_rollback_hook(conn, h)
      end

      test "two subscribers each receive every rollback", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        listener_a = spawn_collector()
        listener_b = spawn_collector()

        {:ok, h_a} = NIF.register_rollback_hook(conn, listener_a)
        {:ok, h_b} = NIF.register_rollback_hook(conn, listener_b)

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)
        Process.sleep(20)

        msgs_a = get_collected(listener_a)
        msgs_b = get_collected(listener_b)
        assert length(msgs_a) == 1
        assert length(msgs_b) == 1

        :ok = NIF.unregister_rollback_hook(conn, h_a)
        :ok = NIF.unregister_rollback_hook(conn, h_b)
      end

      test "unregistering one subscriber leaves the other working", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        listener_kept = spawn_collector()
        listener_removed = spawn_collector()

        {:ok, h_kept} = NIF.register_rollback_hook(conn, listener_kept)
        {:ok, h_removed} = NIF.register_rollback_hook(conn, listener_removed)

        :ok = NIF.unregister_rollback_hook(conn, h_removed)

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)
        Process.sleep(20)

        assert length(get_collected(listener_kept)) == 1
        assert get_collected(listener_removed) == []

        :ok = NIF.unregister_rollback_hook(conn, h_kept)
      end

      test "dead subscriber pid does not crash or block siblings", %{conn: conn} do
        dead = spawn(fn -> :ok end)
        ref = Process.monitor(dead)
        receive do: ({:DOWN, ^ref, :process, ^dead, _} -> :ok)

        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        live = spawn_collector()

        {:ok, h_dead} = NIF.register_rollback_hook(conn, dead)
        {:ok, h_live} = NIF.register_rollback_hook(conn, live)

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)
        Process.sleep(20)

        assert length(get_collected(live)) == 1

        :ok = NIF.unregister_rollback_hook(conn, h_dead)
        :ok = NIF.unregister_rollback_hook(conn, h_live)
      end

      test "GenServer-like process forwards rollback events", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        test_pid = self()

        forwarder =
          spawn(fn ->
            forwarder_loop(test_pid)
          end)

        {:ok, h} = NIF.register_rollback_hook(conn, forwarder)

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)

        assert_receive {:forwarded_rollback, {:xqlite_rollback}}, 500

        :ok = NIF.unregister_rollback_hook(conn, h)
      end

      test "survives 50 rapid register/unregister cycles", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        for _ <- 1..50 do
          {:ok, h} = NIF.register_rollback_hook(conn, self())
          :ok = NIF.unregister_rollback_hook(conn, h)
        end

        {:ok, h} = NIF.register_rollback_hook(conn, self())

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)

        assert_receive {:xqlite_rollback}, 500

        :ok = NIF.unregister_rollback_hook(conn, h)
      end

      test "ROLLBACK TO SAVEPOINT does NOT fire the hook", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        {:ok, h} = NIF.register_rollback_hook(conn, self())

        :ok = NIF.begin(conn, :deferred)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (1)", [])

        :ok = NIF.savepoint(conn, "sp1")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (2)", [])
        :ok = NIF.rollback_to_savepoint(conn, "sp1")
        :ok = NIF.release_savepoint(conn, "sp1")

        # SQLite documented behavior: rollback_hook is NOT invoked for
        # ROLLBACK TO SAVEPOINT, only for outer-transaction rollbacks.
        refute_receive {:xqlite_rollback}, 100

        :ok = NIF.rollback(conn)
        assert_receive {:xqlite_rollback}, 500

        :ok = NIF.unregister_rollback_hook(conn, h)
      end
    end
  end

  describe "closed connection" do
    test "register on closed connection returns error" do
      {:ok, conn} = XqliteNIF.open_in_memory(":memory:")
      :ok = XqliteNIF.close(conn)

      assert {:error, :connection_closed} =
               XqliteNIF.register_rollback_hook(conn, self())
    end

    test "unregister on closed connection returns error" do
      {:ok, conn} = XqliteNIF.open_in_memory(":memory:")
      :ok = XqliteNIF.close(conn)

      assert {:error, :connection_closed} =
               XqliteNIF.unregister_rollback_hook(conn, 1)
    end
  end

  describe "per-connection isolation" do
    test "subscriber on conn1 does not fire for conn2 rollbacks" do
      {:ok, conn1} = XqliteNIF.open_in_memory(":memory:")
      {:ok, conn2} = XqliteNIF.open_in_memory(":memory:")

      on_exit(fn ->
        XqliteNIF.close(conn1)
        XqliteNIF.close(conn2)
      end)

      :ok = XqliteNIF.execute_batch(conn2, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

      listener1 = spawn_collector()
      {:ok, _h1} = XqliteNIF.register_rollback_hook(conn1, listener1)

      :ok = XqliteNIF.begin(conn2, :deferred)
      :ok = XqliteNIF.rollback(conn2)

      assert get_collected(listener1) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp spawn_collector do
    spawn(fn -> collector_loop([]) end)
  end

  defp collector_loop(acc) do
    receive do
      {:get, from} ->
        send(from, {:collected, Enum.reverse(acc)})
        collector_loop(acc)

      {:xqlite_rollback} = event ->
        collector_loop([event | acc])
    end
  end

  defp get_collected(pid) do
    send(pid, {:get, self()})

    receive do
      {:collected, msgs} -> msgs
    after
      500 -> []
    end
  end

  defp forwarder_loop(target) do
    receive do
      {:xqlite_rollback} = event ->
        send(target, {:forwarded_rollback, event})
        forwarder_loop(target)
    end
  end
end
