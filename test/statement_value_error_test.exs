defmodule Xqlite.StatementValueErrorTest do
  @moduledoc """
  What a prepared statement does after a value SQLite handed back could not be
  read — a TEXT column holding bytes that are not valid UTF-8.

  SQLite has already stepped past such a row when the read of it fails, so the
  error belongs to a row that is never delivered and the next call carries on
  at the row after it. `step/1` reports the error at once. `multi_step/2` and
  `multi_step_cancellable/3` hand back the rows they read before the bad one
  in the same batch first and report the error on the next call. `reset/1`
  starts the statement over and drops an error that was held back.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  @sql "SELECT b FROM value_error_rows ORDER BY id"

  for_each_opener "a statement over an unreadable value" do
    setup %{conn: conn} do
      assert {:ok, _} = NIF.set_pragma(conn, "journal_mode", "MEMORY")
      assert {:ok, _} = NIF.set_pragma(conn, "synchronous", "OFF")

      assert :ok =
               NIF.execute_batch(
                 conn,
                 "CREATE TABLE value_error_rows (id INTEGER PRIMARY KEY, b TEXT);"
               )

      :ok
    end

    test "the anchor: the only row is unreadable", %{conn: conn} do
      stmt = seeded_statement(conn, 1, 1)

      assert {:error, {:utf8_error, 0, _detail}} = Xqlite.step(stmt)
      assert {:ok, %{done: true, rows: []}} = Xqlite.multi_step(stmt, 10)
      assert :ok = Xqlite.reset(stmt)
      assert {:error, {:utf8_error, 0, _detail}} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "the rows read before the bad one come back before the error", %{conn: conn} do
      stmt = seeded_statement(conn, 4, 2)

      assert {:ok, %{rows: [["good1"]], done: false}} = Xqlite.multi_step(stmt, 10)
      assert {:error, {:utf8_error, 0, _detail}} = Xqlite.multi_step(stmt, 10)
      assert {:ok, %{rows: [["good3"], ["good4"]], done: true}} = Xqlite.multi_step(stmt, 10)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "a bad row with no row before it in the batch is reported at once", %{conn: conn} do
      stmt = seeded_statement(conn, 2, 1)

      assert {:error, {:utf8_error, 0, _detail}} = Xqlite.multi_step(stmt, 10)
      assert {:ok, %{rows: [["good2"]], done: true}} = Xqlite.multi_step(stmt, 10)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "a reset drops the error that was held back", %{conn: conn} do
      stmt = seeded_statement(conn, 4, 2)

      assert {:ok, %{rows: [["good1"]], done: false}} = Xqlite.multi_step(stmt, 10)
      assert :ok = Xqlite.reset(stmt)
      assert {:ok, %{rows: [["good1"]], done: false}} = Xqlite.multi_step(stmt, 10)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "one row at a time reports the error between the good rows", %{conn: conn} do
      stmt = seeded_statement(conn, 2, 1)

      assert {:error, {:utf8_error, 0, _detail}} = Xqlite.step(stmt)
      assert {:row, ["good2"]} = Xqlite.step(stmt)
      assert :done = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "the cancellable door answers exactly like its plain twin", %{conn: conn} do
      token = new_token()
      stmt = seeded_statement(conn, 4, 2)

      assert {:ok, %{rows: [["good1"]], done: false}} =
               Xqlite.multi_step_cancellable(stmt, 10, token)

      assert {:error, {:utf8_error, 0, _detail}} =
               Xqlite.multi_step_cancellable(stmt, 10, token)

      assert {:ok, %{rows: [["good3"], ["good4"]], done: true}} =
               Xqlite.multi_step_cancellable(stmt, 10, token)

      assert :ok = Xqlite.finalize(stmt)
    end

    test "the cancellable door reports a bad first row at once", %{conn: conn} do
      token = new_token()
      stmt = seeded_statement(conn, 1, 1)

      assert {:error, {:utf8_error, 0, _detail}} =
               Xqlite.multi_step_cancellable(stmt, 10, token)

      assert {:ok, %{rows: [], done: true}} = Xqlite.multi_step_cancellable(stmt, 10, token)
      assert :ok = Xqlite.finalize(stmt)
    end

    property "the answers follow the rule, whatever the batch size and the bad row",
             %{conn: conn} do
      check all(
              count <- integer(1..8),
              bad <- integer(1..count),
              batch <- integer(1..4),
              door <- member_of([:multi_step, :multi_step_cancellable]),
              max_runs: 2000
            ) do
        stmt = seeded_statement(conn, count, bad)
        answers = drive(door, stmt, batch, [], 40)
        assert :ok = Xqlite.finalize(stmt)

        assert expected_answers(count, bad, batch) == answers
        assert good_rows(conn, bad) == delivered_rows(answers)
      end
    end
  end

  # The rows SQLite itself hands back for the same query with the unreadable
  # row left out — the oracle for everything the doors delivered.
  defp good_rows(conn, bad) do
    assert {:ok, %{rows: rows}} =
             Xqlite.query(
               conn,
               "SELECT b FROM value_error_rows WHERE id <> ? ORDER BY id",
               [bad]
             )

    rows
  end

  defp delivered_rows(answers) do
    Enum.flat_map(answers, &rows_of/1)
  end

  defp rows_of({:rows, rows, _done}), do: rows
  defp rows_of(_answer), do: []

  defp drive(_door, _stmt, _batch, acc, 0), do: Enum.reverse(acc)

  defp drive(door, stmt, batch, acc, left) do
    answer = shape(call(door, stmt, batch))
    acc = [answer | acc]

    case answer do
      {:rows, _rows, true} -> Enum.reverse(acc)
      _unfinished -> drive(door, stmt, batch, acc, left - 1)
    end
  end

  defp call(:multi_step, stmt, batch), do: Xqlite.multi_step(stmt, batch)

  defp call(:multi_step_cancellable, stmt, batch),
    do: Xqlite.multi_step_cancellable(stmt, batch, new_token())

  # The answers, stripped of what a law must not depend on: the text SQLite
  # wrote about the byte it could not read.
  defp shape({:ok, %{rows: rows, done: done}}), do: {:rows, rows, done}
  defp shape({:error, {:utf8_error, column, _detail}}), do: {:value_error, column}
  defp shape(other), do: {:unexpected, other}

  # The rule the doors follow, from the first call to the one that reports the
  # statement exhausted: rows come back in batches of `batch`, the batch
  # holding the bad row is cut short before it, the error follows on the next
  # call when that cut left rows in hand and comes at once when it did not.
  defp expected_answers(count, bad, batch) do
    calls(%{position: 1, held_back: false}, count, bad, batch, [])
  end

  defp calls(state, count, bad, batch, acc) do
    {answer, next} = one_call(state, count, bad, batch)
    acc = [answer | acc]

    case answer do
      {:rows, _rows, true} -> Enum.reverse(acc)
      _unfinished -> calls(next, count, bad, batch, acc)
    end
  end

  defp one_call(%{held_back: true} = state, _count, _bad, _batch) do
    {{:value_error, 0}, %{state | held_back: false}}
  end

  defp one_call(%{position: position}, count, bad, batch) do
    one_batch(position, count, bad, batch, [])
  end

  defp one_batch(position, _count, _bad, 0, rows) do
    {{:rows, Enum.reverse(rows), false}, %{position: position, held_back: false}}
  end

  defp one_batch(position, count, _bad, _left, rows) when position > count do
    {{:rows, Enum.reverse(rows), true}, %{position: position, held_back: false}}
  end

  defp one_batch(position, _count, bad, _left, []) when position == bad do
    {{:value_error, 0}, %{position: position + 1, held_back: false}}
  end

  defp one_batch(position, _count, bad, _left, rows) when position == bad do
    {{:rows, Enum.reverse(rows), false}, %{position: position + 1, held_back: true}}
  end

  defp one_batch(position, count, bad, left, rows) do
    one_batch(position + 1, count, bad, left - 1, [[row_value(position, bad)] | rows])
  end

  defp seeded_statement(conn, count, bad) do
    seed(conn, count, bad)
    assert {:ok, stmt} = Xqlite.prepare(conn, @sql)
    stmt
  end

  defp seed(conn, count, bad) do
    assert {:ok, _deleted} = Xqlite.execute(conn, "DELETE FROM value_error_rows", [])

    for id <- 1..count do
      assert {:ok, %{changes: 1}} =
               Xqlite.execute(
                 conn,
                 "INSERT INTO value_error_rows (id, b) VALUES (?, CAST(? AS TEXT))",
                 [id, row_value(id, bad)]
               )
    end
  end

  defp row_value(id, id), do: <<0xFF>>
  defp row_value(id, _bad), do: "good#{id}"

  defp new_token do
    assert {:ok, token} = Xqlite.create_cancel_token()
    token
  end
end
