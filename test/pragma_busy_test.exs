defmodule Xqlite.PragmaBusyTest do
  # Every connection here opens one shared file so that their locks contend;
  # the `connection_openers()` loop gives each connection a database of its own.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.TestUtil, only: [tmp_db_path: 1]

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  # Each name with a value SQLite takes after it. SQLite reads the schema while it
  # prepares the first five, and the file header when it steps the other four.
  @pragmas [
    {"journal_mode", "delete"},
    {"foreign_key_check", "t"},
    {"integrity_check", 1},
    {"quick_check", 1},
    {"page_count", 1},
    {"user_version", 7},
    {"schema_version", 7},
    {"freelist_count", 1},
    {"application_id", 7}
  ]

  setup do
    {:ok, path: tmp_db_path("pragma_busy")}
  end

  property "a PRAGMA that meets another connection's lock answers the busy error, retry: :call",
           %{path: path} do
    holder = holder(path)

    check all(
            {name, value} <- StreamData.member_of(@pragmas),
            call <- StreamData.member_of([:get, :set]),
            max_runs: 2_000
          ) do
      {:ok, probe} = NIF.open(path)
      :ok = Xqlite.put_busy_timeout(probe, 0)
      :ok = Xqlite.begin(holder, :exclusive)
      answer = pragma(call, probe, name, value)
      :ok = Xqlite.commit(holder)
      :ok = NIF.close(probe)
      assert {:error, {:database_busy, %{retry: :call}}} = answer
    end
  end

  test "the anchor: open/2 with busy_timeout: 0 answers the busy error its PRAGMAs meet",
       %{path: path} do
    holder = holder(path)
    :ok = Xqlite.begin(holder, :exclusive)

    assert {:error, {:database_busy, %{retry: :call}}} =
             Xqlite.open(path, journal_mode: :wal, busy_timeout: 0)

    :ok = Xqlite.commit(holder)
  end

  test "Xqlite.Pragma.get/2 waits out the lock its PRAGMA meets", %{path: path} do
    holder = holder(path)
    {:ok, probe} = NIF.open(path)
    {:ok, _} = Xqlite.register_busy_observer(probe, self())
    :ok = Xqlite.begin(holder, :exclusive)
    task = Task.async(fn -> Xqlite.Pragma.get(probe, :journal_mode) end)
    assert_receive {:xqlite_busy, 0, _}, 5_000
    :ok = Xqlite.commit(holder)
    assert {:ok, :delete} = Task.await(task)
  end

  # SQLite answers a checkpoint SQLITE_LOCKED while its own connection has a transaction open.
  test "a checkpoint PRAGMA inside the connection's own read transaction answers :database_locked",
       %{path: path} do
    {:ok, conn} = Xqlite.open(path)
    :ok = Xqlite.execute_batch(conn, "CREATE TABLE t(v); BEGIN; SELECT count(*) FROM t")

    assert {:error, {:database_locked, %{code: _, message: _}}} =
             NIF.get_pragma(conn, "wal_checkpoint")

    assert {:ok, %Xqlite.Result{rows: [[0]]}} = Xqlite.query(conn, "SELECT count(*) FROM t")
  end

  # In rollback-journal mode `BEGIN EXCLUSIVE` keeps every other connection
  # from reading the file, its schema and header included, until the commit.
  defp holder(path) do
    {:ok, holder} = Xqlite.open(path, journal_mode: :delete)
    :ok = Xqlite.execute_batch(holder, "CREATE TABLE t(v)")
    holder
  end

  defp pragma(:get, probe, name, _value), do: NIF.get_pragma(probe, name)
  defp pragma(:set, probe, name, value), do: NIF.set_pragma(probe, name, value)
end
