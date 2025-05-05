defmodule Xqlite.NIF.LastInsertRowidTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]
  alias XqliteNIF, as: NIF

  @table_sql "CREATE TABLE rowid_test (id INTEGER PRIMARY KEY, data TEXT);"

  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        assert {:ok, 0} = NIF.execute(conn, @table_sql, [])
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "returns the explicit rowid", %{conn: conn} do
        insert_sql = "INSERT INTO rowid_test (id, data) VALUES (?1, ?2);"
        explicit_id = 123
        insert_params = [explicit_id, "explicit data"]
        assert {:ok, 1} = NIF.execute(conn, insert_sql, insert_params)
        assert {:ok, ^explicit_id} = NIF.last_insert_rowid(conn)
      end

      test "returns the auto-generated rowid", %{conn: conn} do
        insert_sql = "INSERT INTO rowid_test (data) VALUES (?1);"
        assert {:ok, 1} = NIF.execute(conn, insert_sql, ["auto data 1"])
        # First auto-generated rowid is typically 1
        assert {:ok, 1} = NIF.last_insert_rowid(conn)
        assert {:ok, 1} = NIF.execute(conn, insert_sql, ["auto data 2"])
        assert {:ok, 2} = NIF.last_insert_rowid(conn)
      end

      test "returns 0 if no rows inserted on connection", %{conn: conn} do
        assert {:ok, 0} = NIF.last_insert_rowid(conn)
      end

      test "value persists after failed insert", %{conn: conn} do
        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "INSERT INTO rowid_test (id, data) VALUES (55, 'conn1 data')",
                   []
                 )

        assert {:ok, 55} = NIF.last_insert_rowid(conn)
        # Attempt a failing insert
        assert {:error, _} =
                 NIF.execute(
                   conn,
                   "INSERT INTO rowid_test (id, data) VALUES (55, 'duplicate id')",
                   []
                 )

        # Verify last_insert_rowid still returns the ID from the *last successful* insert
        assert {:ok, 55} = NIF.last_insert_rowid(conn)
      end
    end
  end

  describe "using separate connections" do
    setup do
      assert {:ok, conn1} = NIF.open_in_memory()
      assert {:ok, conn2} = NIF.open_in_memory()
      assert {:ok, 0} = NIF.execute(conn1, @table_sql, [])
      assert {:ok, 0} = NIF.execute(conn2, @table_sql, [])

      on_exit(fn ->
        NIF.close(conn1)
        NIF.close(conn2)
      end)

      {:ok, conn1: conn1, conn2: conn2}
    end

    test "last_insert_rowid is connection specific", %{conn1: conn1, conn2: conn2} do
      assert {:ok, 1} =
               NIF.execute(
                 conn1,
                 "INSERT INTO rowid_test (id, data) VALUES (55, 'conn1 data')",
                 []
               )

      assert {:ok, 1} =
               NIF.execute(
                 conn2,
                 "INSERT INTO rowid_test (id, data) VALUES (77, 'conn2 data')",
                 []
               )

      assert {:ok, 55} = NIF.last_insert_rowid(conn1)
      assert {:ok, 77} = NIF.last_insert_rowid(conn2)
    end
  end
end
