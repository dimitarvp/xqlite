defmodule Xqlite.NIF.LastInsertRowidTest do
  # Reading last insert ID should be safe async with :memory:
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF

  # --- Setup ---
  # Each test gets a fresh :memory: database
  setup do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    on_exit(fn -> NIF.close(conn) end)
    {:ok, conn: conn}
  end

  # --- Tests (Moved from monolithic file) ---

  test "last_insert_rowid returns the explicit rowid of the last inserted row", %{conn: conn} do
    # 1. Setup: Create a simple table with an INTEGER PRIMARY KEY
    create_sql = "CREATE TABLE rowid_test (id INTEGER PRIMARY KEY, data TEXT);"
    # DDL execution usually affects 0 user rows
    assert {:ok, 0} = NIF.execute(conn, create_sql, [])

    # 2. Action: Insert a row providing an explicit ID
    insert_sql = "INSERT INTO rowid_test (id, data) VALUES (?1, ?2);"
    # The specific ID we are inserting
    explicit_id = 123
    insert_params = [explicit_id, "some test data"]
    # Assert that the insert affected 1 row
    assert {:ok, 1} = NIF.execute(conn, insert_sql, insert_params)

    # 3. Verification: Call last_insert_rowid immediately and assert the explicit ID
    assert {:ok, ^explicit_id} = NIF.last_insert_rowid(conn)
  end

  test "last_insert_rowid returns the auto-generated rowid when ID is not provided", %{
    conn: conn
  } do
    # 1. Setup: Create a simple table with an INTEGER PRIMARY KEY
    create_sql = "CREATE TABLE rowid_test_auto (id INTEGER PRIMARY KEY, data TEXT);"
    assert {:ok, 0} = NIF.execute(conn, create_sql, [])

    # 2. Action: Insert a row WITHOUT providing an explicit ID
    insert_sql = "INSERT INTO rowid_test_auto (data) VALUES (?1);"
    insert_params = ["auto data"]
    assert {:ok, 1} = NIF.execute(conn, insert_sql, insert_params)

    # 3. Verification: Call last_insert_rowid. For the first insert in a fresh table,
    # SQLite typically generates rowid 1.
    assert {:ok, 1} = NIF.last_insert_rowid(conn)

    # Insert another row to verify it increments
    assert {:ok, 1} = NIF.execute(conn, insert_sql, ["auto data 2"])
    assert {:ok, 2} = NIF.last_insert_rowid(conn)
  end

  test "last_insert_rowid is connection specific", %{conn: conn} do
    # Create table
    create_sql = "CREATE TABLE rowid_specific (id INTEGER PRIMARY KEY, data TEXT);"
    assert {:ok, 0} = NIF.execute(conn, create_sql, [])

    # Open a second connection (unique :memory: db)
    assert {:ok, conn2} = NIF.open_in_memory(":memory:")
    # Create same table in second DB
    assert {:ok, 0} = NIF.execute(conn2, create_sql, [])

    # Insert into conn1
    assert {:ok, 1} =
             NIF.execute(
               conn,
               "INSERT INTO rowid_specific (id, data) VALUES (55, 'conn1 data')",
               []
             )

    # Insert into conn2 with different ID
    assert {:ok, 1} =
             NIF.execute(
               conn2,
               "INSERT INTO rowid_specific (id, data) VALUES (77, 'conn2 data')",
               []
             )

    # Verify last_insert_rowid for conn1
    assert {:ok, 55} = NIF.last_insert_rowid(conn)
    # Verify last_insert_rowid for conn2 is independent
    assert {:ok, 77} = NIF.last_insert_rowid(conn2)

    # Close second connection
    assert {:ok, true} = NIF.close(conn2)
  end
end
