defmodule Xqlite.NIF.ConnectionTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF
  alias Xqlite.Schema

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
    test "returns a string matching semver-ish format" do
      assert {:ok, version} = NIF.sqlite_version()
      assert is_binary(version)
      assert Regex.match?(~r/^3\.\d+\.\d+/, version)
    end
  end

  describe "using a closed connection" do
    test "query returns connection_closed", %{} do
      {:ok, conn} = NIF.open_in_memory()
      :ok = NIF.close(conn)
      assert {:error, :connection_closed} = NIF.query(conn, "SELECT 1;", [])
    end

    test "execute returns connection_closed", %{} do
      {:ok, conn} = NIF.open_in_memory()
      :ok = NIF.close(conn)
      assert {:error, :connection_closed} = NIF.execute(conn, "SELECT 1;", [])
    end

    test "get_pragma returns connection_closed", %{} do
      {:ok, conn} = NIF.open_in_memory()
      :ok = NIF.close(conn)
      assert {:error, :connection_closed} = NIF.get_pragma(conn, "cache_size")
    end
  end

  describe "concurrent access" do
    test "multiple tasks inserting through the same connection handle" do
      {:ok, conn} = NIF.open_in_memory()
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
      {:ok, conn} = NIF.open_in_memory()
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
end
