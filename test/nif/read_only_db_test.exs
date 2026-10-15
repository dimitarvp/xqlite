defmodule Xqlite.NIF.ReadOnlyDbTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [tmp_db_path: 1]

  alias XqliteNIF, as: NIF

  @test_table_name "ro_test_table"
  @create_table_sql "CREATE TABLE #{@test_table_name} (id INTEGER PRIMARY KEY, data TEXT);"
  @insert_sql "INSERT INTO #{@test_table_name} (id, data) VALUES (1, 'sample data');"

  @readonly_openers [
    {:uri_mode_ro, "URI mode=ro", :open_readonly_via_uri},
    {:open_readonly_nif, "open_readonly/1 NIF", :open_readonly_via_nif}
  ]

  defp create_temp_db_file do
    temp_db_path = tmp_db_path("read_only")

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

        on_exit(fn -> NIF.close(ro_conn) end)

        {:ok, conn: ro_conn, db_path: db_path}
      end

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

      test "INSERT fails with :read_only_database, carrying the extended code", %{
        conn: ro_conn
      } do
        sql = "INSERT INTO #{@test_table_name} (id, data) VALUES (2, 'new');"
        # The SQLite extended result code is surfaced; its low byte is the
        # primary SQLITE_READONLY (8), which discriminates the sub-reason
        # (READONLY_RECOVERY, READONLY_ROLLBACK, …) without parsing message text.
        assert {:error, {:read_only_database, code, msg}} = NIF.execute(ro_conn, sql, [])
        assert is_integer(code)
        assert Bitwise.band(code, 0xFF) == 8
        assert is_binary(msg)
      end

      test "UPDATE fails with :read_only_database", %{conn: ro_conn} do
        sql = "UPDATE #{@test_table_name} SET data = 'updated' WHERE id = 1;"
        assert {:error, {:read_only_database, _, _}} = NIF.execute(ro_conn, sql, [])
      end

      test "DELETE fails with :read_only_database", %{conn: ro_conn} do
        sql = "DELETE FROM #{@test_table_name} WHERE id = 1;"
        assert {:error, {:read_only_database, _, _}} = NIF.execute(ro_conn, sql, [])
      end

      test "CREATE TABLE fails with :read_only_database", %{conn: ro_conn} do
        sql = "CREATE TABLE new_ro_table (id INTEGER);"
        assert {:error, {:read_only_database, _, _}} = NIF.execute(ro_conn, sql, [])
      end

      test "execute_batch with writes fails with :read_only_database", %{conn: ro_conn} do
        sql = "INSERT INTO #{@test_table_name} (id, data) VALUES (3, 'batch');"
        assert {:error, {:read_only_database, _, _}} = NIF.execute_batch(ro_conn, sql)
      end

      test "begin + write fails with :read_only_database", %{conn: ro_conn} do
        case NIF.begin(ro_conn) do
          :ok ->
            sql = "UPDATE #{@test_table_name} SET data = 'tx_update' WHERE id = 1;"
            assert {:error, {:read_only_database, _, _}} = NIF.execute(ro_conn, sql, [])
            :ok = NIF.rollback(ro_conn)

          {:error, {:read_only_database, _, _}} ->
            :ok
        end
      end

      test "commit after begin with no writes succeeds", %{conn: ro_conn} do
        assert :ok = NIF.begin(ro_conn)
        assert :ok = NIF.commit(ro_conn)
        assert :ok = NIF.begin(ro_conn)
        assert :ok = NIF.rollback(ro_conn)
      end
    end
  end

  test "open_readonly on nonexistent file fails" do
    assert {:error, {:cannot_open_database, _, _, _}} =
             NIF.open_readonly("/tmp/nonexistent_readonly_test.db")
  end

  test "open_readonly does not create the file" do
    path = tmp_db_path("should_not_exist")

    NIF.open_readonly(path)
    refute File.exists?(path)
  end

  test "open_in_memory_readonly returns a working read-only connection" do
    {:ok, ro_conn} = NIF.open_in_memory_readonly(":memory:")
    assert {:ok, _} = NIF.get_pragma(ro_conn, "encoding")

    assert {:error, {:read_only_database, _, _}} =
             NIF.execute(ro_conn, "CREATE TABLE t (id INTEGER);", [])

    NIF.close(ro_conn)
  end

  test "a read-only connection on a shared cache opened read-write writes nothing" do
    uri = "file:ro_shared_#{System.unique_integer([:positive])}?cache=shared"
    {:ok, rw} = NIF.open_in_memory(uri)
    :ok = NIF.execute_batch(rw, "CREATE TABLE s (id); INSERT INTO s VALUES (1), (2), (3);")
    {:ok, ro} = Xqlite.open_in_memory_readonly(uri)

    dml = ["INSERT INTO s VALUES (4)", "UPDATE s SET id = 9", "DELETE FROM s"]

    for sql <- dml ++ ["CREATE TABLE u (x)", "DROP TABLE s", "PRAGMA user_version = 99"] do
      assert {:error, {:read_only_database, 8, _}} = NIF.execute(ro, sql, [])
    end

    source = tmp_db_path("ro_restore")
    File.write!(source, "")
    assert {:error, {:cannot_restore, :read_only_connection}} = NIF.restore(ro, "main", source)
    assert {:ok, %{rows: [[1], [2], [3]]}} = NIF.query(rw, "SELECT id FROM s ORDER BY id", [])
    Enum.each([ro, rw], &NIF.close/1)
  end

  test "a mode=memory URI opens read-only on both openers" do
    for open <- [&Xqlite.open_readonly/1, &Xqlite.open_in_memory_readonly/1] do
      {:ok, conn} = open.("file:ro_mode_#{System.unique_integer([:positive])}?mode=memory")
      assert {:error, {:read_only_database, 8, _}} = NIF.execute(conn, "CREATE TABLE t(x)", [])
      NIF.close(conn)
    end
  end

  test "a private read-only connection keeps its TEMP tables" do
    file = fn -> Xqlite.open_readonly(create_temp_db_file()) end

    for open <- [file, &Xqlite.open_in_memory_readonly/0] do
      {:ok, conn} = open.()
      assert {:ok, 0} = NIF.execute(conn, "CREATE TEMP TABLE scratch (x)", [])
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO scratch VALUES (1)", [])
      NIF.close(conn)
    end
  end

  test "query_only on a shared cache stops neither PRAGMA query_only = 0 nor a journal-mode change" do
    db = "file:#{tmp_db_path("ro_query_only")}?cache=shared"
    {:ok, rw} = NIF.open(db)
    :ok = NIF.execute_batch(rw, "PRAGMA journal_mode = wal; CREATE TABLE s (id);")
    {:ok, ro} = Xqlite.open_readonly(db)
    assert {:ok, %{rows: [[1]]}} = NIF.query(ro, "PRAGMA query_only", [])
    pragmas = ["PRAGMA journal_mode = delete", "PRAGMA query_only = 0"]
    :ok = Xqlite.set_authorizer(ro, [:pragma])
    refused = Enum.map(pragmas, &NIF.execute(ro, &1, []))
    assert Enum.all?(refused, &match?({:error, {:authorization_denied, 23, _}}, &1))
    :ok = Xqlite.remove_authorizer(ro)
    assert {:ok, %{rows: [["delete"]]}} = NIF.query(ro, "PRAGMA journal_mode = delete", [])
    assert {:ok, %{rows: [["delete"]]}} = NIF.query(rw, "PRAGMA journal_mode", [])
    assert {:ok, 0} = NIF.execute(ro, "PRAGMA query_only = 0", [])
    assert {:ok, 1} = NIF.execute(ro, "INSERT INTO s VALUES (1)", [])
    assert {:ok, %{rows: [[1]]}} = NIF.query(rw, "SELECT id FROM s", [])
    Enum.each([ro, rw], &NIF.close/1)
  end

  test "a read-only open meets a writer's uncommitted schema change with 262" do
    db = "file:ro_locked_#{System.unique_integer([:positive])}?cache=shared"
    {:ok, rw} = NIF.open_in_memory(db)
    :ok = NIF.execute_batch(rw, "CREATE TABLE s (id); BEGIN; CREATE TABLE z (x);")
    assert {:error, {:cannot_open_database, ^db, 262, _}} = Xqlite.open_in_memory_readonly(db)
    :ok = NIF.execute_batch(rw, "COMMIT;")
    assert {:ok, ro} = Xqlite.open_in_memory_readonly(db)
    Enum.each([ro, rw], &NIF.close/1)
  end

  test "ATTACH and VACUUM INTO reach files as the known-limitations guide says" do
    [file, none, made, kept, shared, rwc, plain] = Enum.map(1..7, &tmp_db_path("reach_#{&1}"))
    {:ok, mem} = Xqlite.open_in_memory_readonly()
    :ok = NIF.execute_batch(mem, "ATTACH 'file:#{file}?mode=rwc' AS x; CREATE TABLE x.t (a);")
    :ok = NIF.execute_batch(mem, "DETACH x; ATTACH 'file:#{file}?mode=rw' AS y;")
    assert {:ok, 1} = NIF.execute(mem, "INSERT INTO y.t VALUES (7)", [])
    :ok = NIF.execute_batch(mem, "VACUUM INTO '#{none}'; VACUUM INTO 'file:#{made}?mode=rwc';")
    {:ok, ro} = Xqlite.open_readonly(file)
    :ok = Xqlite.set_authorizer(ro, [:pragma])
    assert {:ok, 0} = NIF.execute(ro, "VACUUM INTO '#{kept}'", [])
    :ok = Xqlite.set_authorizer(ro, [:attach])
    denied = NIF.execute_batch(ro, "VACUUM INTO '#{none}'")
    assert {:error, {:authorization_denied, 23, _}} = denied
    {:ok, rw} = NIF.open("file:#{shared}?cache=shared")
    :ok = NIF.execute_batch(rw, "CREATE TABLE s (id);")
    {:ok, joined} = Xqlite.open("file:#{shared}?mode=ro&cache=shared")
    assert {:ok, 1} = NIF.execute(joined, "INSERT INTO s VALUES (1)", [])
    {:ok, named} = NIF.open_in_memory("reach_#{System.unique_integer([:positive])}")
    :ok = NIF.execute_batch(named, "ATTACH '#{none}' AS a; CREATE TABLE a.t (x);")
    :ok = NIF.execute_batch(named, "ATTACH 'file:#{rwc}?mode=rwc' AS b; CREATE TABLE b.t (x);")
    {:ok, rw_memory} = Xqlite.open_in_memory()
    :ok = NIF.execute_batch(rw_memory, "ATTACH '#{plain}' AS a; CREATE TABLE a.t (x);")
    exists = Enum.map([none, made, kept, rwc, plain], &File.exists?/1)
    assert exists == [false, true, true, true, true]
    Enum.each([mem, ro, rw, joined, named, rw_memory], &NIF.close/1)
  end
end
