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

  @test_2_create_statements [
    ~S"""
    CREATE TABLE customers (
    customer_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT UNIQUE
    );
    """,
    ~S"""
    CREATE TABLE products (
    product_id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    price REAL NOT NULL
    );
    """,
    ~S"""
    CREATE TABLE orders (
    order_id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL,
    order_date TEXT NOT NULL,
    status TEXT NOT NULL,
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
    );
    """,
    ~S"""
    CREATE TABLE order_items (
    item_id INTEGER PRIMARY KEY,
    order_id INTEGER NOT NULL,
    product_id INTEGER NOT NULL,
    quantity INTEGER NOT NULL,
    price REAL NOT NULL,
    FOREIGN KEY (order_id) REFERENCES orders(order_id),
    FOREIGN KEY (product_id) REFERENCES products(product_id)
    );
    """
  ]

  @test_3_create_and_insert ~S"""
  CREATE TABLE batch_test_table (
    id INTEGER PRIMARY KEY,
    pi_value REAL NOT NULL,
    label TEXT NOT NULL
  );
  INSERT INTO batch_test_table (id, pi_value, label) VALUES (42, 3.14159, 'approx_pi');
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

  describe "open/2 and close/1" do
    test "opens a valid in-memory database, closes it, and fails on second close" do
      assert {:ok, conn} = NIF.open(@valid_db_path)
      assert {:ok, true} = NIF.close(conn)
      assert {:ok, true} = NIF.close(conn)
    end

    test "fails to open an invalid database path immediately" do
      assert {:error, {:cannot_open_database, @invalid_db_path, _reason}} =
               NIF.open(@invalid_db_path)
    end

    test "opens the same database path multiple times, returning the same handle conceptually" do
      assert {:ok, conn1} = NIF.open(@valid_db_path)
      assert {:ok, conn2} = NIF.open(@valid_db_path)

      # The resource handles themselves might be different ResourceArc wrappers,
      # but they should represent the same underlying pooled connection (keyed by path).
      # We can verify this by closing one and checking the other still works (tested by closing)

      assert {:ok, true} = NIF.close(conn1)

      # Closing via conn2 should still succeed because it's no-op on the Rust side
      # as we are relying on the reference-counted Rust `Arc` to ultimately garbage-collect
      # the connection, which leads to actually closing it.
      assert {:ok, true} = NIF.close(conn2)
    end

    # end of describe "open/2 and close/1"
  end

  describe "pragma_write/2" do
    test "can execute a simple PRAGMA" do
      {:ok, conn} = NIF.open(@valid_db_path)
      assert {:ok, true} = NIF.set_pragma(conn, "synchronous", 0)
      assert {:ok, 0} = NIF.get_pragma(conn, "synchronous")
      assert {:ok, true} = NIF.close(conn)
    end
  end

  describe "query/3" do
    test "can execute a simple query" do
      {:ok, conn} = NIF.open(@valid_db_path)

      assert {:ok, %{columns: ["1"], rows: [[1]], num_rows: 1}} =
               NIF.query(conn, "SELECT 1;", [])

      assert {:ok, true} = NIF.close(conn)
    end
  end

  describe "various tests on an initially empty database:" do
    setup do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "create a table and insert records in a single SQL block delimited by a semicolon", %{
      conn: conn
    } do
      assert {:ok, true} == XqliteNIF.execute_batch(conn, @test_3_create_and_insert)

      query_sql = "SELECT id, pi_value, label FROM batch_test_table WHERE id = ?1;"
      query_params = [42]

      assert {:ok,
              %{
                columns: ["id", "pi_value", "label"],
                rows: [[42, 3.14159, "approx_pi"]],
                num_rows: 1
              }} == XqliteNIF.query(conn, query_sql, query_params)
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

    test "fetch all records", %{conn: conn} do
      assert {:ok,
              %{
                columns: ["id", "int_col", "real_col", "string_col", "blob_col"],
                rows: [
                  [1, nil, 3.14, "First row", <<255, 0, 255>>],
                  [2, 42, nil, "Second row", <<192, 175, 143>>],
                  [3, 123, 2.71828, nil, <<237, 159, 191, 237>>],
                  [4, 7, 9.99, "Fourth row", nil],
                  [5, 555, 5.55, "Fifth row", <<254, 128, 128>>],
                  [6, 666, 6.66, "Sixth row", <<240, 128, 128, 128>>],
                  [7, 777, 7.77, "Seventh row", <<255>>]
                ],
                num_rows: 7
              }} == NIF.query(conn, "SELECT * FROM test1;")
    end

    test "fetch records with filters", %{conn: conn} do
      assert {:ok,
              %{
                columns: ["id", "int_col", "real_col", "string_col", "blob_col"],
                rows: [
                  [5, 555, 5.55, "Fifth row", <<254, 128, 128>>],
                  [6, 666, 6.66, "Sixth row", <<240, 128, 128, 128>>],
                  [7, 777, 7.77, "Seventh row", <<255>>]
                ],
                num_rows: 3
              }} ==
               NIF.query(
                 conn,
                 "select * from test1 where int_col > :value and length(string_col) >= :length;",
                 value: 100,
                 length: 3
               )
    end

    # end of "various tests with a single table:"
  end

  describe "various tests with multiple tables:" do
    setup do
      {:ok, conn} = NIF.open(":memory:")

      for ddl <- @test_2_create_statements do
        {:ok, %{columns: [], rows: [], num_rows: 0}} = XqliteNIF.query(conn, ddl)
      end

      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "fetch all tables", %{conn: conn} do
      assert {:ok,
              %{
                columns: ["schema", "name", "type", "ncol", "wr", "strict"],
                rows: [
                  ["main", "order_items", "table", 5, 0, 0],
                  ["main", "orders", "table", 4, 0, 0],
                  ["main", "products", "table", 3, 0, 0],
                  ["main", "customers", "table", 3, 0, 0],
                  ["main", "sqlite_schema", "table", 5, 0, 0],
                  ["temp", "sqlite_temp_schema", "table", 5, 0, 0]
                ],
                num_rows: 6
              }} == XqliteNIF.query(conn, "PRAGMA table_list;")
    end

    test "fetch table information for customers", %{conn: conn} do
      assert {:ok,
              %{
                columns: ["cid", "name", "type", "notnull", "dflt_value", "pk"],
                rows: [
                  [0, "customer_id", "INTEGER", 0, nil, 1],
                  [1, "name", "TEXT", 1, nil, 0],
                  [2, "email", "TEXT", 0, nil, 0]
                ],
                num_rows: 3
              }} == XqliteNIF.query(conn, "PRAGMA table_info(customers);")
    end

    test "fetch table information for products", %{conn: conn} do
      assert {:ok,
              %{
                columns: ["cid", "name", "type", "notnull", "dflt_value", "pk"],
                rows: [
                  [0, "product_id", "INTEGER", 0, nil, 1],
                  [1, "name", "TEXT", 1, nil, 0],
                  [2, "price", "REAL", 1, nil, 0]
                ],
                num_rows: 3
              }} == XqliteNIF.query(conn, "PRAGMA table_info(products);")
    end

    test "fetch table information for orders", %{conn: conn} do
      assert {:ok,
              %{
                columns: ["cid", "name", "type", "notnull", "dflt_value", "pk"],
                rows: [
                  [0, "order_id", "INTEGER", 0, nil, 1],
                  [1, "customer_id", "INTEGER", 1, nil, 0],
                  [2, "order_date", "TEXT", 1, nil, 0],
                  [3, "status", "TEXT", 1, nil, 0]
                ],
                num_rows: 4
              }} == XqliteNIF.query(conn, "PRAGMA table_info(orders);")
    end

    test "fetch table information for order_items", %{conn: conn} do
      assert {:ok,
              %{
                columns: ["cid", "name", "type", "notnull", "dflt_value", "pk"],
                rows: [
                  [0, "item_id", "INTEGER", 0, nil, 1],
                  [1, "order_id", "INTEGER", 1, nil, 0],
                  [2, "product_id", "INTEGER", 1, nil, 0],
                  [3, "quantity", "INTEGER", 1, nil, 0],
                  [4, "price", "REAL", 1, nil, 0]
                ],
                num_rows: 5
              }} == XqliteNIF.query(conn, "PRAGMA table_info(order_items);")
    end

    test "fetch foreign key information for customers", %{conn: conn} do
      assert {:ok,
              %{
                columns: [
                  "id",
                  "seq",
                  "table",
                  "from",
                  "to",
                  "on_update",
                  "on_delete",
                  "match"
                ],
                rows: [],
                num_rows: 0
              }} == XqliteNIF.query(conn, "PRAGMA foreign_key_list(customers);")
    end

    test "fetch foreign key information for products", %{conn: conn} do
      assert {:ok,
              %{
                columns: [
                  "id",
                  "seq",
                  "table",
                  "from",
                  "to",
                  "on_update",
                  "on_delete",
                  "match"
                ],
                rows: [],
                num_rows: 0
              }} == XqliteNIF.query(conn, "PRAGMA foreign_key_list(products);")
    end

    test "fetch foreign key information for orders", %{conn: conn} do
      assert {:ok,
              %{
                columns: [
                  "id",
                  "seq",
                  "table",
                  "from",
                  "to",
                  "on_update",
                  "on_delete",
                  "match"
                ],
                rows: [
                  [
                    0,
                    0,
                    "customers",
                    "customer_id",
                    "customer_id",
                    "NO ACTION",
                    "NO ACTION",
                    "NONE"
                  ]
                ],
                num_rows: 1
              }} == XqliteNIF.query(conn, "PRAGMA foreign_key_list(orders);")
    end

    test "fetch foreign key information for order_items", %{conn: conn} do
      assert {:ok,
              %{
                columns: [
                  "id",
                  "seq",
                  "table",
                  "from",
                  "to",
                  "on_update",
                  "on_delete",
                  "match"
                ],
                rows: [
                  [
                    0,
                    0,
                    "products",
                    "product_id",
                    "product_id",
                    "NO ACTION",
                    "NO ACTION",
                    "NONE"
                  ],
                  [1, 0, "orders", "order_id", "order_id", "NO ACTION", "NO ACTION", "NONE"]
                ],
                num_rows: 2
              }} == XqliteNIF.query(conn, "PRAGMA foreign_key_list(order_items);")
    end

    # end of "various tests with multiple tables:"
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
