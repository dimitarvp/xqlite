defmodule Xqlite.KeywordElementLawTest do
  @moduledoc """
  An element that does not belong in a keyword parameter list, at every door
  that takes one.

  A parameter list is read as a keyword list when its first element is an
  `{atom, value}` pair, so an element that is not one can only sit at position
  two or later. The law: every such door answers
  `{:error, {:expected_keyword_tuple, %{reason: :bad_element, position: n,
  value_type: type}}}`, naming the one-based position of the element and the
  kind of term it is, and never the caller's own value.

  The same element at position one makes the whole list positional instead, so
  the answer there is the refusal the positional decode gives — which for a
  binary or an integer, both perfectly good positional values, names the pair
  that follows it.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  @sql "SELECT :p1"

  @doors [
    :nif_query,
    :nif_execute,
    :nif_query_with_changes,
    :nif_explain_analyze,
    :nif_stmt_bind,
    :nif_stream_open,
    :nif_query_cancellable,
    :nif_execute_cancellable,
    :nif_query_with_changes_cancellable,
    :bind2,
    :bind3
  ]

  test "the anchor: the refusal names the position and the kind of term" do
    assert {:error,
            {:expected_keyword_tuple, %{reason: :bad_element, position: 2, value_type: :atom}}} =
             NIF.query(fresh_conn(), @sql, [{:p1, 1}, :not_a_tuple])
  end

  test "the anchor: the same element first makes the list positional" do
    assert {:error, {:unsupported_atom, _atom}} =
             NIF.query(fresh_conn(), @sql, [:not_a_tuple, {:p1, 1}])
  end

  test "every keyword-taking door names the position of the bad element" do
    for door <- @doors do
      list = [{:p1, 1}, {:p2, 2}, :not_a_tuple]
      answer = answer(door, list)

      assert {^door,
              {:error,
               {:expected_keyword_tuple,
                %{reason: :bad_element, position: 3, value_type: :atom}}}} = {door, answer}
    end
  end

  property "every door names the position and the kind of the bad element" do
    check all(
            door <- member_of(@doors),
            pairs <- integer(1..6),
            element <- hostile_element(),
            position <- integer(2..(pairs + 1)),
            max_runs: 2000
          ) do
      list = with_element(pairs, element, position)
      answer = answer(door, list)
      type = type_of(element)

      assert {^door,
              {:error,
               {:expected_keyword_tuple,
                %{reason: :bad_element, position: ^position, value_type: ^type}}}} =
               {door, answer}
    end
  end

  property "the same element first is refused by the positional decode" do
    check all(
            door <- member_of(@doors),
            pairs <- integer(1..6),
            element <- hostile_element(),
            max_runs: 2000
          ) do
      list = with_element(pairs, element, 1)

      assert {^door, {:error, {tag, _payload}}} = {door, answer(door, list)}
      assert tag in [:unsupported_atom, :unsupported_data_type]
    end
  end

  defp with_element(pairs, element, position) do
    1..pairs
    |> Enum.map(fn index -> {:"p#{index}", index} end)
    |> List.insert_at(position - 1, element)
  end

  defp hostile_element do
    one_of([
      atom(:alphanumeric),
      tuple({atom(:alphanumeric)}),
      tuple({atom(:alphanumeric), integer(), integer()}),
      tuple({short_binary(), integer()}),
      integer(),
      short_binary(),
      list_of(integer(), max_length: 3)
    ])
  end

  defp short_binary, do: scale(binary(), fn size -> min(size, 8) end)

  defp type_of(term) when is_atom(term), do: :atom
  defp type_of(term) when is_bitstring(term), do: :binary
  defp type_of(term) when is_integer(term), do: :integer
  defp type_of(term) when is_list(term), do: :list
  defp type_of(term) when is_tuple(term), do: :tuple

  defp fresh_conn do
    assert {:ok, conn} = NIF.open_in_memory(":memory:")
    conn
  end

  defp answer(door, list), do: call(door, fresh_conn(), list)

  defp call(:nif_query, conn, list), do: NIF.query(conn, @sql, list)

  defp call(:nif_execute, conn, list), do: NIF.execute(conn, @sql, list)

  defp call(:nif_query_with_changes, conn, list), do: NIF.query_with_changes(conn, @sql, list)

  defp call(:nif_explain_analyze, conn, list), do: NIF.explain_analyze(conn, @sql, list)

  defp call(:nif_stmt_bind, conn, list) do
    assert {:ok, stmt} = NIF.stmt_prepare(conn, @sql)
    NIF.stmt_bind(stmt, list)
  end

  defp call(:nif_stream_open, conn, list), do: NIF.stream_open(conn, @sql, list)

  defp call(:nif_query_cancellable, conn, list),
    do: NIF.query_cancellable(conn, @sql, list, [])

  defp call(:nif_execute_cancellable, conn, list),
    do: NIF.execute_cancellable(conn, @sql, list, [])

  defp call(:nif_query_with_changes_cancellable, conn, list),
    do: NIF.query_with_changes_cancellable(conn, @sql, list, [])

  defp call(:bind2, conn, list) do
    assert {:ok, stmt} = Xqlite.prepare(conn, @sql)
    Xqlite.bind(stmt, list)
  end

  defp call(:bind3, conn, list) do
    assert {:ok, stmt} = Xqlite.prepare(conn, @sql)
    Xqlite.bind(stmt, list, [])
  end
end
