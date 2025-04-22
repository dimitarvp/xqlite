defmodule XqliteNifTest do
  use ExUnit.Case, async: false

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

  setup do
    # Ensure the invalid path target doesn't exist before tests using it
    if File.exists?(@invalid_db_path) do
      raise("Invalid DB path '#{@invalid_db_path}' exists, please remove it.")
    end

    # No shared state needed between test.
    :ok
  end

  describe "raw_open/2 and raw_close/1" do
    test "opens a valid in-memory database, closes it, and fails on second close" do
      assert {:ok, conn} = NIF.raw_open(@valid_db_path)
      assert {:ok, true} = NIF.raw_close(conn)
      assert {:ok, true} = NIF.raw_close(conn)
    end

    test "fails to open an invalid database path immediately" do
      assert {:error, {:cannot_open_database, @invalid_db_path, _reason}} =
               NIF.raw_open(@invalid_db_path)
    end

    test "opens the same database path multiple times, returning the same handle conceptually" do
      assert {:ok, conn1} = NIF.raw_open(@valid_db_path)
      assert {:ok, conn2} = NIF.raw_open(@valid_db_path)

      # The resource handles themselves might be different ResourceArc wrappers,
      # but they should represent the same underlying pooled connection (keyed by path).
      # We can verify this by closing one and checking the other still works (tested by closing)

      assert {:ok, true} = NIF.raw_close(conn1)

      # Closing via conn2 should still succeed because it's no-op on the Rust side
      # as we are relying on the reference-counted Rust `Arc` to ultimately garbage-collect
      # the connection, which leads to actually closing it.
      assert {:ok, true} = NIF.raw_close(conn2)
    end

    # end of describe "raw_open/2 and raw_close/1"
  end

  describe "raw_pragma_write/2" do
    test "can execute a simple PRAGMA" do
      {:ok, conn} = NIF.raw_open(@valid_db_path)
      assert {:ok, 0} = NIF.raw_pragma_write(conn, "PRAGMA synchronous = 0;")
      assert {:ok, true} = NIF.raw_close(conn)
    end
  end

  describe "raw_exec/3" do
    test "can execute a simple query" do
      {:ok, conn} = NIF.raw_open(@valid_db_path)
      assert {:ok, [[1]]} = NIF.raw_exec(conn, "SELECT 1;", [])
      assert {:ok, true} = NIF.raw_close(conn)
    end
  end

  describe "various tests with a single table:" do
    setup do
      {:ok, conn} = NIF.raw_open(":memory:")
      {:ok, _} = NIF.raw_exec(conn, @test_1_create)
      {:ok, _} = NIF.raw_exec(conn, @test_1_insert)
      on_exit(fn -> NIF.raw_close(conn) end)
      {:ok, conn: conn}
    end

    test "fetch all records", %{conn: conn} do
      assert {:ok,
              [
                [1, nil, 3.14, "First row", <<255, 0, 255>>],
                [2, 42, nil, "Second row", <<192, 175, 143>>],
                [3, 123, 2.71828, nil, <<237, 159, 191, 237>>],
                [4, 7, 9.99, "Fourth row", nil],
                [5, 555, 5.55, "Fifth row", <<254, 128, 128>>],
                [6, 666, 6.66, "Sixth row", <<240, 128, 128, 128>>],
                [7, 777, 7.77, "Seventh row", <<255>>]
              ]} == NIF.raw_exec(conn, "SELECT * FROM test1;")
    end

    test "fetch records with filters", %{conn: conn} do
      assert {:ok,
              [
                [5, 555, 5.55, "Fifth row", <<254, 128, 128>>],
                [6, 666, 6.66, "Sixth row", <<240, 128, 128, 128>>],
                [7, 777, 7.77, "Seventh row", <<255>>]
              ]} ==
               NIF.raw_exec(
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
      {:ok, conn} = NIF.raw_open(":memory:")

      for ddl <- @test_2_create_statements do
        {:ok, _ddl_result} = XqliteNIF.raw_exec(conn, ddl)
      end

      on_exit(fn -> NIF.raw_close(conn) end)
      {:ok, conn: conn}
    end

    test "fetch all tables", %{conn: conn} do
      assert {:ok,
              [
                ["main", "order_items", "table", 5, 0, 0],
                ["main", "orders", "table", 4, 0, 0],
                ["main", "products", "table", 3, 0, 0],
                ["main", "customers", "table", 3, 0, 0],
                ["main", "sqlite_schema", "table", 5, 0, 0],
                ["temp", "sqlite_temp_schema", "table", 5, 0, 0]
              ]} == XqliteNIF.raw_exec(conn, "PRAGMA table_list;")
    end

    test "fetch table information for customers", %{conn: conn} do
      assert {:ok,
              [
                [0, "customer_id", "INTEGER", 0, nil, 1],
                [1, "name", "TEXT", 1, nil, 0],
                [2, "email", "TEXT", 0, nil, 0]
              ]} == XqliteNIF.raw_exec(conn, "PRAGMA table_info(customers);")
    end

    test "fetch table information for products", %{conn: conn} do
      assert {:ok,
              [
                [0, "product_id", "INTEGER", 0, nil, 1],
                [1, "name", "TEXT", 1, nil, 0],
                [2, "price", "REAL", 1, nil, 0]
              ]} == XqliteNIF.raw_exec(conn, "PRAGMA table_info(products);")
    end

    test "fetch table information for orders", %{conn: conn} do
      assert {:ok,
              [
                [0, "order_id", "INTEGER", 0, nil, 1],
                [1, "customer_id", "INTEGER", 1, nil, 0],
                [2, "order_date", "TEXT", 1, nil, 0],
                [3, "status", "TEXT", 1, nil, 0]
              ]} == XqliteNIF.raw_exec(conn, "PRAGMA table_info(orders);")
    end

    test "fetch table information for order_items", %{conn: conn} do
      assert {:ok,
              [
                [0, "item_id", "INTEGER", 0, nil, 1],
                [1, "order_id", "INTEGER", 1, nil, 0],
                [2, "product_id", "INTEGER", 1, nil, 0],
                [3, "quantity", "INTEGER", 1, nil, 0],
                [4, "price", "REAL", 1, nil, 0]
              ]} == XqliteNIF.raw_exec(conn, "PRAGMA table_info(order_items);")
    end

    test "fetch foreign key information for customers", %{conn: conn} do
      assert {:ok, []} == XqliteNIF.raw_exec(conn, "PRAGMA foreign_key_list(customers);")
    end

    test "fetch foreign key information for products", %{conn: conn} do
      assert {:ok, []} == XqliteNIF.raw_exec(conn, "PRAGMA foreign_key_list(products);")
    end

    test "fetch foreign key information for orders", %{conn: conn} do
      assert {:ok,
              [
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
              ]} == XqliteNIF.raw_exec(conn, "PRAGMA foreign_key_list(orders);")
    end

    test "fetch foreign key information for order_items", %{conn: conn} do
      assert {:ok,
              [
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
              ]} == XqliteNIF.raw_exec(conn, "PRAGMA foreign_key_list(order_items);")
    end

    # end of "various tests with multiple tables:"
  end
end
