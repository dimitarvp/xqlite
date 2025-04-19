defmodule XqliteNifTest do
  use ExUnit.Case, async: false

  alias XqliteNIF, as: NIF

  # Always valid
  @valid_db_path "file:memdb1?mode=memory&cache=shared"

  # Using a path that cannot exist in read-only mode ensures failure
  @invalid_db_path "file:./non_existent_dir_for_sure/read_only_db?mode=ro&immutable=1"

  setup do
    # Ensure the invalid path target doesn't exist before tests using it
    if File.exists?(@invalid_db_path) do
      raise("Invalid DB path '#{@invalid_db_path}' exists, please remove it.")
    end

    # No shared state needed between tests for now.
    :ok
  end

  describe "raw_open/2 and raw_close/1" do
    test "opens a valid in-memory database, closes it, and fails on second close" do
      assert {:ok, conn} = NIF.raw_open(@valid_db_path)
      assert {:ok, true} = NIF.raw_close(conn)

      assert match?(
               {:error, {:connection_not_found, db_path}} when is_binary(db_path),
               NIF.raw_close(conn)
             )
    end

    test "fails to open an invalid database path immediately" do
      assert {:error, {:cannot_open_database, @invalid_db_path, _reason}} =
               NIF.raw_open(@invalid_db_path)
    end

    test "opens the same database path multiple times, returning the same handle conceptually" do
      assert {:ok, conn1} = NIF.raw_open(@valid_db_path)
      assert {:ok, conn2} = NIF.raw_open(@valid_db_path)

      # The resource handles themselves might be different ResourceArc wrappers,
      # but they should represent the same underlying pooled connection (keyed by path).
      # We can verify this by closing one and checking the other still works (tested by closing)

      assert {:ok, true} = NIF.raw_close(conn1)

      # Closing via conn2 should now fail as the pool for @valid_db_path was removed
      assert {:error, {:connection_not_found, @valid_db_path}} = NIF.raw_close(conn2)
    end

    # end of describe "raw_open/2 and raw_close/1"
  end

  describe "raw_open/2 with options" do
    test "opens successfully with valid and extraneous options" do
      valid_options = [
        connection_timeout: 5000,
        idle_timeout: 60_000,
        max_size: 5,
        min_idle: 1,
        # These should be ignored by the Rust code.
        some_other_key: :foo,
        pool_name: "bar"
      ]

      assert {:ok, conn} = NIF.raw_open(@valid_db_path, valid_options)
      assert {:ok, true} = NIF.raw_close(conn)
    end

    test "fails with invalid zero connection_timeout" do
      opts = [connection_timeout: 0]
      assert {:error, {:invalid_time_value, 0}} = NIF.raw_open(@valid_db_path, opts)
    end

    test "fails with invalid zero idle_timeout" do
      opts = [idle_timeout: 0]
      assert {:error, {:invalid_time_value, 0}} = NIF.raw_open(@valid_db_path, opts)
    end

    test "fails with invalid zero max_lifetime" do
      opts = [max_lifetime: 0]
      assert {:error, {:invalid_time_value, 0}} = NIF.raw_open(@valid_db_path, opts)
    end

    test "fails with invalid zero max_size" do
      opts = [max_size: 0]
      assert {:error, {:invalid_pool_size, 0}} = NIF.raw_open(@valid_db_path, opts)
    end

    test "fails when min_idle > explicit max_size" do
      opts = [min_idle: 11, max_size: 10]

      assert {:error, {:invalid_idle_connection_count, 11, 10}} =
               NIF.raw_open(@valid_db_path, opts)
    end

    test "fails when min_idle > default max_size" do
      # NOTE: Assumes DEFAULT_MAX_POOL_SIZE is 10
      opts = [min_idle: 11]

      assert {:error, {:invalid_idle_connection_count, 11, 10}} =
               NIF.raw_open(@valid_db_path, opts)
    end

    test "succeeds when min_idle = max_size" do
      opts = [min_idle: 5, max_size: 5]
      assert {:ok, conn} = NIF.raw_open(@valid_db_path, opts)
      assert {:ok, true} = NIF.raw_close(conn)
    end

    test "succeeds when min_idle < max_size" do
      opts = [min_idle: 3, max_size: 5]
      assert {:ok, conn} = NIF.raw_open(@valid_db_path, opts)
      assert {:ok, true} = NIF.raw_close(conn)
    end

    test "succeeds when min_idle < default max_size" do
      # NOTE: Assumes DEFAULT_MAX_POOL_SIZE is 10
      opts = [min_idle: 9]
      assert {:ok, conn} = NIF.raw_open(@valid_db_path, opts)
      assert {:ok, true} = NIF.raw_close(conn)
    end

    # end of describe "raw_open/2 with options"
  end

  # Minimal test to ensure PRAGMA write NIF exists and accepts args
  describe "raw_pragma_write/2" do
    test "can execute a simple PRAGMA" do
      {:ok, conn} = NIF.raw_open(@valid_db_path)
      assert {:ok, 0} = NIF.raw_pragma_write(conn, "PRAGMA synchronous = 0;")
      assert {:ok, true} = NIF.raw_close(conn)
    end
  end

  # Minimal test to ensure exec NIF exists and accepts args
  describe "raw_exec/3" do
    test "can execute a simple query" do
      {:ok, conn} = NIF.raw_open(@valid_db_path)
      assert {:ok, [[1]]} = NIF.raw_exec(conn, "SELECT 1;", [])
      assert {:ok, true} = NIF.raw_close(conn)
    end
  end
end
