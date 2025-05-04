defmodule Xqlite.NIF.ConnectionTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF
  alias Xqlite.Schema

  # --- Shared test code (generated via `for` loop for different DB types) ---
  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      # Setup uses a single helper to find the appropriate MFA based on context tag
      setup context do
        {mod, fun, args} = find_opener_mfa!(context)

        # Open connection
        assert {:ok, conn} = apply(mod, fun, args),
               "Failed to open connection using #{inspect({mod, fun, args})}"

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # --- Shared test cases applicable to all DB types follow ---
      # These tests inherit the simple atom tag (e.g. :memory_private or :file_temp etc.)

      test "connection is usable (set/get pragma)", %{conn: conn} do
        assert {:ok, true} = NIF.set_pragma(conn, "cache_size", 4000)
        assert {:ok, 4000} = NIF.get_pragma(conn, "cache_size")
      end

      test "close returns true even when called multiple times", %{conn: conn} do
        assert {:ok, true} = NIF.close(conn)

        # Subsequent calls are no-ops on the Rust side but should still return ok via the NIF interface.
        assert {:ok, true} = NIF.close(conn)
        assert {:ok, true} = NIF.close(conn)
      end

      test "basic query execution works", %{conn: conn} do
        assert {:ok, %{columns: ["1"], rows: [[1]], num_rows: 1}} =
                 NIF.query(conn, "SELECT 1;", [])
      end

      test "basic statement execution works", %{conn: conn} do
        sql = "CREATE TABLE conn_test_basic (id INTEGER PRIMARY KEY);"
        assert {:ok, 0} = NIF.execute(conn, sql, [])
      end
    end

    # end describe "Using #{prefix}"
  end

  # end `for` loop that generates a bunch of tests for each DB type

  # --- DB type-specific or other tests (outside the `for` loop) ---
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
    @shared_mem_db_uri "file:shared_mem_conn_test_specific?mode=memory&cache=shared"

    setup do
      assert {:ok, conn1} = NIF.open(@shared_mem_db_uri)
      assert {:ok, conn2} = NIF.open(@shared_mem_db_uri)

      on_exit(fn ->
        NIF.close(conn1)
        NIF.close(conn2)
      end)

      {:ok, conn1: conn1, conn2: conn2}
    end

    # @tag :memory_shared
    test "handles reference the same underlying shared DB", %{conn1: conn1, conn2: conn2} do
      # Handles themselves are distinct ResourceArcs.
      refute conn1 == conn2

      # Check they point to the same DB using cache_size
      # Set cache_size via conn1, assert set success
      assert {:ok, true} = NIF.set_pragma(conn1, "cache_size", 5000)
      # Read back via conn2 using get_pragma, assert it returns the value set by conn1
      assert {:ok, 5000} = NIF.get_pragma(conn2, "cache_size")
    end
  end

  describe "open failure" do
    # This path is used specifically for testing open failures
    @invalid_db_path "file:./non_existent_dir_for_sure/read_only_db?mode=ro"
    # Get directory name
    @invalid_dir Path.dirname(@invalid_db_path)

    # Setup ensures the problematic path doesn't exist and registers cleanup
    setup do
      # Cleanup first in case previous run failed badly
      if File.exists?(@invalid_db_path), do: File.rm!(@invalid_db_path)
      if File.exists?(@invalid_dir), do: File.rmdir!(@invalid_dir)

      on_exit(fn ->
        if File.exists?(@invalid_db_path), do: File.rm!(@invalid_db_path)
        if File.exists?(@invalid_dir), do: File.rmdir!(@invalid_dir)
      end)

      :ok
    end

    # These tests don't depend on the opener type, so define once outside loop
    test "open/1 fails for an invalid path" do
      assert {:error, {:cannot_open_database, @invalid_db_path, _reason}} =
               NIF.open(@invalid_db_path)
    end

    test "open_in_memory/1 fails for an invalid URI schema" do
      # Test attempting to open non-file/memory URI via open_in_memory
      assert {:error, {:cannot_open_database, "http://invalid", _reason}} =
               NIF.open_in_memory("http://invalid")
    end
  end
end
