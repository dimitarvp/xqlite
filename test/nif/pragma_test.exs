defmodule Xqlite.NIF.PragmaTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]
  alias XqliteNIF, as: NIF

  # --- Shared test code (generated via `for` loop) ---
  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # --- Shared test cases applicable to all DB types follow ---

      # --- get_pragma/2 Tests ---
      test "get_pragma/2 reads default values", %{conn: conn} do
        assert {:ok, 0} = NIF.get_pragma(conn, "user_version")
        assert {:ok, 1} = NIF.get_pragma(conn, "foreign_keys")
        assert {:ok, limit} = NIF.get_pragma(conn, "journal_size_limit")
        assert is_integer(limit)
        assert {:ok, mode} = NIF.get_pragma(conn, "journal_mode")
        assert mode in ["memory", "delete", "off"]
      end

      test "get_pragma/2 returns :no_value for non-value pragmas", %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, "PRAGMA optimize;")
        assert {:ok, :no_value} = NIF.get_pragma(conn, "optimize")
      end

      test "get_pragma/2 returns :no_value for invalid pragma name", %{conn: conn} do
        assert {:ok, :no_value} = NIF.get_pragma(conn, "invalid_pragma_name")
      end

      # --- set_pragma/3 Tests ---
      test "set_pragma/3 sets and get_pragma/2 reads integer value", %{conn: conn} do
        assert :ok = NIF.set_pragma(conn, "cache_size", 5000)
        assert {:ok, 5000} = NIF.get_pragma(conn, "cache_size")
      end

      test "set_pragma/3 sets and get_pragma/2 reads boolean ON/true", %{conn: conn} do
        assert :ok = NIF.set_pragma(conn, "foreign_keys", :on)
        assert {:ok, 1} = NIF.get_pragma(conn, "foreign_keys")
        assert :ok = NIF.set_pragma(conn, "foreign_keys", true)
        assert {:ok, 1} = NIF.get_pragma(conn, "foreign_keys")
      end

      test "set_pragma/3 sets and get_pragma/2 reads boolean OFF/false", %{conn: conn} do
        assert :ok = NIF.set_pragma(conn, "foreign_keys", :on)
        assert {:ok, 1} = NIF.get_pragma(conn, "foreign_keys")
        assert :ok = NIF.set_pragma(conn, "foreign_keys", :off)
        assert {:ok, 0} = NIF.get_pragma(conn, "foreign_keys")
        assert :ok = NIF.set_pragma(conn, "foreign_keys", :on)
        assert {:ok, 1} = NIF.get_pragma(conn, "foreign_keys")
        assert :ok = NIF.set_pragma(conn, "foreign_keys", false)
        assert {:ok, 0} = NIF.get_pragma(conn, "foreign_keys")
      end

      # NOTE: Test for journal_mode moved outside the loop as behavior differs

      test "set_pragma/3 succeeds silently for invalid pragma name", %{conn: conn} do
        assert :ok = NIF.set_pragma(conn, "invalid_pragma", 123)
        assert {:ok, :no_value} = NIF.get_pragma(conn, "invalid_pragma")
      end

      test "set_pragma/3 succeeds silently for invalid value", %{conn: conn} do
        # First, explicitly set the pragma to a known state (OFF/0)
        assert :ok = NIF.set_pragma(conn, "foreign_keys", :off)
        assert {:ok, 0} = NIF.get_pragma(conn, "foreign_keys")

        # Now, attempt to set an invalid value. This should be a no-op.
        assert :ok = NIF.set_pragma(conn, "foreign_keys", "invalid_string")

        # Verify the value has not changed from our known state.
        assert {:ok, 0} = NIF.get_pragma(conn, "foreign_keys")
      end

      test "set_pragma/3 returns error for unsupported Elixir type", %{conn: conn} do
        assert {:error, {:unsupported_data_type, :map}} =
                 NIF.set_pragma(conn, "cache_size", %{})
      end
    end

    # end describe "using #{prefix}"
  end

  # end `for` loop

  # --- DB type-specific tests (outside the `for` loop) ---

  describe "using Private In-memory DB (Specific PRAGMA tests)" do
    # Tag specific block
    @tag :memory_private
    setup do
      assert {:ok, conn} = NIF.open_in_memory()
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "set_pragma/3 ignores journal_mode WAL/DELETE for :memory:", %{conn: conn} do
      assert {:ok, "memory"} = NIF.get_pragma(conn, "journal_mode")
      # Attempt to set WAL succeeds, but readback shows it remains memory
      assert :ok = NIF.set_pragma(conn, "journal_mode", :wal)
      assert {:ok, "memory"} = NIF.get_pragma(conn, "journal_mode")
      # Attempt to set DELETE succeeds, but readback shows it remains memory
      assert :ok = NIF.set_pragma(conn, "journal_mode", "DELETE")
      assert {:ok, "memory"} = NIF.get_pragma(conn, "journal_mode")
    end
  end

  describe "using Temporary Disk DB (Specific PRAGMA tests)" do
    # Tag specific block
    @tag :file_temp
    setup do
      assert {:ok, conn} = NIF.open_temporary()
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "set_pragma/3 allows setting journal_mode for temp file", %{conn: conn} do
      # Default might be DELETE or OFF for temp file
      assert {:ok, initial_mode} = NIF.get_pragma(conn, "journal_mode")
      assert initial_mode in ["delete", "off", "memory"]

      # Attempt to set WAL
      assert :ok = NIF.set_pragma(conn, "journal_mode", :wal)
      # Check actual resulting mode - might be WAL or a fallback like DELETE
      assert {:ok, mode_after_wal} = NIF.get_pragma(conn, "journal_mode")
      # Assert it's one of the expected outcomes (WAL ideally, DELETE is common fallback)
      assert mode_after_wal in ["wal", "delete"]

      # Set DELETE explicitly
      assert :ok = NIF.set_pragma(conn, "journal_mode", "DELETE")
      # Expect DELETE should always work for a file DB
      assert {:ok, "delete"} = NIF.get_pragma(conn, "journal_mode")
    end
  end
end
