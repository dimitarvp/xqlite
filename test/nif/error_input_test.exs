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

      # An interior NUL in SQL TEXT must be rejected, not silently truncated.
      # rusqlite hands SQLite the SQL length-delimited, and SQLite's tokenizer
      # stops at the first NUL — so "SELECT\0 1" would run as "SELECT" and the
      # rest is silently dropped. Every SQL-text entry point must refuse with
      # :null_byte_in_string, matching the Security guide's contract. (A NUL in
      # a bound VALUE is fine — that path is length-delimited and unaffected.)
      test "interior NUL in SQL text is rejected on query/execute/execute_batch", %{conn: conn} do
        assert {:error, :null_byte_in_string} = NIF.query(conn, "SELECT\0 1", [])
        assert {:error, :null_byte_in_string} = NIF.execute(conn, "SELECT\0 1", [])

        assert {:error, :null_byte_in_string} =
                 NIF.execute_batch(conn, "CREATE TABLE nul_batch\0 (a);")

        # The prepared-statement and stream entry points reject it too.
        assert {:error, :null_byte_in_string} = NIF.stmt_prepare(conn, "SELECT\0 1")
        assert {:error, :null_byte_in_string} = NIF.stream_open(conn, "SELECT\0 1", [], [])

        # A NUL inside a bound value still round-trips byte-exact.
        assert {:ok, _} =
                 NIF.execute(conn, "INSERT INTO error_input_test (id, data) VALUES (1, ?1)", [
                   "a\0b"
                 ])

        assert {:ok, %{rows: [["a\0b"]]}} =
                 NIF.query(conn, "SELECT data FROM error_input_test WHERE id = 1", [])
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
        # The rejected atom is carried in the structured error.
        assert {:error, {:unsupported_atom, "not_a_keyword_list"}} =
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

      test "execute/3 returns :unsupported_atom (carrying the atom) for an invalid atom param",
           %{conn: conn} do
        sql = "INSERT INTO error_input_test (data) VALUES (?1);"
        params = [:unsupported_atom_value]
        # The offending atom is named in the structured error.
        assert {:error, {:unsupported_atom, "unsupported_atom_value"}} =
                 NIF.execute(conn, sql, params)
      end

      test "query/3 returns :unsupported_atom (carrying the atom) for an invalid atom param",
           %{conn: conn} do
        sql = "SELECT * FROM error_input_test WHERE data = ?1;"
        params = [:unsupported_atom_value]

        assert {:error, {:unsupported_atom, "unsupported_atom_value"}} =
                 NIF.query(conn, sql, params)
      end

      test "a blob wrapper holding a non-binary is refused with its position and type",
           %{conn: conn} do
        sql = "SELECT ?1, ?2;"

        assert {:error, {:invalid_blob_bytes, %{position: 1, type: :integer}}} =
                 NIF.query(conn, sql, [%Xqlite.Blob{bytes: 42}, 1])

        assert {:error, {:invalid_blob_bytes, %{position: 2, type: :atom}}} =
                 NIF.query(conn, sql, [1, %Xqlite.Blob{bytes: nil}])

        assert {:error, {:invalid_blob_bytes, %{position: 2, type: :list}}} =
                 NIF.query(conn, sql, [1, %Xqlite.Blob{bytes: [1, 2]}])
      end

      test "a blob wrapper holding a non-binary is refused inside a keyword list",
           %{conn: conn} do
        sql = "SELECT :a, :b;"

        assert {:error, {:invalid_blob_bytes, %{position: 2, type: :integer}}} =
                 NIF.query(conn, sql, a: 1, b: %Xqlite.Blob{bytes: 42})
      end

      test "a blob wrapper holding a non-binary is refused on execute/3", %{conn: conn} do
        sql = "INSERT INTO error_input_test (data) VALUES (?1);"

        assert {:error, {:invalid_blob_bytes, %{position: 1, type: :float}}} =
                 NIF.execute(conn, sql, [%Xqlite.Blob{bytes: 1.5}])
      end

      # The BEAM has one term type for binaries and bitstrings alike, so the
      # refusal cannot read the case off the term type: bytes that are not a
      # whole number of bytes are the only thing that reaches it from there.
      test "a blob wrapper holding a partial-byte bitstring reports :bitstring",
           %{conn: conn} do
        assert {:error, {:invalid_blob_bytes, %{position: 1, type: :bitstring}}} =
                 NIF.query(conn, "SELECT ?1;", [%Xqlite.Blob{bytes: <<1::7>>}])

        assert {:ok, stmt} = NIF.stmt_prepare(conn, "SELECT ?1;")

        assert {:error, {:invalid_blob_bytes, %{position: 1, type: :bitstring}}} =
                 NIF.stmt_bind(stmt, [%Xqlite.Blob{bytes: <<1::7>>}])
      end

      test "every term type a wrapper's bytes can hold names itself", %{conn: conn} do
        payloads = [
          {42, :integer},
          {1.5, :float},
          {nil, :atom},
          {[1, 2], :list},
          {%{a: 1}, :map},
          {{1, 2}, :tuple},
          {fn -> :ok end, :function},
          {self(), :pid},
          {:erlang.list_to_port(~c"#Port<0.1>"), :port},
          {make_ref(), :reference},
          {<<1::7>>, :bitstring}
        ]

        for {bytes, type} <- payloads do
          assert {:error, {:invalid_blob_bytes, %{position: 1, type: ^type}}} =
                   NIF.query(conn, "SELECT ?1;", [%Xqlite.Blob{bytes: bytes}])
        end
      end

      # Only the struct is a parameter; tuples and plain maps stay refused as
      # before, so nothing that used to be an error quietly became a blob.
      test "tuples and plain maps are still unsupported parameter values", %{conn: conn} do
        sql = "SELECT ?1;"

        assert {:error, {:unsupported_data_type, :tuple}} =
                 NIF.query(conn, sql, [{:blob, "abc", :x}])

        assert {:error, {:unsupported_data_type, :tuple}} = NIF.query(conn, sql, [{1, "abc"}])

        assert {:error, {:unsupported_data_type, :map}} =
                 NIF.query(conn, sql, [%{bytes: "abc"}])

        # A leading atom-headed pair is a keyword list in Elixir and always
        # was; the list dispatch is untouched by the wrapper.
        assert {:error, {:invalid_parameter_name, ":blob"}} =
                 NIF.query(conn, sql, [{:blob, "abc"}])
      end

      test "execute/3 returns :multiple_statements for multi-statement SQL", %{conn: conn} do
        sql = "UPDATE error_input_test SET data = 'a'; SELECT * FROM error_input_test;"
        assert {:error, :multiple_statements} = NIF.execute(conn, sql, [])
      end

      test "query/3 returns :multiple_statements for multi-statement SQL", %{conn: conn} do
        sql = "SELECT 1; SELECT 2;"
        assert {:error, :multiple_statements} = NIF.query(conn, sql, [])
      end

      test "query/3 and execute/3 reject SQL that contains no statement", %{conn: conn} do
        assert {:error, {:cannot_execute, _}} = NIF.query(conn, "   ", [])
        assert {:error, {:cannot_execute, _}} = NIF.query(conn, "-- only a comment\n", [])
        assert {:error, {:cannot_execute, _}} = NIF.query(conn, "/* c */", [])
        assert {:error, {:cannot_execute, _}} = NIF.execute(conn, "", [])
        assert {:error, {:cannot_execute, _}} = NIF.query_with_changes(conn, "  ", [])
      end

      test "SQL that contains no statement is rejected before binding", %{conn: conn} do
        assert {:error, {:cannot_execute, _}} = NIF.query(conn, "  ", [1])
      end

      test "query/3 and prepare/2 reject no-statement SQL identically", %{conn: conn} do
        assert {:error, reason} = Xqlite.prepare(conn, "/* c */")
        assert {:error, ^reason} = NIF.query(conn, "/* c */", [])
      end

      test "no-statement SQL still runs on execute_batch/2", %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, "-- nothing")
        assert {:ok, _} = NIF.query(conn, "SELECT 1", [])
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
