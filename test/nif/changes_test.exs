defmodule Xqlite.NIF.ChangesTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "changes using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE ch (id INTEGER PRIMARY KEY, val TEXT);
          """)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # changes/1
      # -------------------------------------------------------------------

      test "changes returns 0 before any DML", %{conn: conn} do
        assert {:ok, 0} = NIF.changes(conn)
      end

      test "changes returns 1 after single INSERT", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (1, 'a')", [])
        assert {:ok, 1} = NIF.changes(conn)
      end

      test "changes returns row count after multi-row INSERT", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          INSERT INTO ch VALUES (1, 'a');
          INSERT INTO ch VALUES (2, 'b');
          INSERT INTO ch VALUES (3, 'c');
          """)

        assert {:ok, 1} = NIF.changes(conn)
      end

      test "changes returns affected count after UPDATE", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          INSERT INTO ch VALUES (1, 'a');
          INSERT INTO ch VALUES (2, 'b');
          INSERT INTO ch VALUES (3, 'c');
          """)

        {:ok, 3} = NIF.execute(conn, "UPDATE ch SET val = 'x'", [])
        assert {:ok, 3} = NIF.changes(conn)
      end

      test "changes returns affected count after partial UPDATE", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          INSERT INTO ch VALUES (1, 'a');
          INSERT INTO ch VALUES (2, 'b');
          INSERT INTO ch VALUES (3, 'c');
          """)

        {:ok, 1} = NIF.execute(conn, "UPDATE ch SET val = 'x' WHERE id = 2", [])
        assert {:ok, 1} = NIF.changes(conn)
      end

      test "changes returns affected count after DELETE", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          INSERT INTO ch VALUES (1, 'a');
          INSERT INTO ch VALUES (2, 'b');
          INSERT INTO ch VALUES (3, 'c');
          """)

        {:ok, 2} = NIF.execute(conn, "DELETE FROM ch WHERE id IN (1, 3)", [])
        assert {:ok, 2} = NIF.changes(conn)
      end

      test "changes returns 0 after DELETE that matches nothing", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (1, 'a')", [])
        {:ok, 0} = NIF.execute(conn, "DELETE FROM ch WHERE id = 999", [])
        assert {:ok, 0} = NIF.changes(conn)
      end

      test "changes reflects only the most recent statement", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (1, 'a')", [])
        assert {:ok, 1} = NIF.changes(conn)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (2, 'b')", [])
        assert {:ok, 1} = NIF.changes(conn)

        {:ok, 2} = NIF.execute(conn, "DELETE FROM ch", [])
        assert {:ok, 2} = NIF.changes(conn)
      end

      test "changes persists after SELECT (not reset)", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (1, 'a')", [])
        {:ok, _} = NIF.query(conn, "SELECT * FROM ch", [])
        assert {:ok, 1} = NIF.changes(conn)
      end

      test "changes persists after DDL (not reset)", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (1, 'a')", [])
        :ok = NIF.execute_batch(conn, "CREATE TABLE ch2 (id INTEGER);")
        assert {:ok, 1} = NIF.changes(conn)
      end

      test "changes does not count trigger-fired rows", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE ch_audit (id INTEGER PRIMARY KEY, action TEXT);
          CREATE TRIGGER ch_insert_audit AFTER INSERT ON ch
          BEGIN
            INSERT INTO ch_audit (action) VALUES ('insert');
          END;
          """)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (1, 'a')", [])
        assert {:ok, 1} = NIF.changes(conn)
      end

      # -------------------------------------------------------------------
      # total_changes/1
      # -------------------------------------------------------------------

      test "total_changes starts at 0 on fresh connection", %{conn: conn} do
        assert {:ok, 0} = NIF.total_changes(conn)
      end

      test "total_changes accumulates across statements", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (1, 'a')", [])
        assert {:ok, 1} = NIF.total_changes(conn)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (2, 'b')", [])
        assert {:ok, 2} = NIF.total_changes(conn)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (3, 'c')", [])
        assert {:ok, 3} = NIF.total_changes(conn)
      end

      test "total_changes includes UPDATE and DELETE", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (2, 'b')", [])
        {:ok, 2} = NIF.execute(conn, "UPDATE ch SET val = 'x'", [])
        {:ok, 1} = NIF.execute(conn, "DELETE FROM ch WHERE id = 1", [])

        assert {:ok, 5} = NIF.total_changes(conn)
      end

      test "total_changes includes trigger-fired rows", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE ch_log (id INTEGER PRIMARY KEY, msg TEXT);
          CREATE TRIGGER ch_log_insert AFTER INSERT ON ch
          BEGIN
            INSERT INTO ch_log (msg) VALUES ('logged');
          END;
          """)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (2, 'b')", [])

        {:ok, total} = NIF.total_changes(conn)
        assert total == 4
      end

      test "total_changes never decreases", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (1, 'a')", [])
        {:ok, t1} = NIF.total_changes(conn)

        {:ok, 0} = NIF.execute(conn, "DELETE FROM ch WHERE id = 999", [])
        {:ok, t2} = NIF.total_changes(conn)

        assert t2 >= t1
      end

      test "total_changes survives transaction rollback", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (1, 'a')", [])
        {:ok, before_tx} = NIF.total_changes(conn)

        :ok = NIF.begin(conn, :immediate)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO ch VALUES (2, 'b')", [])
        :ok = NIF.rollback(conn)

        {:ok, after_rollback} = NIF.total_changes(conn)
        assert after_rollback > before_tx
      end
    end
  end

  # -------------------------------------------------------------------
  # Edge cases outside loop
  # -------------------------------------------------------------------

  test "changes on closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    NIF.close(conn)
    assert {:error, :connection_closed} = NIF.changes(conn)
  end

  test "total_changes on closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    NIF.close(conn)
    assert {:error, :connection_closed} = NIF.total_changes(conn)
  end

  test "changes is connection-specific" do
    {:ok, conn1} = NIF.open_in_memory(":memory:")
    {:ok, conn2} = NIF.open_in_memory(":memory:")

    :ok = NIF.execute_batch(conn1, "CREATE TABLE ch1 (id INTEGER PRIMARY KEY);")
    :ok = NIF.execute_batch(conn2, "CREATE TABLE ch2 (id INTEGER PRIMARY KEY);")

    {:ok, 1} = NIF.execute(conn1, "INSERT INTO ch1 VALUES (1)", [])
    {:ok, 1} = NIF.execute(conn1, "INSERT INTO ch1 VALUES (2)", [])
    {:ok, 1} = NIF.execute(conn1, "INSERT INTO ch1 VALUES (3)", [])

    {:ok, 1} = NIF.execute(conn2, "INSERT INTO ch2 VALUES (1)", [])

    assert {:ok, 1} = NIF.changes(conn1)
    assert {:ok, 1} = NIF.changes(conn2)

    assert {:ok, 3} = NIF.total_changes(conn1)
    assert {:ok, 1} = NIF.total_changes(conn2)

    NIF.close(conn1)
    NIF.close(conn2)
  end
end
