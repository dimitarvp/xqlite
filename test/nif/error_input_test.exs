defmodule Xqlite.NIF.ErrorInputTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1, tmp_db_path: 1]

  alias XqliteNIF, as: NIF

  @simple_table "CREATE TABLE error_input_test (id INTEGER PRIMARY KEY, data TEXT);"

  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        assert {:ok, 0} = NIF.execute(conn, @simple_table, [])
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

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

        assert {:error, :null_byte_in_string} = NIF.stmt_prepare(conn, "SELECT\0 1")
        assert {:error, :null_byte_in_string} = NIF.stream_open(conn, "SELECT\0 1", [])

        assert {:ok, _} =
                 NIF.execute(conn, "INSERT INTO error_input_test (id, data) VALUES (1, ?1)", [
                   "a\0b"
                 ])

        assert {:ok, %{rows: [["a\0b"]]}} =
                 NIF.query(conn, "SELECT data FROM error_input_test WHERE id = 1", [])
      end

      test "query/3 returns :expected_keyword_list when keyword list expected but invalid list provided",
           %{conn: conn} do
        sql = "SELECT * FROM error_input_test WHERE id = :id;"
        invalid_keyword_list = [:not_a_keyword_list]

        assert {:error, {:unsupported_atom, "not_a_keyword_list"}} =
                 NIF.query(conn, sql, invalid_keyword_list)
      end

      test "query/3 returns :expected_keyword_tuple when keyword list has invalid element", %{
        conn: conn
      } do
        sql = "SELECT * FROM error_input_test WHERE id = :id;"
        invalid_element_list = [{:valid, 1}, :not_a_tuple]

        assert {:error,
                {:expected_keyword_tuple,
                 %{reason: :bad_element, position: 2, value_type: :atom}}} =
                 NIF.query(conn, sql, invalid_element_list)
      end

      test "execute/3 returns :unsupported_atom (carrying the atom) for an invalid atom param",
           %{conn: conn} do
        sql = "INSERT INTO error_input_test (data) VALUES (?1);"
        params = [:unsupported_atom_value]

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
        assert {:error, :no_statement} = NIF.query(conn, "   ", [])
        assert {:error, :no_statement} = NIF.query(conn, "-- only a comment\n", [])
        assert {:error, :no_statement} = NIF.query(conn, "/* c */", [])
        assert {:error, :no_statement} = NIF.execute(conn, "", [])
        assert {:error, :no_statement} = NIF.query_with_changes(conn, "  ", [])
      end

      test "SQL that contains no statement is rejected before binding", %{conn: conn} do
        assert {:error, :no_statement} = NIF.query(conn, "  ", [1])
      end

      test "query/3 and prepare/2 reject no-statement SQL identically", %{conn: conn} do
        assert {:error, reason} = Xqlite.prepare(conn, "/* c */")
        assert {:error, ^reason} = NIF.query(conn, "/* c */", [])
      end

      test "no-statement SQL still runs on execute_batch/2", %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, "-- nothing")
        assert {:ok, _} = NIF.query(conn, "SELECT 1", [])
      end

      test "execute/3 returns :no_such_index when dropping non-existent index", %{conn: conn} do
        sql = "DROP INDEX non_existent_index;"
        assert {:error, {:no_such_index, msg}} = NIF.execute(conn, sql, [])
        assert String.contains?(msg || "", "non_existent_index")
      end

      test "execute/3 returns :constraint_foreign_key on invalid INSERT", %{conn: conn} do
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

        # parent_id 99 doesn't exist
        sql = "INSERT INTO fk_child_insert (id, parent_id) VALUES (10, 99);"

        assert {:error, {:constraint_violation, :constraint_foreign_key, _msg}} =
                 NIF.execute(conn, sql, [])
      end

      test "execute/3 returns :constraint_foreign_key on invalid DELETE", %{conn: conn} do
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

        sql = "DELETE FROM fk_parent_delete WHERE id = 1;"

        assert {:error, {:constraint_violation, :constraint_foreign_key, _msg}} =
                 NIF.execute(conn, sql, [])
      end

      test "SQL text that is not UTF-8 is refused on every SQL door", %{conn: conn} do
        sql = "SELECT " <> <<255>>

        assert {:error, :invalid_utf8_in_string} = NIF.query(conn, sql, [])
        assert {:error, :invalid_utf8_in_string} = NIF.execute(conn, sql, [])
        assert {:error, :invalid_utf8_in_string} = NIF.execute_batch(conn, sql)
        assert {:error, :invalid_utf8_in_string} = NIF.stmt_prepare(conn, sql)
        assert {:error, :invalid_utf8_in_string} = NIF.stream_open(conn, sql, [])
        assert {:error, :invalid_utf8_in_string} = NIF.explain_analyze(conn, sql, [])

        assert {:error, :invalid_utf8_in_string} = Xqlite.query(conn, sql, [])
        assert {:error, :invalid_utf8_in_string} = Xqlite.execute(conn, sql, [])
        assert {:error, :invalid_utf8_in_string} = Xqlite.execute_batch(conn, sql)
        assert {:error, :invalid_utf8_in_string} = Xqlite.prepare(conn, sql)
        assert {:error, :invalid_utf8_in_string} = Xqlite.stream(conn, sql, [])
        assert {:error, :invalid_utf8_in_string} = Xqlite.explain_analyze(conn, sql, [])
      end

      test "the cancellable twins refuse the same SQL text", %{conn: conn} do
        sql = "SELECT " <> <<255>>

        assert {:error, :invalid_utf8_in_string} = NIF.query_cancellable(conn, sql, [], [])
        assert {:error, :invalid_utf8_in_string} = NIF.execute_cancellable(conn, sql, [], [])
        assert {:error, :invalid_utf8_in_string} = NIF.execute_batch_cancellable(conn, sql, [])

        assert {:error, :invalid_utf8_in_string} =
                 NIF.query_with_changes_cancellable(conn, sql, [], [])
      end

      # One byte apart, two faults, one atom each.
      test "an interior NUL and bytes that are no UTF-8 answer their own atom", %{conn: conn} do
        assert {:error, :null_byte_in_string} = NIF.query(conn, "SELECT 1" <> <<0>>, [])
        assert {:error, :invalid_utf8_in_string} = NIF.query(conn, "SELECT 1" <> <<255>>, [])
      end

      test "every text argument of the raw NIFs refuses bytes that are no UTF-8", %{conn: conn} do
        for {door, call} <- text_doors(conn, <<109, 97, 255, 110>>) do
          assert {^door, {:error, :invalid_utf8_in_string}} = {door, call.()}
        end
      end

      test "every text argument still raises for a term that is no binary", %{conn: conn} do
        for {_door, call} <- text_doors(conn, 42) do
          assert_raise ArgumentError, fn -> call.() end
        end
      end

      # The witness that nothing is prepared: an authorizer that denies SELECT
      # answers for a statement SQLite parses, so a text refusal arriving
      # instead means SQLite was never asked.
      property "text that is not UTF-8 is refused before SQLite sees a statement", %{
        conn: conn
      } do
        assert :ok = Xqlite.set_authorizer(conn, [:select])
        assert {:error, {:authorization_denied, _code, _msg}} = NIF.query(conn, "SELECT 1", [])

        check all(
                head <- short_ascii(),
                tail <- short_ascii(),
                max_runs: 2000
              ) do
          sql = "SELECT '" <> head <> <<255>> <> tail <> "'"
          refute String.valid?(sql)

          assert {:error, :invalid_utf8_in_string} = NIF.query(conn, sql, [])
          assert {:error, :invalid_utf8_in_string} = NIF.stmt_prepare(conn, sql)
          assert {:error, :invalid_utf8_in_string} = NIF.execute_batch(conn, sql)
        end
      end

      # The rule the refusal must not move: the same bytes in a PARAMETER are
      # a BLOB, not text, and come back byte for byte.
      property "the same bytes as a parameter still bind as a BLOB", %{conn: conn} do
        check all(
                head <- short_ascii(),
                tail <- short_ascii(),
                max_runs: 2000
              ) do
          bytes = head <> <<255>> <> tail

          assert {:ok, %{rows: [["blob", ^bytes]]}} =
                   NIF.query(conn, "SELECT typeof(?1), ?1", [bytes])

          assert {:ok, %{rows: [["blob", ^bytes]]}} =
                   NIF.query(conn, "SELECT typeof(:v), :v", v: bytes)
        end
      end
    end
  end

  defp short_ascii do
    StreamData.scale(StreamData.string(:alphanumeric), fn size -> min(size, 12) end)
  end

  # One call per argument the native side reads as caller text, each with the
  # text position holding `value`. The calls are functions so a test can run
  # them for an answer or for a raise.
  defp text_doors(conn, value) do
    assert {:ok, session} = NIF.session_new(conn)
    path = tmp_db_path("bad_text_arg")

    [
      {:open, fn -> NIF.open(value) end},
      {:open_in_memory, fn -> NIF.open_in_memory(value) end},
      {:open_readonly, fn -> NIF.open_readonly(value) end},
      {:open_in_memory_readonly, fn -> NIF.open_in_memory_readonly(value) end},
      {:query, fn -> NIF.query(conn, value, []) end},
      {:execute, fn -> NIF.execute(conn, value, []) end},
      {:execute_batch, fn -> NIF.execute_batch(conn, value) end},
      {:query_with_changes, fn -> NIF.query_with_changes(conn, value, []) end},
      {:query_cancellable, fn -> NIF.query_cancellable(conn, value, [], []) end},
      {:execute_cancellable, fn -> NIF.execute_cancellable(conn, value, [], []) end},
      {:execute_batch_cancellable, fn -> NIF.execute_batch_cancellable(conn, value, []) end},
      {:query_with_changes_cancellable,
       fn -> NIF.query_with_changes_cancellable(conn, value, [], []) end},
      {:explain_analyze, fn -> NIF.explain_analyze(conn, value, []) end},
      {:stmt_prepare, fn -> NIF.stmt_prepare(conn, value) end},
      {:stream_open, fn -> NIF.stream_open(conn, value, []) end},
      {:savepoint, fn -> NIF.savepoint(conn, value) end},
      {:rollback_to_savepoint, fn -> NIF.rollback_to_savepoint(conn, value) end},
      {:release_savepoint, fn -> NIF.release_savepoint(conn, value) end},
      {:schema_list_objects, fn -> NIF.schema_list_objects(conn, value) end},
      {:schema_columns, fn -> NIF.schema_columns(conn, value) end},
      {:schema_foreign_keys, fn -> NIF.schema_foreign_keys(conn, value) end},
      {:schema_indexes, fn -> NIF.schema_indexes(conn, value) end},
      {:schema_index_columns, fn -> NIF.schema_index_columns(conn, value) end},
      {:get_create_sql, fn -> NIF.get_create_sql(conn, value) end},
      {:txn_state, fn -> NIF.txn_state(conn, value) end},
      {:wal_checkpoint, fn -> NIF.wal_checkpoint(conn, :passive, value) end},
      {:progress_hook_tag, fn -> NIF.register_progress_hook(conn, self(), 1, value) end},
      {:serialize, fn -> NIF.serialize(conn, value) end},
      {:deserialize, fn -> NIF.deserialize(conn, value, <<>>, false) end},
      {:load_extension_path, fn -> NIF.load_extension(conn, value, nil) end},
      {:load_extension_entry_point, fn -> NIF.load_extension(conn, path, value) end},
      {:backup_schema, fn -> NIF.backup(conn, value, path) end},
      {:backup_dest_path, fn -> NIF.backup(conn, "main", value) end},
      {:restore_schema, fn -> NIF.restore(conn, value, path) end},
      {:restore_src_path, fn -> NIF.restore(conn, "main", value) end},
      {:backup_with_progress_schema,
       fn -> NIF.backup_with_progress(conn, value, path, self(), 1, []) end},
      {:backup_with_progress_dest,
       fn -> NIF.backup_with_progress(conn, "main", value, self(), 1, []) end},
      {:session_attach, fn -> NIF.session_attach(session, value) end},
      {:blob_open_db, fn -> NIF.blob_open(conn, value, "t", "c", 1, false) end},
      {:blob_open_table, fn -> NIF.blob_open(conn, "main", value, "c", 1, false) end},
      {:blob_open_column, fn -> NIF.blob_open(conn, "main", "t", value, 1, false) end}
    ]
  end
end
