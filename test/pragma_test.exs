defmodule XqlitePragmaTest do
  use ExUnit.Case, async: true
  doctest Xqlite.Pragma

  alias XqliteNIF, as: NIF
  alias Xqlite.Pragma, as: P

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
    P.valid_write_arg_values()
    |> Enum.each(fn {name, arg_spec} ->
      test name, %{db: db} do
        assert valid_pragma_write(db, unquote(name), unquote(Macro.escape(arg_spec)))
      end
    end)
  end

  defp valid_get_result({:error, _, _}), do: false
  defp valid_get_result({:error, _}), do: false
  defp valid_get_result({:ok, _}), do: true

  defp valid_get_result(other) do
    IO.puts("pragma_get_result: unknown response: #{inspect(other)}")
  end

  defp valid_put_result(_name, :ok), do: true
  defp valid_put_result(_name, {:ok, _result}), do: true

  defp valid_put_result(name, {:error, :unsupported_value, val}) do
    flunk("PRAGMA put #{name} failed: unsupported value: #{val}")
  end

  defp valid_put_result(name, {:error, :cannot_execute_pragma, msg}) do
    flunk("PRAGMA put #{name} failed with error message: #{msg}")
  end

  defp valid_put_result(name, other) do
    IO.puts(
      "pragma_put_result: unknown response for setting pragma #{name}: #{inspect(other)}"
    )
  end

  defp valid_pragma_write(db, name, enumerable) do
    val = Enum.random(enumerable)
    result = P.put(db, name, val)
    valid_put_result(name, result)
  end
end
