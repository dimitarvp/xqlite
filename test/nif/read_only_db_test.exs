defmodule Xqlite.NIF.ReadOnlyDbTest do
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF

  @test_table_name "ro_test_table"
  @create_table_sql "CREATE TABLE #{@test_table_name} (id INTEGER PRIMARY KEY, data TEXT);"
  @insert_sql "INSERT INTO #{@test_table_name} (id, data) VALUES (1, 'sample data');"

  @readonly_openers [
    {:uri_mode_ro, "URI mode=ro", :open_readonly_via_uri},
    {:open_readonly_nif, "open_readonly/1 NIF", :open_readonly_via_nif}
  ]

  defp create_temp_db_file() do
    temp_db_path =
      Path.join(
        System.tmp_dir!(),
        "read_only_test_" <>
          Integer.to_string(:erlang.unique_integer([:positive])) <> ".db"
      )

    File.rm(temp_db_path)
    {:ok, conn_rw} = NIF.open(temp_db_path)
    {:ok, 0} = NIF.execute(conn_rw, @create_table_sql, [])
    {:ok, 1} = NIF.execute(conn_rw, @insert_sql, [])
    :ok = NIF.close(conn_rw)
    temp_db_path
  end

  defp open_readonly_via_uri(db_path) do
    NIF.open("file:#{db_path}?mode=ro")
  end

  defp open_readonly_via_nif(db_path) do
    NIF.open_readonly(db_path)
  end

  for {tag, description, opener_fun} <- @readonly_openers do
    describe "#{description}" do
      @describetag tag

      setup do
        db_path = create_temp_db_file()
        {:ok, ro_conn} = unquote(opener_fun)(db_path)

        on_exit(fn ->
          NIF.close(ro_conn)
          File.rm(db_path)
        end)

        {:ok, conn: ro_conn, db_path: db_path}
      end

      # --- Read Operations ---

      test "SELECT succeeds", %{conn: ro_conn} do
        assert {:ok, %{columns: ["id", "data"], rows: [[1, "sample data"]], num_rows: 1}} =
                 NIF.query(
                   ro_conn,
                   "SELECT id, data FROM #{@test_table_name} WHERE id = 1;",
                   []
                 )
      end

      test "get_pragma succeeds", %{conn: ro_conn} do
        assert {:ok, "UTF-8"} = NIF.get_pragma(ro_conn, "encoding")
      end

      test "schema introspection succeeds", %{conn: ro_conn} do
        assert {:ok, [db_info | _]} = NIF.schema_databases(ro_conn)
        assert db_info.name == "main"

        assert {:ok, objects} = NIF.schema_list_objects(ro_conn, "main")
        assert Enum.any?(objects, &(&1.name == @test_table_name and &1.object_type == :table))

        assert {:ok, columns} = NIF.schema_columns(ro_conn, @test_table_name)
        assert length(columns) == 2
      end

      # --- Write Operations (must fail) ---

      test "INSERT fails with :read_only_database", %{conn: ro_conn} do
        sql = "INSERT INTO #{@test_table_name} (id, data) VALUES (2, 'new');"
        assert {:error, {:read_only_database, _}} = NIF.execute(ro_conn, sql, [])
      end

      test "UPDATE fails with :read_only_database", %{conn: ro_conn} do
        sql = "UPDATE #{@test_table_name} SET data = 'updated' WHERE id = 1;"
        assert {:error, {:read_only_database, _}} = NIF.execute(ro_conn, sql, [])
      end

      test "DELETE fails with :read_only_database", %{conn: ro_conn} do
        sql = "DELETE FROM #{@test_table_name} WHERE id = 1;"
        assert {:error, {:read_only_database, _}} = NIF.execute(ro_conn, sql, [])
      end

      test "CREATE TABLE fails with :read_only_database", %{conn: ro_conn} do
        sql = "CREATE TABLE new_ro_table (id INTEGER);"
        assert {:error, {:read_only_database, _}} = NIF.execute(ro_conn, sql, [])
      end

      test "execute_batch with writes fails with :read_only_database", %{conn: ro_conn} do
        sql = "INSERT INTO #{@test_table_name} (id, data) VALUES (3, 'batch');"
        assert {:error, {:read_only_database, _}} = NIF.execute_batch(ro_conn, sql)
      end

      test "begin + write fails with :read_only_database", %{conn: ro_conn} do
        case NIF.begin(ro_conn) do
          :ok ->
            sql = "UPDATE #{@test_table_name} SET data = 'tx_update' WHERE id = 1;"
            assert {:error, {:read_only_database, _}} = NIF.execute(ro_conn, sql, [])
            :ok = NIF.rollback(ro_conn)

          {:error, {:read_only_database, _}} ->
            :ok
        end
      end

      test "commit after begin with no writes succeeds", %{conn: ro_conn} do
        assert :ok = NIF.begin(ro_conn)
        assert :ok = NIF.commit(ro_conn)

        # Verify connection left the transaction
        assert :ok = NIF.begin(ro_conn)
        assert :ok = NIF.rollback(ro_conn)
      end
    end
  end

  # --- open_readonly-specific edge cases ---

  test "open_readonly on nonexistent file fails" do
    assert {:error, {:cannot_open_database, _, _, _}} =
             NIF.open_readonly("/tmp/nonexistent_readonly_test.db")
  end

  test "open_readonly does not create the file" do
    path =
      Path.join(
        System.tmp_dir!(),
        "should_not_exist_#{:erlang.unique_integer([:positive])}.db"
      )

    NIF.open_readonly(path)
    refute File.exists?(path)
  end

  test "open_in_memory_readonly returns a working read-only connection" do
    {:ok, ro_conn} = NIF.open_in_memory_readonly(":memory:")
    # Can read pragmas
    assert {:ok, _} = NIF.get_pragma(ro_conn, "encoding")
    # Cannot create tables
    assert {:error, {:read_only_database, _}} =
             NIF.execute(ro_conn, "CREATE TABLE t (id INTEGER);", [])

    NIF.close(ro_conn)
  end
end
