defmodule Xqlite.NIF.TxnStateTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "autocommit/1 returns true on a fresh connection", %{conn: conn} do
        assert {:ok, true} = NIF.autocommit(conn)
      end

      test "autocommit/1 returns false inside a transaction", %{conn: conn} do
        {:ok, _} = NIF.execute(conn, "BEGIN", [])
        assert {:ok, false} = NIF.autocommit(conn)
        {:ok, _} = NIF.execute(conn, "COMMIT", [])
        assert {:ok, true} = NIF.autocommit(conn)
      end

      test "txn_state/1 returns :none on a fresh connection", %{conn: conn} do
        assert {:ok, :none} = NIF.txn_state(conn)
      end

      test "txn_state/1 returns :read after a read-only statement in a txn", %{conn: conn} do
        {:ok, 0} = NIF.execute(conn, "CREATE TABLE t(id INTEGER)", [])
        {:ok, _} = NIF.execute(conn, "BEGIN", [])
        {:ok, _} = NIF.query(conn, "SELECT 1 FROM t", [])
        assert {:ok, :read} = NIF.txn_state(conn)
        {:ok, _} = NIF.execute(conn, "COMMIT", [])
      end

      test "txn_state/1 returns :write after a write statement in a txn", %{conn: conn} do
        {:ok, 0} = NIF.execute(conn, "CREATE TABLE t(id INTEGER)", [])
        {:ok, _} = NIF.execute(conn, "BEGIN", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (1)", [])
        assert {:ok, :write} = NIF.txn_state(conn)
        {:ok, _} = NIF.execute(conn, "COMMIT", [])
        assert {:ok, :none} = NIF.txn_state(conn)
      end

      test "txn_state/2 accepts a schema name", %{conn: conn} do
        assert {:ok, :none} = NIF.txn_state(conn, "main")
      end

      test "txn_state/2 on an unknown schema errors", %{conn: conn} do
        assert {:error, _} = NIF.txn_state(conn, "does_not_exist")
      end
    end
  end
end
