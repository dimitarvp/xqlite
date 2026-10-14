defmodule Xqlite.NIF.BackupTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1, tmp_db_path: 1]

  alias XqliteNIF, as: NIF

  @no_file_sources ["", ":memory:", "file::memory:", "file:x?mode=memory", "file:x?vfs=memdb"]

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "backup using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        backup_path = tmp_db_path("backup")

        on_exit(fn -> NIF.close(conn) end)

        {:ok, conn: conn, backup_path: backup_path}
      end

      # -------------------------------------------------------------------
      # backup — basic
      # -------------------------------------------------------------------

      test "backup empty database to file", %{conn: conn, backup_path: path} do
        assert :ok = NIF.backup(conn, "main", path)
        assert File.exists?(path)
        assert File.stat!(path).size > 0
      end

      test "backup database with table and data", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE bk_data (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, 1} = NIF.execute(conn, "INSERT INTO bk_data VALUES (1, 'hello')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO bk_data VALUES (2, 'world')", [])

        assert :ok = NIF.backup(conn, "main", path)

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

        :ok = NIF.backup(conn, "main", path)

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

        :ok = NIF.backup(conn, "main", path)

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

        :ok = NIF.backup(conn, "main", path)

        {:ok, verify_conn} = NIF.open_readonly(path)

        assert {:ok, %{rows: [[fk_table, fk_to]]}} =
                 NIF.query(
                   verify_conn,
                   ~s{SELECT "table", "to" FROM pragma_foreign_key_list('bk_child')},
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

        :ok = NIF.backup(conn, "main", path)

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
        :ok = NIF.backup(conn, "main", path)

        :ok = NIF.execute_batch(conn, "CREATE TABLE bk_over2 (id INTEGER);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO bk_over2 VALUES (2)", [])
        :ok = NIF.backup(conn, "main", path)

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

        :ok = NIF.backup(conn, "main", path)

        {:ok, verify_conn} = NIF.open_readonly(path)

        assert {:ok, %{rows: [[1000]]}} =
                 NIF.query(verify_conn, "SELECT COUNT(*) FROM bk_large", [])

        NIF.close(verify_conn)
      end

      # -------------------------------------------------------------------
      # backup — error cases
      # -------------------------------------------------------------------

      test "backup to invalid path returns error", %{conn: conn} do
        assert {:error, _} = NIF.backup(conn, "main", "/no/such/directory/backup.db")
      end

      test "backup with invalid schema returns error", %{conn: conn, backup_path: path} do
        assert {:error, {:no_such_schema, "nope"}} = NIF.backup(conn, "nope", path)
        refute File.exists?(path)
      end

      # -------------------------------------------------------------------
      # restore — basic
      # -------------------------------------------------------------------

      test "restore from backup file", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE rs_src (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, 1} = NIF.execute(conn, "INSERT INTO rs_src VALUES (1, 'original')", [])
        :ok = NIF.backup(conn, "main", path)

        {:ok, dest_conn} = NIF.open_in_memory(":memory:")
        :ok = NIF.restore(dest_conn, "main", path)

        assert {:ok, %{rows: [[1, "original"]], num_rows: 1}} =
                 NIF.query(dest_conn, "SELECT * FROM rs_src", [])

        NIF.close(dest_conn)
      end

      test "restore replaces existing data", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE rs_rep (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, 1} = NIF.execute(conn, "INSERT INTO rs_rep VALUES (1, 'backup')", [])
        :ok = NIF.backup(conn, "main", path)

        {:ok, dest_conn} = NIF.open_in_memory(":memory:")
        :ok = NIF.execute_batch(dest_conn, "CREATE TABLE rs_old (x INTEGER);")
        {:ok, 1} = NIF.execute(dest_conn, "INSERT INTO rs_old VALUES (99)", [])

        :ok = NIF.restore(dest_conn, "main", path)

        assert {:ok, %{rows: [[1, "backup"]]}} =
                 NIF.query(dest_conn, "SELECT * FROM rs_rep", [])

        assert {:error, _} = NIF.query(dest_conn, "SELECT * FROM rs_old", [])

        NIF.close(dest_conn)
      end

      test "restore with explicit main schema", %{conn: conn, backup_path: path} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE rs_sch (val TEXT);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO rs_sch VALUES ('schema_test')", [])
        :ok = NIF.backup(conn, "main", path)

        {:ok, dest_conn} = NIF.open_in_memory(":memory:")
        :ok = NIF.restore(dest_conn, "main", path)

        assert {:ok, %{rows: [["schema_test"]]}} =
                 NIF.query(dest_conn, "SELECT * FROM rs_sch", [])

        NIF.close(dest_conn)
      end

      # -------------------------------------------------------------------
      # restore — error cases
      # -------------------------------------------------------------------

      test "restore from a path with no database file changes nothing", %{
        conn: conn,
        backup_path: path
      } do
        :ok = NIF.execute_batch(conn, "CREATE TABLE kept (x); INSERT INTO kept VALUES (1)")

        for src <- [path | @no_file_sources] do
          assert {:error, {:cannot_open_database, ^src, _, _}} = NIF.restore(conn, "main", src)
          assert {:ok, %{rows: [[1]]}} = NIF.query(conn, "SELECT x FROM kept", [])
        end

        refute File.exists?(path)
      end

      test "restore from corrupt file returns error", %{conn: conn} do
        corrupt_path = tmp_db_path("corrupt")

        File.write!(corrupt_path, "this is not a sqlite database")

        result = NIF.restore(conn, "main", corrupt_path)

        assert {:error, _} = result
      end

      test "a source with no pages is rejected", %{conn: conn, backup_path: path} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE kept (x); INSERT INTO kept VALUES (1)")
        File.write!(path, "")
        assert {:error, :no_pages} = NIF.restore(conn, "main", path)
        assert {:ok, %{rows: [[1]]}} = NIF.query(conn, "SELECT x FROM kept", [])
        :ok = NIF.backup(conn, "temp", path)
        assert :ok = NIF.restore(conn, "main", path)
        assert {:ok, %{rows: []}} = NIF.query(conn, "SELECT name FROM sqlite_schema", [])
      end

      test "a blocked restore answers what a blocked backup answers", %{backup_path: path} do
        own_path = tmp_db_path("own")
        {:ok, own} = Xqlite.open(own_path, journal_mode: :delete, busy_timeout: 0)
        :ok = NIF.backup(own, "main", path)
        {:ok, holder} = NIF.open(own_path)
        :ok = NIF.execute_batch(holder, "BEGIN EXCLUSIVE")
        blocked = NIF.backup(own, "main", tmp_db_path("blocked"))
        {micros, answer} = :timer.tc(fn -> NIF.restore(own, "main", path) end)
        assert {:error, {:database_busy_or_locked, 5, _}} = answer
        assert answer == blocked
        assert micros < 150_000
        Enum.each([holder, own], &NIF.close/1)
      end

      test "the files the library opens wait for no lock", %{conn: conn, backup_path: path} do
        {:ok, holder} = NIF.open(path)
        :ok = NIF.execute_batch(holder, "CREATE TABLE h (x); BEGIN EXCLUSIVE")
        progress = &NIF.backup_with_progress(conn, "main", &1, self(), 1, [])
        restore = &NIF.restore(conn, "main", &1)

        for call <- [&NIF.backup(conn, "main", &1), progress, restore] do
          {micros, answer} = :timer.tc(call, [path])
          assert {:error, {:database_busy_or_locked, 5, _}} = answer
          assert micros < 2_000_000
        end

        NIF.close(holder)
      end

      test "a destination SQLite gives no file for is rejected", %{conn: conn} do
        for dest <- @no_file_sources do
          assert {:error, {:cannot_open_database, ^dest, 14, _}} =
                   NIF.backup(conn, "main", dest)

          assert {:error, {:cannot_open_database, ^dest, 14, _}} =
                   NIF.backup_with_progress(conn, "main", dest, self(), 1, [])
        end

        refute Enum.any?(@no_file_sources, &File.exists?/1)
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

        :ok = NIF.backup(conn, "main", path)

        {:ok, restored} = NIF.open_in_memory(":memory:")
        :ok = NIF.restore(restored, "main", path)

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
    {:ok, conn} = NIF.open_in_memory(":memory:")
    NIF.close(conn)

    assert {:error, _} = NIF.backup(conn, "main", "/tmp/xqlite_closed_backup.db")
  end

  test "restore on closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    NIF.close(conn)

    assert {:error, _} = NIF.restore(conn, "main", "/tmp/xqlite_nonexistent.db")
  end

  test "backup then restore between two independent connections" do
    {:ok, src} = NIF.open_in_memory(":memory:")
    :ok = NIF.execute_batch(src, "CREATE TABLE xfer (id INTEGER PRIMARY KEY, msg TEXT);")
    {:ok, 1} = NIF.execute(src, "INSERT INTO xfer VALUES (1, 'transferred')", [])

    path = tmp_db_path("xfer")

    :ok = NIF.backup(src, "main", path)
    NIF.close(src)

    {:ok, dst} = NIF.open_in_memory(":memory:")
    :ok = NIF.restore(dst, "main", path)

    assert {:ok, %{rows: [[1, "transferred"]], num_rows: 1}} =
             NIF.query(dst, "SELECT * FROM xfer", [])

    NIF.close(dst)
  end

  for journal <- [:wal, :delete] do
    test "a copy in one step ends while another connection writes, #{journal} journal" do
      path = tmp_db_path("one_step")
      {src, cells, ref} = source_with_writer(path, unquote(journal))
      [dest, dest2] = [tmp_db_path("one_step_dest"), tmp_db_path("one_step_dest")]
      assert :ok = Xqlite.backup(src, dest)
      assert_copied(cells, dest)
      assert :ok = Xqlite.backup_with_progress(src, dest2, self(), pages_per_step: 2 ** 31 - 1)
      assert_copied(cells, dest2)
      assert_received {:xqlite_backup_progress, %{status: :copied, remaining: 0}}
      refute_received {:xqlite_backup_progress, _}
      if unquote(journal) == :wal, do: assert_restored(path, cells)
      :atomics.put(cells, 2, 1)
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}, 60_000
      :ok = Xqlite.close(src)
    end
  end

  defp assert_restored(path, cells) do
    {:ok, conn} = Xqlite.open_in_memory()
    assert :ok = Xqlite.restore(conn, path)
    assert_copied(cells, conn)
  end

  defp source_with_writer(path, journal) do
    {:ok, src} = Xqlite.open(path, journal_mode: journal, busy_timeout: 60_000)

    :ok =
      NIF.execute_batch(src, """
      CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);
      WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
      INSERT INTO t SELECT i, hex(randomblob(1800)) FROM c;
      """)

    cells = :atomics.new(2, [])
    test_pid = self()

    {_pid, ref} =
      spawn_monitor(fn ->
        {:ok, writer} = Xqlite.open(path, journal_mode: journal, busy_timeout: 60_000)
        commit_until_stopped(writer, cells, test_pid)
      end)

    assert_receive :first_commit, 60_000
    {src, cells, ref}
  end

  # The liveness bound is a count of commits, not a clock: 50_000 is far past
  # what a copy in one step lets through.
  defp commit_until_stopped(writer, cells, test_pid) do
    # Counted before the insert: another connection can see the row before execute returns.
    commits = :atomics.add_get(cells, 1, 1)
    {:ok, 1} = NIF.execute(writer, "INSERT INTO t (v) VALUES ('w')", [])
    if commits == 1, do: send(test_pid, :first_commit)

    case :atomics.get(cells, 2) == 0 and commits < 50_000 do
      true -> commit_until_stopped(writer, cells, test_pid)
      false -> Xqlite.close(writer)
    end
  end

  defp assert_copied(cells, dest) when is_binary(dest) do
    {:ok, copy} = NIF.open(dest)
    assert_copied(cells, copy)
    :ok = NIF.close(copy)
  end

  defp assert_copied(cells, copy) do
    commits = :atomics.get(cells, 1)
    assert commits < 50_000
    assert {:ok, %{rows: [["ok"]]}} = NIF.query(copy, "PRAGMA integrity_check", [])
    assert {:ok, %{rows: [[rows]]}} = NIF.query(copy, "SELECT count(*) FROM t", [])
    assert rows in 3000..(3000 + commits)
  end
end
