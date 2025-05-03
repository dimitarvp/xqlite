defmodule Xqlite.NIF.TransactionTest do
  # Use async: true if tests are isolated by :memory: db
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF

  # --- Module Attributes ---
  @simple_tx_table "CREATE TABLE tx_test (id INTEGER PRIMARY KEY, name TEXT);"

  @savepoint_table_setup ~S"""
  CREATE TABLE savepoint_test (
    id INTEGER PRIMARY KEY,
    val TEXT NOT NULL
  );
  INSERT INTO savepoint_test (id, val) VALUES (1, 'one');
  """

  # --- Setup ---
  setup do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    on_exit(fn -> NIF.close(conn) end)
    {:ok, conn: conn}
  end

  # --- Basic Transaction Tests ---

  describe "basic commit/rollback" do
    # Setup table specific to these basic tests
    setup %{conn: conn} do
      assert {:ok, 0} = NIF.execute(conn, @simple_tx_table, [])
      :ok
    end

    test "insert a record and commit transaction", %{conn: conn} do
      # Start transaction
      assert {:ok, true} = NIF.begin(conn)

      # Perform action within transaction
      assert {:ok, 1} =
               NIF.execute(
                 conn,
                 "INSERT INTO tx_test (id, name) VALUES (100, 'Committed');",
                 []
               )

      # Commit the transaction
      assert {:ok, true} = NIF.commit(conn)

      # Verify data persists after commit
      assert {:ok, %{rows: [[100, "Committed"]], num_rows: 1}} =
               NIF.query(conn, "SELECT * FROM tx_test where id = 100;", [])
    end

    test "insert a record and rollback transaction", %{conn: conn} do
      # Start transaction
      assert {:ok, true} = NIF.begin(conn)

      # Perform action within transaction
      assert {:ok, 1} =
               NIF.execute(
                 conn,
                 "INSERT INTO tx_test (id, name) VALUES (101, 'Rolled Back');",
                 []
               )

      # Rollback the transaction
      assert {:ok, true} = NIF.rollback(conn)

      # Verify data does not persist after rollback
      assert {:ok, %{rows: [], num_rows: 0}} =
               NIF.query(conn, "SELECT * FROM tx_test where id = 101;", [])
    end

    test "commit without begin fails", %{conn: conn} do
      # Trying to commit outside a transaction is an error
      # Check for specific SQLite failure indicating no active transaction
      assert {:error, {:sqlite_failure, code, _ext_code, msg}} = NIF.commit(conn)
      # Check common error codes (MISUSE) or the specific message
      assert code == 21 or String.contains?(msg || "", "no transaction is active")
    end

    test "rollback without begin fails", %{conn: conn} do
      # Trying to rollback outside a transaction is an error
      # Check for specific SQLite failure indicating no active transaction
      assert {:error, {:sqlite_failure, code, _ext_code, msg}} = NIF.rollback(conn)
      assert code == 21 or String.contains?(msg || "", "no transaction is active")
    end

    test "begin within begin fails", %{conn: conn} do
      # Start the outer transaction
      assert {:ok, true} = NIF.begin(conn)
      # Cannot start nested transaction directly with BEGIN
      # Check for specific SQLite failure indicating nested transaction attempt
      assert {:error, {:sqlite_failure, code, _ext_code, msg}} = NIF.begin(conn)
      assert code == 21 or String.contains?(msg || "", "within a transaction")
      # Rollback the outer transaction to clean up state
      assert {:ok, true} = NIF.rollback(conn)
    end
  end

  # --- Savepoint Tests ---

  describe "savepoints" do
    # --- Helper functions specific to savepoint tests ---
    defp query_savepoint_test_row(conn, id) do
      sql = "SELECT id, val FROM savepoint_test WHERE id = ?1;"
      NIF.query(conn, sql, [id])
    end

    # Asserts that a specific record exists with the expected value
    defp assert_savepoint_record_present(conn, id, expected_val) do
      expected_result =
        {:ok, %{columns: ["id", "val"], rows: [[id, expected_val]], num_rows: 1}}

      assert expected_result == query_savepoint_test_row(conn, id)
    end

    # Asserts that a specific record does NOT exist
    defp assert_savepoint_record_missing(conn, id) do
      expected_result = {:ok, %{columns: ["id", "val"], rows: [], num_rows: 0}}
      assert expected_result == query_savepoint_test_row(conn, id)
    end

    # Setup specific to savepoint tests: create and populate savepoint_test table
    setup %{conn: conn} do
      assert {:ok, true} = NIF.execute_batch(conn, @savepoint_table_setup)
      :ok
    end

    # --- Savepoint Test Cases ---
    test "rollback_to_savepoint reverts changes made after the savepoint", %{conn: conn} do
      # Verify initial state
      assert_savepoint_record_present(conn, 1, "one")
      # Start transaction
      assert {:ok, true} = NIF.begin(conn)
      # Insert before savepoint
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO savepoint_test VALUES (2, 'two')", [])
      assert_savepoint_record_present(conn, 2, "two")
      # Create savepoint
      assert {:ok, true} = NIF.savepoint(conn, "sp1")
      # Insert after savepoint
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO savepoint_test VALUES (3, 'three')", [])
      assert_savepoint_record_present(conn, 3, "three")
      # Rollback to savepoint
      assert {:ok, true} = NIF.rollback_to_savepoint(conn, "sp1")
      # Verify state after rollback (row 3 gone, row 2 remains)
      assert_savepoint_record_missing(conn, 3)
      assert_savepoint_record_present(conn, 2, "two")
      # Commit remaining changes (row 2 insert)
      assert {:ok, true} = NIF.commit(conn)
      # Final verification of persistent state
      assert_savepoint_record_present(conn, 1, "one")
      assert_savepoint_record_present(conn, 2, "two")
      assert_savepoint_record_missing(conn, 3)
    end

    test "release_savepoint incorporates changes made after the savepoint", %{conn: conn} do
      # Verify initial state
      assert_savepoint_record_present(conn, 1, "one")
      # Start transaction
      assert {:ok, true} = NIF.begin(conn)
      # Insert before savepoint
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO savepoint_test VALUES (2, 'two')", [])
      assert_savepoint_record_present(conn, 2, "two")
      # Create savepoint
      assert {:ok, true} = NIF.savepoint(conn, "sp1")
      # Insert after savepoint
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO savepoint_test VALUES (3, 'three')", [])
      assert_savepoint_record_present(conn, 3, "three")
      # Release the savepoint (merges changes)
      assert {:ok, true} = NIF.release_savepoint(conn, "sp1")
      # Verify state after release (both row 2 and 3 should be present)
      assert_savepoint_record_present(conn, 3, "three")
      assert_savepoint_record_present(conn, 2, "two")
      # Commit the merged changes
      assert {:ok, true} = NIF.commit(conn)
      # Final verification of persistent state
      assert_savepoint_record_present(conn, 1, "one")
      assert_savepoint_record_present(conn, 2, "two")
      assert_savepoint_record_present(conn, 3, "three")
    end

    test "rollback_to_savepoint after release fails", %{conn: conn} do
      # Start transaction and create/release savepoint
      assert {:ok, true} = NIF.begin(conn)
      assert {:ok, true} = NIF.savepoint(conn, "sp1")
      assert {:ok, true} = NIF.release_savepoint(conn, "sp1")
      # Trying to rollback to a released (non-existent) savepoint is an error
      # Check for specific SQLite failure indicating no such savepoint
      assert {:error, {:sqlite_failure, code, _ext_code, msg}} =
               NIF.rollback_to_savepoint(conn, "sp1")

      assert code == 21 or String.contains?(msg || "", "no such savepoint")
      # Rollback main transaction to clean up
      assert {:ok, true} = NIF.rollback(conn)
    end
  end

  # end describe "savepoints"
end
