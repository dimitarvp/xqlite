defmodule XqliteNifTest do
  use ExUnit.Case

  alias XqliteNIF, as: NIF

  test "open and close" do
    {:ok, db} = NIF.open(Xqlite.anon_db(), [])
    :ok = NIF.close(db)
    {:error, :already_closed} = NIF.close(db)
  end
end
