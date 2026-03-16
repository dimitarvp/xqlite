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

  test "from_map/1 defaults changes to 0" do
    result = Result.from_map(%{columns: ["x"], rows: [[1]], num_rows: 1})
    assert result.changes == 0
  end

  test "from_map/1 preserves changes when present" do
    result = Result.from_map(%{columns: [], rows: [], num_rows: 0, changes: 5})
    assert result.changes == 5
  end

  for {type_tag, prefix, _opener_mfa} <- Xqlite.TestUtil.connection_openers() do
    describe "Xqlite.query/3 using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = Xqlite.TestUtil.find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE hq (id INTEGER PRIMARY KEY, val TEXT);
          INSERT INTO hq VALUES (1, 'a');
          INSERT INTO hq VALUES (2, 'b');
          """)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "SELECT returns Result with rows", %{conn: conn} do
        assert {:ok, %Result{} = result} =
                 Xqlite.query(conn, "SELECT * FROM hq ORDER BY id", [])

        assert result.columns == ["id", "val"]
        assert result.rows == [[1, "a"], [2, "b"]]
        assert result.num_rows == 2
      end

      test "INSERT via query returns Result with changes", %{conn: conn} do
        assert {:ok, %Result{} = result} =
                 Xqlite.query(conn, "INSERT INTO hq VALUES (3, 'c')", [])

        assert result.columns == []
        assert result.rows == []
        assert result.num_rows == 0
        assert result.changes == 1
      end

      test "UPDATE via query returns affected count in changes", %{conn: conn} do
        assert {:ok, %Result{} = result} =
                 Xqlite.query(conn, "UPDATE hq SET val = 'x'", [])

        assert result.changes == 2
      end

      test "DELETE via query returns affected count in changes", %{conn: conn} do
        assert {:ok, %Result{} = result} =
                 Xqlite.query(conn, "DELETE FROM hq WHERE id = 1", [])

        assert result.changes == 1
      end
    end

    describe "Xqlite.execute/3 using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = Xqlite.TestUtil.find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE he (id INTEGER PRIMARY KEY, val TEXT);
          INSERT INTO he VALUES (1, 'a');
          INSERT INTO he VALUES (2, 'b');
          """)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "INSERT returns Result with changes", %{conn: conn} do
        assert {:ok, %Result{} = result} =
                 Xqlite.execute(conn, "INSERT INTO he VALUES (3, 'c')", [])

        assert result.changes == 1
        assert result.columns == []
        assert result.rows == []
      end

      test "UPDATE returns affected count", %{conn: conn} do
        assert {:ok, %Result{changes: 2}} =
                 Xqlite.execute(conn, "UPDATE he SET val = 'x'", [])
      end

      test "DDL returns Result", %{conn: conn} do
        assert {:ok, %Result{columns: [], rows: []}} =
                 Xqlite.execute(conn, "CREATE TABLE he2 (id INTEGER PRIMARY KEY)", [])
      end
    end
  end
end
