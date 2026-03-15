defmodule Xqlite.NIF.BackupTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "backup using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        backup_path =
          Path.join(
            System.tmp_dir!(),
            "xqlite_backup_#{:erlang.unique_integer([:positive])}.db"
          )

        on_exit(fn ->
          NIF.close(conn)
          File.rm(backup_path)
        end)

        {:ok, conn: conn, backup_path: backup_path}
      end

      # -------------------------------------------------------------------
      # backup — basic
      # -------------------------------------------------------------------

      test "backup empty database to file", %{conn: conn, backup_path: path} do
        assert :ok = NIF.backup(conn, path)
        assert File.exists?(path)
        assert File.stat!(path).size > 0
      end

      test "backup database with table and data", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE bk_data (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, 1} = NIF.execute(conn, "INSERT INTO bk_data VALUES (1, 'hello')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO bk_data VALUES (2, 'world')", [])

        assert :ok = NIF.backup(conn, path)

        {:ok, verify_conn} = NIF.open_readonly(path)

        assert {:ok, %{rows: [[1, "hello"], [2, "world"]], num_rows: 2}} =
                 NIF.query(verify_conn, "SELECT * FROM bk_data ORDER BY id", [])

        NIF.close(verify_conn)
      end

      test "backup with explicit main schema", %{conn: conn, backup_path: path} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE bk_schema (id INTEGER PRIMARY KEY);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO bk_schema VALUES (1)", [])

        assert :ok = NIF.backup(conn, "main", path)

        {:ok, verify_conn} = NIF.open_readonly(path)

        assert {:ok, %{rows: [[1]], num_rows: 1}} =
                 NIF.query(verify_conn, "SELECT * FROM bk_schema", [])

        NIF.close(verify_conn)
      end

      test "backup preserves multiple tables", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bk_t1 (id INTEGER PRIMARY KEY, a TEXT);
          CREATE TABLE bk_t2 (id INTEGER PRIMARY KEY, b INTEGER);
          INSERT INTO bk_t1 VALUES (1, 'alpha');
          INSERT INTO bk_t2 VALUES (1, 42);
          """)

        :ok = NIF.backup(conn, path)

        {:ok, verify_conn} = NIF.open_readonly(path)

        assert {:ok, %{rows: [[1, "alpha"]]}} =
                 NIF.query(verify_conn, "SELECT * FROM bk_t1", [])

        assert {:ok, %{rows: [[1, 42]]}} =
                 NIF.query(verify_conn, "SELECT * FROM bk_t2", [])

        NIF.close(verify_conn)
      end

      test "backup preserves indexes", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bk_idx (id INTEGER PRIMARY KEY, val TEXT);
          CREATE INDEX bk_idx_val ON bk_idx(val);
          INSERT INTO bk_idx VALUES (1, 'test');
          """)

        :ok = NIF.backup(conn, path)

        {:ok, verify_conn} = NIF.open_readonly(path)

        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   verify_conn,
                   "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'bk_idx'",
                   []
                 )

        assert rows == [["bk_idx_val"]]
        NIF.close(verify_conn)
      end

      test "backup preserves foreign keys", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bk_parent (id INTEGER PRIMARY KEY);
          CREATE TABLE bk_child (id INTEGER PRIMARY KEY, pid INTEGER REFERENCES bk_parent(id));
          INSERT INTO bk_parent VALUES (1);
          INSERT INTO bk_child VALUES (1, 1);
          """)

        :ok = NIF.backup(conn, path)

        {:ok, verify_conn} = NIF.open_readonly(path)

        assert {:ok, %{rows: [[fk_table, fk_to]]}} =
                 NIF.query(
                   verify_conn,
                   "SELECT \"table\", \"to\" FROM pragma_foreign_key_list('bk_child')",
                   []
                 )

        assert fk_table == "bk_parent"
        assert fk_to == "id"
        NIF.close(verify_conn)
      end

      test "backup preserves all SQLite types", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bk_types (
            i INTEGER, r REAL, t TEXT, b BLOB, n INTEGER
          );
          """)

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO bk_types VALUES (?1, ?2, ?3, ?4, ?5)",
            [42, 3.14, "hello", <<0xDE, 0xAD>>, nil]
          )

        :ok = NIF.backup(conn, path)

        {:ok, verify_conn} = NIF.open_readonly(path)

        assert {:ok, %{rows: [[42, pi, "hello", blob, nil]]}} =
                 NIF.query(verify_conn, "SELECT * FROM bk_types", [])

        assert_in_delta pi, 3.14, 0.001
        assert blob == <<0xDE, 0xAD>>
        NIF.close(verify_conn)
      end

      test "backup overwrites existing destination file", %{conn: conn, backup_path: path} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE bk_over1 (id INTEGER);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO bk_over1 VALUES (1)", [])
        :ok = NIF.backup(conn, path)

        :ok = NIF.execute_batch(conn, "CREATE TABLE bk_over2 (id INTEGER);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO bk_over2 VALUES (2)", [])
        :ok = NIF.backup(conn, path)

        {:ok, verify_conn} = NIF.open_readonly(path)

        assert {:ok, %{rows: [[2]]}} =
                 NIF.query(verify_conn, "SELECT * FROM bk_over2", [])

        NIF.close(verify_conn)
      end

      test "backup large database with many rows", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE bk_large (id INTEGER PRIMARY KEY, data TEXT);")

        for i <- 1..1000 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO bk_large VALUES (?1, ?2)", [
              i,
              String.duplicate("x", 100)
            ])
        end

        :ok = NIF.backup(conn, path)

        {:ok, verify_conn} = NIF.open_readonly(path)

        assert {:ok, %{rows: [[1000]]}} =
                 NIF.query(verify_conn, "SELECT COUNT(*) FROM bk_large", [])

        NIF.close(verify_conn)
      end

      # -------------------------------------------------------------------
      # backup — error cases
      # -------------------------------------------------------------------

      test "backup to invalid path returns error", %{conn: conn} do
        assert {:error, _} = NIF.backup(conn, "/no/such/directory/backup.db")
      end

      test "backup with invalid schema returns error", %{conn: conn, backup_path: path} do
        assert {:error, _} = NIF.backup(conn, "nonexistent_schema", path)
      end

      # -------------------------------------------------------------------
      # restore — basic
      # -------------------------------------------------------------------

      test "restore from backup file", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE rs_src (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, 1} = NIF.execute(conn, "INSERT INTO rs_src VALUES (1, 'original')", [])
        :ok = NIF.backup(conn, path)

        {:ok, dest_conn} = NIF.open_in_memory()
        :ok = NIF.restore(dest_conn, path)

        assert {:ok, %{rows: [[1, "original"]], num_rows: 1}} =
                 NIF.query(dest_conn, "SELECT * FROM rs_src", [])

        NIF.close(dest_conn)
      end

      test "restore replaces existing data", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE rs_rep (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, 1} = NIF.execute(conn, "INSERT INTO rs_rep VALUES (1, 'backup')", [])
        :ok = NIF.backup(conn, path)

        {:ok, dest_conn} = NIF.open_in_memory()
        :ok = NIF.execute_batch(dest_conn, "CREATE TABLE rs_old (x INTEGER);")
        {:ok, 1} = NIF.execute(dest_conn, "INSERT INTO rs_old VALUES (99)", [])

        :ok = NIF.restore(dest_conn, path)

        assert {:ok, %{rows: [[1, "backup"]]}} =
                 NIF.query(dest_conn, "SELECT * FROM rs_rep", [])

        assert {:error, _} = NIF.query(dest_conn, "SELECT * FROM rs_old", [])

        NIF.close(dest_conn)
      end

      test "restore with explicit main schema", %{conn: conn, backup_path: path} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE rs_sch (val TEXT);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO rs_sch VALUES ('schema_test')", [])
        :ok = NIF.backup(conn, path)

        {:ok, dest_conn} = NIF.open_in_memory()
        :ok = NIF.restore(dest_conn, "main", path)

        assert {:ok, %{rows: [["schema_test"]]}} =
                 NIF.query(dest_conn, "SELECT * FROM rs_sch", [])

        NIF.close(dest_conn)
      end

      # -------------------------------------------------------------------
      # restore — error cases
      # -------------------------------------------------------------------

      test "restore from nonexistent file returns error", %{conn: conn} do
        assert {:error, _} =
                 NIF.restore(conn, "/no/such/file/backup.db")
      end

      test "restore from corrupt file returns error", %{conn: conn} do
        corrupt_path =
          Path.join(
            System.tmp_dir!(),
            "xqlite_corrupt_#{:erlang.unique_integer([:positive])}.db"
          )

        File.write!(corrupt_path, "this is not a sqlite database")

        result = NIF.restore(conn, corrupt_path)
        File.rm(corrupt_path)

        assert {:error, _} = result
      end

      # -------------------------------------------------------------------
      # round-trip: backup then restore preserves integrity
      # -------------------------------------------------------------------

      test "backup + restore round-trip preserves all data", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE rt_users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER);
          CREATE TABLE rt_orders (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES rt_users(id), amount REAL);
          CREATE INDEX rt_orders_user ON rt_orders(user_id);
          INSERT INTO rt_users VALUES (1, 'alice', 30);
          INSERT INTO rt_users VALUES (2, 'bob', 25);
          INSERT INTO rt_orders VALUES (1, 1, 99.99);
          INSERT INTO rt_orders VALUES (2, 1, 49.50);
          INSERT INTO rt_orders VALUES (3, 2, 150.00);
          """)

        :ok = NIF.backup(conn, path)

        {:ok, restored} = NIF.open_in_memory()
        :ok = NIF.restore(restored, path)

        assert {:ok, %{rows: users}} =
                 NIF.query(restored, "SELECT * FROM rt_users ORDER BY id", [])

        assert users == [[1, "alice", 30], [2, "bob", 25]]

        assert {:ok, %{rows: orders}} =
                 NIF.query(restored, "SELECT * FROM rt_orders ORDER BY id", [])

        assert [[1, 1, amount1], [2, 1, amount2], [3, 2, amount3]] = orders
        assert_in_delta amount1, 99.99, 0.001
        assert_in_delta amount2, 49.50, 0.001
        assert_in_delta amount3, 150.00, 0.001

        assert {:ok, %{rows: idx_rows}} =
                 NIF.query(
                   restored,
                   "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'rt_orders_user'",
                   []
                 )

        assert idx_rows == [["rt_orders_user"]]

        NIF.close(restored)
      end
    end
  end

  # -------------------------------------------------------------------
  # Edge cases outside the connection_openers loop
  # -------------------------------------------------------------------

  test "backup on closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory()
    NIF.close(conn)

    assert {:error, _} = NIF.backup(conn, "/tmp/xqlite_closed_backup.db")
  end

  test "restore on closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory()
    NIF.close(conn)

    assert {:error, _} = NIF.restore(conn, "/tmp/xqlite_nonexistent.db")
  end

  test "backup then restore between two independent connections" do
    {:ok, src} = NIF.open_in_memory()
    :ok = NIF.execute_batch(src, "CREATE TABLE xfer (id INTEGER PRIMARY KEY, msg TEXT);")
    {:ok, 1} = NIF.execute(src, "INSERT INTO xfer VALUES (1, 'transferred')", [])

    path =
      Path.join(
        System.tmp_dir!(),
        "xqlite_xfer_#{:erlang.unique_integer([:positive])}.db"
      )

    :ok = NIF.backup(src, path)
    NIF.close(src)

    {:ok, dst} = NIF.open_in_memory()
    :ok = NIF.restore(dst, path)

    assert {:ok, %{rows: [[1, "transferred"]], num_rows: 1}} =
             NIF.query(dst, "SELECT * FROM xfer", [])

    NIF.close(dst)
    File.rm(path)
  end
end
