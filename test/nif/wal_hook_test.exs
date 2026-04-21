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
    pid = self()

    sink_pid =
      spawn(fn ->
        receive do
          _ -> :ok
        end
      end)

    # Install with self() first.
    :ok = NIF.set_wal_hook(conn, pid)
    :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
    assert_receive {:xqlite_wal, _, _}, 500

    # Replace with a different pid.
    :ok = NIF.set_wal_hook(conn, sink_pid)
    {:ok, 1} = NIF.execute(conn, "INSERT INTO t DEFAULT VALUES", [])

    # Original pid (self) should receive nothing new.
    refute_receive {:xqlite_wal, _, _}, 100

    :ok = NIF.remove_wal_hook(conn)
  end
end
