defmodule XqliteNifTest do
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF

  # Always valid
  @valid_db_path "file:memdb1?mode=memory&cache=shared"

  # Using a path that cannot exist in read-only mode ensures failure
  @invalid_db_path "file:./non_existent_dir_for_sure/read_only_db?mode=ro&immutable=1"

  @test_1_create ~S"""
  CREATE TABLE test1 (
    id INTEGER PRIMARY KEY,
    int_col INTEGER,
    real_col REAL,
    string_col TEXT,
    blob_col BLOB
  );
  """

  @test_1_insert ~S"""
  INSERT INTO test1 (id, int_col, real_col, string_col, blob_col)
  VALUES
    (1, NULL, 3.14, 'First row', x'FF00FF'),
    (2, 42, NULL, 'Second row', x'C0AF8F'),
    (3, 123, 2.71828, NULL, x'ED9FBFED'),
    (4, 7, 9.99, 'Fourth row', NULL),
    (5, 555, 5.55, 'Fifth row', x'FE8080'),
    (6, 666, 6.66, 'Sixth row', x'F0808080'),
    (7, 777, 7.77, 'Seventh row', x'FF');
  """

  @savepoint_table_setup ~S"""
  CREATE TABLE savepoint_test (
    id INTEGER PRIMARY KEY,
    val TEXT NOT NULL
  );
  INSERT INTO savepoint_test (id, val) VALUES (1, 'one');
  """

  setup do
    # Ensure the invalid path target doesn't exist before tests using it
    if File.exists?(@invalid_db_path) do
      raise("Invalid DB path '#{@invalid_db_path}' exists, please remove it.")
    end

    # No shared state needed between test.
    :ok
  end

  describe "pragma_write/2" do
    test "can execute a simple PRAGMA" do
      {:ok, conn} = NIF.open(@valid_db_path)
      assert {:ok, true} = NIF.set_pragma(conn, "synchronous", 0)
      assert {:ok, 0} = NIF.get_pragma(conn, "synchronous")
      assert {:ok, true} = NIF.close(conn)
    end
  end

  describe "various tests on an initially empty database:" do
    setup do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "last_insert_rowid returns the explicit rowid of the last inserted row", %{conn: conn} do
      # 1. Setup: Create a simple table with an INTEGER PRIMARY KEY
      create_sql = "CREATE TABLE rowid_test (id INTEGER PRIMARY KEY, data TEXT);"
      # DDL execution usually affects 0 user rows
      assert {:ok, 0} == XqliteNIF.execute(conn, create_sql, [])

      # 2. Action: Insert a row providing an explicit ID
      insert_sql = "INSERT INTO rowid_test (id, data) VALUES (?1, ?2);"
      # The specific ID we are inserting
      explicit_id = 123
      insert_params = [explicit_id, "some test data"]
      # Assert that the insert affected 1 row
      assert {:ok, 1} == XqliteNIF.execute(conn, insert_sql, insert_params)

      # 3. Verification: Call last_insert_rowid immediately and assert the explicit ID
      assert {:ok, 123} == XqliteNIF.last_insert_rowid(conn)
    end

    # Optional: Test with default rowid generation (should be 1 for first insert)
    test "last_insert_rowid returns the auto-generated rowid when ID is not provided", %{
      conn: conn
    } do
      # 1. Setup: Create a simple table with an INTEGER PRIMARY KEY
      create_sql = "CREATE TABLE rowid_test_auto (id INTEGER PRIMARY KEY, data TEXT);"
      assert {:ok, 0} == XqliteNIF.execute(conn, create_sql, [])

      # 2. Action: Insert a row WITHOUT providing an explicit ID
      insert_sql = "INSERT INTO rowid_test_auto (data) VALUES (?1);"
      insert_params = ["auto data"]
      assert {:ok, 1} == XqliteNIF.execute(conn, insert_sql, insert_params)

      # 3. Verification: Call last_insert_rowid. For the first insert in a fresh table,
      # SQLite typically generates rowid 1.
      assert {:ok, 1} == XqliteNIF.last_insert_rowid(conn)
    end

    test "rollback_to_savepoint reverts changes made after the savepoint", %{conn: conn} do
      # Setup: Create table and insert initial row (id: 1)
      assert {:ok, true} == XqliteNIF.execute_batch(conn, @savepoint_table_setup)

      # Verify initial state
      assert_savepoint_record_present(conn, 1, "one")

      # Start the main transaction
      assert {:ok, true} == XqliteNIF.begin(conn)

      # Insert row 2 within the main transaction
      assert {:ok, 1} ==
               XqliteNIF.execute(conn, "INSERT INTO savepoint_test VALUES (2, 'two')", [])

      # Verify row 2 exists within the transaction
      assert_savepoint_record_present(conn, 2, "two")

      # Create a savepoint
      assert {:ok, true} == XqliteNIF.savepoint(conn, "sp1")

      # Insert row 3 after the savepoint
      assert {:ok, 1} ==
               XqliteNIF.execute(
                 conn,
                 "INSERT INTO savepoint_test VALUES (3, 'three')",
                 []
               )

      # Verify row 3 exists before rollback
      assert_savepoint_record_present(conn, 3, "three")

      # Rollback to the savepoint "sp1"
      assert {:ok, true} == XqliteNIF.rollback_to_savepoint(conn, "sp1")

      # Verify: Row 3 should now be gone
      assert_savepoint_record_missing(conn, 3)

      # Verify: Row 2 should still be there
      assert_savepoint_record_present(conn, 2, "two")

      # Commit the main transaction (which now only includes the insertion of row 2)
      assert {:ok, true} == XqliteNIF.commit(conn)

      # Final verification outside transaction
      assert_savepoint_record_present(conn, 1, "one")
      assert_savepoint_record_present(conn, 2, "two")
      assert_savepoint_record_missing(conn, 3)
    end

    test "release_savepoint incorporates changes made after the savepoint into the transaction",
         %{
           conn: conn
         } do
      # Setup: Create table and insert initial row (id: 1)
      assert {:ok, true} == XqliteNIF.execute_batch(conn, @savepoint_table_setup)

      # Verify initial state
      assert_savepoint_record_present(conn, 1, "one")

      # Start the main transaction
      assert {:ok, true} == XqliteNIF.begin(conn)

      # Insert row 2 within the main transaction
      assert {:ok, 1} ==
               XqliteNIF.execute(conn, "INSERT INTO savepoint_test VALUES (2, 'two')", [])

      # Verify row 2 exists within the transaction
      assert_savepoint_record_present(conn, 2, "two")

      # Create a savepoint
      assert {:ok, true} == XqliteNIF.savepoint(conn, "sp1")

      # Insert row 3 after the savepoint
      assert {:ok, 1} ==
               XqliteNIF.execute(
                 conn,
                 "INSERT INTO savepoint_test VALUES (3, 'three')",
                 []
               )

      # Verify row 3 exists before release
      assert_savepoint_record_present(conn, 3, "three")

      # Release the savepoint "sp1". This merges inserting row 3 into the main transaction.
      assert {:ok, true} == XqliteNIF.release_savepoint(conn, "sp1")

      # Verify: Row 3 should still be there after release
      assert_savepoint_record_present(conn, 3, "three")

      # Verify: Row 2 should also still be there
      assert_savepoint_record_present(conn, 2, "two")

      # Commit the main transaction (which now includes the insertion of both row 2 and row 3)
      assert {:ok, true} == XqliteNIF.commit(conn)

      # Final verification outside transaction
      assert_savepoint_record_present(conn, 1, "one")
      assert_savepoint_record_present(conn, 2, "two")
      assert_savepoint_record_present(conn, 3, "three")
    end
  end

  describe "various tests with a single table:" do
    setup do
      {:ok, conn} = NIF.open(":memory:")
      # DDL statements don't return tables created / modified / dropped.
      {:ok, 0} = NIF.execute(conn, @test_1_create)
      # Modifying statements -- INSERT, DELETE, UPDATE -- do return a number of affected rows.
      {:ok, 7} = NIF.execute(conn, @test_1_insert)
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "insert a record and commit transaction", %{conn: conn} do
      assert {:ok, true} == NIF.begin(conn)

      assert {:ok, 1} ==
               NIF.execute(conn, ~S"""
               INSERT INTO test1 (id, int_col, real_col, string_col, blob_col)
               VALUES (100, 101, 5.19, 'Some row', x'FF00FF');
               """)

      assert {:ok, true} == NIF.commit(conn)

      assert {:ok,
              %{
                columns: ["id", "int_col", "real_col", "string_col", "blob_col"],
                rows: [
                  [100, 101, 5.19, "Some row", <<255, 0, 255>>]
                ],
                num_rows: 1
              }} == NIF.query(conn, "SELECT * FROM test1 where id = 100;")
    end

    test "insert a record and rollback transaction", %{conn: conn} do
      assert {:ok, true} == NIF.begin(conn)

      assert {:ok, 1} ==
               NIF.execute(conn, ~S"""
               INSERT INTO test1 (id, int_col, real_col, string_col, blob_col)
               VALUES (100, 101, 5.19, 'Some row', x'FF00FF');
               """)

      assert {:ok, true} == NIF.rollback(conn)

      assert {:ok,
              %{
                columns: ["id", "int_col", "real_col", "string_col", "blob_col"],
                rows: [],
                num_rows: 0
              }} == NIF.query(conn, "SELECT * FROM test1 where id = 100;")
    end

    # end of "various tests with a single table:"
  end

  defp query_savepoint_test_row(conn, id) do
    sql = "SELECT id, val FROM savepoint_test WHERE id = ?1;"
    XqliteNIF.query(conn, sql, [id])
  end

  # Asserts that a specific record exists with the expected value
  defp assert_savepoint_record_present(conn, id, expected_val) do
    expected_result =
      {:ok,
       %{
         columns: ["id", "val"],
         rows: [[id, expected_val]],
         num_rows: 1
       }}

    assert expected_result == query_savepoint_test_row(conn, id)
  end

  # Asserts that a specific record does NOT exist
  defp assert_savepoint_record_missing(conn, id) do
    expected_result =
      {:ok,
       %{
         columns: ["id", "val"],
         rows: [],
         num_rows: 0
       }}

    assert expected_result == query_savepoint_test_row(conn, id)
  end
end
