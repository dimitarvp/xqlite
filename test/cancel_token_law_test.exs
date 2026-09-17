defmodule Xqlite.CancelTokenLawTest do
  @moduledoc """
  What every cancellable entry point does with the tokens it is handed.

  A cancel token is an Erlang reference and so is every other reference, so
  Elixir on its own cannot tell one from the other; `XqliteNIF.is_cancel_token/1`
  asks the NIF, which tries the resource decode and answers `true` or `false`.

  The law: an entry point that takes tokens answers
  `{:error, {:invalid_cancel_tokens, value}}` — carrying the value the caller
  passed, unchanged, list or not — for anything that is not a live token, and
  never raises; a value made only of live tokens is taken as before.

  `cancel_operation/1` signals one token rather than a list, so a list is not a
  valid value there either.
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

  for_each_opener "cancel token validation" do
    setup %{conn: conn} do
      assert {:ok, _} = NIF.set_pragma(conn, "journal_mode", "MEMORY")
      assert {:ok, _} = NIF.set_pragma(conn, "synchronous", "OFF")
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE cancel_law_rows(x);")
      assert {:ok, stmt} = Xqlite.prepare(conn, @select)

      {:ok, stmt: stmt, dest: TestUtil.tmp_db_path("cancel_law_dest")}
    end

    test "the anchor: a stream refuses a reference that is not a token", %{conn: conn} do
      alien = make_ref()

      assert {:error, {:invalid_cancel_tokens, ^alien}} =
               Xqlite.stream(conn, @select, [], cancel_tokens: alien)
    end

    test "the anchor: a refusal closes the query span instead of raising", %{conn: conn} do
      handler = attach_capture([[:xqlite, :query, :start], [:xqlite, :query, :stop]])

      assert {:error, {:invalid_cancel_tokens, :bogus}} =
               Xqlite.query_cancellable(conn, @select, [], :bogus)

      assert {_start_md, stop_md} = assert_span([:xqlite, :query])
      assert stop_md.result_class == :error
      assert stop_md.error_reason == {:invalid_cancel_tokens, :bogus}

      detach(handler)
    end

    property "every door refuses a value that is not tokens, unchanged", context do
      %{conn: conn, stmt: stmt, dest: dest} = context

      check all(value <- alien_value(), max_runs: 2000) do
        for {door, answer} <- doors(conn, stmt, dest, value) do
          assert {^door, {:error, {:invalid_cancel_tokens, ^value}}} = {door, answer}
        end
      end
    end

    property "a value made only of live tokens is taken", %{conn: conn, stmt: stmt} do
      check all(shape <- shape(), count <- StreamData.integer(0..3), max_runs: 2000) do
        value = token_value(shape, count)

        for {door, answer} <- taking_doors(conn, stmt, value) do
          refute match?({:error, {:invalid_cancel_tokens, _}}, answer), "refused by #{door}"
        end
      end
    end

    property "a live token is signalled, anything else is refused" do
      check all(alien <- alien_term(), max_runs: 2000) do
        assert {:ok, token} = Xqlite.create_cancel_token()
        assert :ok = Xqlite.cancel_operation(token)
        assert {:error, {:invalid_cancel_tokens, ^alien}} = Xqlite.cancel_operation(alien)
      end
    end
  end

  defp doors(conn, stmt, dest, value) do
    [
      {:query, Xqlite.query_cancellable(conn, @select, [], value)},
      {:execute, Xqlite.execute_cancellable(conn, @insert, [], value)},
      {:execute_batch, Xqlite.execute_batch_cancellable(conn, @insert, value)},
      {:query_with_changes, Xqlite.query_with_changes_cancellable(conn, @insert, [], value)},
      {:multi_step, Xqlite.multi_step_cancellable(stmt, 1, value)},
      {:backup, Xqlite.backup_with_progress(conn, "main", dest, self(), 1, value)},
      {:stream, Xqlite.stream(conn, @select, [], cancel_tokens: value)},
      {:cancel_operation, Xqlite.cancel_operation(value)}
    ]
  end

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

  defp token_value(:bare, _count), do: new_token()
  defp token_value(:list, count), do: Enum.map(1..count//1, fn _index -> new_token() end)

  defp new_token do
    assert {:ok, token} = Xqlite.create_cancel_token()
    token
  end

  defp shape, do: StreamData.member_of([:bare, :list])

  defp alien_value do
    StreamData.one_of([alien_term(), spoiled_list()])
  end

  defp spoiled_list do
    gen all(
          alien <- alien_term(),
          good <- StreamData.integer(0..3),
          position <- StreamData.integer(0..good)
        ) do
      new_token()
      |> List.duplicate(good)
      |> List.insert_at(position, alien)
    end
  end

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
