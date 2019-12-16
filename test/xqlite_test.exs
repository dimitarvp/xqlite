defmodule XqliteTest do
  use ExUnit.Case
  doctest Xqlite

  test "open and close" do
    {:ok, db} = Xqlite.open(Xqlite.unnamed_memory_db())
    :ok = Xqlite.close(db)
  end
end
