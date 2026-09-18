defmodule Xqlite.ConnectionLimitLawTest do
  @moduledoc """
  `Xqlite.limit/3` reads and sets one of SQLite's thirteen per-connection
  limits, and always answers the value that was in force before the call.

  The law: for a category and a value between 0 and 2^31-1, the value that
  takes effect is the one asked for, clamped down to the category's own
  compile-time ceiling and up to its floor — 30 for `:length`, which is the
  only category with one — and the number the call answers is whatever was in
  force before it. A `new_value` of -1 reads without setting.

  Outside that domain the call is refused rather than clamped: a value below
  -1 or above 2^31-1 answers `{:error, {:invalid_limit_value, _}}`, and an
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
        assert {:ok, value} = Xqlite.limit(conn, category, -1)
        assert is_integer(value)
        assert value >= 0
      end
    end

    test "the anchor: a set answers the value it displaced", %{conn: conn} do
      assert {:ok, before} = Xqlite.limit(conn, :length, -1)
      assert {:ok, ^before} = Xqlite.limit(conn, :length, 100)
      assert {:ok, 100} = Xqlite.limit(conn, :length, -1)
      assert {:ok, 100} = Xqlite.limit(conn, :length, 200)
    end

    test "a value above the ceiling reads back as the ceiling", %{conn: conn} do
      assert {:ok, _previous} = Xqlite.limit(conn, :length, @highest_value)
      assert {:ok, ceiling} = Xqlite.limit(conn, :length, -1)
      assert ceiling < @highest_value
    end

    test "a length below the floor reads back as the floor", %{conn: conn} do
      assert {:ok, _previous} = Xqlite.limit(conn, :length, 0)
      assert {:ok, @length_floor} = Xqlite.limit(conn, :length, -1)
    end

    test "a value outside the domain is refused, not clamped", %{conn: conn} do
      assert {:error, {:invalid_limit_value, %{category: :length, value: -2}}} =
               Xqlite.limit(conn, :length, -2)

      assert {:error, {:invalid_limit_value, %{category: :length, value: 2_147_483_648}}} =
               Xqlite.limit(conn, :length, 2_147_483_648)
    end

    test "an atom naming no category is refused", %{conn: conn} do
      assert {:error, {:invalid_limit_category, :page_size}} =
               Xqlite.limit(conn, :page_size, -1)
    end

    test "a term of the wrong kind is refused at the typed door", %{conn: conn} do
      # Through apply/3, so that the terms of the wrong kind are the test's
      # subject rather than something the compiler judges at the call site.
      assert_raise FunctionClauseError, fn -> apply(Xqlite, :limit, [conn, "length", -1]) end
      assert_raise FunctionClauseError, fn -> apply(Xqlite, :limit, [conn, :length, 1.5]) end
      assert_raise ArgumentError, fn -> apply(NIF, :limit, [conn, :length, 1.5]) end
      assert_raise ArgumentError, fn -> apply(NIF, :limit, [conn, :length, 1 <<< 64]) end
    end

    property "a set takes effect clamped, and answers what it displaced",
             %{conn: conn} do
      check all(
              category <- member_of(@categories),
              value <- integer(0..@highest_value),
              max_runs: 2000
            ) do
        assert {:ok, _displaced} = Xqlite.limit(conn, category, @highest_value)
        assert {:ok, ceiling} = Xqlite.limit(conn, category, value)
        assert {:ok, effective} = Xqlite.limit(conn, category, -1)

        assert effective == clamped(category, value, ceiling)
      end
    end
  end

  defp clamped(category, value, ceiling) do
    value
    |> min(ceiling)
    |> max(floor_for(category))
  end

  defp floor_for(:length), do: @length_floor
  defp floor_for(_category), do: 0
end
