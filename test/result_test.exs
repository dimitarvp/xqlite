defmodule Xqlite.ResultTest do
  use ExUnit.Case, async: true

  alias Xqlite.Result
  alias XqliteNIF, as: NIF

  setup do
    {:ok, conn} = NIF.open_in_memory()

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

  describe "from_map/1" do
    test "converts a NIF query result map", %{conn: conn} do
      {:ok, map} = NIF.query(conn, "SELECT id, name FROM users ORDER BY id", [])
      result = Result.from_map(map)

      assert %Result{} = result
      assert result.columns == ["id", "name"]
      assert result.rows == [[1, "Alice"], [2, "Bob"], [3, "Carol"]]
      assert result.num_rows == 3
    end

    test "handles empty result set", %{conn: conn} do
      {:ok, map} = NIF.query(conn, "SELECT id FROM users WHERE id = 999", [])
      result = Result.from_map(map)

      assert result.columns == ["id"]
      assert result.rows == []
      assert result.num_rows == 0
    end
  end

  describe "Table.Reader protocol" do
    test "returns rows with metadata", %{conn: conn} do
      {:ok, map} = NIF.query(conn, "SELECT id, name FROM users ORDER BY id", [])
      result = Result.from_map(map)

      assert {:rows, metadata, rows} = Table.Reader.init(result)
      assert metadata.columns == ["id", "name"]
      assert metadata.count == 3
      assert Enum.to_list(rows) == [[1, "Alice"], [2, "Bob"], [3, "Carol"]]
    end

    test "works with empty results" do
      result = %Result{columns: ["x"], rows: [], num_rows: 0}

      assert {:rows, metadata, rows} = Table.Reader.init(result)
      assert metadata.columns == ["x"]
      assert metadata.count == 0
      assert Enum.to_list(rows) == []
    end

    test "works with Table.to_rows/1", %{conn: conn} do
      {:ok, map} = NIF.query(conn, "SELECT id, name FROM users ORDER BY id", [])
      result = Result.from_map(map)

      rows = Table.to_rows(result)

      assert Enum.to_list(rows) == [
               %{"id" => 1, "name" => "Alice"},
               %{"id" => 2, "name" => "Bob"},
               %{"id" => 3, "name" => "Carol"}
             ]
    end

    test "works with Table.to_columns/1", %{conn: conn} do
      {:ok, map} = NIF.query(conn, "SELECT id, name FROM users ORDER BY id", [])
      result = Result.from_map(map)

      columns = Table.to_columns(result)

      assert columns == %{
               "id" => [1, 2, 3],
               "name" => ["Alice", "Bob", "Carol"]
             }
    end

    test "Table.to_rows/1 with single column", %{conn: conn} do
      {:ok, map} = NIF.query(conn, "SELECT name FROM users ORDER BY id", [])
      result = Result.from_map(map)

      rows = Table.to_rows(result)

      assert Enum.to_list(rows) == [
               %{"name" => "Alice"},
               %{"name" => "Bob"},
               %{"name" => "Carol"}
             ]
    end

    test "Table.to_columns/1 with empty result" do
      result = %Result{columns: ["a", "b"], rows: [], num_rows: 0}
      assert Table.to_columns(result) == %{"a" => [], "b" => []}
    end

    test "preserves SQLite value types through Table.Reader", %{conn: conn} do
      :ok =
        NIF.execute_batch(conn, """
        CREATE TABLE types (i INTEGER, f REAL, t TEXT, b BLOB, n);
        INSERT INTO types VALUES (42, 3.14, 'hello', X'DEADBEEF', NULL);
        """)

      {:ok, map} = NIF.query(conn, "SELECT * FROM types", [])
      result = Result.from_map(map)

      [row] =
        result
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
