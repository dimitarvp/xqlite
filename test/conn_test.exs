defmodule XqliteConnTest do
  use ExUnit.Case

  alias Xqlite.Conn
  alias XqliteNIF, as: NIF

  test "opening and closing through our wrapper" do
    {:ok, db} = Conn.open(Xqlite.unnamed_memory_db())
    :ok = Conn.close(db)
    {:error, :already_closed} = Conn.close(db)
  end

  test "opening and closing through the NIF" do
    {:ok, db} = NIF.open(Xqlite.unnamed_memory_db(), [])
    :ok = NIF.close(db)
    {:error, :already_closed} = NIF.close(db)
  end
end
