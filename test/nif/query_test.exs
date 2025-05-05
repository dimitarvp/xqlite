defmodule Xqlite.NIF.QueryTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  @query_test_table_sql """
  CREATE TABLE query_test (
    id INTEGER PRIMARY KEY,
    name TEXT,
    age INTEGER,
    score REAL,
    is_active INTEGER,      -- boolean 0/1
    utf8_text TEXT,         -- Standard text column
    arbitrary_blob BLOB     -- Column specifically for binary data
  );
  """

  @query_test_insert_sql """
  INSERT INTO query_test (id, name, age, score, is_active, utf8_text, arbitrary_blob)
  VALUES
    (1, 'Alice',   30,  95.5, 1, 'First row',  x'FF00FF'),
    (2, 'Bob',     NULL, 80.0, 0, 'Second row', x'C0AF8F'),
    (3, 'Charlie', 35,  NULL, 1, NULL,         x'ED9FBFED'),
    (4, 'Diana',   28,  77.7, NULL,'Fourth row', NULL),
    (5, 'Eve',     40,  88.8, 1, 'Fifth row',  x'FE8080'),
    (6, 'Frank',   22,  91.2, 0, 'Sixth row',  x'F0808080'),
    (7, 'Grace',   50,  70.1, 1, 'Seventh row',x'FF');
  """

  # --- Shared test code (generated via `for` loop for different DB types) ---
  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      # Setup uses a single helper to find the appropriate MFA based on context tag
      setup context do
        {mod, fun, args} = find_opener_mfa!(context)

        assert {:ok, conn} = apply(mod, fun, args),
               "Failed to open connection for tag :#{context[:describetag]}"

        # Create and populate table for query tests
        assert {:ok, 0} = NIF.execute(conn, @query_test_table_sql, [])
        assert {:ok, 7} = NIF.execute(conn, @query_test_insert_sql, [])
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # --- Shared test cases applicable to all DB types follow ---

      test "query/3 fetches all records correctly, including blobs and nulls", %{conn: conn} do
        expected_rows = [
          [1, "Alice", 30, 95.5, 1, "First row", <<255, 0, 255>>],
          [2, "Bob", nil, 80.0, 0, "Second row", <<192, 175, 143>>],
          [3, "Charlie", 35, nil, 1, nil, <<237, 159, 191, 237>>],
          [4, "Diana", 28, 77.7, nil, "Fourth row", nil],
          [5, "Eve", 40, 88.8, 1, "Fifth row", <<254, 128, 128>>],
          [6, "Frank", 22, 91.2, 0, "Sixth row", <<240, 128, 128, 128>>],
          [7, "Grace", 50, 70.1, 1, "Seventh row", <<255>>]
        ]

        expected_columns = [
          "id",
          "name",
          "age",
          "score",
          "is_active",
          "utf8_text",
          "arbitrary_blob"
        ]

        assert {:ok, %{columns: actual_columns, rows: actual_rows, num_rows: actual_num_rows}} =
                 NIF.query(conn, "SELECT * FROM query_test ORDER BY id;", [])

        assert actual_columns == expected_columns
        assert actual_num_rows == 7
        assert actual_rows == expected_rows
      end

      test "query/3 fetches records with positional parameter filters", %{conn: conn} do
        sql = "SELECT id, name FROM query_test WHERE age > ?1 AND is_active = ?2 ORDER BY id;"
        params = [29, 1]
        expected_rows = [[1, "Alice"], [3, "Charlie"], [5, "Eve"], [7, "Grace"]]

        assert {:ok, %{columns: ["id", "name"], rows: expected_rows, num_rows: 4}} ==
                 NIF.query(conn, sql, params)
      end

      test "query/3 fetches records with named parameter filters", %{conn: conn} do
        sql =
          "SELECT id, name FROM query_test WHERE age > :min_age AND arbitrary_blob = :blob ORDER BY id;"

        blob_param = <<0xED, 0x9F, 0xBF, 0xED>>
        params = [min_age: 30, blob: blob_param]
        expected_rows = [[3, "Charlie"]]

        assert {:ok, %{columns: ["id", "name"], rows: expected_rows, num_rows: 1}} ==
                 NIF.query(conn, sql, params)
      end

      test "query/3 handles various parameter data types (named params)", %{conn: conn} do
        sql = """
        SELECT id FROM query_test
        WHERE age = :age
          OR score = :score
          OR (is_active = :active AND is_active IS NOT NULL)
          OR name = :name
          OR arbitrary_blob = :data
        ORDER BY id;
        """

        blob_param = <<0xDD>>
        params = [age: 30, score: 80.0, active: false, name: "Diana", data: blob_param]
        expected_rows = [[1], [2], [4], [6]]

        assert {:ok, %{columns: ["id"], rows: expected_rows, num_rows: 4}} ==
                 NIF.query(conn, sql, params)
      end

      test "query/3 handles nil parameter correctly (positional)", %{conn: conn} do
        sql = "SELECT id FROM query_test WHERE arbitrary_blob IS ?1;"
        params = [nil]
        expected_rows = [[4]]

        assert {:ok, %{columns: ["id"], rows: expected_rows, num_rows: 1}} ==
                 NIF.query(conn, sql, params)
      end

      test "query/3 returns correct structure for query with no results", %{conn: conn} do
        sql = "SELECT id FROM query_test WHERE name = ?1;"
        params = ["NonExistent"]
        assert {:ok, %{columns: ["id"], rows: [], num_rows: 0}} == NIF.query(conn, sql, params)
      end

      # Test INSERT ... RETURNING via query/3
      test "query/3 executes INSERT ... RETURNING and returns inserted ID", %{conn: conn} do
        sql = "INSERT INTO query_test (name, utf8_text) VALUES (?1, ?2) RETURNING id;"
        params = ["New Guy", "Inserted via RETURNING"]

        assert {:ok, %{columns: ["id"], rows: [[inserted_id]], num_rows: 1}} =
                 NIF.query(conn, sql, params)

        assert inserted_id == 8

        # Verify insertion separately
        assert {:ok, %{rows: [[8, "New Guy", "Inserted via RETURNING"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT id, name, utf8_text FROM query_test WHERE id = 8;",
                   []
                 )
      end

      test "query/3 executes INSERT ... RETURNING multiple columns", %{conn: conn} do
        sql =
          "INSERT INTO query_test (name, age, score, arbitrary_blob) VALUES (?1, ?2, ?3, ?4) RETURNING id, name, is_active, arbitrary_blob;"

        blob_param = <<0xEE>>
        params = ["Multi Return", 50, 100.0, blob_param]

        assert {:ok,
                %{
                  columns: ["id", "name", "is_active", "arbitrary_blob"],
                  rows: [[inserted_id, "Multi Return", nil, ^blob_param]],
                  num_rows: 1
                }} =
                 NIF.query(conn, sql, params)

        {:ok, %{rows: [[max_id]]}} = NIF.query(conn, "SELECT MAX(id) FROM query_test;", [])
        assert inserted_id == max_id
      end

      # --- Error Cases for query/3 ---

      test "query/3 returns error for invalid SQL syntax", %{conn: conn} do
        assert {:error, {:cannot_prepare_statement, "SELEC * FROM query_test;", _reason}} =
                 NIF.query(conn, "SELEC * FROM query_test;", [])
      end

      test "query/3 returns error for incorrect parameter count (positional)", %{conn: conn} do
        sql = "SELECT id FROM query_test WHERE age = ?1 AND name = ?2;"

        assert {:error, {:invalid_parameter_count, %{expected: 2, provided: 1}}} =
                 NIF.query(conn, sql, [30])

        assert {:error, {:invalid_parameter_count, %{expected: 2, provided: 3}}} =
                 NIF.query(conn, sql, [30, "Alice", "Extra"])
      end

      test "query/3 returns success for missing named parameter (unexpected)", %{conn: conn} do
        sql = "SELECT id FROM query_test WHERE age = :age AND name = :name;"
        # NOTE: Unexpectedly succeeds, possibly rusqlite treats unbound named params as NULL.
        assert {:ok, %{columns: ["id"], rows: [], num_rows: 0}} ==
                 NIF.query(conn, sql, age: 30)
      end

      test "query/3 returns error for invalid parameter name (named)", %{conn: conn} do
        sql = "SELECT id FROM query_test WHERE age = :age AND name = :name;"

        assert {:error, {:invalid_parameter_name, ":nombre"}} =
                 NIF.query(conn, sql, age: 30, nombre: "Alice")
      end

      test "query/3 parameter type interactions (named vs positional)", %{conn: conn} do
        # SQL with both positional and named placeholders
        sql_mixed = "SELECT id FROM query_test WHERE age = ?1 AND name = :name;"

        # --- Case 1: Using NAMED parameters with MIXED SQL ---
        # This correctly fails because rusqlite tries to bind :age and :name,
        # but the SQL also contains "?1", leading to parameter name/index mismatches.
        named_params = [age: 30, name: "Alice"]

        assert {:error, {:invalid_parameter_name, ":age"}} =
                 NIF.query(conn, sql_mixed, named_params)

        # --- Case 2: Using POSITIONAL parameters with MIXED SQL ---
        # NOTE: Unexpected Behavior: This query SUCCEEDS instead of failing due to
        # the mixed/invalid placeholders (?1 and :name). It appears that when
        # *positional* parameters are provided, rusqlite/SQLite successfully binds
        # the parameter to the positional placeholder (?1) and effectively IGNORES
        # the unbound named placeholder (:name) condition in the WHERE clause.
        # This behavior was confirmed consistent across :memory: and temporary file DBs.
        # age = 30 should match Alice (ID 1)
        positional_params = [30, "Alice"]
        expected_rows = [[1]]

        assert {:ok, %{columns: ["id"], rows: expected_rows, num_rows: 1}} ==
                 NIF.query(conn, sql_mixed, positional_params)

        # --- Case 3: Control - Using ONLY named placeholders with NAMED params ---
        # This should work correctly.
        sql_named_only = "SELECT id FROM query_test WHERE age = :age AND name = :name;"

        assert {:ok, %{columns: ["id"], rows: [[1]], num_rows: 1}} ==
                 NIF.query(conn, sql_named_only, age: 30, name: "Alice")

        # --- Case 4: Control - Using ONLY positional placeholders with POSITIONAL params ---
        # This should work correctly.
        sql_pos_only = "SELECT id FROM query_test WHERE age = ?1 AND name = ?2;"

        assert {:ok, %{columns: ["id"], rows: [[1]], num_rows: 1}} ==
                 NIF.query(conn, sql_pos_only, [30, "Alice"])
      end

      test "query/3 returns error for invalid parameter type (unsupported)", %{conn: conn} do
        sql = "SELECT id FROM query_test WHERE age = ?1;"

        assert {:error, {:unsupported_data_type, :map}} =
                 NIF.query(conn, sql, [%{invalid: :map}])
      end

      test "query/3 returns error for NoSuchTable on SELECT", %{conn: conn} do
        # Try selecting from a table that doesn't exist
        sql = "SELECT * FROM non_existent_table;"
        # This fails during prepare, not execution
        assert {:error, {:cannot_prepare_statement, ^sql, reason}} = NIF.query(conn, sql, [])
        # Verify the reason message confirms the underlying issue
        assert String.contains?(reason || "", "no such table: non_existent_table")
      end
    end

    # end describe "using #{prefix}"
  end

  # end `for` loop

  # --- DB type-specific or other tests (outside the `for` loop) ---
  # None currently identified specifically for query logic
end
