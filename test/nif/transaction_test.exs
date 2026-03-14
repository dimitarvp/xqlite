defmodule Xqlite.NIF.TransactionTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]
  alias XqliteNIF, as: NIF

  @simple_tx_table "CREATE TABLE tx_test (id INTEGER PRIMARY KEY, name TEXT);"

  @savepoint_table_setup ~S"""
  CREATE TABLE savepoint_test (
    id INTEGER PRIMARY KEY,
    val TEXT NOT NULL
  );
  INSERT INTO savepoint_test (id, val) VALUES (1, 'one');
  """

  # --- Helper functions specific to savepoint tests ---
  # Defined at module level as they are used across iterations of the loop
  defp query_savepoint_test_row(conn, id) do
    sql = "SELECT id, val FROM savepoint_test WHERE id = ?1;"
    NIF.query(conn, sql, [id])
  end

  defp assert_savepoint_record_present(conn, id, expected_val) do
    expected_result = {:ok, %{columns: ["id", "val"], rows: [[id, expected_val]], num_rows: 1}}
    assert expected_result == query_savepoint_test_row(conn, id)
  end

  defp assert_savepoint_record_missing(conn, id) do
    expected_result = {:ok, %{columns: ["id", "val"], rows: [], num_rows: 0}}
    assert expected_result == query_savepoint_test_row(conn, id)
  end

  # --- Shared test code (generated via `for` loop) ---
  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      # Top-level setup for the describe block (opens connection)
      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # --- Basic Commit/Rollback Tests ---
      # Setup specific table needed for these tests
      setup %{conn: conn} do
        assert {:ok, 0} = NIF.execute(conn, @simple_tx_table, [])
        :ok
      end

      test "insert a record and commit transaction", %{conn: conn} do
        assert :ok = NIF.begin(conn)

        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "INSERT INTO tx_test (id, name) VALUES (100, 'Committed');",
                   []
                 )

        assert :ok = NIF.commit(conn)

        assert {:ok, %{rows: [[100, "Committed"]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM tx_test where id = 100;", [])
      end

      test "insert a record and rollback transaction", %{conn: conn} do
        assert :ok = NIF.begin(conn)

        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "INSERT INTO tx_test (id, name) VALUES (101, 'Rolled Back');",
                   []
                 )

        assert :ok = NIF.rollback(conn)

        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(conn, "SELECT * FROM tx_test where id = 101;", [])
      end

      test "commit without begin fails", %{conn: conn} do
        assert {:error, {:sqlite_failure, code, _, msg}} = NIF.commit(conn)
        assert code == 21 or String.contains?(msg || "", "no transaction is active")
      end

      test "rollback without begin fails", %{conn: conn} do
        assert {:error, {:sqlite_failure, code, _, msg}} = NIF.rollback(conn)
        assert code == 21 or String.contains?(msg || "", "no transaction is active")
      end

      test "begin within begin fails", %{conn: conn} do
        assert :ok = NIF.begin(conn)
        assert {:error, {:sqlite_failure, code, _, msg}} = NIF.begin(conn)
        assert code == 21 or String.contains?(msg || "", "within a transaction")
        # Clean up outer transaction
        assert :ok = NIF.rollback(conn)
      end

      # --- Transaction Mode Tests ---

      test "begin with explicit :deferred mode", %{conn: conn} do
        assert :ok = NIF.begin(conn, :deferred)

        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "INSERT INTO tx_test (id, name) VALUES (200, 'deferred');",
                   []
                 )

        assert :ok = NIF.commit(conn)

        assert {:ok, %{rows: [[200, "deferred"]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM tx_test WHERE id = 200;", [])
      end

      test "begin with :immediate mode", %{conn: conn} do
        assert :ok = NIF.begin(conn, :immediate)

        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "INSERT INTO tx_test (id, name) VALUES (201, 'immediate');",
                   []
                 )

        assert :ok = NIF.commit(conn)

        assert {:ok, %{rows: [[201, "immediate"]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM tx_test WHERE id = 201;", [])
      end

      test "begin with :exclusive mode", %{conn: conn} do
        assert :ok = NIF.begin(conn, :exclusive)

        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "INSERT INTO tx_test (id, name) VALUES (202, 'exclusive');",
                   []
                 )

        assert :ok = NIF.commit(conn)

        assert {:ok, %{rows: [[202, "exclusive"]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM tx_test WHERE id = 202;", [])
      end

      test "begin with :immediate mode and rollback", %{conn: conn} do
        assert :ok = NIF.begin(conn, :immediate)

        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "INSERT INTO tx_test (id, name) VALUES (203, 'rollback_imm');",
                   []
                 )

        assert :ok = NIF.rollback(conn)

        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(conn, "SELECT * FROM tx_test WHERE id = 203;", [])
      end

      test "begin with invalid mode returns error", %{conn: conn} do
        assert {:error, :invalid_transaction_mode} = NIF.begin(conn, :bogus)
      end

      # --- Savepoint Tests ---
      # Setup specific table needed for these tests
      setup %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, @savepoint_table_setup)
        :ok
      end

      test "rollback_to_savepoint reverts changes", %{conn: conn} do
        assert_savepoint_record_present(conn, 1, "one")
        assert :ok = NIF.begin(conn)
        assert {:ok, 1} = NIF.execute(conn, "INSERT INTO savepoint_test VALUES (2, 'two')", [])
        assert_savepoint_record_present(conn, 2, "two")
        assert :ok = NIF.savepoint(conn, "sp1")

        assert {:ok, 1} =
                 NIF.execute(conn, "INSERT INTO savepoint_test VALUES (3, 'three')", [])

        assert_savepoint_record_present(conn, 3, "three")
        assert :ok = NIF.rollback_to_savepoint(conn, "sp1")
        assert_savepoint_record_missing(conn, 3)
        assert_savepoint_record_present(conn, 2, "two")
        assert :ok = NIF.commit(conn)
        assert_savepoint_record_present(conn, 1, "one")
        assert_savepoint_record_present(conn, 2, "two")
        assert_savepoint_record_missing(conn, 3)
      end

      test "release_savepoint incorporates changes", %{conn: conn} do
        assert_savepoint_record_present(conn, 1, "one")
        assert :ok = NIF.begin(conn)
        assert {:ok, 1} = NIF.execute(conn, "INSERT INTO savepoint_test VALUES (2, 'two')", [])
        assert_savepoint_record_present(conn, 2, "two")
        assert :ok = NIF.savepoint(conn, "sp1")

        assert {:ok, 1} =
                 NIF.execute(conn, "INSERT INTO savepoint_test VALUES (3, 'three')", [])

        assert_savepoint_record_present(conn, 3, "three")
        assert :ok = NIF.release_savepoint(conn, "sp1")
        assert_savepoint_record_present(conn, 3, "three")
        assert_savepoint_record_present(conn, 2, "two")
        assert :ok = NIF.commit(conn)
        assert_savepoint_record_present(conn, 1, "one")
        assert_savepoint_record_present(conn, 2, "two")
        assert_savepoint_record_present(conn, 3, "three")
      end

      test "rollback_to_savepoint after release fails", %{conn: conn} do
        assert :ok = NIF.begin(conn)
        assert :ok = NIF.savepoint(conn, "sp1")
        assert :ok = NIF.release_savepoint(conn, "sp1")

        assert {:error, {:sqlite_failure, code, _, msg}} =
                 NIF.rollback_to_savepoint(conn, "sp1")

        assert code == 21 or String.contains?(msg || "", "no such savepoint")
        # Clean up main transaction
        assert :ok = NIF.rollback(conn)
      end
    end

    # end describe "using #{prefix}"
  end

  # end `for` loop

  # --- Edge case: savepoint without active transaction ---
  test "isolated: savepoint without active transaction succeeds (implicitly starts one)" do
    {:ok, conn} = NIF.open_in_memory()
    {:ok, 0} = NIF.execute(conn, "CREATE TABLE sp_no_tx (id INTEGER)", [])

    assert :ok = NIF.savepoint(conn, "sp_implicit")
    assert {:ok, 1} = NIF.execute(conn, "INSERT INTO sp_no_tx VALUES (1)", [])
    assert :ok = NIF.release_savepoint(conn, "sp_implicit")

    assert {:ok, %{rows: [[1]], num_rows: 1}} =
             NIF.query(conn, "SELECT id FROM sp_no_tx", [])

    NIF.close(conn)
  end

  # --- Edge case: special characters in savepoint names ---
  test "isolated: savepoint with apostrophe in name" do
    {:ok, conn} = NIF.open_in_memory()
    :ok = NIF.begin(conn)
    assert :ok = NIF.savepoint(conn, "it's a savepoint")
    assert :ok = NIF.release_savepoint(conn, "it's a savepoint")
    :ok = NIF.rollback(conn)
    NIF.close(conn)
  end

  test "isolated: savepoint with spaces in name" do
    {:ok, conn} = NIF.open_in_memory()
    :ok = NIF.begin(conn)
    assert :ok = NIF.savepoint(conn, "my save point")
    assert :ok = NIF.release_savepoint(conn, "my save point")
    :ok = NIF.rollback(conn)
    NIF.close(conn)
  end

  test "isolated: savepoint with unicode in name" do
    {:ok, conn} = NIF.open_in_memory()
    :ok = NIF.begin(conn)
    assert :ok = NIF.savepoint(conn, "savepoint_éàü")
    assert :ok = NIF.release_savepoint(conn, "savepoint_éàü")
    :ok = NIF.rollback(conn)
    NIF.close(conn)
  end

  test "isolated: savepoint with double quotes in name" do
    {:ok, conn} = NIF.open_in_memory()
    :ok = NIF.begin(conn)
    assert :ok = NIF.savepoint(conn, "sp with \"quotes\"")
    assert :ok = NIF.release_savepoint(conn, "sp with \"quotes\"")
    :ok = NIF.rollback(conn)
    NIF.close(conn)
  end
end
