defmodule Xqlite.StreamColumnNameLawTest do
  @moduledoc """
  A stream row is a map keyed by column name, so two columns of one name
  cannot both be in it: the second value would land under the key the first
  one used, and the first would be gone with nothing said about it.

  The law: `Xqlite.stream/4` opens exactly when the statement's column names
  are all different. Two the same are refused at open, before a row is read,
  and the refusal carries the first name that repeats in SQLite's own order;
  when the names are all different, each row is a map with one key per column
  and every value under its own name. The doors that answer lists —
  `Xqlite.query/4` and the raw stream doors — are untouched and keep both
  values.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  @alphabet ~w(a b c)

  setup do
    assert {:ok, conn} = NIF.open_in_memory(":memory:")

    assert :ok =
             NIF.execute_batch(
               conn,
               "CREATE TABLE ta (v); INSERT INTO ta VALUES (1);" <>
                 "CREATE TABLE tb (v); INSERT INTO tb VALUES (2);"
             )

    on_exit(fn -> NIF.close(conn) end)
    {:ok, conn: conn}
  end

  test "the anchor: a join of two tables sharing a column name is refused at open",
       %{conn: conn} do
    assert {:error, {:duplicate_column_name, "v"}} =
             Xqlite.stream(conn, "SELECT ta.v, tb.v FROM ta, tb")
  end

  test "the same join with aliases streams both values", %{conn: conn} do
    assert [%{"a" => 1, "b" => 2}] =
             conn
             |> Xqlite.stream("SELECT ta.v AS a, tb.v AS b FROM ta, tb")
             |> Enum.to_list()
  end

  test "a statement whose names are all different streams as it always did", %{conn: conn} do
    assert [%{"v" => 1}] =
             conn
             |> Xqlite.stream("SELECT v FROM ta")
             |> Enum.to_list()
  end

  # SQLite names a column that has no name of its own after the text that
  # produced it, so these repeat with no alias in sight.
  test "an expression written twice repeats the name SQLite gives it", %{conn: conn} do
    assert {:error, {:duplicate_column_name, "?"}} =
             Xqlite.stream(conn, "SELECT ?, ?, ?", [1, 2, 3])

    assert {:error, {:duplicate_column_name, "1"}} = Xqlite.stream(conn, "SELECT 1, 1")

    assert {:error, {:duplicate_column_name, "?1"}} = Xqlite.stream(conn, "SELECT ?1, ?1", [1])
  end

  test "the refusal names the first repeat, not a later one", %{conn: conn} do
    assert {:error, {:duplicate_column_name, "b"}} =
             Xqlite.stream(conn, "SELECT 1 AS a, 2 AS b, 3 AS c, 4 AS b, 5 AS c")
  end

  test "the doors that answer lists keep both values", %{conn: conn} do
    sql = "SELECT ta.v, tb.v FROM ta, tb"

    assert {:ok, %{columns: ["v", "v"], rows: [[1, 2]]}} = Xqlite.query(conn, sql)

    assert {:ok, handle} = NIF.stream_open(conn, sql, [])
    assert {:ok, ["v", "v"]} = NIF.stream_get_columns(handle)
    assert {:ok, %{rows: [[1, 2]]}} = NIF.stream_fetch(handle, 10)
    assert :ok = NIF.stream_close(handle)
  end

  test "a refused open leaves the connection ready for the next stream", %{conn: conn} do
    assert {:error, {:duplicate_column_name, "v"}} =
             Xqlite.stream(conn, "SELECT ta.v, tb.v FROM ta, tb")

    assert [%{"a" => 1, "b" => 2}] =
             conn
             |> Xqlite.stream("SELECT ta.v AS a, tb.v AS b FROM ta, tb")
             |> Enum.to_list()

    assert {:ok, handle} = NIF.stream_open(conn, "SELECT ta.v, tb.v FROM ta, tb", [])
    assert :ok = NIF.stream_close(handle)
  end

  property "a statement opens as a stream exactly when its column names differ",
           %{conn: conn} do
    check all(
            names <- list_of(member_of(@alphabet), min_length: 1, max_length: 6),
            max_runs: 2000
          ) do
      sql = select_naming(names)

      case first_repeat(names, MapSet.new()) do
        nil ->
          assert [row] = conn |> Xqlite.stream(sql) |> Enum.to_list()
          assert map_size(row) == length(names)
          assert row == row_of(names)

        name ->
          assert {:error, {:duplicate_column_name, ^name}} = Xqlite.stream(conn, sql)
      end
    end
  end

  defp select_naming(names) do
    columns =
      names
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {name, index} -> "#{index} AS #{name}" end)

    "SELECT " <> columns
  end

  defp row_of(names) do
    names
    |> Enum.with_index(1)
    |> Map.new(fn {name, index} -> {name, index} end)
  end

  defp first_repeat([], _seen), do: nil

  defp first_repeat([name | rest], seen) do
    case MapSet.member?(seen, name) do
      true -> name
      false -> first_repeat(rest, MapSet.put(seen, name))
    end
  end
end
