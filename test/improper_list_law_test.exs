defmodule Xqlite.ImproperListLawTest do
  @moduledoc """
  An improper list — a list whose tail is not a list, like `[1 | 2]` — at
  every door that takes one.

  The law: every such door answers a structured refusal naming the improper
  tail, and no door lets the term reach a decoder that cannot describe it.
  The refusal carries the reason and the type of the term that stopped the
  walk, so a caller can tell "your list has a broken tail" from "that is not
  a list at all".

  Every generated input gets its own connection: a door that fails this law
  does so from inside the connection's lock, which leaves the connection
  unusable for the rest of the process, and a shared one would make every
  later input fail for that reason instead of its own.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  # Each door: the kind of element its list holds, and the tag it refuses
  # with. Nineteen doors — every argument the library reads as a list.
  @doors [
    {:stream_params, :value, :expected_list},
    {:bind2_params, :value, :expected_list},
    {:bind3_params, :value, :expected_list},
    {:set_authorizer, :action, :expected_list},
    {:nif_query_params, :value, :expected_list},
    {:nif_query_keyword, :pair, :expected_keyword_list},
    {:nif_execute_params, :value, :expected_list},
    {:nif_query_with_changes_params, :value, :expected_list},
    {:nif_stmt_bind_params, :value, :expected_list},
    {:nif_stream_open_params, :value, :expected_list},
    {:nif_explain_analyze_params, :value, :expected_list},
    {:nif_query_cancellable_tokens, :token, :expected_list},
    {:nif_execute_cancellable_tokens, :token, :expected_list},
    {:nif_execute_batch_cancellable_tokens, :token, :expected_list},
    {:nif_query_with_changes_cancellable_tokens, :token, :expected_list},
    {:nif_stmt_multi_step_cancellable_tokens, :token, :expected_list},
    {:nif_stream_fetch_cancellable_tokens, :token, :expected_list},
    {:nif_set_authorizer, :action, :expected_list},
    {:nif_backup_with_progress_tokens, :token, :expected_list}
  ]

  test "the anchor: a stream refuses an improper parameter list at open" do
    conn = fresh_conn()

    assert {:error, {:expected_list, %{reason: :improper_tail, value_type: :integer}}} =
             Xqlite.stream(conn, "SELECT ?1", [1 | 2])
  end

  test "the anchor: a proper list of the same values still streams" do
    conn = fresh_conn()

    assert [%{"?1" => 1}] =
             conn
             |> Xqlite.stream("SELECT ?1", [1])
             |> Enum.to_list()
  end

  test "every list-taking door refuses an improper list" do
    for {door, kind, tag} <- @doors do
      list = improper(elements(kind, 2), :tail_atom)
      answer = answer(door, list)

      assert {^door, {:error, {^tag, %{reason: :improper_tail, value_type: :atom}}}} =
               {door, answer}
    end
  end

  property "every list-taking door refuses a generated improper list" do
    check all(
            {door, kind, tag} <- member_of(@doors),
            count <- integer(1..4),
            tail <- tail(),
            max_runs: 2000
          ) do
      list = improper(elements(kind, count), tail)
      answer = answer(door, list)
      type = type_of(tail)

      assert {^door, {:error, {^tag, %{reason: :improper_tail, value_type: ^type}}}} =
               {door, answer}
    end
  end

  property "a term that is no list at all is refused as such" do
    check all(term <- tail(), max_runs: 2000) do
      type = type_of(term)

      assert {:error, {:expected_list, %{reason: :not_a_list, value_type: ^type}}} =
               NIF.query(fresh_conn(), "SELECT ?1", term)
    end
  end

  # `nil` is left out on purpose: it is not a list either, but it is the one
  # non-list term the parameter doors read as "no parameters".
  defp tail do
    [integer(), atom(:alphanumeric), binary(), float(), tuple({integer(), integer()})]
    |> one_of()
    |> scale(fn size -> min(size, 10) end)
    |> filter(fn term -> term != nil end)
  end

  defp type_of(term) when is_integer(term), do: :integer
  defp type_of(term) when is_float(term), do: :float
  defp type_of(term) when is_atom(term), do: :atom
  defp type_of(term) when is_binary(term), do: :binary
  defp type_of(term) when is_tuple(term), do: :tuple

  defp improper(prefix, tail) do
    prefix
    |> Enum.reverse()
    |> Enum.reduce(tail, fn element, acc -> [element | acc] end)
  end

  defp elements(:value, count), do: Enum.to_list(1..count)
  defp elements(:pair, count), do: Enum.map(1..count, fn i -> {:"p#{i}", i} end)
  defp elements(:action, count), do: Enum.map(1..count, fn _i -> :pragma end)

  defp elements(:token, count) do
    Enum.map(1..count, fn _i ->
      {:ok, token} = NIF.create_cancel_token()
      token
    end)
  end

  defp fresh_conn do
    assert {:ok, conn} = NIF.open_in_memory(":memory:")
    conn
  end

  defp answer(door, list), do: call(door, fresh_conn(), list)

  defp call(:stream_params, conn, list), do: Xqlite.stream(conn, "SELECT ?1", list)

  defp call(:bind2_params, conn, list) do
    assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
    Xqlite.bind(stmt, list)
  end

  defp call(:bind3_params, conn, list) do
    assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
    Xqlite.bind(stmt, list, [])
  end

  defp call(:set_authorizer, conn, list), do: Xqlite.set_authorizer(conn, list)

  defp call(:nif_query_params, conn, list), do: NIF.query(conn, "SELECT ?1", list)

  defp call(:nif_query_keyword, conn, list), do: NIF.query(conn, "SELECT :p1", list)

  defp call(:nif_execute_params, conn, list), do: NIF.execute(conn, "SELECT ?1", list)

  defp call(:nif_query_with_changes_params, conn, list),
    do: NIF.query_with_changes(conn, "SELECT ?1", list)

  defp call(:nif_stmt_bind_params, conn, list) do
    assert {:ok, stmt} = NIF.stmt_prepare(conn, "SELECT ?1")
    NIF.stmt_bind(stmt, list)
  end

  defp call(:nif_stream_open_params, conn, list),
    do: NIF.stream_open(conn, "SELECT ?1", list, [])

  defp call(:nif_explain_analyze_params, conn, list),
    do: NIF.explain_analyze(conn, "SELECT ?1", list)

  defp call(:nif_query_cancellable_tokens, conn, list),
    do: NIF.query_cancellable(conn, "SELECT 1", [], list)

  defp call(:nif_execute_cancellable_tokens, conn, list),
    do: NIF.execute_cancellable(conn, "SELECT 1", [], list)

  defp call(:nif_execute_batch_cancellable_tokens, conn, list),
    do: NIF.execute_batch_cancellable(conn, "SELECT 1;", list)

  defp call(:nif_query_with_changes_cancellable_tokens, conn, list),
    do: NIF.query_with_changes_cancellable(conn, "SELECT 1", [], list)

  defp call(:nif_stmt_multi_step_cancellable_tokens, conn, list) do
    assert {:ok, stmt} = NIF.stmt_prepare(conn, "SELECT 1")
    NIF.stmt_multi_step_cancellable(stmt, 1, list)
  end

  defp call(:nif_stream_fetch_cancellable_tokens, conn, list) do
    assert {:ok, stream} = NIF.stream_open(conn, "SELECT 1", [], [])
    NIF.stream_fetch_cancellable(stream, 1, list)
  end

  defp call(:nif_set_authorizer, conn, list), do: NIF.set_authorizer(conn, list)

  defp call(:nif_backup_with_progress_tokens, conn, list) do
    dest = Path.join(System.tmp_dir!(), "xqlite_improper_list_backup_never_written.db")
    NIF.backup_with_progress(conn, "main", dest, self(), 1, list)
  end
end
