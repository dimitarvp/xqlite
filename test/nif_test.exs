defmodule XqliteNifTest do
  use ExUnit.Case

  alias XqliteNIF, as: NIF

  test "open and close" do
    {:ok, db} = NIF.raw_open(Xqlite.anon_db())
    {:ok, true} = NIF.raw_close(db)
    {:error, {:connection_not_found, _}} = NIF.raw_close(db)
  end
end
