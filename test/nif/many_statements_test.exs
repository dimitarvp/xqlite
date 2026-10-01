defmodule Xqlite.NIF.ManyStatementsTest do
  @moduledoc "Its own file: if execute/3 crashes on many statements, only this OS process dies."

  use ExUnit.Case, async: true

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  for_each_opener do
    test "execute/3 rejects 100 000 statements and the connection still answers", %{conn: conn} do
      sql = String.duplicate("SELECT 1;", 100_000)
      assert {:error, :multiple_statements} = NIF.execute(conn, sql, [])
      assert {:ok, %{rows: [[1]]}} = NIF.query(conn, "SELECT 1", [])
    end
  end
end
