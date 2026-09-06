defmodule Xqlite.NIF.ConnectionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias Xqlite.Schema
  alias XqliteNIF, as: NIF

  @shared_mem_db_uri "file:shared_mem_conn_test_specific?mode=memory&cache=shared"
  @invalid_db_path "file:./non_existent_dir_for_sure/read_only_db?mode=ro"

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "connection is usable (set/get pragma)", %{conn: conn} do
        assert {:ok, _} = NIF.set_pragma(conn, "cache_size", 4000)
        assert {:ok, 4000} = NIF.get_pragma(conn, "cache_size")
      end

      test "close is idempotent", %{conn: conn} do
        assert :ok = NIF.close(conn)
        assert :ok = NIF.close(conn)
        assert :ok = NIF.close(conn)
      end

      test "Xqlite.close/1 wrapper is idempotent and blocks further ops", %{conn: conn} do
        assert :ok = Xqlite.close(conn)
        assert :ok = Xqlite.close(conn)
        assert {:error, :connection_closed} = NIF.query(conn, "SELECT 1;", [])
      end

      test "db_path returns nil (no backing file)", %{conn: conn} do
        assert {:ok, nil} = NIF.db_path(conn)
      end

      test "basic query execution works", %{conn: conn} do
        assert {:ok, %{columns: ["1"], rows: [[1]], num_rows: 1}} =
                 NIF.query(conn, "SELECT 1;", [])
      end

      test "basic statement execution works", %{conn: conn} do
        assert {:ok, 0} =
                 NIF.execute(
                   conn,
                   "CREATE TABLE conn_test_basic (id INTEGER PRIMARY KEY);",
                   []
                 )
      end

      test "compile_options returns known flags", %{conn: conn} do
        assert {:ok, options} = NIF.compile_options(conn)

        assert "ENABLE_API_ARMOR" in options
        assert "ENABLE_FTS5" in options
        assert "ENABLE_RTREE" in options
        assert "ENABLE_LOAD_EXTENSION" in options
        assert Enum.any?(options, &String.starts_with?(&1, "THREADSAFE"))
      end
    end
  end

  describe "sqlite_version/0" do
    test "returns three dot-separated integer components starting at major 3" do
      assert {:ok, version} = NIF.sqlite_version()
      assert is_binary(version)

      parsed = version |> String.split(".") |> Enum.map(&Integer.parse/1)
      assert [{3, ""}, {minor, ""}, {patch, ""} | _] = parsed
      assert is_integer(minor) and minor >= 0
      assert is_integer(patch) and patch >= 0
    end
  end

  describe "using a closed connection" do
    test "query returns connection_closed", %{} do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      :ok = NIF.close(conn)
      assert {:error, :connection_closed} = NIF.query(conn, "SELECT 1;", [])
    end

    test "execute returns connection_closed", %{} do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      :ok = NIF.close(conn)
      assert {:error, :connection_closed} = NIF.execute(conn, "SELECT 1;", [])
    end

    test "get_pragma returns connection_closed", %{} do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      :ok = NIF.close(conn)
      assert {:error, :connection_closed} = NIF.get_pragma(conn, "cache_size")
    end
  end

  describe "concurrent access" do
    test "multiple tasks inserting through the same connection handle" do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(conn) end)

      {:ok, 0} =
        NIF.execute(conn, "CREATE TABLE conc (id INTEGER PRIMARY KEY, val INTEGER)", [])

      n = 50

      tasks =
        Enum.map(1..n, fn i ->
          Task.async(fn ->
            NIF.execute(conn, "INSERT INTO conc (id, val) VALUES (?1, ?2)", [i, i * 10])
          end)
        end)

      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, &match?({:ok, 1}, &1))

      assert {:ok, %{num_rows: ^n}} = NIF.query(conn, "SELECT * FROM conc", [])
    end

    test "concurrent operations during close get success or connection_closed" do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(conn) end)

      tasks =
        Enum.map(1..20, fn _ ->
          Task.async(fn -> NIF.query(conn, "SELECT 1;", []) end)
        end)

      :ok = NIF.close(conn)

      results = Task.await_many(tasks, 5_000)

      Enum.each(results, fn result ->
        assert match?({:ok, _}, result) or match?({:error, :connection_closed}, result)
      end)
    end
  end

  describe "temporary file DB" do
    setup do
      assert {:ok, conn} = NIF.open_temporary()
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    @tag :file_temp
    test "schema_databases shows empty file path", %{conn: conn} do
      assert {:ok, [%Schema.DatabaseInfo{name: "main", file: ""}]} =
               NIF.schema_databases(conn)
    end
  end

  describe "db_path on a file-backed DB" do
    test "returns the file's path and errors after close" do
      path = Xqlite.TestUtil.tmp_db_path("db_path")
      assert {:ok, conn} = NIF.open(path)

      assert {:ok, db_path} = NIF.db_path(conn)
      assert is_binary(db_path)
      assert String.ends_with?(db_path, Path.basename(path))

      assert :ok = NIF.close(conn)
      assert {:error, :connection_closed} = NIF.db_path(conn)
    end
  end

  describe "Xqlite.open_readonly/1 and open_temporary/0 wrappers" do
    test "open_readonly opens an existing file read-only" do
      path = Xqlite.TestUtil.tmp_db_path("ro_wrap")
      assert {:ok, rw} = NIF.open(path)
      assert {:ok, 0} = NIF.execute(rw, "CREATE TABLE t (id INTEGER PRIMARY KEY)", [])
      assert :ok = Xqlite.close(rw)

      assert {:ok, ro} = Xqlite.open_readonly(path)
      assert {:ok, %{num_rows: 0}} = NIF.query(ro, "SELECT * FROM t", [])

      assert {:error, {:read_only_database, _, _}} =
               NIF.execute(ro, "INSERT INTO t VALUES (1)", [])

      assert :ok = Xqlite.close(ro)
    end

    test "open_temporary yields a pathless usable connection" do
      assert {:ok, conn} = Xqlite.open_temporary()
      assert {:ok, nil} = NIF.db_path(conn)
      assert {:ok, 0} = NIF.execute(conn, "CREATE TABLE t (id INTEGER)", [])
      assert :ok = Xqlite.close(conn)
    end
  end

  describe "WAL cleanup on close" do
    test "the -wal sidecar is checkpointed and removed by the last close" do
      path = Xqlite.TestUtil.tmp_db_path("wal_close")
      assert {:ok, conn} = NIF.open(path)
      assert {:ok, _} = NIF.set_pragma(conn, "journal_mode", "WAL")
      assert {:ok, 0} = NIF.execute(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY)", [])
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (1)", [])
      assert File.exists?(path <> "-wal")

      assert :ok = Xqlite.close(conn)

      refute File.exists?(path <> "-wal")
      assert File.exists?(path)
    end
  end

  describe "close with live child handles" do
    property "close finalizes every child of the connection and frees the handle" do
      path = Xqlite.TestUtil.tmp_db_path("close_children_law")

      check all(
              statements <- StreamData.list_of(statement_state(), max_length: 4),
              streams <- StreamData.list_of(stream_state(), max_length: 2),
              blobs <- StreamData.list_of(blob_state(), max_length: 2),
              max_runs: 2000
            ) do
        # One path, one database per run: a run that leaked would otherwise
        # keep the file open and fail the runs after it instead of itself.
        for ext <- ["", "-wal", "-shm"], do: File.rm(path <> ext)
        conn = open_wal_db(path)

        children =
          Enum.map(statements, &open_statement(conn, &1)) ++
            Enum.map(streams, &open_stream(conn, &1)) ++
            Enum.map(blobs, &open_blob(conn, &1))

        assert :ok = NIF.close(conn)
        refute File.exists?(path <> "-wal")

        Enum.each(children, &assert_child_after_close/1)

        assert :ok = NIF.close(conn)
        assert {:error, :connection_closed} = NIF.query(conn, "SELECT 1", [])
      end
    end

    test "an unstepped prepared statement does not keep the handle open" do
      assert_close_frees(fn conn -> [open_statement(conn, :unstepped)] end)
    end

    test "a stepped prepared statement does not keep the handle open" do
      assert_close_frees(fn conn -> [open_statement(conn, :stepped)] end)
    end

    test "an undrained stream does not keep the handle open" do
      assert_close_frees(fn conn -> [open_stream(conn, :undrained)] end)
    end

    test "an open incremental blob does not keep the handle open" do
      assert_close_frees(fn conn -> [open_blob(conn, :open)] end)
    end

    test "a statement, a stream and a blob together do not keep the handle open" do
      assert_close_frees(fn conn ->
        [
          open_statement(conn, :stepped),
          open_stream(conn, :undrained),
          open_blob(conn, :open)
        ]
      end)
    end

    test "the statements an FTS5 table owns do not keep the handle open" do
      path = Xqlite.TestUtil.tmp_db_path("close_children_fts5")
      conn = open_wal_db(path)

      assert :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE docs USING fts5(body);")
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO docs (body) VALUES ('hello')", [])

      assert {:ok, %{num_rows: 1}} =
               NIF.query(conn, "SELECT body FROM docs WHERE docs MATCH 'hello'", [])

      children = [open_statement(conn, :stepped)]

      assert :ok = NIF.close(conn)
      refute File.exists?(path <> "-wal")

      Enum.each(children, &assert_child_after_close/1)
    end
  end

  describe "shared memory DB" do
    setup do
      assert {:ok, conn1} = NIF.open(@shared_mem_db_uri)
      assert {:ok, conn2} = NIF.open(@shared_mem_db_uri)

      on_exit(fn ->
        NIF.close(conn1)
        NIF.close(conn2)
      end)

      {:ok, conn1: conn1, conn2: conn2}
    end

    test "handles reference the same underlying shared DB", %{conn1: conn1, conn2: conn2} do
      refute conn1 == conn2
      assert {:ok, _} = NIF.set_pragma(conn1, "cache_size", 5000)
      assert {:ok, 5000} = NIF.get_pragma(conn2, "cache_size")
    end
  end

  describe "open failure" do
    test "open/1 fails for an invalid path" do
      assert {:error, {:cannot_open_database, @invalid_db_path, _code, _reason}} =
               NIF.open(@invalid_db_path)
    end

    test "open_in_memory/1 fails for an invalid URI schema" do
      assert {:error, {:cannot_open_database, "http://invalid", _code, _reason}} =
               NIF.open_in_memory("http://invalid")
    end
  end

  # A WAL database keeps its -wal sidecar for exactly as long as a connection
  # holds the database open, and SQLite deletes it when the last connection
  # really closes. That makes the file the portable oracle for "the SQLite
  # handle was freed", which is what these helpers assert around close/1.
  defp open_wal_db(path) do
    assert {:ok, conn} = NIF.open(path)
    assert {:ok, _} = NIF.set_pragma(conn, "journal_mode", "WAL")
    assert :ok = NIF.execute_batch(conn, "PRAGMA synchronous=OFF;")

    assert :ok =
             NIF.execute_batch(
               conn,
               "CREATE TABLE IF NOT EXISTS kids (id INTEGER PRIMARY KEY, data BLOB);"
             )

    assert {:ok, 1} =
             NIF.execute(conn, "INSERT OR REPLACE INTO kids VALUES (1, zeroblob(16))", [])

    assert File.exists?(path <> "-wal")
    conn
  end

  defp assert_close_frees(build) do
    path = Xqlite.TestUtil.tmp_db_path("close_children")
    conn = open_wal_db(path)
    children = build.(conn)

    assert :ok = NIF.close(conn)
    refute File.exists?(path <> "-wal")

    Enum.each(children, &assert_child_after_close/1)

    assert :ok = NIF.close(conn)
    assert {:error, :connection_closed} = NIF.query(conn, "SELECT 1", [])
  end

  defp statement_state, do: StreamData.member_of([:unstepped, :stepped, :finalized])
  defp stream_state, do: StreamData.member_of([:undrained, :drained, :closed])
  defp blob_state, do: StreamData.member_of([:open, :closed])

  defp open_statement(conn, state) do
    assert {:ok, stmt} = NIF.stmt_prepare(conn, "SELECT id FROM kids")
    apply_statement_state(stmt, state)
    {:statement, stmt}
  end

  defp apply_statement_state(_stmt, :unstepped), do: :ok
  defp apply_statement_state(stmt, :stepped), do: assert({:row, [1]} = NIF.stmt_step(stmt))
  defp apply_statement_state(stmt, :finalized), do: assert(:ok = NIF.stmt_finalize(stmt))

  defp open_stream(conn, state) do
    assert {:ok, stream} = NIF.stream_open(conn, "SELECT id FROM kids", [], [])
    apply_stream_state(stream, state)
    {:stream, stream}
  end

  defp apply_stream_state(_stream, :undrained), do: :ok

  defp apply_stream_state(stream, :drained) do
    assert {:ok, %{rows: [[1]]}} = NIF.stream_fetch(stream, 10)
    assert :done = NIF.stream_fetch(stream, 10)
  end

  defp apply_stream_state(stream, :closed), do: assert(:ok = NIF.stream_close(stream))

  defp open_blob(conn, state) do
    assert {:ok, blob} = NIF.blob_open(conn, "main", "kids", "data", 1, false)
    apply_blob_state(blob, state)
    {:blob, blob}
  end

  defp apply_blob_state(_blob, :open), do: :ok
  defp apply_blob_state(blob, :closed), do: assert(:ok = NIF.blob_close(blob))

  defp assert_child_after_close({:statement, stmt}) do
    assert {:error, :connection_closed} = NIF.stmt_step(stmt)
    assert :ok = NIF.stmt_finalize(stmt)
  end

  defp assert_child_after_close({:stream, stream}) do
    assert {:error, :connection_closed} = NIF.stream_fetch(stream, 1)
    assert :ok = NIF.stream_close(stream)
  end

  defp assert_child_after_close({:blob, blob}) do
    assert {:error, :connection_closed} = NIF.blob_size(blob)
    assert :ok = NIF.blob_close(blob)
  end
end
