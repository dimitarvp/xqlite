defmodule XqliteTest do
  use ExUnit.Case
  doctest Xqlite

  test "open and close" do
    {:ok, db} = Xqlite.open(":memory:")
    :ok = Xqlite.close(db)
  end
end
