defmodule Xqlite.NIF.WalHookTest do
  # File-backed DB required — WAL mode is a no-op for in-memory / temp
  # anonymous databases, so no wal_hook would ever fire there.
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF

  setup do
    path =
      Path.join(System.tmp_dir!(), "xqlite_walhook_#{:erlang.unique_integer([:positive])}.db")

    on_exit(fn ->
      for ext <- ["", "-wal", "-shm", "-journal"], do: File.rm(path <> ext)
    end)

    {:ok, conn} = NIF.open(path)
    {:ok, _} = NIF.set_pragma(conn, "journal_mode", "WAL")

    {:ok, path: path, conn: conn}
  end

  test "register / unregister returns handle and is idempotent", %{conn: conn} do
    assert {:ok, h} = NIF.register_wal_hook(conn, self())
    assert is_integer(h) and h > 0
    assert :ok = NIF.unregister_wal_hook(conn, h)
    # Idempotent: same handle, second unregister still :ok.
    assert :ok = NIF.unregister_wal_hook(conn, h)
    # Unknown handle: also :ok.
    assert :ok = NIF.unregister_wal_hook(conn, 999_999)
  end

  test "single subscriber: hook fires after commit with db name and page count",
       %{conn: conn} do
    {:ok, h} = NIF.register_wal_hook(conn, self())
    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);")
    {:ok, 1} = NIF.execute(conn, "INSERT INTO t(v) VALUES (?1)", ["a"])

    assert_receive {:xqlite_wal, db_name, pages}, 500
    assert db_name == "main"
    assert is_integer(pages) and pages >= 0

    :ok = NIF.unregister_wal_hook(conn, h)
  end

  test "multiple commits produce multiple notifications", %{conn: conn} do
    {:ok, h} = NIF.register_wal_hook(conn, self())
    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

    # Drain the CREATE TABLE's commit notification.
    assert_receive {:xqlite_wal, _, _}, 500

    for _ <- 1..3 do
      {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])
    end

    for _ <- 1..3 do
      assert_receive {:xqlite_wal, "main", _}, 500
    end

    :ok = NIF.unregister_wal_hook(conn, h)
  end

  test "unregister stops delivery to that subscriber", %{conn: conn} do
    {:ok, h} = NIF.register_wal_hook(conn, self())
    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
    assert_receive {:xqlite_wal, _, _}, 500

    :ok = NIF.unregister_wal_hook(conn, h)

    {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])
    refute_receive {:xqlite_wal, _, _}, 100
  end

  test "two subscribers each receive every event", %{conn: conn} do
    listener_a = spawn_collector()
    listener_b = spawn_collector()

    {:ok, h_a} = NIF.register_wal_hook(conn, listener_a)
    {:ok, h_b} = NIF.register_wal_hook(conn, listener_b)

    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
    {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])
    Process.sleep(20)

    msgs_a = get_collected(listener_a)
    msgs_b = get_collected(listener_b)
    assert length(msgs_a) > 0
    assert length(msgs_b) > 0
    # Both should see the same number of events (each commit fans out to both).
    assert length(msgs_a) == length(msgs_b)

    :ok = NIF.unregister_wal_hook(conn, h_a)
    :ok = NIF.unregister_wal_hook(conn, h_b)
  end

  test "unregistering one subscriber leaves the other working", %{conn: conn} do
    listener_kept = spawn_collector()
    listener_removed = spawn_collector()

    {:ok, h_kept} = NIF.register_wal_hook(conn, listener_kept)
    {:ok, h_removed} = NIF.register_wal_hook(conn, listener_removed)

    :ok = NIF.unregister_wal_hook(conn, h_removed)

    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
    {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])
    Process.sleep(20)

    assert length(get_collected(listener_kept)) > 0
    assert get_collected(listener_removed) == []

    :ok = NIF.unregister_wal_hook(conn, h_kept)
  end

  test "dead subscriber pid does not crash the NIF or block siblings",
       %{conn: conn} do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    receive do: ({:DOWN, ^ref, :process, ^dead, _} -> :ok)

    live = spawn_collector()

    {:ok, h_dead} = NIF.register_wal_hook(conn, dead)
    {:ok, h_live} = NIF.register_wal_hook(conn, live)

    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
    {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])
    Process.sleep(20)

    # Live subscriber must still receive its messages despite the dead
    # one in the same fan-out list.
    assert length(get_collected(live)) > 0

    :ok = NIF.unregister_wal_hook(conn, h_dead)
    :ok = NIF.unregister_wal_hook(conn, h_live)
  end

  test "register / unregister on a closed connection returns structured error",
       %{path: path} do
    {:ok, conn} = NIF.open(path)
    :ok = NIF.close(conn)

    assert {:error, :connection_closed} = NIF.register_wal_hook(conn, self())
    assert {:error, :connection_closed} = NIF.unregister_wal_hook(conn, 1)
  end

  test "per-connection isolation: a hook on conn A is not invoked by conn B commits",
       %{path: path} do
    {:ok, conn_b} = NIF.open(path)
    {:ok, _} = NIF.set_pragma(conn_b, "journal_mode", "WAL")
    on_exit(fn -> NIF.close(conn_b) end)

    collector_a = spawn_collector()
    {:ok, _h_b} = NIF.register_wal_hook(conn_b, self())

    :ok = NIF.execute_batch(conn_b, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
    assert_receive {:xqlite_wal, "main", _}, 500

    assert get_collected(collector_a) == []
  end

  test "GenServer-like process forwards wal events", %{conn: conn} do
    test_pid = self()

    forwarder =
      spawn(fn ->
        forwarder_loop(test_pid)
      end)

    {:ok, h} = NIF.register_wal_hook(conn, forwarder)
    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

    assert_receive {:forwarded_wal, {:xqlite_wal, "main", _}}, 500

    :ok = NIF.unregister_wal_hook(conn, h)
  end

  test "survives 50 rapid register/unregister cycles", %{conn: conn} do
    for _ <- 1..50 do
      {:ok, h} = NIF.register_wal_hook(conn, self())
      :ok = NIF.unregister_wal_hook(conn, h)
    end

    {:ok, h} = NIF.register_wal_hook(conn, self())
    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
    assert_receive {:xqlite_wal, "main", _}, 500
    :ok = NIF.unregister_wal_hook(conn, h)
  end

  test "concurrent register/unregister from multiple tasks does not crash",
       %{conn: conn} do
    tasks =
      Enum.map(1..10, fn _ ->
        Task.async(fn ->
          for _ <- 1..20 do
            {:ok, h} = NIF.register_wal_hook(conn, self())
            NIF.unregister_wal_hook(conn, h)
          end
        end)
      end)

    Task.await_many(tasks, 10_000)

    # Sanity: register one more, do a write, get an event, unregister.
    {:ok, h} = NIF.register_wal_hook(conn, self())
    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
    assert_receive {:xqlite_wal, "main", _}, 500
    :ok = NIF.unregister_wal_hook(conn, h)
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

      {:xqlite_wal, _, _} = event ->
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
      {:xqlite_wal, _, _} = event ->
        send(target, {:forwarded_wal, event})
        forwarder_loop(target)
    end
  end
end
