defmodule Xqlite.NIF.PragmaTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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
        assert {:ok, limit} = NIF.get_pragma(conn, "journal_size_limit")
        assert is_integer(limit)
        assert {:ok, mode} = NIF.get_pragma(conn, "journal_mode")
        assert mode in ["persist", "wal", "truncate", "memory", "delete", "off"]
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
        assert {:ok, _} = NIF.set_pragma(conn, "cache_size", 5000)
        assert {:ok, 5000} = NIF.get_pragma(conn, "cache_size")
      end

      test "set_pragma/3 sets and get_pragma/2 reads boolean ON/true", %{conn: conn} do
        assert {:ok, _} = NIF.set_pragma(conn, "foreign_keys", :on)
        assert {:ok, 1} = NIF.get_pragma(conn, "foreign_keys")
        assert {:ok, _} = NIF.set_pragma(conn, "foreign_keys", true)
        assert {:ok, 1} = NIF.get_pragma(conn, "foreign_keys")
      end

      test "set_pragma/3 sets and get_pragma/2 reads boolean OFF/false", %{conn: conn} do
        assert {:ok, _} = NIF.set_pragma(conn, "foreign_keys", :on)
        assert {:ok, 1} = NIF.get_pragma(conn, "foreign_keys")
        assert {:ok, _} = NIF.set_pragma(conn, "foreign_keys", :off)
        assert {:ok, 0} = NIF.get_pragma(conn, "foreign_keys")
        assert {:ok, _} = NIF.set_pragma(conn, "foreign_keys", :on)
        assert {:ok, 1} = NIF.get_pragma(conn, "foreign_keys")
        assert {:ok, _} = NIF.set_pragma(conn, "foreign_keys", false)
        assert {:ok, 0} = NIF.get_pragma(conn, "foreign_keys")
      end

      # NOTE: Test for journal_mode moved outside the loop as behavior differs

      test "set_pragma/3 succeeds silently for invalid pragma name", %{conn: conn} do
        assert {:ok, _} = NIF.set_pragma(conn, "invalid_pragma", 123)
        assert {:ok, :no_value} = NIF.get_pragma(conn, "invalid_pragma")
      end

      test "set_pragma/3 succeeds silently for invalid value", %{conn: conn} do
        # First, explicitly set the pragma to a known state (OFF/0)
        assert {:ok, _} = NIF.set_pragma(conn, "foreign_keys", :off)
        assert {:ok, 0} = NIF.get_pragma(conn, "foreign_keys")

        # Now, attempt to set an invalid value. This should be a no-op.
        assert {:ok, _} = NIF.set_pragma(conn, "foreign_keys", "invalid_string")

        # Verify the value has not changed from our known state.
        assert {:ok, 0} = NIF.get_pragma(conn, "foreign_keys")
      end

      test "set_pragma/3 returns error for unsupported Elixir type", %{conn: conn} do
        assert {:error, {:unsupported_data_type, :map}} =
                 NIF.set_pragma(conn, "cache_size", %{})
      end

      # A PRAGMA value is interpolated into the statement, so it has to be
      # text. Three ways it can fail to be, three answers.
      test "set_pragma/3 refuses a value that is no text, by what it is", %{conn: conn} do
        assert {:error, {:unsupported_data_type, :bitstring}} =
                 NIF.set_pragma(conn, "user_version", <<1::7>>)

        assert {:error, {:cannot_execute_pragma, "user_version", reason}} =
                 NIF.set_pragma(conn, "user_version", <<255>>)

        assert is_binary(reason)

        assert {:error, :null_byte_in_string} = NIF.set_pragma(conn, "user_version", <<0>>)

        assert {:ok, 0} = NIF.get_pragma(conn, "user_version")
      end

      test "the wrapper answers the same for a name the schema does not model", %{conn: conn} do
        assert {:error, {:unsupported_data_type, :bitstring}} =
                 Xqlite.set_pragma(conn, :not_a_pragma, <<1::7>>)

        assert {:error, {:cannot_execute_pragma, "not_a_pragma", _reason}} =
                 Xqlite.set_pragma(conn, :not_a_pragma, <<255>>)

        assert {:error, :null_byte_in_string} =
                 Xqlite.set_pragma(conn, :not_a_pragma, <<0>>)
      end

      property "a bit size that is no whole byte is refused by its kind", %{conn: conn} do
        check all(bits <- partial_byte_bitstring(), max_runs: 2000) do
          assert {:error, {:unsupported_data_type, :bitstring}} =
                   NIF.set_pragma(conn, "user_version", bits)
        end
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
      assert {:ok, conn} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "set_pragma/3 ignores journal_mode WAL/DELETE for :memory:", %{conn: conn} do
      assert {:ok, "memory"} = NIF.get_pragma(conn, "journal_mode")
      # Attempt to set WAL — journal_mode echoes actual mode (stays "memory")
      assert {:ok, "memory"} = NIF.set_pragma(conn, "journal_mode", :wal)
      assert {:ok, "memory"} = NIF.get_pragma(conn, "journal_mode")
      # Attempt to set DELETE — same, stays "memory"
      assert {:ok, "memory"} = NIF.set_pragma(conn, "journal_mode", "DELETE")
      assert {:ok, "memory"} = NIF.get_pragma(conn, "journal_mode")
    end
  end

  # --- Edge case: pragma name injection ---
  describe "pragma name validation" do
    setup do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "set_pragma rejects names with semicolons", %{conn: conn} do
      assert {:error, {:invalid_pragma_name, _}} =
               NIF.set_pragma(conn, "x; DROP TABLE foo; --", "1")
    end

    test "get_pragma rejects names with semicolons", %{conn: conn} do
      assert {:error, {:invalid_pragma_name, _}} =
               NIF.get_pragma(conn, "x; DROP TABLE foo; --")
    end

    test "set_pragma rejects empty name", %{conn: conn} do
      assert {:error, {:invalid_pragma_name, _}} = NIF.set_pragma(conn, "", "1")
    end

    test "set_pragma accepts valid pragma names", %{conn: conn} do
      assert {:ok, _} = NIF.set_pragma(conn, "cache_size", -1000)
    end

    # A name of digits passes the name check and then fails SQLite's parser,
    # which is the only way to reach the two arms that carry the statement.
    test "a refused PRAGMA names itself, whichever step refused it", %{conn: conn} do
      assert {:error, {:cannot_execute_pragma, "42", _read_reason}} =
               NIF.get_pragma(conn, "42")

      assert {:error, {:cannot_execute_pragma, "42", _write_reason}} =
               NIF.set_pragma(conn, "42", 1)

      assert {:error, {:cannot_execute_pragma, "user_version", _value_reason}} =
               NIF.set_pragma(conn, "user_version", <<255>>)
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

      # Attempt to set WAL — journal_mode echoes the actual resulting mode
      assert {:ok, mode_after_wal} = NIF.set_pragma(conn, "journal_mode", :wal)
      assert mode_after_wal in ["wal", "delete"]
      assert {:ok, ^mode_after_wal} = NIF.get_pragma(conn, "journal_mode")

      # Set DELETE explicitly — echoes "delete"
      assert {:ok, "delete"} = NIF.set_pragma(conn, "journal_mode", "DELETE")
      assert {:ok, "delete"} = NIF.get_pragma(conn, "journal_mode")
    end
  end

  defp partial_byte_bitstring do
    StreamData.bitstring()
    |> StreamData.scale(fn size -> min(size, 32) end)
    |> StreamData.filter(&partial_byte?/1)
  end

  defp partial_byte?(bits), do: rem(bit_size(bits), 8) != 0
end
