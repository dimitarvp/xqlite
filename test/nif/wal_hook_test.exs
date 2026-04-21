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

  test "hook fires after commit with db name and page count", %{conn: conn} do
    :ok = NIF.set_wal_hook(conn, self())
    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);")
    {:ok, 1} = NIF.execute(conn, "INSERT INTO t(v) VALUES (?1)", ["a"])

    assert_receive {:xqlite_wal, db_name, pages}, 500
    assert db_name == "main"
    assert is_integer(pages) and pages >= 0

    :ok = NIF.remove_wal_hook(conn)
  end

  test "multiple commits produce multiple notifications", %{conn: conn} do
    :ok = NIF.set_wal_hook(conn, self())
    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

    # Drain the CREATE TABLE's commit notification.
    assert_receive {:xqlite_wal, _, _}, 500

    for _ <- 1..3 do
      {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])
    end

    for _ <- 1..3 do
      assert_receive {:xqlite_wal, "main", _}, 500
    end

    :ok = NIF.remove_wal_hook(conn)
  end

  test "remove stops delivery", %{conn: conn} do
    :ok = NIF.set_wal_hook(conn, self())
    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
    assert_receive {:xqlite_wal, _, _}, 500

    :ok = NIF.remove_wal_hook(conn)

    {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])
    refute_receive {:xqlite_wal, _, _}, 100
  end

  test "replacing hook atomically — previous pid stops receiving", %{conn: conn} do
    old_listener = spawn_collector()
    new_listener = spawn_collector()

    :ok = NIF.set_wal_hook(conn, old_listener)
    :ok = NIF.set_wal_hook(conn, new_listener)

    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
    {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])

    assert length(get_collected(new_listener)) > 0
    assert get_collected(old_listener) == []

    :ok = NIF.remove_wal_hook(conn)
  end

  test "re-register after remove works", %{conn: conn} do
    :ok = NIF.set_wal_hook(conn, self())
    :ok = NIF.remove_wal_hook(conn)
    :ok = NIF.set_wal_hook(conn, self())

    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
    assert_receive {:xqlite_wal, "main", _}, 500

    :ok = NIF.remove_wal_hook(conn)
  end

  test "dead subscriber pid does not crash the NIF", %{conn: conn} do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    receive do: ({:DOWN, ^ref, :process, ^dead, _} -> :ok)

    :ok = NIF.set_wal_hook(conn, dead)

    # DDL + DML must both succeed with a dead subscriber.
    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
    {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])

    :ok = NIF.remove_wal_hook(conn)
  end

  test "set / remove on a closed connection returns structured error", %{path: path} do
    {:ok, conn} = NIF.open(path)
    :ok = NIF.close(conn)

    assert {:error, :connection_closed} = NIF.set_wal_hook(conn, self())
    assert {:error, :connection_closed} = NIF.remove_wal_hook(conn)
  end

  test "per-connection isolation: hook on conn A is not invoked by conn B commits", %{
    path: path
  } do
    {:ok, conn_b} = NIF.open(path)
    {:ok, _} = NIF.set_pragma(conn_b, "journal_mode", "WAL")
    on_exit(fn -> NIF.close(conn_b) end)

    # Give conn A (from setup) a hook pointed at a collector; conn B gets none.
    collector_a = spawn_collector()
    :ok = NIF.set_wal_hook(conn_b, self())

    # Use conn_b for a commit; its hook (self) should receive the message.
    :ok = NIF.execute_batch(conn_b, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
    assert_receive {:xqlite_wal, "main", _}, 500

    # conn_a's listener (collector) should remain empty.
    assert get_collected(collector_a) == []

    :ok = NIF.remove_wal_hook(conn_b)
  end

  test "GenServer-like process forwards wal events", %{conn: conn} do
    test_pid = self()

    forwarder =
      spawn(fn ->
        forwarder_loop(test_pid)
      end)

    :ok = NIF.set_wal_hook(conn, forwarder)
    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

    assert_receive {:forwarded_wal, {:xqlite_wal, "main", _}}, 500

    :ok = NIF.remove_wal_hook(conn)
  end

  test "survives 50 rapid set/remove cycles without dropping messages", %{conn: conn} do
    for _ <- 1..50 do
      :ok = NIF.set_wal_hook(conn, self())
      :ok = NIF.remove_wal_hook(conn)
    end

    :ok = NIF.set_wal_hook(conn, self())
    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

    assert_receive {:xqlite_wal, "main", _}, 500

    :ok = NIF.remove_wal_hook(conn)
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
