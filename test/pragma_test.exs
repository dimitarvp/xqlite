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
      verify_is_ok_atom: 2
    ]

  @write_test_cases [
    # {pragma_name, [list_of_values_to_test], optional_verify_function}
    # The verify function is `fn(set_val, fetched_val) -> boolean`

    # Simple set/get
    {:application_id, [12345, 98765]},
    {:user_version, [5, 10]},
    # Note: can only be set on a fresh DB before data is written.
    {:page_size, [2048, 4096]},

    # PRAGMAs with special value mappings
    {:synchronous, [{"NORMAL", :normal}, {1, :normal}, {"OFF", :off}, {0, :off}]},
    {:temp_store, [{"FILE", :file}, {1, :file}, {"MEMORY", :memory}, {2, :memory}]},

    # PRAGMAs with platform-dependent or state-dependent results
    {:journal_mode, [{"WAL", ~w(wal memory)}, {"DELETE", ~w(delete memory)}]},
    {:locking_mode, [{"NORMAL", "normal"}, {"EXCLUSIVE", "exclusive"}]},
    {:encoding, [{"UTF-8", "UTF-8"}, {"UTF-16", ~w(UTF-16le UTF-16be)}]},

    # Write-only or no-value-on-read PRAGMAs
    {:case_sensitive_like, [true, false], &verify_is_ok_atom/2},

    # PRAGMAs whose values are advisory and may not be honored exactly
    # We test that setting them doesn't error, and reading back gives *some* int.
    # The exact value isn't asserted here as it depends on SQLite version & state.
    {:cache_size, [-10000, 5000], &verify_is_integer/2},
    {:threads, [0, 2], &verify_is_integer/2},

    # These are best tested by observing side-effects, but for a simple write test,
    # we just ensure they can be set without error.
    {:auto_vacuum, [0, 1, 2], &verify_is_atom/2}
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
