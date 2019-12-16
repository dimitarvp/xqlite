defmodule XqlitePragmaTest do
  use ExUnit.Case
  doctest Xqlite.Pragma

  alias Xqlite.Pragma, as: P

  setup_all do
    {:ok, db} = Sqlitex.open(":memory:")
    {:ok, db: db}
  end

  describe "getting raw pragma" do
    P.supported()
    |> Enum.each(fn name ->
      test name, %{db: db} do
        assert valid_pragma(P.raw(db, unquote(name)))
      end
    end)
  end

  defp valid_pragma([]), do: true
  defp valid_pragma([kw | _rest_kws]) when is_list(kw), do: true
  defp valid_pragma(_), do: false
end
