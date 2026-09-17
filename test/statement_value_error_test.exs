defmodule Xqlite.StatementValueErrorTest do
  @moduledoc """
  What a prepared statement does when a step does not produce a row it can
  deliver. There are two separate failures here and they behave differently.

  A value SQLite handed back that could not be read — a TEXT column holding
  bytes that are not valid UTF-8 — belongs to a row SQLite has already
  stepped past, so that row is never delivered and the run carries on at the
  row after it. `step/1` reports it at once. `multi_step/2` and
  `multi_step_cancellable/3` hand back the rows they read before it in the
  same batch and hold the error back; the next call that reads a row answers
  it, whichever of the three doors makes that call. `reset/1` and
  `finalize/1` drop an error that was held back.

  A `sqlite3_step` that fails outright — a runtime error in the SQL, a
  trigger's `RAISE` — stepped past no row at all. It is answered at once,
  `multi_step/2` discards the rows of the batch it lands in, and the
  statement is left where SQLite left it: the next step is SQLite's own rerun
  from the top, which meets the same failure.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  @sql "SELECT b FROM value_error_rows ORDER BY id"

  # A run of at most this many calls; every domain here finishes well inside
  # it, so a run that does not is the law failing rather than the cap.
  @fuel 40

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

    test "step/1 answers the error a batch held back, then carries on", %{conn: conn} do
      stmt = seeded_statement(conn, 4, 2)

      assert {:ok, %{rows: [["good1"]], done: false}} = Xqlite.multi_step(stmt, 2)
      assert {:error, {:utf8_error, 0, _detail}} = Xqlite.step(stmt)
      assert {:row, ["good3"]} = Xqlite.step(stmt)
      assert {:row, ["good4"]} = Xqlite.step(stmt)
      assert :done = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "step/1 answers the error a batch held back when the bad row was last",
         %{conn: conn} do
      stmt = seeded_statement(conn, 4, 4)

      assert {:ok, %{rows: [["good1"], ["good2"], ["good3"]], done: false}} =
               Xqlite.multi_step(stmt, 10)

      assert {:error, {:utf8_error, 0, _detail}} = Xqlite.step(stmt)
      assert :done = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "a finalize after a batch held an error back answers its own result",
         %{conn: conn} do
      stmt = seeded_statement(conn, 4, 2)

      assert {:ok, %{rows: [["good1"]], done: false}} = Xqlite.multi_step(stmt, 10)
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

    property "the answers follow the rule, whatever the doors are called in",
             %{conn: conn} do
      check all(
              count <- integer(1..8),
              bad <- integer(1..count),
              plan <- plan(),
              door <- member_of([:multi_step, :multi_step_cancellable]),
              max_runs: 2000
            ) do
        stmt = seeded_statement(conn, count, bad)
        answers = drive(door, stmt, plan, plan, [], @fuel)
        assert :ok = Xqlite.finalize(stmt)

        assert expected_answers(count, bad, plan) == answers
        assert good_rows(conn, bad) == delivered_rows(answers)
      end
    end
  end

  for_each_opener "a statement whose step fails" do
    setup %{conn: conn} do
      assert {:ok, _} = NIF.set_pragma(conn, "journal_mode", "MEMORY")
      assert {:ok, _} = NIF.set_pragma(conn, "synchronous", "OFF")

      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE step_rows (id INTEGER PRIMARY KEY, v INTEGER);
               INSERT INTO step_rows (id, v) VALUES (1, 10), (2, 20);
               INSERT INTO step_rows (id, v) VALUES (3, -9223372036854775808);
               CREATE TABLE sink (id INTEGER);
               CREATE TRIGGER guard BEFORE INSERT ON sink
               BEGIN
                 SELECT raise(ABORT, 'refused') WHERE new.id = 3;
               END;
               """)

      :ok
    end

    test "the anchor: a runtime error in the SQL is answered with none of the batch's rows",
         %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, overflow_sql())

      assert {:error, {:sqlite_failure, _code, _extended, _message}} =
               Xqlite.multi_step(stmt, 10)

      assert :ok = Xqlite.finalize(stmt)
    end

    test "a failed step leaves the statement where SQLite left it", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, overflow_sql())

      assert {:error, {:sqlite_failure, _c1, _e1, _m1}} = Xqlite.multi_step(stmt, 10)

      # SQLite reruns a statement stepped after a failed step, so the rows
      # before the failing one come back once more and the failure follows.
      assert {:ok, %{rows: [[1, 10], [2, 20]], done: false}} = Xqlite.multi_step(stmt, 2)
      assert {:error, {:sqlite_failure, _c2, _e2, _m2}} = Xqlite.multi_step(stmt, 10)

      assert :ok = Xqlite.reset(stmt)
      assert {:error, {:sqlite_failure, _c3, _e3, _m3}} = Xqlite.multi_step(stmt, 10)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "step/1 delivers the rows before a failing step, then the error", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, overflow_sql())

      assert {:row, [1, 10]} = Xqlite.step(stmt)
      assert {:row, [2, 20]} = Xqlite.step(stmt)
      assert {:error, {:sqlite_failure, _c1, _e1, _m1}} = Xqlite.step(stmt)
      assert {:row, [1, 10]} = Xqlite.step(stmt)
      assert {:row, [2, 20]} = Xqlite.step(stmt)
      assert {:error, {:sqlite_failure, _c2, _e2, _m2}} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "the cancellable door answers a failed step like its plain twin", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, overflow_sql())

      assert {:error, {:sqlite_failure, _c1, _e1, _m1}} =
               Xqlite.multi_step_cancellable(stmt, 10, new_token())

      assert {:ok, %{rows: [[1, 10], [2, 20]], done: false}} =
               Xqlite.multi_step_cancellable(stmt, 2, new_token())

      assert {:error, {:sqlite_failure, _c2, _e2, _m2}} =
               Xqlite.multi_step_cancellable(stmt, 10, new_token())

      assert :ok = Xqlite.finalize(stmt)
    end

    # A trigger's RAISE fails the statement's very first step, so no row is
    # ever answered — the outcome after a failed step differs by failure.
    test "a trigger abort answers the error on every step and never a row", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, abort_sql())

      for _attempt <- 1..3 do
        assert {:error, {:constraint_violation, :constraint_trigger, _details}} =
                 Xqlite.step(stmt)
      end

      assert {:error, {:constraint_violation, :constraint_trigger, _details}} =
               Xqlite.multi_step(stmt, 10)

      assert :ok = Xqlite.reset(stmt)

      assert {:error, {:constraint_violation, :constraint_trigger, _details}} =
               Xqlite.multi_step(stmt, 10)

      assert :ok = Xqlite.finalize(stmt)
      assert {:ok, %{rows: []}} = Xqlite.query(conn, "SELECT id FROM sink ORDER BY id", [])
    end

    test "a stream over the same rows delivers the good rows, then the error", %{conn: conn} do
      assert [
               {:ok, %{"id" => 1}},
               {:ok, %{"id" => 2}},
               {:error, {:sqlite_failure, _code, _extended, _message}}
             ] =
               conn
               |> Xqlite.stream(overflow_sql(), [], on_error: :emit_error)
               |> Enum.to_list()
    end

    test "the default stream mode raises on a failed step", %{conn: conn} do
      assert_raise Xqlite.StreamError, fn ->
        conn
        |> Xqlite.stream(overflow_sql())
        |> Enum.to_list()
      end
    end
  end

  # abs/1 of the smallest int64 has no int64 answer, so SQLite fails the step
  # that reaches that row instead of handing a row back.
  defp overflow_sql, do: "SELECT id, abs(v) FROM step_rows ORDER BY id"

  defp abort_sql, do: "INSERT INTO sink (id) SELECT id FROM step_rows ORDER BY id"

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
  defp rows_of({:row, values}), do: [values]
  defp rows_of(_answer), do: []

  # A run is a sequence of calls, cycled until the statement reports itself
  # exhausted: one row at a time through `step/1`, or a batch of up to four
  # through the door under test.
  defp plan do
    list_of(one_of([constant(:step), tuple({constant(:batch), integer(1..4)})]),
      min_length: 1,
      max_length: 4
    )
  end

  defp drive(_door, _stmt, _plan, _rest, acc, 0), do: Enum.reverse(acc)

  defp drive(door, stmt, plan, [], acc, left), do: drive(door, stmt, plan, plan, acc, left)

  defp drive(door, stmt, plan, [next | rest], acc, left) do
    answer = shape(call(door, stmt, next))
    acc = [answer | acc]

    case exhausted?(answer) do
      true -> Enum.reverse(acc)
      false -> drive(door, stmt, plan, rest, acc, left - 1)
    end
  end

  defp call(_door, stmt, :step), do: Xqlite.step(stmt)
  defp call(:multi_step, stmt, {:batch, size}), do: Xqlite.multi_step(stmt, size)

  defp call(:multi_step_cancellable, stmt, {:batch, size}),
    do: Xqlite.multi_step_cancellable(stmt, size, new_token())

  # The answers, stripped of what a law must not depend on: the text SQLite
  # wrote about the byte it could not read.
  defp shape({:ok, %{rows: rows, done: done}}), do: {:rows, rows, done}
  defp shape({:row, values}), do: {:row, values}
  defp shape(:done), do: :done
  defp shape({:error, {:utf8_error, column, _detail}}), do: {:value_error, column}
  defp shape(other), do: {:unexpected, other}

  defp exhausted?({:rows, _rows, true}), do: true
  defp exhausted?(:done), do: true
  defp exhausted?(_answer), do: false

  # The rule the doors follow, from the first call to the one that reports the
  # statement exhausted: a batch hands back rows until it meets the bad row
  # and is cut short before it, `step/1` hands back one row at a time, and
  # the error a cut-short batch held back is answered by the next call that
  # reads a row, whichever door makes it.
  defp expected_answers(count, bad, plan) do
    calls(%{position: 1, held_back: false}, count, bad, plan, plan, [], @fuel)
  end

  defp calls(_state, _count, _bad, _plan, _rest, acc, 0), do: Enum.reverse(acc)

  defp calls(state, count, bad, plan, [], acc, left),
    do: calls(state, count, bad, plan, plan, acc, left)

  defp calls(state, count, bad, plan, [next | rest], acc, left) do
    {answer, after_call} = one_call(state, count, bad, next)
    acc = [answer | acc]

    case exhausted?(answer) do
      true -> Enum.reverse(acc)
      false -> calls(after_call, count, bad, plan, rest, acc, left - 1)
    end
  end

  defp one_call(%{held_back: true} = state, _count, _bad, _next) do
    {{:value_error, 0}, %{state | held_back: false}}
  end

  defp one_call(%{position: position}, count, bad, :step) do
    one_step(position, count, bad)
  end

  defp one_call(%{position: position}, count, bad, {:batch, size}) do
    one_batch(position, count, bad, size, [])
  end

  defp one_step(position, count, _bad) when position > count do
    {:done, %{position: position, held_back: false}}
  end

  defp one_step(position, _count, bad) when position == bad do
    {{:value_error, 0}, %{position: position + 1, held_back: false}}
  end

  defp one_step(position, _count, bad) do
    {{:row, [row_value(position, bad)]}, %{position: position + 1, held_back: false}}
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
