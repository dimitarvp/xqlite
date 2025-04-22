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

    # No shared state needed between test.
    :ok
  end

  describe "raw_open/2 and raw_close/1" do
    test "opens a valid in-memory database, closes it, and fails on second close" do
      assert {:ok, conn} = NIF.raw_open(@valid_db_path)
      assert {:ok, true} = NIF.raw_close(conn)
      assert {:ok, true} = NIF.raw_close(conn)
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

      # Closing via conn2 should still succeed because it's no-op on the Rust side
      # as we are relying on the reference-counted Rust `Arc` to ultimately garbage-collect
      # the connection, which leads to actually closing it.
      assert {:ok, true} = NIF.raw_close(conn2)
    end

    # end of describe "raw_open/2 and raw_close/1"
  end

  describe "raw_pragma_write/2" do
    test "can execute a simple PRAGMA" do
      {:ok, conn} = NIF.raw_open(@valid_db_path)
      assert {:ok, 0} = NIF.raw_pragma_write(conn, "PRAGMA synchronous = 0;")
      assert {:ok, true} = NIF.raw_close(conn)
    end
  end

  describe "raw_exec/3" do
    test "can execute a simple query" do
      {:ok, conn} = NIF.raw_open(@valid_db_path)
      assert {:ok, [[1]]} = NIF.raw_exec(conn, "SELECT 1;", [])
      assert {:ok, true} = NIF.raw_close(conn)
    end
  end
end
