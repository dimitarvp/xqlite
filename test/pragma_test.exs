defmodule XqlitePragmaTest do
  use ExUnit.Case, async: true
  doctest Xqlite.Pragma

  alias XqliteNIF, as: NIF
  alias Xqlite.Pragma, as: P

  import Xqlite.TestUtil,
    only: [
      default_verify_values: 2,
      normalize_test_values: 1,
      verify_is_atom: 2,
      verify_is_integer: 2,
      verify_is_integer_or_no_value_atom: 2,
      verify_is_ok_atom: 2
    ]

  @write_test_cases [
    # Simple set/get with representative values
    {:application_id, [0, 12345, 98765]},
    {:user_version, [0, 5, 10]},
    # Can only be set on a fresh DB
    {:page_size, [2048, 4096, 8192]},
    {:busy_timeout, [0, 1000, 5000]},
    # -1 means no limit
    {:journal_size_limit, [0, -1, 102_400]},
    {:max_page_count, [1, 1_000_000]},

    # All boolean PRAGMAs
    {:automatic_index, [true, false]},
    {:cell_size_check, [true, false]},
    {:checkpoint_fullfsync, [true, false]},
    {:defer_foreign_keys, [true, false]},
    {:foreign_keys, [true, false]},
    {:fullfsync, [true, false]},
    {:ignore_check_constraints, [true, false]},
    {:legacy_alter_table, [true, false]},
    {:query_only, [true, false]},
    {:read_uncommitted, [true, false]},
    {:recursive_triggers, [true, false]},
    {:reverse_unordered_selects, [true, false]},
    {:trusted_schema, [true, false]},

    # PRAGMAs with special value mappings (test all specified values)
    {:synchronous,
     [
       {"NORMAL", :normal},
       {1, :normal},
       {"OFF", :off},
       {0, :off},
       {"FULL", :full},
       {2, :full},
       {"EXTRA", :extra},
       {3, :extra}
     ]},
    {:temp_store,
     [
       {"DEFAULT", :default},
       {0, :default},
       {"FILE", :file},
       {1, :file},
       {"MEMORY", :memory},
       {2, :memory}
     ]},
    {:auto_vacuum, [{0, :none}, {1, :full}, {2, :incremental}], &verify_is_atom/2},
    {:secure_delete, [{0, false}, {1, true}, {2, :fast}]},

    # PRAGMAs with platform-dependent results
    {:journal_mode,
     [
       # Most common default for file DBs
       {"DELETE", "delete"},
       {"TRUNCATE", "truncate"},
       {"PERSIST", "persist"},
       {"MEMORY", "memory"},
       # On in-memory, WAL falls back to memory
       {"WAL", ~w(wal memory)},
       {"OFF", "off"}
     ]},
    {:locking_mode, [{"NORMAL", "normal"}, {"EXCLUSIVE", "exclusive"}]},
    {:encoding,
     [
       {"UTF-8", "UTF-8"},
       {"UTF-16le", "UTF-16le"},
       {"UTF-16be", "UTF-16be"},
       # Setting UTF-16 may result in le or be
       {"UTF-16", ~w(UTF-16le UTF-16be)}
     ]},

    # Write-only or special verification
    {:case_sensitive_like, [true, false], &verify_is_ok_atom/2},

    # Advisory values
    # Test with a positive, negative (if applicable), and zero value
    {:cache_size, [0, 5000, -10000], &verify_is_integer/2},
    {:soft_heap_limit, [0, 1024 * 1024], &verify_is_integer/2},
    {:hard_heap_limit, [0, 1024 * 1024], &verify_is_integer/2},
    {:threads, [0, 1, 8], &verify_is_integer/2},
    {:wal_autocheckpoint, [0, 1000], &verify_is_integer/2},
    {:mmap_size, [0, 256 * 1024 * 1024], &verify_is_integer_or_no_value_atom/2}
  ]

  setup do
    {:ok, db} = NIF.open(":memory:")
    {:ok, db: db}
  end

  # All readable PRAGMAs with zero args.
  describe "read pragma with no arguments:" do
    P.readable_with_zero_args()
    |> Enum.each(fn name ->
      test name, %{db: db} do
        assert valid_get_result(P.get(db, unquote(name)))
      end
    end)
  end

  # All of the readable PRAGMAs with one arg are actually instructions that change the DB.
  # We are not going to test those for now.

  # All writable PRAGMAs with one arg.

  describe "write pragma with one argument:" do
    for {name, values_to_test, verify_fun} <- @write_test_cases,
        verify_fun = Macro.escape(verify_fun) do
      verify_fun = verify_fun || (&default_verify_values/2)

      # Generate a test for each value to be set for a given PRAGMA
      for {set_val, expected_val} <- normalize_test_values(values_to_test) do
        test "#{name} = #{inspect(set_val)}", %{db: db} do
          # We have to do `unquote(name)` several times here because Elixir's 1.18 compiler
          # warns us that certain comparisons can never succeed.
          set_val = unquote(set_val)
          expected_val = unquote(expected_val)
          verify_fun = unquote(verify_fun)

          # We need a clean DB for some PRAGMAs like page_size
          db = if unquote(name) == :page_size, do: clean_db(), else: db

          # The core of the test: put, then get and verify
          assert :ok = P.put(db, unquote(name), set_val)

          case P.get(db, unquote(name)) do
            {:ok, fetched_val} ->
              assert verify_fun.(set_val, fetched_val) or
                       fetched_val in List.wrap(expected_val),
                     "Set `#{inspect(set_val)}`, but fetched `#{inspect(fetched_val)}`, expected one of `#{inspect(expected_val)}`"

            # For write-only PRAGMAs
            :ok ->
              assert verify_fun.(set_val, :ok)

            error ->
              flunk(
                "P.get returned an unexpected error after a successful put: `#{inspect(error)}`"
              )
          end
        end
      end
    end
  end

  defp valid_get_result({:error, _, _}), do: false
  defp valid_get_result({:error, _}), do: false
  defp valid_get_result({:ok, _}), do: true
  defp valid_get_result(:ok), do: true

  defp valid_get_result(other) do
    IO.puts("pragma_get_result: unknown response: `#{inspect(other)}`")
  end

  defp clean_db() do
    {:ok, db} = NIF.open(":memory:")
    db
  end
end
