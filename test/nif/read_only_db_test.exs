defmodule Xqlite.NIF.ReadOnlyDbTest do
  # Read-only tests involve file setup once
  use ExUnit.Case, async: false

  alias XqliteNIF, as: NIF

  @db_file_prefix "read_only_test_"
  @test_table_name "ro_test_table"
  @create_table_sql "CREATE TABLE #{@test_table_name} (id INTEGER PRIMARY KEY, data TEXT);"
  @insert_sql "INSERT INTO #{@test_table_name} (id, data) VALUES (1, 'sample data');"

  defp create_temp_db_file() do
    temp_db_path =
      Path.join(
        System.tmp_dir!(),
        @db_file_prefix <> Integer.to_string(:erlang.unique_integer([:positive])) <> ".db"
      )

    # Clean up if exists
    File.rm(temp_db_path)
    {:ok, conn_rw} = NIF.open(temp_db_path)
    assert {:ok, 0} = NIF.execute(conn_rw, @create_table_sql, [])
    assert {:ok, 1} = NIF.execute(conn_rw, @insert_sql, [])
    assert :ok = NIF.close(conn_rw)
    temp_db_path
  end

  setup_all do
    db_path = create_temp_db_file()
    read_only_uri = "file:#{db_path}?mode=ro"
    {:ok, ro_conn} = NIF.open(read_only_uri)

    on_exit(fn ->
      NIF.close(ro_conn)
      File.rm(db_path)
    end)

    {:ok, conn: ro_conn, db_path: db_path}
  end

  # --- Read Operations on Read-Only DB ---

  test "query/3 (SELECT) succeeds on a read-only database", %{conn: ro_conn} do
    # Added column names for completeness
    assert {:ok, %{columns: ["id", "data"], rows: [[1, "sample data"]], num_rows: 1}} =
             NIF.query(ro_conn, "SELECT id, data FROM #{@test_table_name} WHERE id = 1;", [])
  end

  test "get_pragma/2 succeeds for read-only pragmas", %{conn: ro_conn} do
    # More specific assertion
    assert {:ok, "UTF-8"} = NIF.get_pragma(ro_conn, "encoding")
    assert {:ok, 0} = NIF.get_pragma(ro_conn, "foreign_keys")
  end

  test "schema introspection NIFs succeed on a read-only database", %{conn: ro_conn} do
    # Check main db file path in schema_databases
    assert {:ok, [db_info | _]} = NIF.schema_databases(ro_conn)
    assert db_info.name == "main"
    # Path will be absolute
    assert String.ends_with?(db_info.file, ".db")

    # More robustly find the specific table
    assert {:ok, [object_info | _]} =
             NIF.schema_list_objects(ro_conn, "main")
             |> then(fn {:ok, objects} ->
               filtered = Enum.filter(objects, &(&1.name == @test_table_name))
               {:ok, filtered}
             end)

    assert object_info.name == @test_table_name and object_info.object_type == :table

    assert {:ok, columns} = NIF.schema_columns(ro_conn, @test_table_name)
    # id, data
    assert Enum.count(columns) == 2
  end

  # --- Write Operations on Read-Only DB (Expect :read_only_database error) ---

  @tag :expect_read_only_error
  test "execute/3 (INSERT) fails with :read_only_database", %{conn: ro_conn} do
    sql = "INSERT INTO #{@test_table_name} (id, data) VALUES (2, 'new data');"
    # Corrected assertion
    assert {:error, {:read_only_database, _msg}} = NIF.execute(ro_conn, sql, [])
  end

  @tag :expect_read_only_error
  test "execute/3 (UPDATE) fails with :read_only_database", %{conn: ro_conn} do
    sql = "UPDATE #{@test_table_name} SET data = 'updated' WHERE id = 1;"
    # Corrected assertion
    assert {:error, {:read_only_database, _msg}} = NIF.execute(ro_conn, sql, [])
  end

  @tag :expect_read_only_error
  test "execute/3 (DELETE) fails with :read_only_database", %{conn: ro_conn} do
    sql = "DELETE FROM #{@test_table_name} WHERE id = 1;"
    # Corrected assertion
    assert {:error, {:read_only_database, _msg}} = NIF.execute(ro_conn, sql, [])
  end

  @tag :expect_read_only_error
  test "execute/3 (CREATE TABLE) fails with :read_only_database", %{conn: ro_conn} do
    sql = "CREATE TABLE new_ro_table (id INTEGER);"
    # Corrected assertion
    assert {:error, {:read_only_database, _msg}} = NIF.execute(ro_conn, sql, [])
  end

  @tag :expect_read_only_error
  test "execute_batch/2 with write statements fails with :read_only_database", %{conn: ro_conn} do
    sql_batch = "INSERT INTO #{@test_table_name} (id, data) VALUES (3, 'batch data');"
    # Corrected assertion
    assert {:error, {:read_only_database, _msg}} = NIF.execute_batch(ro_conn, sql_batch)
  end

  # Removed set_pragma test for user_version as it's not a reliable RO error trigger here

  @tag :expect_read_only_error
  test "begin/1 followed by write attempt fails with :read_only_database", %{conn: ro_conn} do
    # BEGIN DEFERRED might succeed as it does nothing until the first write.
    # The crucial part is that the write operation itself fails.
    case NIF.begin(ro_conn) do
      :ok ->
        write_attempt_result =
          NIF.execute(
            ro_conn,
            "UPDATE #{@test_table_name} SET data = 'ro_tx_update' WHERE id=1;",
            []
          )

        # Corrected assertion
        assert {:error, {:read_only_database, _msg}} = write_attempt_result
        # Clean up the transaction state
        assert :ok = NIF.rollback(ro_conn)

      # Some SQLite versions/configurations might make BEGIN itself fail on a mode=ro DB
      # if it tries to acquire even a read lock that implies eventual write capability.
      {:error, {:read_only_database, _msg}} ->
        # This is also an acceptable outcome for BEGIN on a strictly read-only DB.
        :ok

      other_error ->
        # If begin succeeded, we must roll back if an assertion below fails.
        # However, if begin itself returned an unexpected error, flunk directly.
        # Attempt rollback just in case
        NIF.rollback(ro_conn)
        flunk("begin/1 returned unexpected result on read-only DB: #{inspect(other_error)}")
    end
  end

  @tag :read_only_commit_behavior
  test "commit/1 on a read-only database after begin (with no writes) succeeds as no-op", %{
    conn: ro_conn
  } do
    # Deferred transaction starts
    assert :ok = NIF.begin(ro_conn)

    # On a read-only DB with mode=ro, a COMMIT with no preceding write operations
    # is a no-op and should succeed.
    # Expect success for vacuous commit
    assert :ok = NIF.commit(ro_conn)

    # Verify connection is no longer in a transaction (is_autocommit would be true)
    # We can test this by trying to start another transaction. If it succeeds,
    # the previous one was properly closed.
    assert :ok = NIF.begin(ro_conn)
    # Clean up the new transaction
    assert :ok = NIF.rollback(ro_conn)
  end
end
