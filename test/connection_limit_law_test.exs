defmodule Xqlite.ConnectionLimitLawTest do
  @moduledoc """
  `Xqlite.get_limit/2` reads and `Xqlite.put_limit/3` sets one of SQLite's
  thirteen per-connection limits; a write answers the value now in force.

  The law: for a category and a value between 0 and 2^31-1, the value that
  takes effect is the one asked for, clamped down to the category's own
  compile-time ceiling and up to its floor — 30 for `:length`, which is the
  only category with one — and the write and the next read both answer it.
  The ceiling is SQLite's own answer to a write of 2^31-1.

  Outside that domain the write is refused rather than clamped, before the
  category is looked at, and the limit stays. An
  atom naming none of the thirteen answers
  `{:error, {:invalid_limit_category, _}}`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise
  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  @categories [
    :length,
    :sql_length,
    :column,
    :expr_depth,
    :compound_select,
    :vdbe_op,
    :function_arg,
    :attached,
    :like_pattern_length,
    :variable_number,
    :trigger_depth,
    :worker_threads,
    :parser_depth
  ]

  @length_floor 30
  @highest_value 2_147_483_647

  for_each_opener "a connection limit" do
    test "the anchor: every category reads a value of its own", %{conn: conn} do
      for category <- @categories do
        assert {:ok, value} = Xqlite.get_limit(conn, category)
        assert is_integer(value)
        assert value >= 0
      end
    end

    test "the anchor: a write answers the value now in force, the floor included",
         %{conn: conn} do
      assert {:ok, 100} = Xqlite.put_limit(conn, :length, 100)
      assert {:ok, 100} = Xqlite.get_limit(conn, :length)
      assert {:ok, @length_floor} = Xqlite.put_limit(conn, :length, 0)
    end

    test "the anchor: a value outside the domain is refused before the category",
         %{conn: conn} do
      for value <- [-1, 2_147_483_648, 1 <<< 64] do
        assert {:error, {:invalid_limit_value, %{category: :page_size, value: ^value}}} =
                 Xqlite.put_limit(conn, :page_size, value)
      end

      assert {:error, {:invalid_limit_value, %{category: :page_size, value: -1}}} =
               NIF.put_limit(conn, :page_size, -1)
    end

    test "an atom naming no category is refused", %{conn: conn} do
      assert {:error, {:invalid_limit_category, :page_size}} =
               Xqlite.get_limit(conn, :page_size)

      assert {:error, {:invalid_limit_category, :page_size}} =
               Xqlite.put_limit(conn, :page_size, 1)
    end

    test "a term of the wrong kind is refused at the typed door", %{conn: conn} do
      # Through apply/3, so that the terms of the wrong kind are the test's
      # subject rather than something the compiler judges at the call site.
      assert_raise FunctionClauseError, fn -> apply(Xqlite, :get_limit, [conn, "length"]) end

      assert_raise FunctionClauseError, fn ->
        apply(Xqlite, :put_limit, [conn, :column, 1.5])
      end

      assert_raise ArgumentError, fn -> apply(NIF, :put_limit, [conn, :length, 1.5]) end
      assert_raise ArgumentError, fn -> apply(NIF, :put_limit, [conn, :length, 1 <<< 64]) end
    end

    property "a write answers the value SQLite keeps, and the next read agrees",
             %{conn: conn} do
      check all(
              category <- member_of(@categories),
              drawn <- one_of([integer(0..64), integer(0..@highest_value)]),
              offset <- frequency([{2, constant(nil)}, {1, member_of([-1, 0, 1])}]),
              max_runs: 2000
            ) do
        assert {:ok, ceiling} = Xqlite.put_limit(conn, category, @highest_value)
        value = if offset, do: (ceiling + offset) |> max(0) |> min(@highest_value), else: drawn
        kept = value |> min(ceiling) |> max(floor_for(category))

        assert {:ok, ^kept} = Xqlite.put_limit(conn, category, value)
        assert {:ok, ^kept} = Xqlite.get_limit(conn, category)
      end
    end

    property "a value outside 0..2^31-1 is refused and the limit stays", %{conn: conn} do
      check all(
              category <- member_of(@categories),
              value <- refused_value(),
              max_runs: 2000
            ) do
        assert {:ok, before} = Xqlite.get_limit(conn, category)

        assert {:error, {:invalid_limit_value, %{category: ^category, value: ^value}}} =
                 Xqlite.put_limit(conn, category, value)

        assert {:ok, ^before} = Xqlite.get_limit(conn, category)
      end
    end
  end

  defp refused_value do
    one_of([
      integer(-(1 <<< 70)..-1),
      integer((@highest_value + 1)..((1 <<< 63) - 1)),
      integer((1 <<< 63)..(1 <<< 70))
    ])
  end

  defp floor_for(:length), do: @length_floor
  defp floor_for(_category), do: 0
end
