defmodule XqliteNifTest do
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF

  # Using a path that cannot exist in read-only mode ensures failure
  @invalid_db_path "file:./non_existent_dir_for_sure/read_only_db?mode=ro&immutable=1"

  setup do
    # Ensure the invalid path target doesn't exist before tests using it
    if File.exists?(@invalid_db_path) do
      raise("Invalid DB path '#{@invalid_db_path}' exists, please remove it.")
    end

    # No shared state needed between test.
    :ok
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
  end
end
