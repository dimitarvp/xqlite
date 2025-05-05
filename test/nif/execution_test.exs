defmodule Xqlite.NIF.ExecutionTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  # Standard column definitions for reusable test table setup
  @exec_test_columns_sql """
  (
    id INTEGER PRIMARY KEY,
    name TEXT,
    val_int INTEGER,
    val_real REAL,
    val_blob BLOB,
    val_bool INTEGER -- Storing bools as 0/1
  )
  """

  # Creates a table with the standard test columns but allows specifying the name.
  defp setup_named_table(conn, table_name \\ "exec_test") do
    create_sql = "CREATE TABLE #{table_name} #{@exec_test_columns_sql};"
    # Pattern match ensures execute returns success, otherwise test fails here.
    {:ok, 0} = NIF.execute(conn, create_sql, [])
    conn
  end

  # --- Shared test code (generated via `for` loop for different DB types) ---
  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      # Setup uses a single helper to find the appropriate MFA based on context tag
      setup context do
        {mod, fun, args} = find_opener_mfa!(context)

        # Open connection
        assert {:ok, conn} = apply(mod, fun, args),
               "Failed to open connection for tag :#{context[:describetag]}"

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # --- Shared test cases applicable to all DB types follow ---
      # These tests inherit the simple atom tag (e.g. :memory_private or :file_temp etc.)

      test "execute/3 creates a table successfully", %{conn: conn} do
        sql = "CREATE TABLE simple_create (id INTEGER PRIMARY KEY);"
        # DDL usually returns 0 affected rows
        assert {:ok, 0} = NIF.execute(conn, sql, [])

        # Verify table exists by querying PRAGMA table_list
        assert {:ok, %{rows: [[_, "simple_create", _, _, _, _]], num_rows: 1}} =
                 NIF.query(conn, "PRAGMA table_list;", [])
                 |> then(fn {:ok, res} ->
                   filtered_rows =
                     Enum.filter(res.rows, fn [_schema, name, _, _, _, _] ->
                       name == "simple_create"
                     end)

                   {:ok, %{res | rows: filtered_rows, num_rows: Enum.count(filtered_rows)}}
                 end)
      end

      test "execute/3 inserts data with various parameter types", %{conn: conn} do
        setup_named_table(conn)

        sql = """
        INSERT INTO exec_test (id, name, val_int, val_real, val_blob, val_bool)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6);
        """

        blob_data = <<1, 2, 3, 4, 5>>
        params = [1, "Test Name", 123, 99.9, blob_data, true]

        # INSERT affects 1 row
        assert {:ok, 1} = NIF.execute(conn, sql, params)

        # Verify insertion using query
        assert {:ok, %{rows: [[1, "Test Name", 123, 99.9, ^blob_data, 1]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM exec_test WHERE id = 1;", [])
      end

      test "execute/3 inserts data with nil values", %{conn: conn} do
        setup_named_table(conn)

        sql = """
        INSERT INTO exec_test (id, name, val_int, val_real, val_blob, val_bool)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6);
        """

        # Use Elixir nil
        params = [2, nil, nil, nil, nil, nil]

        assert {:ok, 1} = NIF.execute(conn, sql, params)
        # Verify nil values were inserted correctly
        assert {:ok, %{rows: [[2, nil, nil, nil, nil, nil]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM exec_test WHERE id = 2;", [])
      end

      test "execute/3 handles boolean false parameter", %{conn: conn} do
        setup_named_table(conn)

        sql = """
        INSERT INTO exec_test (id, name, val_bool) VALUES (?1, ?2, ?3);
        """

        # Use Elixir false
        params = [3, "Bool False Test", false]

        assert {:ok, 1} = NIF.execute(conn, sql, params)
        # Verify boolean false was stored as integer 0
        assert {:ok, %{rows: [[3, "Bool False Test", 0]], num_rows: 1}} =
                 NIF.query(conn, "SELECT id, name, val_bool FROM exec_test WHERE id = 3;", [])
      end

      test "execute/3 updates data", %{conn: conn} do
        setup_named_table(conn)
        # Insert initial row
        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO exec_test (id, name, val_int) VALUES (1, 'Initial', 10);",
            []
          )

        update_sql = "UPDATE exec_test SET name = ?1, val_int = ?2 WHERE id = ?3;"
        update_params = ["Updated Name", 20, 1]

        assert {:ok, 1} = NIF.execute(conn, update_sql, update_params)

        # Verify update by querying the row
        assert {:ok, %{rows: [[1, "Updated Name", 20]], num_rows: 1}} =
                 NIF.query(conn, "SELECT id, name, val_int FROM exec_test WHERE id = 1;", [])
      end

      test "execute/3 deletes data", %{conn: conn} do
        setup_named_table(conn)

        # Insert initial row
        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO exec_test (id, name, val_int) VALUES (1, 'To Delete', 30);",
            []
          )

        # Verify it exists before delete
        assert {:ok, %{num_rows: 1}} =
                 NIF.query(conn, "SELECT id FROM exec_test WHERE id = 1;", [])

        delete_sql = "DELETE FROM exec_test WHERE id = ?1;"
        delete_params = [1]

        # DELETE affects 1 row
        assert {:ok, 1} = NIF.execute(conn, delete_sql, delete_params)

        # Verify deletion by querying again
        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(conn, "SELECT id FROM exec_test WHERE id = 1;", [])
      end

      test "execute_batch/2 creates table and inserts data", %{conn: conn} do
        create_and_insert_sql = """
        CREATE TABLE batch_exec_test ( id INTEGER PRIMARY KEY, label TEXT );
        INSERT INTO batch_exec_test (id, label) VALUES (1, 'Batch Label 1');
        INSERT INTO batch_exec_test (id, label) VALUES (2, 'Batch Label 2');
        """

        assert {:ok, true} = NIF.execute_batch(conn, create_and_insert_sql)

        assert {:ok, %{rows: [[1, "Batch Label 1"], [2, "Batch Label 2"]], num_rows: 2}} =
                 NIF.query(conn, "SELECT * FROM batch_exec_test ORDER BY id;", [])
      end

      test "execute_batch/2 handles empty string", %{conn: conn} do
        assert {:ok, true} = NIF.execute_batch(conn, "")
      end

      test "execute_batch/2 handles string with only whitespace/comments", %{conn: conn} do
        assert {:ok, true} = NIF.execute_batch(conn, "  -- comment \n ; \t ")
      end

      test "execute_batch/2 returns error on invalid SQL in batch", %{conn: conn} do
        bad_sql = """
        CREATE TABLE ok_table (id INT);
        INSERT INTO ok_table VALUES (1);
        SELECT * FROM non_existent_table; -- This SELECT fails at runtime
        INSERT INTO ok_table VALUES (2); -- This won't run
        """

        # Expect :no_such_table error from the SELECT statement
        assert {:error, {:no_such_table, msg}} = NIF.execute_batch(conn, bad_sql)
        assert String.contains?(msg || "", "no such table: non_existent_table")

        # Verify statements before the error might have executed
        assert {:ok, %{rows: [[1]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM ok_table;", [])
      end

      test "execute/3 returns error for invalid SQL syntax", %{conn: conn} do
        assert {:error, {:sql_input_error, %{message: msg}}} =
                 NIF.execute(conn, "CREATE TABLET bad (id INT);", [])

        assert String.contains?(msg, "syntax error")
        assert String.contains?(msg, "TABLET")
      end

      test "execute/3 returns error for NoSuchTable on INSERT", %{conn: conn} do
        # Try inserting into a table that doesn't exist
        sql = "INSERT INTO non_existent_table (col) VALUES (1);"
        assert {:error, {:no_such_table, msg}} = NIF.execute(conn, sql, [])
        assert String.contains?(msg || "", "no such table: non_existent_table")
      end

      test "execute/3 returns error for TableExists", %{conn: conn} do
        # Use distinct name
        table_name = "already_exists_test_exec"
        # Create the table first
        setup_named_table(conn, table_name)
        # Try creating it again
        create_sql = "CREATE TABLE #{table_name} (id INT);"
        assert {:error, {:table_exists, msg}} = NIF.execute(conn, create_sql, [])
        assert String.contains?(msg || "", "table #{table_name} already exists")
      end

      test "execute/3 returns error for IndexExists", %{conn: conn} do
        # Use distinct name
        table_name = "index_exists_test_exec"
        # Use distinct name
        index_name = "idx_exists_test_exec"
        setup_named_table(conn, table_name)
        # Create the index first
        create_index_sql = "CREATE INDEX #{index_name} ON #{table_name}(name);"
        assert {:ok, 0} = NIF.execute(conn, create_index_sql, [])
        # Try creating it again
        assert {:error, {:index_exists, msg}} = NIF.execute(conn, create_index_sql, [])
        assert String.contains?(msg || "", "index #{index_name} already exists")
      end

      test "execute/3 returns error for constraint violation (UNIQUE)", %{conn: conn} do
        # Use setup helper with a specific table name for isolation
        # Use distinct name from other tests
        table_name = "unique_test_exec"
        setup_named_table(conn, table_name)
        # Add unique index
        {:ok, 0} =
          NIF.execute(
            conn,
            "CREATE UNIQUE INDEX idx_unique_name_exec ON #{table_name}(name);",
            []
          )

        # Insert first row successfully
        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "INSERT INTO #{table_name} (id, name) VALUES (1, 'UniqueName');",
                   []
                 )

        # Attempt to insert duplicate name, expect constraint violation
        assert {:error, {:constraint_violation, :constraint_unique, _msg}} =
                 NIF.execute(
                   conn,
                   "INSERT INTO #{table_name} (id, name) VALUES (2, 'UniqueName');",
                   []
                 )
      end

      test "execute/3 returns error for constraint violation (NOT NULL)", %{conn: conn} do
        table_name = "notnull_test_exec"

        create_notnull_sql =
          "CREATE TABLE #{table_name} (id INTEGER PRIMARY KEY, name TEXT NOT NULL);"

        assert {:ok, 0} = NIF.execute(conn, create_notnull_sql, [])
        # Attempt to insert NULL into the NOT NULL column
        assert {:error, {:constraint_violation, :constraint_not_null, _msg}} =
                 NIF.execute(
                   conn,
                   "INSERT INTO #{table_name} (id, name) VALUES (1, NULL);",
                   []
                 )
      end

      test "execute/3 returns error for constraint violation (CHECK)", %{conn: conn} do
        # Use distinct name
        table_name = "check_test_exec"
        create_sql = "CREATE TABLE #{table_name} (id INT, val INT CHECK(val > 10));"
        assert {:ok, 0} = NIF.execute(conn, create_sql, [])
        assert {:ok, 1} = NIF.execute(conn, "INSERT INTO #{table_name} VALUES (1, 15);", [])
        # Attempt to insert an invalid row violating the CHECK
        assert {:error, {:constraint_violation, :constraint_check, _msg}} =
                 NIF.execute(conn, "INSERT INTO #{table_name} VALUES (2, 5);", [])
      end

      test "execute/3 returns error for incorrect parameter count", %{conn: conn} do
        # Use setup helper with default table name
        setup_named_table(conn)
        sql = "INSERT INTO exec_test (id, name) VALUES (?1, ?2);"
        # Provide 1 param where 2 are expected
        assert {:error, {:invalid_parameter_count, %{expected: 2, provided: 1}}} =
                 NIF.execute(conn, sql, [1])

        # Provide 3 params where 2 are expected
        assert {:error, {:invalid_parameter_count, %{expected: 2, provided: 3}}} =
                 NIF.execute(conn, sql, [1, "Name", 999])
      end

      test "execute/3 returns error for invalid parameter type (unsupported)", %{conn: conn} do
        # Use setup helper with default table name
        setup_named_table(conn)
        sql = "INSERT INTO exec_test (id, name) VALUES (?1, ?2);"
        # Pass a map, which is not a supported type for direct binding
        assert {:error, {:unsupported_data_type, :map}} =
                 NIF.execute(conn, sql, [1, %{invalid: :map}])
      end

      test "execute/3 successfully stores and query/3 retrieves strings with NUL bytes", %{
        conn: conn
      } do
        # Use setup helper with default table name
        setup_named_table(conn)

        nul_string = "String with\0embedded NUL"
        sql_insert = "INSERT INTO exec_test (id, name) VALUES (?1, ?2);"
        insert_params = [10, nul_string]

        # Assert that inserting the NUL-containing string succeeds
        assert {:ok, 1} = NIF.execute(conn, sql_insert, insert_params)

        # Verify that the stored string, when retrieved, contains the NUL byte
        sql_select = "SELECT name FROM exec_test WHERE id = ?1;"
        select_params = [10]

        # Assert the query succeeds and the retrieved string matches the original
        assert {:ok, %{columns: ["name"], rows: [[^nul_string]], num_rows: 1}} =
                 NIF.query(conn, sql_select, select_params)

        # Double-check byte size to be sure NUL wasn't truncated
        assert byte_size(nul_string) == 24

        assert {:ok, %{rows: [[retrieved_string]]}} =
                 NIF.query(conn, sql_select, select_params)

        assert byte_size(retrieved_string) == 24
      end

      test "execute/3 returns error when trying to execute non-query with RETURNING via execute",
           %{conn: conn} do
        # Use setup helper with default table name
        setup_named_table(conn)

        sql = "INSERT INTO exec_test (name, val_int) VALUES (?1, ?2) RETURNING id;"
        params = ["Should Fail", 99]
        assert {:error, :execute_returned_results} = NIF.execute(conn, sql, params)
      end
    end

    # end describe "using #{prefix}"
  end

  # end `for` loop

  # --- DB type-specific or other tests (outside the `for` loop) ---
  # None currently identified for execute/execute_batch
end
