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

      test "hook fires on explicit rollback", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        :ok = NIF.set_rollback_hook(conn, self())

        :ok = NIF.begin(conn, :deferred)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])
        :ok = NIF.rollback(conn)

        assert_receive {:xqlite_rollback}, 500

        :ok = NIF.remove_rollback_hook(conn)
      end

      test "hook does not fire on commit", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        :ok = NIF.set_rollback_hook(conn, self())

        :ok = NIF.begin(conn, :deferred)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])
        :ok = NIF.commit(conn)

        refute_receive {:xqlite_rollback}, 100

        :ok = NIF.remove_rollback_hook(conn)
      end

      test "remove stops delivery", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        :ok = NIF.set_rollback_hook(conn, self())

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)
        assert_receive {:xqlite_rollback}, 500

        :ok = NIF.remove_rollback_hook(conn)

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)
        refute_receive {:xqlite_rollback}, 100
      end

      test "multiple sequential rollbacks each fire exactly once", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        collector = spawn_collector()
        :ok = NIF.set_rollback_hook(conn, collector)

        for i <- 1..5 do
          :ok = NIF.begin(conn, :deferred)
          {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (?1)", [i])
          :ok = NIF.rollback(conn)
        end

        assert length(get_collected(collector)) == 5

        :ok = NIF.remove_rollback_hook(conn)
      end

      test "re-register after remove works", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        :ok = NIF.set_rollback_hook(conn, self())
        :ok = NIF.remove_rollback_hook(conn)
        :ok = NIF.set_rollback_hook(conn, self())

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)

        assert_receive {:xqlite_rollback}, 500

        :ok = NIF.remove_rollback_hook(conn)
      end

      test "replacing listener — old pid stops receiving", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        old_listener = spawn_collector()
        new_listener = spawn_collector()

        :ok = NIF.set_rollback_hook(conn, old_listener)
        :ok = NIF.set_rollback_hook(conn, new_listener)

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)

        # Give the fire-and-forget send a moment to complete.
        Process.sleep(20)

        assert length(get_collected(new_listener)) > 0
        assert get_collected(old_listener) == []

        :ok = NIF.remove_rollback_hook(conn)
      end

      test "dead subscriber pid does not crash the NIF", %{conn: conn} do
        dead = spawn(fn -> :ok end)
        ref = Process.monitor(dead)
        receive do: ({:DOWN, ^ref, :process, ^dead, _} -> :ok)

        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        :ok = NIF.set_rollback_hook(conn, dead)

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)

        :ok = NIF.remove_rollback_hook(conn)
      end

      test "GenServer-like process forwards rollback events", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        test_pid = self()

        forwarder =
          spawn(fn ->
            forwarder_loop(test_pid)
          end)

        :ok = NIF.set_rollback_hook(conn, forwarder)

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)

        assert_receive {:forwarded_rollback, {:xqlite_rollback}}, 500

        :ok = NIF.remove_rollback_hook(conn)
      end

      test "survives 50 rapid set/remove cycles", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        for _ <- 1..50 do
          :ok = NIF.set_rollback_hook(conn, self())
          :ok = NIF.remove_rollback_hook(conn)
        end

        :ok = NIF.set_rollback_hook(conn, self())

        :ok = NIF.begin(conn, :deferred)
        :ok = NIF.rollback(conn)

        assert_receive {:xqlite_rollback}, 500

        :ok = NIF.remove_rollback_hook(conn)
      end

      test "ROLLBACK TO SAVEPOINT does NOT fire the hook", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

        :ok = NIF.set_rollback_hook(conn, self())

        :ok = NIF.begin(conn, :deferred)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (1)", [])

        :ok = NIF.savepoint(conn, "sp1")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (2)", [])
        :ok = NIF.rollback_to_savepoint(conn, "sp1")
        :ok = NIF.release_savepoint(conn, "sp1")

        # SQLite's documented behavior: rollback_hook is NOT invoked for
        # ROLLBACK TO SAVEPOINT operations, only for outer-transaction
        # rollbacks.
        refute_receive {:xqlite_rollback}, 100

        # But an actual outer rollback still fires.
        :ok = NIF.rollback(conn)
        assert_receive {:xqlite_rollback}, 500

        :ok = NIF.remove_rollback_hook(conn)
      end
    end
  end

  # Outside the per-connection-mode loop — closed-conn + multi-conn isolation.

  describe "closed connection" do
    test "set_rollback_hook on closed connection returns error" do
      {:ok, conn} = XqliteNIF.open_in_memory(":memory:")
      :ok = XqliteNIF.close(conn)
      assert {:error, :connection_closed} = XqliteNIF.set_rollback_hook(conn, self())
    end

    test "remove_rollback_hook on closed connection returns error" do
      {:ok, conn} = XqliteNIF.open_in_memory(":memory:")
      :ok = XqliteNIF.close(conn)
      assert {:error, :connection_closed} = XqliteNIF.remove_rollback_hook(conn)
    end
  end

  describe "per-connection isolation" do
    test "hook on conn1 does not fire for conn2 rollbacks" do
      {:ok, conn1} = XqliteNIF.open_in_memory(":memory:")
      {:ok, conn2} = XqliteNIF.open_in_memory(":memory:")

      on_exit(fn ->
        XqliteNIF.close(conn1)
        XqliteNIF.close(conn2)
      end)

      :ok = XqliteNIF.execute_batch(conn2, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

      listener1 = spawn_collector()
      :ok = XqliteNIF.set_rollback_hook(conn1, listener1)

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
