defmodule Xqlite.CancelTokenLawTest do
  @moduledoc """
  What every cancellable entry point does with the tokens it is handed.

  A cancel token is an Erlang reference and so is every other reference, so
  Elixir on its own cannot tell one from the other; `XqliteNIF.is_cancel_token/1`
  asks the NIF, which tries the resource decode and answers `true` or `false`.

  The law: an entry point that takes tokens answers
  `{:error, {:invalid_cancel_tokens, refusal}}` for anything that is not a
  live token, and never raises. The refusal is the same map the other list
  refusals carry: `%{reason: :bad_element, position: n, value_type: type}`
  names the one-based position of the element that is no token and the kind
  of term it is, and `%{reason: :improper_tail, value_type: type}` a list
  whose tail stops being one part-way through. A value made only of live
  tokens is taken as before.

  `cancel_operation/1` signals one token rather than a list, so a list — of
  live tokens or empty — is not a valid value there either, and is refused as
  the one element it was handed.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase
  import Xqlite.Telemetry.TestSupport, only: [attach_capture: 1, detach: 1, assert_span: 1]

  alias Xqlite.TestUtil
  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  @select "SELECT 1"
  @insert "INSERT INTO cancel_law_rows(x) VALUES (1)"

  # The doors that take a token or a list of them from Elixir, and the raw
  # NIFs that take a list and nothing else. `XqliteNIF.cancel_operation/1` is
  # in neither: it decodes its one argument through rustler and raises for
  # every term that is not a live token, the documented kind for a raw NIF.
  @elixir_doors [
    :query,
    :execute,
    :execute_batch,
    :query_with_changes,
    :multi_step,
    :backup,
    :stream
  ]

  @raw_doors [
    :nif_query,
    :nif_execute,
    :nif_execute_batch,
    :nif_query_with_changes,
    :nif_multi_step,
    :nif_stream_fetch,
    :nif_backup
  ]

  for_each_opener "cancel token validation" do
    setup %{conn: conn} do
      assert {:ok, _} = NIF.set_pragma(conn, "journal_mode", "MEMORY")
      assert {:ok, _} = NIF.set_pragma(conn, "synchronous", "OFF")
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE cancel_law_rows(x);")
      assert {:ok, stmt} = Xqlite.prepare(conn, @select)
      assert {:ok, stream} = NIF.stream_open(conn, @select, [])

      context = %{
        conn: conn,
        stmt: stmt,
        stream: stream,
        dest: TestUtil.tmp_db_path("cancel_law_dest")
      }

      {:ok, doors: context, stmt: stmt}
    end

    test "the anchor: a stream refuses a reference that is not a token", %{conn: conn} do
      assert {:error,
              {:invalid_cancel_tokens,
               %{reason: :bad_element, position: 1, value_type: :reference}}} =
               Xqlite.stream(conn, @select, [], cancel_tokens: make_ref())
    end

    test "the anchor: the refusal names the position of the element", %{conn: conn} do
      tokens = [new_token(), :bogus, new_token()]

      assert {:error,
              {:invalid_cancel_tokens, %{reason: :bad_element, position: 2, value_type: :atom}}} =
               Xqlite.query_cancellable(conn, @select, [], tokens)
    end

    test "the anchor: a token list that does not end in [] is refused", %{conn: conn} do
      improper = [new_token() | :bogus]

      assert {:error, {:invalid_cancel_tokens, %{reason: :improper_tail, value_type: :atom}}} =
               Xqlite.stream(conn, @select, [], cancel_tokens: improper)

      assert {:error, {:invalid_cancel_tokens, %{reason: :improper_tail, value_type: :atom}}} =
               Xqlite.query_cancellable(conn, @select, [], improper)
    end

    test "the anchor: a raw door names the position too", %{conn: conn} do
      tokens = [new_token(), 7]

      assert {:error,
              {:invalid_cancel_tokens,
               %{reason: :bad_element, position: 2, value_type: :integer}}} =
               NIF.query_cancellable(conn, @select, [], tokens)
    end

    # A raw door takes a list of tokens and nothing else, so a term that is no
    # list is refused as the token list it was meant to be — and the reason
    # differs from the Elixir door's on purpose, which reads a bare term as one
    # token and so blames element one.
    test "the anchor: a raw door names a token argument that is no list", %{conn: conn} do
      assert {:error, {:invalid_cancel_tokens, %{reason: :not_a_list, value_type: :atom}}} =
               NIF.execute_batch_cancellable(conn, @insert, :bogus)

      assert {:error,
              {:invalid_cancel_tokens, %{reason: :bad_element, position: 1, value_type: :atom}}} =
               Xqlite.execute_batch_cancellable(conn, @insert, :bogus)
    end

    # The other list of the same call keeps its own tag, which is what makes
    # the token tag worth having.
    test "the anchor: a parameter list that is no list is still about the parameters",
         %{conn: conn} do
      token = new_token()

      assert {:error, {:expected_list, %{reason: :not_a_list, value_type: :atom}}} =
               NIF.query_cancellable(conn, @select, :bogus, [token])

      assert {:error, {:expected_list, %{reason: :improper_tail, value_type: :integer}}} =
               NIF.query_cancellable(conn, @select, [1 | 2], [token])
    end

    test "the anchor: cancel_operation/1 takes one token, not a list" do
      token = new_token()

      assert {:error,
              {:invalid_cancel_tokens, %{reason: :bad_element, position: 1, value_type: :list}}} =
               Xqlite.cancel_operation([token])

      assert {:error,
              {:invalid_cancel_tokens, %{reason: :bad_element, position: 1, value_type: :list}}} =
               Xqlite.cancel_operation([])

      assert :ok = Xqlite.cancel_operation(token)
    end

    test "the anchor: a refusal closes the query span instead of raising", %{conn: conn} do
      handler = attach_capture([[:xqlite, :query, :start], [:xqlite, :query, :stop]])

      assert {:error,
              {:invalid_cancel_tokens, %{reason: :bad_element, position: 1, value_type: :atom}}} =
               Xqlite.query_cancellable(conn, @select, [], :bogus)

      assert {_start_md, stop_md} = assert_span([:xqlite, :query])
      assert stop_md.result_class == :error

      assert stop_md.error_reason ==
               {:invalid_cancel_tokens,
                %{reason: :bad_element, position: 1, value_type: :atom}}

      detach(handler)
    end

    property "every door names the position and kind of the element that is no token",
             %{doors: doors} do
      check all(
              door <- StreamData.member_of(@elixir_doors ++ @raw_doors),
              alien <- alien_term(),
              good <- StreamData.integer(0..3),
              position <- StreamData.integer(1..(good + 1)),
              max_runs: 2000
            ) do
        value = spoiled(good, alien, position)
        type = type_of(alien)

        assert {^door,
                {:error,
                 {:invalid_cancel_tokens,
                  %{reason: :bad_element, position: ^position, value_type: ^type}}}} =
                 {door, answer(door, doors, value)}
      end
    end

    property "a single term that is no token is the element at position one",
             %{doors: doors} do
      check all(
              door <- StreamData.member_of(@elixir_doors),
              alien <- alien_term(),
              max_runs: 2000
            ) do
        type = type_of(alien)

        assert {^door,
                {:error,
                 {:invalid_cancel_tokens,
                  %{reason: :bad_element, position: 1, value_type: ^type}}}} =
                 {door, answer(door, doors, alien)}
      end
    end

    property "a token list with a broken tail is refused as such", %{doors: doors} do
      check all(
              door <- StreamData.member_of(@elixir_doors),
              tail <- alien_term(),
              good <- StreamData.integer(1..3),
              max_runs: 2000
            ) do
        value = improper(good, tail)
        type = type_of(tail)

        assert {^door,
                {:error,
                 {:invalid_cancel_tokens, %{reason: :improper_tail, value_type: ^type}}}} =
                 {door, answer(door, doors, value)}
      end
    end

    # A raw door takes a list and nothing else, so a broken tail there is a
    # refusal about the list itself, by the walk-by-hand rule — and the list it
    # was reading is the token list, which the refusal names.
    property "a raw door refuses a broken tail as a token list it cannot read",
             %{doors: doors} do
      check all(
              door <- StreamData.member_of(@raw_doors),
              tail <- alien_term(),
              good <- StreamData.integer(1..3),
              max_runs: 2000
            ) do
        value = improper(good, tail)
        type = type_of(tail)

        assert {^door,
                {:error,
                 {:invalid_cancel_tokens, %{reason: :improper_tail, value_type: ^type}}}} =
                 {door, answer(door, doors, value)}
      end
    end

    property "a raw door refuses a token argument that is no list as such", %{doors: doors} do
      check all(
              door <- StreamData.member_of(@raw_doors),
              alien <- alien_term(),
              max_runs: 2000
            ) do
        type = type_of(alien)

        assert {^door,
                {:error, {:invalid_cancel_tokens, %{reason: :not_a_list, value_type: ^type}}}} =
                 {door, answer(door, doors, alien)}
      end
    end

    property "a value made only of live tokens is taken", %{conn: conn, stmt: stmt} do
      check all(shape <- shape(), count <- StreamData.integer(0..3), max_runs: 2000) do
        value = token_value(shape, count)

        for {door, taken} <- taking_doors(conn, stmt, value) do
          refute match?({:error, {:invalid_cancel_tokens, _}}, taken), "refused by #{door}"
        end
      end
    end

    property "a live token is signalled, anything else is refused" do
      check all(alien <- alien_term(), max_runs: 2000) do
        type = type_of(alien)

        assert {:ok, token} = Xqlite.create_cancel_token()
        assert :ok = Xqlite.cancel_operation(token)

        assert {:error,
                {:invalid_cancel_tokens,
                 %{reason: :bad_element, position: 1, value_type: ^type}}} =
                 Xqlite.cancel_operation(alien)
      end
    end
  end

  defp answer(:query, %{conn: conn}, value),
    do: Xqlite.query_cancellable(conn, @select, [], value)

  defp answer(:execute, %{conn: conn}, value),
    do: Xqlite.execute_cancellable(conn, @insert, [], value)

  defp answer(:execute_batch, %{conn: conn}, value),
    do: Xqlite.execute_batch_cancellable(conn, @insert, value)

  defp answer(:query_with_changes, %{conn: conn}, value),
    do: Xqlite.query_with_changes_cancellable(conn, @insert, [], value)

  defp answer(:multi_step, %{stmt: stmt}, value),
    do: Xqlite.multi_step_cancellable(stmt, 1, value)

  defp answer(:backup, %{conn: conn, dest: dest}, value),
    do: Xqlite.backup_with_progress(conn, "main", dest, self(), 1, value)

  defp answer(:stream, %{conn: conn}, value),
    do: Xqlite.stream(conn, @select, [], cancel_tokens: value)

  defp answer(:nif_query, %{conn: conn}, value),
    do: NIF.query_cancellable(conn, @select, [], value)

  defp answer(:nif_execute, %{conn: conn}, value),
    do: NIF.execute_cancellable(conn, @insert, [], value)

  defp answer(:nif_execute_batch, %{conn: conn}, value),
    do: NIF.execute_batch_cancellable(conn, @insert, value)

  defp answer(:nif_query_with_changes, %{conn: conn}, value),
    do: NIF.query_with_changes_cancellable(conn, @insert, [], value)

  defp answer(:nif_multi_step, %{stmt: stmt}, value),
    do: NIF.stmt_multi_step_cancellable(stmt, 1, value)

  defp answer(:nif_stream_fetch, %{stream: stream}, value),
    do: NIF.stream_fetch_cancellable(stream, 1, value)

  defp answer(:nif_backup, %{conn: conn, dest: dest}, value),
    do: NIF.backup_with_progress(conn, "main", dest, self(), 1, value)

  defp taking_doors(conn, stmt, value) do
    [
      {:query, Xqlite.query_cancellable(conn, @select, [], value)},
      {:execute, Xqlite.execute_cancellable(conn, @insert, [], value)},
      {:execute_batch, Xqlite.execute_batch_cancellable(conn, @insert, value)},
      {:query_with_changes, Xqlite.query_with_changes_cancellable(conn, @insert, [], value)},
      {:multi_step, Xqlite.multi_step_cancellable(stmt, 1, value)},
      {:stream, drained_stream(conn, value)}
    ]
  end

  defp drained_stream(conn, value) do
    case Xqlite.stream(conn, @select, [], cancel_tokens: value) do
      {:error, reason} -> {:error, reason}
      stream -> Enum.to_list(stream)
    end
  end

  defp spoiled(good, alien, position) do
    good
    |> live_tokens()
    |> List.insert_at(position - 1, alien)
  end

  defp improper(good, tail) do
    good
    |> live_tokens()
    |> Enum.reverse()
    |> Enum.reduce(tail, fn token, acc -> [token | acc] end)
  end

  defp live_tokens(count), do: Enum.map(1..count//1, fn _index -> new_token() end)

  defp token_value(:bare, _count), do: new_token()
  defp token_value(:list, count), do: live_tokens(count)

  defp new_token do
    assert {:ok, token} = Xqlite.create_cancel_token()
    token
  end

  defp shape, do: StreamData.member_of([:bare, :list])

  # The same names the NIF gives a term's kind, so both sides of every door
  # can be read against one table.
  defp type_of(term) when is_atom(term), do: :atom
  defp type_of(term) when is_bitstring(term), do: :binary
  defp type_of(term) when is_float(term), do: :float
  defp type_of(term) when is_function(term), do: :function
  defp type_of(term) when is_integer(term), do: :integer
  defp type_of(term) when is_list(term), do: :list
  defp type_of(term) when is_map(term), do: :map
  defp type_of(term) when is_pid(term), do: :pid
  defp type_of(term) when is_port(term), do: :port
  defp type_of(term) when is_reference(term), do: :reference
  defp type_of(term) when is_tuple(term), do: :tuple

  defp alien_term do
    StreamData.one_of([
      StreamData.map(StreamData.constant(:fresh), fn _seed -> make_ref() end),
      StreamData.constant(self()),
      StreamData.atom(:alphanumeric),
      StreamData.integer(),
      StreamData.scale(StreamData.binary(), fn size -> min(size, 16) end),
      StreamData.constant(nil),
      StreamData.constant(%{}),
      StreamData.constant({:not, :a, :token})
    ])
  end
end
