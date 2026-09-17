defmodule Xqlite.SqliteValueLawTest do
  @moduledoc """
  The two value types, one per direction.

  `Xqlite.sqlite_value/0` says what a result row holds, `Xqlite.param_value/0`
  what the binder takes. They differ in both directions: a REAL that is not
  finite reads back as `:positive_infinity` or `:negative_infinity` and
  neither atom can be bound, while `%Xqlite.Blob{}` is a parameter form no
  row ever carries.

  The first two tests read the unions out of the compiled typespec, so a
  member added or dropped fails here. The property then drives generated
  values and the three SQL forms of a non-finite REAL through every read
  path and checks each cell against the row union's members.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteNIF, as: NIF

  setup do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    on_exit(fn -> NIF.close(conn) end)
    {:ok, conn: conn}
  end

  test "the row union holds exactly what a row can hold" do
    assert union_members(:sqlite_value) ==
             Enum.sort([
               :integer,
               :float,
               :binary,
               :positive_infinity,
               :negative_infinity,
               nil
             ])
  end

  test "the parameter union holds exactly what the binder takes" do
    assert union_members(:param_value) ==
             Enum.sort([:integer, :float, :binary, :boolean, nil, {Xqlite.Blob, :t}])
  end

  test "neither sentinel atom can be bound as a parameter", %{conn: conn} do
    assert {:error, {:unsupported_atom, "positive_infinity"}} =
             NIF.query(conn, "SELECT ?1", [:positive_infinity])

    assert {:error, {:unsupported_atom, "negative_infinity"}} =
             NIF.query(conn, "SELECT ?1", [:negative_infinity])
  end

  property "every cell of every read path is a member of the row union", %{conn: conn} do
    members = union_members(:sqlite_value)

    check all({sql, params} <- cell_source(), max_runs: 2000) do
      assert Enum.all?(queried_cells(conn, sql, params), &member?(&1, members))
      assert Enum.all?(stepped_cells(conn, sql, params), &member?(&1, members))
      assert Enum.all?(streamed_cells(conn, sql, params), &member?(&1, members))
    end
  end

  defp queried_cells(conn, sql, params) do
    assert {:ok, %{rows: rows}} = NIF.query(conn, sql, params)
    Enum.concat(rows)
  end

  defp stepped_cells(conn, sql, params) do
    assert {:ok, stmt} = Xqlite.prepare(conn, sql)
    assert :ok = Xqlite.bind(stmt, params)
    assert {:row, row} = Xqlite.step(stmt)
    assert :ok = Xqlite.finalize(stmt)
    row
  end

  defp streamed_cells(conn, sql, params) do
    conn
    |> Xqlite.stream(sql, params)
    |> Enum.flat_map(&Map.values/1)
  end

  # The predicate is the union itself: a scalar stands for its type name, and
  # anything else stands for itself, which is how the two atoms and `nil` are
  # written in the union.
  defp member?(value, members), do: kind(value) in members

  defp kind(value) when is_integer(value), do: :integer
  defp kind(value) when is_float(value), do: :float
  defp kind(value) when is_binary(value), do: :binary
  defp kind(value), do: value

  # A bound scalar, or one of the three SQL forms that produce a REAL which is
  # not finite: SQLite overflows both literals and answers NULL for the NaN.
  defp cell_source do
    StreamData.one_of([
      StreamData.map(scalar(), fn value -> {"SELECT ?1", [value]} end),
      StreamData.member_of([
        {"SELECT 1e999", []},
        {"SELECT -1e999", []},
        {"SELECT 1e999 - 1e999", []}
      ])
    ])
  end

  defp scalar do
    StreamData.one_of([
      StreamData.integer(),
      StreamData.member_of([
        0,
        -1,
        4_294_967_296,
        9_223_372_036_854_775_807,
        -9_223_372_036_854_775_808
      ]),
      StreamData.scale(StreamData.float(), fn size -> min(size, 20) end),
      StreamData.scale(StreamData.binary(), fn size -> min(size, 32) end),
      StreamData.member_of([
        "",
        <<0>>,
        <<0, 1, 0xFF, 0xFE>>,
        <<0xC3, 0x28>>,
        "a\0b",
        ~s|"quoted"|
      ]),
      StreamData.constant(nil)
    ])
  end

  defp union_members(name) do
    assert {:ok, types} = Code.Typespec.fetch_types(Xqlite)
    assert {:type, {^name, form, []}} = Enum.find(types, &named?(&1, name))
    assert {:type, _line, :union, alternatives} = form

    alternatives
    |> Enum.map(&member_name/1)
    |> Enum.sort()
  end

  defp named?({:type, {name, _form, _args}}, name), do: true
  defp named?(_entry, _name), do: false

  defp member_name({:type, _line, kind, []}), do: kind
  defp member_name({:atom, _line, value}), do: value

  defp member_name({:remote_type, _line, [{:atom, _, module}, {:atom, _, type}, []]}),
    do: {module, type}

  defp member_name(other), do: other
end
