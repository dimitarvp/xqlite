defmodule Xqlite.NIF.ExecutionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

  @one_then_nope "INSERT INTO t VALUES (1); INSERT INTO nope VALUES (1);"
  @tails ["", ";", " ", "\n-- tail", " /* tail */", ";;  -- tail\n"]

  @forty_free_pages """
  PRAGMA auto_vacuum = INCREMENTAL; VACUUM; CREATE TABLE IF NOT EXISTS big (b BLOB);
  WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 40)
  INSERT INTO big SELECT randomblob(3000) FROM n; DELETE FROM big;
  """

  defp one_row(text), do: "INSERT INTO t VALUES ('#{String.replace(text, "'", "''")}');"
  defp count_t(conn), do: NIF.query(conn, "SELECT count(*) FROM t", [])

  # Creates a table with the standard test columns but allows specifying the name.
  defp setup_named_table(conn, table_name \\ "exec_test") do
    create_sql = "CREATE TABLE #{table_name} #{@exec_test_columns_sql};"
    {:ok, 0} = NIF.execute(conn, create_sql, [])
    conn
  end

  # --- Shared test code (generated via `for` loop for different DB types) ---
  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)

        assert {:ok, conn} = apply(mod, fun, args)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "execute/3 works with nil as params (no parameters)", %{conn: conn} do
        assert {:ok, 0} =
                 NIF.execute(
                   conn,
                   "CREATE TABLE nil_params_test (id INTEGER PRIMARY KEY);",
                   nil
                 )
      end

      test "execute/3 creates a table successfully", %{conn: conn} do
        assert {:ok, 0} =
                 NIF.execute(conn, "CREATE TABLE simple_create (id INTEGER PRIMARY KEY);", [])

        {:ok, objects} = NIF.schema_list_objects(conn, "main")
        assert Enum.any?(objects, &(&1.name == "simple_create"))
      end

      test "execute/3 inserts data with various parameter types", %{conn: conn} do
        setup_named_table(conn)

        sql = """
        INSERT INTO exec_test (id, name, val_int, val_real, val_blob, val_bool)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6);
        """

        blob_data = <<1, 2, 3, 4, 5>>
        params = [1, "Test Name", 123, 99.9, blob_data, true]

        assert {:ok, 1} = NIF.execute(conn, sql, params)

        assert {:ok, %{rows: [[1, "Test Name", 123, 99.9, ^blob_data, 1]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM exec_test WHERE id = 1;", [])
      end

      test "execute/3 inserts data with named parameters", %{conn: conn} do
        setup_named_table(conn)

        sql = """
        INSERT INTO exec_test (id, name, val_int)
        VALUES (:id, :name, :val);
        """

        assert {:ok, 1} = NIF.execute(conn, sql, id: 100, name: "Named", val: 42)

        assert {:ok, %{rows: [[100, "Named", 42]], num_rows: 1}} =
                 NIF.query(conn, "SELECT id, name, val_int FROM exec_test WHERE id = 100;", [])
      end

      test "execute/3 updates data with named parameters", %{conn: conn} do
        setup_named_table(conn)

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO exec_test (id, name) VALUES (?1, ?2);", [
            200,
            "Before"
          ])

        sql = "UPDATE exec_test SET name = :new_name WHERE id = :id;"
        assert {:ok, 1} = NIF.execute(conn, sql, new_name: "After", id: 200)

        assert {:ok, %{rows: [["After"]], num_rows: 1}} =
                 NIF.query(conn, "SELECT name FROM exec_test WHERE id = 200;", [])
      end

      test "execute/3 returns error for invalid named parameter", %{conn: conn} do
        setup_named_table(conn)
        sql = "INSERT INTO exec_test (id, name) VALUES (:id, :name);"

        assert {:error, {:invalid_parameter_name, ":nonexistent"}} =
                 NIF.execute(conn, sql, id: 1, nonexistent: "oops")
      end

      test "execute/3 inserts data with nil values", %{conn: conn} do
        setup_named_table(conn)

        sql = """
        INSERT INTO exec_test (id, name, val_int, val_real, val_blob, val_bool)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6);
        """

        params = [2, nil, nil, nil, nil, nil]

        assert {:ok, 1} = NIF.execute(conn, sql, params)

        assert {:ok, %{rows: [[2, nil, nil, nil, nil, nil]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM exec_test WHERE id = 2;", [])
      end

      test "execute/3 handles boolean false parameter", %{conn: conn} do
        setup_named_table(conn)

        sql = """
        INSERT INTO exec_test (id, name, val_bool) VALUES (?1, ?2, ?3);
        """

        params = [3, "Bool False Test", false]

        assert {:ok, 1} = NIF.execute(conn, sql, params)

        assert {:ok, %{rows: [[3, "Bool False Test", 0]], num_rows: 1}} =
                 NIF.query(conn, "SELECT id, name, val_bool FROM exec_test WHERE id = 3;", [])
      end

      test "execute/3 updates data", %{conn: conn} do
        setup_named_table(conn)

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO exec_test (id, name, val_int) VALUES (1, 'Initial', 10);",
            []
          )

        update_sql = "UPDATE exec_test SET name = ?1, val_int = ?2 WHERE id = ?3;"
        update_params = ["Updated Name", 20, 1]

        assert {:ok, 1} = NIF.execute(conn, update_sql, update_params)

        assert {:ok, %{rows: [[1, "Updated Name", 20]], num_rows: 1}} =
                 NIF.query(conn, "SELECT id, name, val_int FROM exec_test WHERE id = 1;", [])
      end

      test "execute/3 deletes data", %{conn: conn} do
        setup_named_table(conn)

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO exec_test (id, name, val_int) VALUES (1, 'To Delete', 30);",
            []
          )

        assert {:ok, %{num_rows: 1}} =
                 NIF.query(conn, "SELECT id FROM exec_test WHERE id = 1;", [])

        delete_sql = "DELETE FROM exec_test WHERE id = ?1;"
        delete_params = [1]

        assert {:ok, 1} = NIF.execute(conn, delete_sql, delete_params)

        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(conn, "SELECT id FROM exec_test WHERE id = 1;", [])
      end

      test "execute_batch/2 creates table and inserts data", %{conn: conn} do
        create_and_insert_sql = """
        CREATE TABLE batch_exec_test ( id INTEGER PRIMARY KEY, label TEXT );
        INSERT INTO batch_exec_test (id, label) VALUES (1, 'Batch Label 1');
        INSERT INTO batch_exec_test (id, label) VALUES (2, 'Batch Label 2');
        """

        assert :ok = NIF.execute_batch(conn, create_and_insert_sql)

        assert {:ok, %{rows: [[1, "Batch Label 1"], [2, "Batch Label 2"]], num_rows: 2}} =
                 NIF.query(conn, "SELECT * FROM batch_exec_test ORDER BY id;", [])
      end

      test "execute_batch/2 handles empty string", %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, "")
      end

      test "execute_batch/2 handles string with only whitespace/comments", %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, "  -- comment \n ; \t ")
      end

      test "execute_batch/2 returns error on invalid SQL in batch", %{conn: conn} do
        bad_sql = """
        CREATE TABLE ok_table (id INT);
        INSERT INTO ok_table VALUES (1);
        SELECT * FROM non_existent_table; -- This SELECT fails at runtime
        INSERT INTO ok_table VALUES (2); -- This won't run
        """

        # Expect :no_such_table error from the SELECT statement
        assert {:error, {:no_such_table, _msg}} = NIF.execute_batch(conn, bad_sql)

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
        assert {:error, {:no_such_table, "non_existent_table"}} = NIF.execute(conn, sql, [])
      end

      test "execute/3 returns error for TableExists", %{conn: conn} do
        table_name = "already_exists_test_exec"
        setup_named_table(conn, table_name)
        create_sql = "CREATE TABLE #{table_name} (id INT);"
        assert {:error, {:table_exists, ^table_name}} = NIF.execute(conn, create_sql, [])
      end

      test "execute/3 returns error for IndexExists", %{conn: conn} do
        table_name = "index_exists_test_exec"
        index_name = "idx_exists_test_exec"
        setup_named_table(conn, table_name)
        create_index_sql = "CREATE INDEX #{index_name} ON #{table_name}(name);"
        assert {:ok, 0} = NIF.execute(conn, create_index_sql, [])
        assert {:error, {:index_exists, ^index_name}} = NIF.execute(conn, create_index_sql, [])
      end

      test "execute/3 returns error for constraint violation (UNIQUE)", %{conn: conn} do
        table_name = "unique_test_exec"
        setup_named_table(conn, table_name)

        {:ok, 0} =
          NIF.execute(
            conn,
            "CREATE UNIQUE INDEX idx_unique_name_exec ON #{table_name}(name);",
            []
          )

        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "INSERT INTO #{table_name} (id, name) VALUES (1, 'UniqueName');",
                   []
                 )

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

        assert {:error, {:constraint_violation, :constraint_not_null, _msg}} =
                 NIF.execute(
                   conn,
                   "INSERT INTO #{table_name} (id, name) VALUES (1, NULL);",
                   []
                 )
      end

      test "execute/3 returns error for constraint violation (CHECK)", %{conn: conn} do
        table_name = "check_test_exec"
        create_sql = "CREATE TABLE #{table_name} (id INT, val INT CHECK(val > 10));"
        assert {:ok, 0} = NIF.execute(conn, create_sql, [])
        assert {:ok, 1} = NIF.execute(conn, "INSERT INTO #{table_name} VALUES (1, 15);", [])

        assert {:error, {:constraint_violation, :constraint_check, _msg}} =
                 NIF.execute(conn, "INSERT INTO #{table_name} VALUES (2, 5);", [])
      end

      test "execute/3 returns parsed details for constraint violation (ROWID)", %{conn: conn} do
        table_name = "rowid_test_exec"
        assert {:ok, 0} = NIF.execute(conn, "CREATE TABLE #{table_name} (a TEXT);", [])

        assert {:ok, 1} =
                 NIF.execute(conn, "INSERT INTO #{table_name} (rowid, a) VALUES (1, 'x');", [])

        assert {:error,
                {:constraint_violation, :constraint_rowid,
                 %{table: ^table_name, columns: ["rowid"]}}} =
                 NIF.execute(conn, "INSERT INTO #{table_name} (rowid, a) VALUES (1, 'x');", [])
      end

      test "execute/3 returns empty details for a bare virtual-table constraint failure",
           %{conn: conn} do
        table_name = "fts_test_exec"

        assert {:ok, 1} =
                 NIF.execute(conn, "CREATE VIRTUAL TABLE #{table_name} USING fts5(x);", [])

        assert {:ok, 1} =
                 NIF.execute(conn, "INSERT INTO #{table_name} (rowid, x) VALUES (1, 'a');", [])

        assert {:error,
                {:constraint_violation, :constraint_primary_key,
                 %{
                   table: nil,
                   columns: [],
                   index_name: nil,
                   constraint_name: nil,
                   source_type: nil,
                   target_type: nil
                 }}} =
                 NIF.execute(conn, "INSERT INTO #{table_name} (rowid, x) VALUES (1, 'a');", [])
      end

      test "execute/3 reports the fallback kind for a plain SQLITE_CONSTRAINT",
           %{conn: conn} do
        table_name = "rtree_test_exec"

        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "CREATE VIRTUAL TABLE #{table_name} USING rtree(id, minX, maxX);",
                   []
                 )

        assert {:error, {:constraint_violation, :constraint_violation, _details}} =
                 NIF.execute(
                   conn,
                   "INSERT INTO #{table_name} VALUES (1, 5.0, 1.0);",
                   []
                 )
      end

      test "execute/3 returns error for incorrect parameter count", %{conn: conn} do
        setup_named_table(conn)
        sql = "INSERT INTO exec_test (id, name) VALUES (?1, ?2);"

        assert {:error, {:invalid_parameter_count, %{expected: 2, provided: 1}}} =
                 NIF.execute(conn, sql, [1])

        assert {:error, {:invalid_parameter_count, %{expected: 2, provided: 3}}} =
                 NIF.execute(conn, sql, [1, "Name", 999])
      end

      test "execute/3 returns error for invalid parameter type (unsupported)", %{conn: conn} do
        setup_named_table(conn)
        sql = "INSERT INTO exec_test (id, name) VALUES (?1, ?2);"

        assert {:error, {:unsupported_data_type, :map}} =
                 NIF.execute(conn, sql, [1, %{invalid: :map}])
      end

      test "execute/3 successfully stores and query/3 retrieves strings with NUL bytes", %{
        conn: conn
      } do
        setup_named_table(conn)

        nul_string = "String with\0embedded NUL"
        sql_insert = "INSERT INTO exec_test (id, name) VALUES (?1, ?2);"
        insert_params = [10, nul_string]

        assert {:ok, 1} = NIF.execute(conn, sql_insert, insert_params)

        # Verify that the stored string, when retrieved, contains the NUL byte
        sql_select = "SELECT name FROM exec_test WHERE id = ?1;"
        select_params = [10]

        assert {:ok, %{columns: ["name"], rows: [[^nul_string]], num_rows: 1}} =
                 NIF.query(conn, sql_select, select_params)

        assert byte_size(nul_string) == 24
      end

      test "every execute function runs a RETURNING write to its end and answers its count",
           %{conn: conn} do
        setup_named_table(conn)
        sql = "INSERT INTO exec_test (name) VALUES (?1) RETURNING id;"

        assert {:ok, 1} = NIF.execute(conn, sql, ["a"])
        assert {:ok, 1} = NIF.execute_cancellable(conn, sql, ["b"], [])
        assert {:ok, %Xqlite.Result{changes: 1, rows: []}} = Xqlite.execute(conn, sql, ["c"])
        assert {:ok, 1} = Xqlite.execute_cancellable(conn, sql, ["d"], [])

        assert {:ok, %{rows: [["a"], ["b"], ["c"], ["d"]]}} =
                 NIF.query(conn, "SELECT name FROM exec_test ORDER BY id", [])
      end

      test "a batch and execute run PRAGMA incremental_vacuum until no page is free",
           %{conn: conn} do
        for run <- [
              &NIF.execute_batch(&1, "PRAGMA incremental_vacuum;"),
              &NIF.execute(&1, "PRAGMA incremental_vacuum", [])
            ] do
          assert :ok = NIF.execute_batch(conn, @forty_free_pages)
          assert {:ok, %{rows: [[40]]}} = NIF.query(conn, "PRAGMA freelist_count", [])
          assert run.(conn) in [:ok, {:ok, 0}]
          assert {:ok, %{rows: [[0]]}} = NIF.query(conn, "PRAGMA freelist_count", [])
        end
      end

      test "a batch stops at the first failure, in a statement's compile or in any of its rows",
           %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t (x);")
        rest = " INSERT INTO t VALUESS (3); INSERT INTO t VALUES (4);"
        batch = "INSERT INTO t VALUES (1); INSERT INTO t VALUES (2);" <> rest
        overflow = "SELECT abs(v) FROM (SELECT 1 AS v UNION ALL SELECT -9223372036854775808);"

        assert {:error, {:sql_input_error, %{sql: ^rest, offset: 15}}} =
                 NIF.execute_batch(conn, batch)

        assert {:error, {:sqlite_failure, 1, 1, _}} =
                 NIF.execute_batch(conn, overflow <> " INSERT INTO t VALUES (5);")

        assert {:ok, %{rows: [[1], [2]]}} = NIF.query(conn, "SELECT x FROM t", [])
      end

      test "a failed batch rolls back the transaction it opened itself and no other",
           %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t (x);")

        for open <- ["BEGIN;", "SAVEPOINT a;"] do
          assert {:error, {:no_such_table, "nope"}} =
                   NIF.execute_batch(conn, "#{open} #{@one_then_nope} COMMIT;")

          assert {{:ok, true}, {:ok, %{rows: [[0]]}}} = {NIF.autocommit(conn), count_t(conn)}
        end

        :ok = NIF.execute_batch(conn, "BEGIN; INSERT INTO t VALUES (0);")
        assert {:error, {:no_such_table, "nope"}} = NIF.execute_batch(conn, @one_then_nope)
        assert {{:ok, false}, {:ok, %{rows: [[2]]}}} = {NIF.autocommit(conn), count_t(conn)}
        assert {:ok, 0} = NIF.execute(conn, "ROLLBACK", [])
        :ok = NIF.set_authorizer(conn, [:transaction])

        assert {:error, {:no_such_table, "nope"}} =
                 NIF.execute_batch(conn, "SAVEPOINT a; #{@one_then_nope}")

        assert {:ok, false} = NIF.autocommit(conn)
      end

      test "the anchor: a batch longer than the SQL length limit runs when each statement fits",
           %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t (x);")
        assert {:ok, 60} = Xqlite.put_limit(conn, :sql_length, 60)
        assert :ok = NIF.execute_batch(conn, String.duplicate(one_row("a"), 3))
        assert {:ok, %{rows: [[3]]}} = count_t(conn)
      end

      # SQLite checks the SQL length limit against the text it is handed to
      # compile, so a batch longer than the limit ran one statement at a time.
      property "every statement of a batch runs, in order, compiled one at a time",
               %{conn: conn} do
        :ok = NIF.execute_batch(conn, "PRAGMA journal_mode = MEMORY; PRAGMA synchronous = 0;")
        :ok = NIF.execute_batch(conn, "CREATE TABLE t (x);")

        text =
          one_of([string(:printable, max_length: 12), string(~c"';-/*\n ab", max_length: 12)])

        check all(
                texts <- list_of(text, min_length: 1, max_length: 16),
                tail <- member_of(@tails),
                max_runs: 2_000
              ) do
          statements = Enum.map(texts, &one_row/1)
          limit = (statements |> Enum.map(&byte_size/1) |> Enum.max()) + 16
          assert {:ok, ^limit} = Xqlite.put_limit(conn, :sql_length, limit)
          answer = NIF.execute_batch(conn, Enum.join(statements, " ") <> tail)
          assert {:ok, %{rows: rows}} = NIF.query(conn, "SELECT x FROM t ORDER BY rowid", [])
          assert {:ok, _} = NIF.execute(conn, "DELETE FROM t", [])
          assert {answer, rows} == {:ok, Enum.map(texts, &[&1])}
        end
      end

      test "INSERT with 120 positional parameters succeeds", %{conn: conn} do
        col_defs =
          1..120
          |> Enum.map_join(", ", fn i -> "c#{i} INTEGER" end)

        :ok = NIF.execute_batch(conn, "CREATE TABLE big_t (#{col_defs});")

        placeholders =
          1..120
          |> Enum.map_join(", ", fn i -> "?#{i}" end)

        col_names =
          1..120
          |> Enum.map_join(", ", fn i -> "c#{i}" end)

        params = Enum.to_list(1..120)
        sql = "INSERT INTO big_t (#{col_names}) VALUES (#{placeholders})"
        assert {:ok, 1} = NIF.execute(conn, sql, params)

        {:ok, %{rows: [row]}} = NIF.query(conn, "SELECT * FROM big_t", [])
        assert row == params
      end
    end
  end
end
