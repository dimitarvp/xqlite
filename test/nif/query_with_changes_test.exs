defmodule Xqlite.NIF.QueryWithChangesTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "query_with_changes using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE qwc (id INTEGER PRIMARY KEY, val TEXT);
          """)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # SELECT — changes should be 0
      # -------------------------------------------------------------------

      test "SELECT returns changes 0 even after prior DML", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (2, 'b')", [])

        assert {:ok, %{columns: ["id", "val"], rows: rows, num_rows: 2, changes: 0}} =
                 NIF.query_with_changes(conn, "SELECT * FROM qwc ORDER BY id", [])

        assert rows == [[1, "a"], [2, "b"]]
      end

      test "SELECT on empty table returns changes 0", %{conn: conn} do
        assert {:ok, %{columns: ["id", "val"], rows: [], num_rows: 0, changes: 0}} =
                 NIF.query_with_changes(conn, "SELECT * FROM qwc", [])
      end

      # -------------------------------------------------------------------
      # INSERT — changes should match affected count
      # -------------------------------------------------------------------

      test "INSERT returns changes 1", %{conn: conn} do
        assert {:ok, %{columns: [], rows: [], num_rows: 0, changes: 1}} =
                 NIF.query_with_changes(conn, "INSERT INTO qwc VALUES (1, 'a')", [])
      end

      test "INSERT with params returns changes 1", %{conn: conn} do
        assert {:ok, %{columns: [], rows: [], num_rows: 0, changes: 1}} =
                 NIF.query_with_changes(conn, "INSERT INTO qwc VALUES (?1, ?2)", [1, "a"])
      end

      test "INSERT RETURNING returns rows AND changes", %{conn: conn} do
        assert {:ok, %{columns: ["id"], rows: [[1]], num_rows: 1, changes: 1}} =
                 NIF.query_with_changes(
                   conn,
                   "INSERT INTO qwc VALUES (1, 'a') RETURNING id",
                   []
                 )
      end

      # -------------------------------------------------------------------
      # UPDATE — changes should match affected count
      # -------------------------------------------------------------------

      test "UPDATE returns correct changes count", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (2, 'b')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (3, 'c')", [])

        assert {:ok, %{changes: 3}} =
                 NIF.query_with_changes(conn, "UPDATE qwc SET val = 'x'", [])
      end

      test "UPDATE with WHERE returns partial changes", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (2, 'b')", [])

        assert {:ok, %{changes: 1}} =
                 NIF.query_with_changes(conn, "UPDATE qwc SET val = 'x' WHERE id = 1", [])
      end

      test "UPDATE matching nothing returns changes 0", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (1, 'a')", [])

        assert {:ok, %{changes: 0}} =
                 NIF.query_with_changes(conn, "UPDATE qwc SET val = 'x' WHERE id = 999", [])
      end

      test "UPDATE RETURNING returns rows AND changes", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (2, 'b')", [])

        assert {:ok, %{columns: ["id"], rows: rows, num_rows: 2, changes: 2}} =
                 NIF.query_with_changes(conn, "UPDATE qwc SET val = 'x' RETURNING id", [])

        assert Enum.sort(rows) == [[1], [2]]
      end

      # -------------------------------------------------------------------
      # DELETE — changes should match affected count
      # -------------------------------------------------------------------

      test "DELETE returns correct changes count", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (2, 'b')", [])

        assert {:ok, %{changes: 2}} =
                 NIF.query_with_changes(conn, "DELETE FROM qwc", [])
      end

      test "DELETE matching nothing returns changes 0", %{conn: conn} do
        assert {:ok, %{changes: 0}} =
                 NIF.query_with_changes(conn, "DELETE FROM qwc WHERE id = 999", [])
      end

      test "DELETE RETURNING returns rows AND changes", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (2, 'b')", [])

        assert {:ok, %{columns: ["id"], rows: rows, num_rows: 2, changes: 2}} =
                 NIF.query_with_changes(conn, "DELETE FROM qwc RETURNING id", [])

        assert Enum.sort(rows) == [[1], [2]]
      end

      # -------------------------------------------------------------------
      # DDL — changes should be 0
      # -------------------------------------------------------------------

      test "DDL after DML returns changes 0 (no sticky leak)", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (1, 'a')", [])

        # CREATE TABLE changes no rows, so its reported count is 0 even
        # though sqlite3_changes() stays sticky at the prior INSERT's 1.
        assert {:ok, %{columns: [], changes: 0}} =
                 NIF.query_with_changes(conn, "CREATE TABLE qwc2 (id INTEGER)", [])
      end

      test "PRAGMA read after DML returns changes 0", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (1, 'a')", [])

        # A read PRAGMA returns columns but changes no rows.
        assert {:ok, %{changes: 0}} =
                 NIF.query_with_changes(conn, "PRAGMA user_version", [])
      end

      # -------------------------------------------------------------------
      # Atomicity — changes is not stale from prior DML
      # -------------------------------------------------------------------

      test "changes from prior INSERT does not leak into subsequent SELECT", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (2, 'b')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (3, 'c')", [])

        assert {:ok, %{changes: 0, num_rows: 3}} =
                 NIF.query_with_changes(conn, "SELECT * FROM qwc", [])
      end

      test "changes from prior DELETE does not leak into subsequent SELECT", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO qwc VALUES (2, 'b')", [])
        {:ok, 2} = NIF.execute(conn, "DELETE FROM qwc", [])

        assert {:ok, %{changes: 0, num_rows: 0}} =
                 NIF.query_with_changes(conn, "SELECT * FROM qwc", [])
      end

      # -------------------------------------------------------------------
      # Named params
      # -------------------------------------------------------------------

      test "works with named params", %{conn: conn} do
        assert {:ok, %{changes: 1}} =
                 NIF.query_with_changes(
                   conn,
                   "INSERT INTO qwc VALUES (:id, :val)",
                   id: 1,
                   val: "named"
                 )
      end

      # -------------------------------------------------------------------
      # Error cases
      # -------------------------------------------------------------------

      test "invalid SQL returns error", %{conn: conn} do
        assert {:error, _} =
                 NIF.query_with_changes(conn, "SELEKT * FROM qwc", [])
      end

      test "wrong param count returns error", %{conn: conn} do
        assert {:error, _} =
                 NIF.query_with_changes(conn, "INSERT INTO qwc VALUES (?1, ?2)", [1])
      end
    end
  end

  # -------------------------------------------------------------------
  # Cancellable variant
  # -------------------------------------------------------------------

  test "query_with_changes_cancellable returns same shape" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    :ok = NIF.execute_batch(conn, "CREATE TABLE qwcc (id INTEGER PRIMARY KEY, val TEXT);")
    {:ok, 1} = NIF.execute(conn, "INSERT INTO qwcc VALUES (1, 'a')", [])
    {:ok, token} = NIF.create_cancel_token()

    assert {:ok, %{columns: ["id", "val"], rows: [[1, "a"]], num_rows: 1, changes: 0}} =
             NIF.query_with_changes_cancellable(conn, "SELECT * FROM qwcc", [], [token])

    NIF.close(conn)
  end

  test "query_with_changes_cancellable can be cancelled" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    {:ok, token} = NIF.create_cancel_token()
    :ok = NIF.cancel_operation(token)

    assert {:error, :operation_cancelled} =
             NIF.query_with_changes_cancellable(
               conn,
               "WITH RECURSIVE cnt(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM cnt LIMIT 5000000) SELECT SUM(x) FROM cnt",
               [],
               [token]
             )

    NIF.close(conn)
  end

  test "closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    NIF.close(conn)
    assert {:error, :connection_closed} = NIF.query_with_changes(conn, "SELECT 1", [])
  end
end
