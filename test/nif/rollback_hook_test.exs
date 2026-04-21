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
    end
  end
end
