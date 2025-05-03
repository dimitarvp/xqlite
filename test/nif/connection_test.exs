defmodule Xqlite.NIF.ConnectionTest do
  # Safe with :memory: databases
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF
  # Needed for DatabaseInfo struct
  alias Xqlite.Schema

  # Shared in-memory DB URI for tests that need the *same* underlying DB
  @shared_mem_db_uri "file:shared_mem_conn_test?mode=memory&cache=shared"

  # Invalid path for testing open errors
  @invalid_db_path "file:./non_existent_dir_for_sure/read_only_db?mode=ro"

  # Value to use for cache_size tests
  @test_cache_size 4000

  setup do
    if File.exists?(@invalid_db_path) do
      raise(
        "Invalid DB path target '#{@invalid_db_path}' exists, please remove it before testing."
      )
    end

    :ok
  end

  # --- open/1 Tests ---

  test "open/1 successfully opens a unique :memory: database" do
    assert {:ok, conn} = NIF.open(":memory:")
    # Verify it's usable: set PRAGMA returns :ok, true; get PRAGMA returns the value.
    assert {:ok, true} = NIF.set_pragma(conn, "cache_size", @test_cache_size)
    # Assert directly against module attribute value
    assert {:ok, @test_cache_size} = NIF.get_pragma(conn, "cache_size")
    assert {:ok, true} = NIF.close(conn)
  end

  test "open/1 successfully opens a shared in-memory database via URI" do
    assert {:ok, conn} = NIF.open(@shared_mem_db_uri)
    # Verify usability: set PRAGMA returns :ok, true; get PRAGMA returns the value.
    # Use a different value to ensure it's distinct from other tests using the shared URI
    test_val = @test_cache_size + 1
    assert {:ok, true} = NIF.set_pragma(conn, "cache_size", test_val)
    # Use pin operator ^ for the variable test_val
    assert {:ok, ^test_val} = NIF.get_pragma(conn, "cache_size")
    assert {:ok, true} = NIF.close(conn)
  end

  test "open/1 fails for an invalid path" do
    assert {:error, {:cannot_open_database, @invalid_db_path, _reason}} =
             NIF.open(@invalid_db_path)
  end

  test "open/1 with shared URI returns different handles referencing the same DB" do
    assert {:ok, conn1} = NIF.open(@shared_mem_db_uri)
    assert {:ok, conn2} = NIF.open(@shared_mem_db_uri)

    # Handles themselves are distinct ResourceArcs wrapping the same underlying connection.
    refute conn1 == conn2

    # Check they point to the same DB by setting/getting cache_size
    # Set cache_size via conn1, assert set returns :ok, true
    assert {:ok, true} = NIF.set_pragma(conn1, "cache_size", @test_cache_size)

    # Read back via conn2 using get_pragma, assert it returns the value set by conn1 (use attribute directly)
    assert {:ok, @test_cache_size} = NIF.get_pragma(conn2, "cache_size")

    assert {:ok, true} = NIF.close(conn1)
    # Closing via conn2 should still succeed because close/1 is conceptually idempotent
    # and relies on Arc/GC for the actual underlying close.
    assert {:ok, true} = NIF.close(conn2)
  end

  # --- open_in_memory/1 Tests ---

  test "open_in_memory/1 successfully opens a unique :memory: database" do
    assert {:ok, conn} = NIF.open_in_memory(":memory:")
    # Verify usability: set PRAGMA, check success, then get PRAGMA
    assert {:ok, true} = NIF.set_pragma(conn, "cache_size", @test_cache_size)
    # Assert directly against module attribute value
    assert {:ok, @test_cache_size} = NIF.get_pragma(conn, "cache_size")
    assert {:ok, true} = NIF.close(conn)
  end

  test "open_in_memory/1 successfully opens a shared in-memory database via URI" do
    assert {:ok, conn} = NIF.open_in_memory(@shared_mem_db_uri)
    # Verify usability: set PRAGMA, check success, then get PRAGMA
    # Use a different value
    test_val = @test_cache_size + 2
    assert {:ok, true} = NIF.set_pragma(conn, "cache_size", test_val)
    # Use pin operator ^ for the variable test_val
    assert {:ok, ^test_val} = NIF.get_pragma(conn, "cache_size")
    assert {:ok, true} = NIF.close(conn)
  end

  test "open_in_memory/1 fails for an invalid URI schema (requires file: or :memory:)" do
    assert {:error, {:cannot_open_database, "http://invalid", _reason}} =
             NIF.open_in_memory("http://invalid")
  end

  test "open_in_memory/1 with shared URI returns different handles referencing the same DB" do
    assert {:ok, conn1} = NIF.open_in_memory(@shared_mem_db_uri)
    assert {:ok, conn2} = NIF.open_in_memory(@shared_mem_db_uri)

    # Handles themselves are distinct ResourceArcs.
    refute conn1 == conn2

    # Check they point to the same DB using cache_size
    # Set cache_size via conn1, assert set success
    assert {:ok, true} = NIF.set_pragma(conn1, "cache_size", @test_cache_size)
    # Read back via conn2 using get_pragma (use attribute directly)
    assert {:ok, @test_cache_size} = NIF.get_pragma(conn2, "cache_size")

    assert {:ok, true} = NIF.close(conn1)
    assert {:ok, true} = NIF.close(conn2)
  end

  # --- open_temporary/0 Tests ---

  test "open_temporary/0 successfully opens a unique temporary file database" do
    assert {:ok, conn} = NIF.open_temporary()
    # Verify usability: set PRAGMA, check success, then get PRAGMA
    assert {:ok, true} = NIF.set_pragma(conn, "cache_size", @test_cache_size)
    # Assert directly against module attribute value
    assert {:ok, @test_cache_size} = NIF.get_pragma(conn, "cache_size")
    # Check database list - should show main with empty file path ("" not nil) for temporary DB
    assert {:ok, [%Schema.DatabaseInfo{name: "main", file: ""}]} =
             NIF.schema_databases(conn)

    assert {:ok, true} = NIF.close(conn)
  end

  test "open_temporary/0 creates distinct databases on subsequent calls" do
    assert {:ok, conn1} = NIF.open_temporary()
    assert {:ok, conn2} = NIF.open_temporary()

    # Handles represent distinct underlying temporary databases.
    refute conn1 == conn2

    # Verify they are distinct DBs using cache_size
    # Get default cache_size on conn2 first
    {:ok, default_cache_size_conn2} = NIF.get_pragma(conn2, "cache_size")
    # Set cache_size on conn1, assert set success
    assert {:ok, true} = NIF.set_pragma(conn1, "cache_size", @test_cache_size)
    # Verify the value was set on conn1 (use attribute directly)
    assert {:ok, @test_cache_size} = NIF.get_pragma(conn1, "cache_size")
    # Read back via conn2 using get_pragma, assert it's still the default value (pin variable)
    assert {:ok, ^default_cache_size_conn2} = NIF.get_pragma(conn2, "cache_size")

    assert {:ok, true} = NIF.close(conn1)
    assert {:ok, true} = NIF.close(conn2)
  end

  # --- close/1 Tests ---

  test "close/1 returns {:ok, true} even when called multiple times" do
    assert {:ok, conn} = NIF.open(":memory:")
    assert {:ok, true} = NIF.close(conn)

    # Subsequent calls are no-ops on the Rust side but should still return ok via the NIF interface.
    assert {:ok, true} = NIF.close(conn)
    assert {:ok, true} = NIF.close(conn)
  end
end
