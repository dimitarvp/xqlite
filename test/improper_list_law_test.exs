defmodule Xqlite.ImproperListLawTest do
  @moduledoc """
  An improper list — a list whose tail is not a list, like `[1 | 2]` — at
  every door that takes one.

  The law: every such door answers a structured refusal naming the improper
  tail, and no door lets the term reach a decoder that cannot describe it.
  The refusal carries the reason and the type of the term that stopped the
  walk, so a caller can tell "your list has a broken tail" from "that is not
  a list at all".

  A parameter door is driven twice, once with a type extension on and once
  without, because the two settings walk the list in different places: with
  no extension the term travels untouched to the native walk, and with one
  the encode chain walks it in Elixir first. The answer has to be the same.

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
  # with. Every argument the library reads as a list. A token list is named
  # by its own tag on both sides of the door, so `:expected_list` on a
  # cancellable call is always about its parameters.
  @doors [
    {:stream_params, :value, :expected_list},
    {:stream_keyword, :pair, :expected_keyword_list},
    {:bind2_params, :value, :expected_list},
    {:bind2_keyword, :pair, :expected_keyword_list},
    {:bind3_params, :value, :expected_list},
    {:bind3_keyword, :pair, :expected_keyword_list},
    {:set_authorizer, :action, :expected_list},
    {:query_params, :value, :expected_list},
    {:query_keyword, :pair, :expected_keyword_list},
    {:execute_params, :value, :expected_list},
    {:execute_keyword, :pair, :expected_keyword_list},
    {:explain_analyze_params, :value, :expected_list},
    {:explain_analyze_keyword, :pair, :expected_keyword_list},
    {:query_cancellable_params, :value, :expected_list},
    {:query_cancellable_keyword, :pair, :expected_keyword_list},
    {:execute_cancellable_params, :value, :expected_list},
    {:execute_cancellable_keyword, :pair, :expected_keyword_list},
    {:query_with_changes_cancellable_params, :value, :expected_list},
    {:query_with_changes_cancellable_keyword, :pair, :expected_keyword_list},
    {:nif_query_params, :value, :expected_list},
    {:nif_query_keyword, :pair, :expected_keyword_list},
    {:nif_execute_params, :value, :expected_list},
    {:nif_execute_keyword, :pair, :expected_keyword_list},
    {:nif_query_with_changes_params, :value, :expected_list},
    {:nif_query_with_changes_keyword, :pair, :expected_keyword_list},
    {:nif_stmt_bind_params, :value, :expected_list},
    {:nif_stmt_bind_keyword, :pair, :expected_keyword_list},
    {:nif_stream_open_params, :value, :expected_list},
    {:nif_stream_open_keyword, :pair, :expected_keyword_list},
    {:nif_explain_analyze_params, :value, :expected_list},
    {:nif_explain_analyze_keyword, :pair, :expected_keyword_list},
    {:nif_query_cancellable_tokens, :token, :invalid_cancel_tokens},
    {:nif_execute_cancellable_tokens, :token, :invalid_cancel_tokens},
    {:nif_execute_batch_cancellable_tokens, :token, :invalid_cancel_tokens},
    {:nif_query_with_changes_cancellable_tokens, :token, :invalid_cancel_tokens},
    {:nif_stmt_multi_step_cancellable_tokens, :token, :invalid_cancel_tokens},
    {:nif_stream_fetch_cancellable_tokens, :token, :invalid_cancel_tokens},
    {:nif_set_authorizer, :action, :expected_list},
    {:nif_backup_with_progress_tokens, :token, :invalid_cancel_tokens},
    {:query_type_extensions, :extension, :invalid_type_extensions},
    {:execute_type_extensions, :extension, :invalid_type_extensions},
    {:explain_analyze_type_extensions, :extension, :invalid_type_extensions},
    {:bind_type_extensions, :extension, :invalid_type_extensions},
    {:stream_type_extensions, :extension, :invalid_type_extensions},
    {:query_cancellable_type_extensions, :extension, :invalid_type_extensions},
    {:execute_cancellable_type_extensions, :extension, :invalid_type_extensions},
    {:query_with_changes_cancellable_type_extensions, :extension, :invalid_type_extensions},
    {:stream_params_extension, :value, :expected_list},
    {:stream_keyword_extension, :pair, :expected_keyword_list},
    {:bind_params_extension, :value, :expected_list},
    {:bind_keyword_extension, :pair, :expected_keyword_list},
    {:query_params_extension, :value, :expected_list},
    {:query_keyword_extension, :pair, :expected_keyword_list},
    {:execute_params_extension, :value, :expected_list},
    {:execute_keyword_extension, :pair, :expected_keyword_list},
    {:explain_analyze_params_extension, :value, :expected_list},
    {:explain_analyze_keyword_extension, :pair, :expected_keyword_list},
    {:query_cancellable_params_extension, :value, :expected_list},
    {:query_cancellable_keyword_extension, :pair, :expected_keyword_list},
    {:execute_cancellable_params_extension, :value, :expected_list},
    {:execute_cancellable_keyword_extension, :pair, :expected_keyword_list},
    {:query_with_changes_cancellable_params_extension, :value, :expected_list},
    {:query_with_changes_cancellable_keyword_extension, :pair, :expected_keyword_list}
  ]

  @extension_opts [type_extensions: [Xqlite.TypeExtension.JSON]]

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

  # `nil` is the one non-list term every parameter door reads as "no
  # parameters at all", so it is the exception the law above leaves out.
  test "nil binds nothing on every parameter door" do
    conn = fresh_conn()

    assert {:ok, %{rows: [[1]]}} = NIF.query(conn, "SELECT 1", nil)
    assert {:error, :execute_returned_results} = NIF.execute(conn, "SELECT 1", nil)
    assert {:ok, %{rows: [[1]]}} = NIF.query_with_changes(conn, "SELECT 1", nil)
    assert {:ok, _report} = NIF.explain_analyze(conn, "SELECT 1", nil)
    assert {:ok, _stream} = NIF.stream_open(conn, "SELECT 1", nil)

    assert {:ok, stmt} = NIF.stmt_prepare(conn, "SELECT 1")
    assert :ok = NIF.stmt_bind(stmt, nil)
    assert {:row, [1]} = NIF.stmt_step(stmt)
  end

  # `nil` means no parameters, so a statement that has one is a count
  # mismatch, exactly as an empty list is.
  test "nil on a one-parameter statement is a count mismatch" do
    conn = fresh_conn()

    assert {:ok, stmt} = NIF.stmt_prepare(conn, "SELECT ?1")

    assert {:error, {:invalid_parameter_count, %{expected: 1, provided: 0}}} =
             NIF.stmt_bind(stmt, nil)

    assert :ok = NIF.stmt_finalize(stmt)
  end

  property "a term that is no list at all is refused as such" do
    check all(term <- tail(), max_runs: 2000) do
      type = type_of(term)

      for {door, answer} <- not_a_list_answers(term) do
        assert {^door, {:error, {:expected_list, %{reason: :not_a_list, value_type: ^type}}}} =
                 {door, answer}
      end
    end
  end

  # The raw door, the typed statement door at both arities, and two doors with
  # a type extension on, which walks the term in Elixir before the native side
  # is reached.
  defp not_a_list_answers(term) do
    conn = fresh_conn()
    assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")

    [
      {:nif_query, NIF.query(conn, "SELECT ?1", term)},
      {:bind2, Xqlite.bind(stmt, term)},
      {:bind3, Xqlite.bind(stmt, term, [])},
      {:bind3_extension, Xqlite.bind(stmt, term, @extension_opts)},
      {:query_extension, Xqlite.query(conn, "SELECT ?1", term, @extension_opts)}
    ]
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

  defp elements(:extension, count),
    do: Enum.map(1..count, fn _i -> Xqlite.TypeExtension.JSON end)

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

  defp new_token do
    assert {:ok, token} = Xqlite.create_cancel_token()
    token
  end

  # `execute/4` refuses a statement that returns rows, so its door writes one.
  defp insert_sql(conn, placeholder) do
    assert :ok = NIF.execute_batch(conn, "CREATE TABLE improper_rows (v)")
    "INSERT INTO improper_rows (v) VALUES (#{placeholder})"
  end

  defp answer(door, list), do: call(door, fresh_conn(), list)

  defp call(:stream_params, conn, list), do: Xqlite.stream(conn, "SELECT ?1", list)

  defp call(:stream_keyword, conn, list), do: Xqlite.stream(conn, "SELECT :p1", list)

  defp call(:bind2_params, conn, list) do
    assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
    Xqlite.bind(stmt, list)
  end

  defp call(:bind2_keyword, conn, list) do
    assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT :p1")
    Xqlite.bind(stmt, list)
  end

  defp call(:bind3_params, conn, list) do
    assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
    Xqlite.bind(stmt, list, [])
  end

  defp call(:bind3_keyword, conn, list) do
    assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT :p1")
    Xqlite.bind(stmt, list, [])
  end

  defp call(:set_authorizer, conn, list), do: Xqlite.set_authorizer(conn, list)

  defp call(:query_params, conn, list), do: Xqlite.query(conn, "SELECT ?1", list)

  defp call(:query_keyword, conn, list), do: Xqlite.query(conn, "SELECT :p1", list)

  defp call(:execute_params, conn, list),
    do: Xqlite.execute(conn, insert_sql(conn, "?1"), list)

  defp call(:execute_keyword, conn, list),
    do: Xqlite.execute(conn, insert_sql(conn, ":p1"), list)

  defp call(:explain_analyze_params, conn, list),
    do: Xqlite.explain_analyze(conn, "SELECT ?1", list)

  defp call(:explain_analyze_keyword, conn, list),
    do: Xqlite.explain_analyze(conn, "SELECT :p1", list)

  defp call(:query_cancellable_params, conn, list),
    do: Xqlite.query_cancellable(conn, "SELECT ?1", list, new_token())

  defp call(:query_cancellable_keyword, conn, list),
    do: Xqlite.query_cancellable(conn, "SELECT :p1", list, new_token())

  defp call(:execute_cancellable_params, conn, list),
    do: Xqlite.execute_cancellable(conn, insert_sql(conn, "?1"), list, new_token())

  defp call(:execute_cancellable_keyword, conn, list),
    do: Xqlite.execute_cancellable(conn, insert_sql(conn, ":p1"), list, new_token())

  defp call(:query_with_changes_cancellable_params, conn, list),
    do: Xqlite.query_with_changes_cancellable(conn, "SELECT ?1", list, new_token())

  defp call(:query_with_changes_cancellable_keyword, conn, list),
    do: Xqlite.query_with_changes_cancellable(conn, "SELECT :p1", list, new_token())

  defp call(:nif_query_params, conn, list), do: NIF.query(conn, "SELECT ?1", list)

  defp call(:nif_query_keyword, conn, list), do: NIF.query(conn, "SELECT :p1", list)

  defp call(:nif_execute_params, conn, list), do: NIF.execute(conn, "SELECT ?1", list)

  defp call(:nif_execute_keyword, conn, list), do: NIF.execute(conn, "SELECT :p1", list)

  defp call(:nif_query_with_changes_params, conn, list),
    do: NIF.query_with_changes(conn, "SELECT ?1", list)

  defp call(:nif_query_with_changes_keyword, conn, list),
    do: NIF.query_with_changes(conn, "SELECT :p1", list)

  defp call(:nif_stmt_bind_params, conn, list) do
    assert {:ok, stmt} = NIF.stmt_prepare(conn, "SELECT ?1")
    NIF.stmt_bind(stmt, list)
  end

  defp call(:nif_stmt_bind_keyword, conn, list) do
    assert {:ok, stmt} = NIF.stmt_prepare(conn, "SELECT :p1")
    NIF.stmt_bind(stmt, list)
  end

  defp call(:nif_stream_open_params, conn, list), do: NIF.stream_open(conn, "SELECT ?1", list)

  defp call(:nif_stream_open_keyword, conn, list),
    do: NIF.stream_open(conn, "SELECT :p1", list)

  defp call(:nif_explain_analyze_params, conn, list),
    do: NIF.explain_analyze(conn, "SELECT ?1", list)

  defp call(:nif_explain_analyze_keyword, conn, list),
    do: NIF.explain_analyze(conn, "SELECT :p1", list)

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
    assert {:ok, stream} = NIF.stream_open(conn, "SELECT 1", [])
    NIF.stream_fetch_cancellable(stream, 1, list)
  end

  defp call(:nif_set_authorizer, conn, list), do: NIF.set_authorizer(conn, list)

  defp call(:nif_backup_with_progress_tokens, conn, list) do
    dest = Path.join(System.tmp_dir!(), "xqlite_improper_list_backup_never_written.db")
    NIF.backup_with_progress(conn, "main", dest, self(), 1, list)
  end

  defp call(:query_type_extensions, conn, list),
    do: Xqlite.query(conn, "SELECT ?1", [1], type_extensions: list)

  defp call(:execute_type_extensions, conn, list),
    do: Xqlite.execute(conn, insert_sql(conn, "?1"), [1], type_extensions: list)

  defp call(:explain_analyze_type_extensions, conn, list),
    do: Xqlite.explain_analyze(conn, "SELECT ?1", [1], type_extensions: list)

  defp call(:bind_type_extensions, conn, list) do
    assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
    Xqlite.bind(stmt, [1], type_extensions: list)
  end

  defp call(:stream_type_extensions, conn, list),
    do: Xqlite.stream(conn, "SELECT ?1", [1], type_extensions: list)

  defp call(:query_cancellable_type_extensions, conn, list),
    do: Xqlite.query_cancellable(conn, "SELECT ?1", [1], new_token(), type_extensions: list)

  defp call(:execute_cancellable_type_extensions, conn, list) do
    Xqlite.execute_cancellable(conn, insert_sql(conn, "?1"), [1], new_token(),
      type_extensions: list
    )
  end

  defp call(:query_with_changes_cancellable_type_extensions, conn, list) do
    Xqlite.query_with_changes_cancellable(conn, "SELECT ?1", [1], new_token(),
      type_extensions: list
    )
  end

  defp call(:stream_params_extension, conn, list),
    do: Xqlite.stream(conn, "SELECT ?1", list, @extension_opts)

  defp call(:stream_keyword_extension, conn, list),
    do: Xqlite.stream(conn, "SELECT :p1", list, @extension_opts)

  defp call(:bind_params_extension, conn, list) do
    assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
    Xqlite.bind(stmt, list, @extension_opts)
  end

  defp call(:bind_keyword_extension, conn, list) do
    assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT :p1")
    Xqlite.bind(stmt, list, @extension_opts)
  end

  defp call(:query_params_extension, conn, list),
    do: Xqlite.query(conn, "SELECT ?1", list, @extension_opts)

  defp call(:query_keyword_extension, conn, list),
    do: Xqlite.query(conn, "SELECT :p1", list, @extension_opts)

  defp call(:execute_params_extension, conn, list),
    do: Xqlite.execute(conn, insert_sql(conn, "?1"), list, @extension_opts)

  defp call(:execute_keyword_extension, conn, list),
    do: Xqlite.execute(conn, insert_sql(conn, ":p1"), list, @extension_opts)

  defp call(:explain_analyze_params_extension, conn, list),
    do: Xqlite.explain_analyze(conn, "SELECT ?1", list, @extension_opts)

  defp call(:explain_analyze_keyword_extension, conn, list),
    do: Xqlite.explain_analyze(conn, "SELECT :p1", list, @extension_opts)

  defp call(:query_cancellable_params_extension, conn, list),
    do: Xqlite.query_cancellable(conn, "SELECT ?1", list, new_token(), @extension_opts)

  defp call(:query_cancellable_keyword_extension, conn, list),
    do: Xqlite.query_cancellable(conn, "SELECT :p1", list, new_token(), @extension_opts)

  defp call(:execute_cancellable_params_extension, conn, list) do
    Xqlite.execute_cancellable(
      conn,
      insert_sql(conn, "?1"),
      list,
      new_token(),
      @extension_opts
    )
  end

  defp call(:execute_cancellable_keyword_extension, conn, list) do
    Xqlite.execute_cancellable(
      conn,
      insert_sql(conn, ":p1"),
      list,
      new_token(),
      @extension_opts
    )
  end

  defp call(:query_with_changes_cancellable_params_extension, conn, list) do
    Xqlite.query_with_changes_cancellable(
      conn,
      "SELECT ?1",
      list,
      new_token(),
      @extension_opts
    )
  end

  defp call(:query_with_changes_cancellable_keyword_extension, conn, list) do
    Xqlite.query_with_changes_cancellable(
      conn,
      "SELECT :p1",
      list,
      new_token(),
      @extension_opts
    )
  end
end
