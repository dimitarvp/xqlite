defmodule XqliteConnTest do
  use ExUnit.Case

  alias Xqlite.Conn

  test "open and close" do
    {:ok, db} = Conn.open(Xqlite.anon_db())
    :ok = Conn.close(db)
    {:error, :already_closed} = Conn.close(db)
  end
end
