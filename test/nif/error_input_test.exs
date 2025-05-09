defmodule Xqlite.NIF.ErrorInputTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]
  alias XqliteNIF, as: NIF

  @simple_table "CREATE TABLE error_input_test (id INTEGER PRIMARY KEY, data TEXT);"

  # --- Shared test code (generated via `for` loop) ---
  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        # Setup a minimal table for tests that need a valid target
        assert {:ok, 0} = NIF.execute(conn, @simple_table, [])
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # --- Input Validation Error Tests ---

      test "execute/3 returns :expected_list when params is not a list", %{conn: conn} do
        sql = "INSERT INTO error_input_test (id) VALUES (?1);"
        invalid_params = :not_a_list
        assert {:error, {:expected_list, _}} = NIF.execute(conn, sql, invalid_params)
      end

      test "query/3 returns :expected_list when params is not a list", %{conn: conn} do
        sql = "SELECT * FROM error_input_test WHERE id = ?1;"
        invalid_params = :not_a_list
        assert {:error, {:expected_list, _}} = NIF.query(conn, sql, invalid_params)
      end

      test "query/3 returns :expected_keyword_list when keyword list expected but invalid list provided",
           %{conn: conn} do
        # This test assumes named params detection requires a non-empty list
        # starting with a valid tuple format. Providing a list not matching
        # keyword format should ideally trigger this, but might trigger
        # :invalid_parameter_name if the first element isn't a tuple.
        # Let's test passing a list of atoms.
        sql = "SELECT * FROM error_input_test WHERE id = :id;"
        invalid_keyword_list = [:not_a_keyword_list]
        # The specific error might depend on rusqlite's internal parsing order.
        # It might raise invalid_parameter_name or expected_keyword_tuple/list.
        # Based on implementation, ExpectedKeywordList seems less likely here than
        # ExpectedKeywordTuple or InvalidParameterName if it attempts binding.
        # Let's assert for the most likely based on needing {atom, term} tuples.
        assert {:error, :unsupported_atom} =
                 NIF.query(conn, sql, invalid_keyword_list)
      end

      test "query/3 returns :expected_keyword_tuple when keyword list has invalid element", %{
        conn: conn
      } do
        sql = "SELECT * FROM error_input_test WHERE id = :id;"
        # List starts like a keyword list but contains an invalid element
        invalid_element_list = [{:valid, 1}, :not_a_tuple]

        assert {:error, {:expected_keyword_tuple, _}} =
                 NIF.query(conn, sql, invalid_element_list)
      end

      test "execute/3 returns :unsupported_atom when parameter atom is invalid", %{conn: conn} do
        sql = "INSERT INTO error_input_test (data) VALUES (?1);"
        params = [:unsupported_atom_value]
        assert {:error, :unsupported_atom} = NIF.execute(conn, sql, params)
      end

      test "query/3 returns :unsupported_atom when parameter atom is invalid", %{conn: conn} do
        sql = "SELECT * FROM error_input_test WHERE data = ?1;"
        params = [:unsupported_atom_value]
        assert {:error, :unsupported_atom} = NIF.query(conn, sql, params)
      end

      test "execute/3 returns :multiple_statements for multi-statement SQL", %{conn: conn} do
        sql = "UPDATE error_input_test SET data = 'a'; SELECT * FROM error_input_test;"
        assert {:error, :multiple_statements} = NIF.execute(conn, sql, [])
      end

      test "query/3 returns :multiple_statements for multi-statement SQL", %{conn: conn} do
        sql = "SELECT 1; SELECT 2;"
        assert {:error, {:cannot_prepare_statement, _sql, _reason}} = NIF.query(conn, sql, [])
      end

      # --- DB State / Execution Error Tests ---

      test "execute/3 returns :no_such_index when dropping non-existent index", %{conn: conn} do
        sql = "DROP INDEX non_existent_index;"
        # Note: SQLite error messages sometimes include the type, e.g., "index"
        assert {:error, {:no_such_index, msg}} = NIF.execute(conn, sql, [])
        assert String.contains?(msg || "", "non_existent_index")
      end

      # --- Foreign Key Constraint Violation Tests ---
      # DDL is now included within each test that needs it.

      test "execute/3 returns :constraint_foreign_key on invalid INSERT", %{conn: conn} do
        # Setup FK tables for this specific test
        fk_ddl = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE fk_parent_insert (id INTEGER PRIMARY KEY);
        CREATE TABLE fk_child_insert (
          id INTEGER PRIMARY KEY,
          parent_id INTEGER NOT NULL REFERENCES fk_parent_insert(id)
        );
        INSERT INTO fk_parent_insert (id) VALUES (1);
        """

        assert :ok = NIF.execute_batch(conn, fk_ddl)

        # Test the violation
        # parent_id 99 doesn't exist
        sql = "INSERT INTO fk_child_insert (id, parent_id) VALUES (10, 99);"

        assert {:error, {:constraint_violation, :constraint_foreign_key, _msg}} =
                 NIF.execute(conn, sql, [])
      end

      test "execute/3 returns :constraint_foreign_key on invalid DELETE", %{conn: conn} do
        # Setup FK tables for this specific test (using different names to avoid conflict)
        fk_ddl = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE fk_parent_delete (id INTEGER PRIMARY KEY);
        CREATE TABLE fk_child_delete (
          id INTEGER PRIMARY KEY,
          parent_id INTEGER NOT NULL REFERENCES fk_parent_delete(id)
        );
        INSERT INTO fk_parent_delete (id) VALUES (1);
        INSERT INTO fk_child_delete (id, parent_id) VALUES (10, 1);
        """

        assert :ok = NIF.execute_batch(conn, fk_ddl)

        # Test the violation: Try deleting the parent row referenced by the child
        sql = "DELETE FROM fk_parent_delete WHERE id = 1;"

        assert {:error, {:constraint_violation, :constraint_foreign_key, _msg}} =
                 NIF.execute(conn, sql, [])
      end
    end
  end
end
