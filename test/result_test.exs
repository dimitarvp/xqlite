defmodule Xqlite.ResultTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias Xqlite.Result
  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "Result using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER);
          INSERT INTO users VALUES (1, 'Alice', 30);
          INSERT INTO users VALUES (2, 'Bob', 25);
          INSERT INTO users VALUES (3, 'Carol', 35);
          """)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "from_map/1 converts a NIF query result map", %{conn: conn} do
        {:ok, map} = NIF.query(conn, "SELECT id, name FROM users ORDER BY id", [])
        result = Result.from_map(map)

        assert %Result{} = result
        assert result.columns == ["id", "name"]
        assert result.rows == [[1, "Alice"], [2, "Bob"], [3, "Carol"]]
        assert result.num_rows == 3
      end

      test "from_map/1 handles empty result set", %{conn: conn} do
        {:ok, map} = NIF.query(conn, "SELECT id FROM users WHERE id = 999", [])
        result = Result.from_map(map)

        assert result.columns == ["id"]
        assert result.rows == []
        assert result.num_rows == 0
      end

      test "Table.Reader returns rows with metadata", %{conn: conn} do
        {:ok, map} = NIF.query(conn, "SELECT id, name FROM users ORDER BY id", [])
        result = Result.from_map(map)

        assert {:rows, metadata, rows} = Table.Reader.init(result)
        assert metadata.columns == ["id", "name"]
        assert metadata.count == 3
        assert Enum.to_list(rows) == [[1, "Alice"], [2, "Bob"], [3, "Carol"]]
      end

      test "Table.to_rows/1 returns string-keyed maps", %{conn: conn} do
        {:ok, map} = NIF.query(conn, "SELECT id, name FROM users ORDER BY id", [])
        result = Result.from_map(map)

        assert Enum.to_list(Table.to_rows(result)) == [
                 %{"id" => 1, "name" => "Alice"},
                 %{"id" => 2, "name" => "Bob"},
                 %{"id" => 3, "name" => "Carol"}
               ]
      end

      test "Table.to_columns/1 returns column-oriented data", %{conn: conn} do
        {:ok, map} = NIF.query(conn, "SELECT id, name FROM users ORDER BY id", [])
        result = Result.from_map(map)

        assert Table.to_columns(result) == %{
                 "id" => [1, 2, 3],
                 "name" => ["Alice", "Bob", "Carol"]
               }
      end

      test "preserves SQLite value types through Table.Reader", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE types (i INTEGER, f REAL, t TEXT, b BLOB, n);
          INSERT INTO types VALUES (42, 3.14, 'hello', X'DEADBEEF', NULL);
          """)

        {:ok, map} = NIF.query(conn, "SELECT * FROM types", [])

        [row] =
          map
          |> Result.from_map()
          |> Table.to_rows()
          |> Enum.to_list()

        assert row["i"] == 42
        assert row["f"] == 3.14
        assert row["t"] == "hello"
        assert row["b"] == <<0xDE, 0xAD, 0xBE, 0xEF>>
        assert row["n"] == nil
      end
    end
  end

  test "Table.Reader with empty struct" do
    result = %Result{columns: ["a", "b"], rows: [], num_rows: 0}

    assert {:rows, metadata, rows} = Table.Reader.init(result)
    assert metadata.columns == ["a", "b"]
    assert metadata.count == 0
    assert Enum.to_list(rows) == []
    assert Table.to_columns(result) == %{"a" => [], "b" => []}
  end
end
