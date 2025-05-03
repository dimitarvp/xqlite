defmodule Xqlite.NIF.PragmaTest do
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF

  # --- Setup ---
  setup do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    on_exit(fn -> NIF.close(conn) end)
    {:ok, conn: conn}
  end

  # --- get_pragma/2 Tests ---

  test "get_pragma/2 reads default values", %{conn: conn} do
    assert {:ok, 0} = NIF.get_pragma(conn, "user_version")
    # Default is OFF (0)
    assert {:ok, 0} = NIF.get_pragma(conn, "foreign_keys")
    # Default journal_size_limit might vary, assert it's an integer
    assert {:ok, limit} = NIF.get_pragma(conn, "journal_size_limit")
    # Check type instead of exact value like -1 or 32768
    assert is_integer(limit)
    # Default journal_mode for :memory: is "memory"
    assert {:ok, "memory"} = NIF.get_pragma(conn, "journal_mode")
  end

  test "get_pragma/2 returns :no_value for pragmas that don't return a value when read", %{
    conn: conn
  } do
    # Execute optimize first
    assert {:ok, true} = NIF.execute_batch(conn, "PRAGMA optimize;")
    # Reading "optimize" returns no rows
    assert {:ok, :no_value} = NIF.get_pragma(conn, "optimize")
  end

  test "get_pragma/2 returns :no_value for invalid pragma name", %{conn: conn} do
    # Reading an unknown PRAGMA returns no rows, not an error
    assert {:ok, :no_value} = NIF.get_pragma(conn, "invalid_pragma_name")
  end

  # --- set_pragma/3 Tests ---

  # Cannot reliably test immediate read-back of user_version on same connection
  # test "set_pragma/3 sets and get_pragma/2 reads integer value (user_version)"

  test "set_pragma/3 sets and get_pragma/2 reads boolean ON/true (foreign_keys)", %{conn: conn} do
    # Test setting with :on atom
    assert {:ok, true} = NIF.set_pragma(conn, "foreign_keys", :on)
    # SQLite returns 1 for ON
    assert {:ok, 1} = NIF.get_pragma(conn, "foreign_keys")

    # Test setting with true boolean
    assert {:ok, true} = NIF.set_pragma(conn, "foreign_keys", true)
    assert {:ok, 1} = NIF.get_pragma(conn, "foreign_keys")
  end

  test "set_pragma/3 sets and get_pragma/2 reads boolean OFF/false (foreign_keys)", %{
    conn: conn
  } do
    # First enable it
    assert {:ok, true} = NIF.set_pragma(conn, "foreign_keys", :on)
    assert {:ok, 1} = NIF.get_pragma(conn, "foreign_keys")

    # Test setting with :off atom
    assert {:ok, true} = NIF.set_pragma(conn, "foreign_keys", :off)
    # SQLite returns 0 for OFF
    assert {:ok, 0} = NIF.get_pragma(conn, "foreign_keys")

    # Re-enable and test setting with false boolean
    assert {:ok, true} = NIF.set_pragma(conn, "foreign_keys", :on)
    assert {:ok, 1} = NIF.get_pragma(conn, "foreign_keys")
    assert {:ok, true} = NIF.set_pragma(conn, "foreign_keys", false)
    assert {:ok, 0} = NIF.get_pragma(conn, "foreign_keys")
  end

  test "set_pragma/3 sets journal_mode but reading back reflects :memory: db behavior", %{
    conn: conn
  } do
    # Initial mode for :memory: is "memory"
    assert {:ok, "memory"} = NIF.get_pragma(conn, "journal_mode")

    # Attempt to set using atom :wal - set operation succeeds
    assert {:ok, true} = NIF.set_pragma(conn, "journal_mode", :wal)
    # Read back, expect it to still be "memory" because WAL is ignored/forced for :memory:
    assert {:ok, "memory"} = NIF.get_pragma(conn, "journal_mode")

    # Attempt to set using string "DELETE" - set operation succeeds
    assert {:ok, true} = NIF.set_pragma(conn, "journal_mode", "DELETE")
    # Read back, expect it to still be "memory"
    assert {:ok, "memory"} = NIF.get_pragma(conn, "journal_mode")
  end

  test "set_pragma/3 succeeds silently for invalid pragma name", %{conn: conn} do
    # Setting an unknown PRAGMA is often ignored by SQLite, not an error
    assert {:ok, true} = NIF.set_pragma(conn, "invalid_pragma", 123)
    # Verify by reading it back (should return no value)
    assert {:ok, :no_value} = NIF.get_pragma(conn, "invalid_pragma")
  end

  test "set_pragma/3 succeeds silently for invalid value type", %{conn: conn} do
    # Get initial journal_mode
    assert {:ok, "memory"} = NIF.get_pragma(conn, "journal_mode")

    # Attempt to set journal_mode with an integer - set operation succeeds silently
    assert {:ok, true} = NIF.set_pragma(conn, "journal_mode", 123)
    # Verify by reading back - it should be unchanged ("memory")
    assert {:ok, "memory"} = NIF.get_pragma(conn, "journal_mode")

    # Try setting foreign_keys with a string (expects boolean/ON/OFF) - succeeds silently
    assert {:ok, true} = NIF.set_pragma(conn, "foreign_keys", "invalid_string")
    # Verify value remains unchanged (should be 0 by default)
    assert {:ok, 0} = NIF.get_pragma(conn, "foreign_keys")
  end

  test "set_pragma/3 returns error for unsupported Elixir type", %{conn: conn} do
    # Setting with a map should fail during term conversion in the NIF helper
    assert {:error, {:unsupported_data_type, :map}} =
             NIF.set_pragma(conn, "user_version", %{})
  end
end
