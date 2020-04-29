defmodule XqlitePragmaTest do
  use ExUnit.Case
  doctest Xqlite.Pragma

  alias Xqlite.Conn
  alias Xqlite.Pragma, as: P
  alias XqliteNIF, as: NIF

  setup_all do
    {:ok, db} = Conn.open(Xqlite.unnamed_memory_db())
    {:ok, db: db}
  end

  describe "pragma getting through our wrapper" do
    P.supported()
    |> Enum.each(fn name ->
      test name, %{db: db} do
        assert valid_pragma(P.get(db, unquote(name)))
      end
    end)
  end

  describe "pragma getting through the NIF" do
    P.supported()
    |> Enum.each(fn name ->
      test name, %{db: db} do
        assert valid_pragma(NIF.pragma_get0(db, Atom.to_string(unquote(name)), []))
      end
    end)
  end

  defp valid_pragma({:error, _, _}), do: false
  defp valid_pragma({:error, _}), do: false
  defp valid_pragma({:ok, _}), do: true
end
