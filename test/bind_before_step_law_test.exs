defmodule Xqlite.BindBeforeStepLawTest do
  @moduledoc """
  A prepared statement that takes parameters runs only once something has set
  them.

  SQLite reads a parameter nothing was bound to as NULL, so a statement
  stepped straight after `prepare/2` writes NULL into every column it touches,
  and a bind the library refused binds nothing at all, which leaves the
  statement in exactly that state. Both are refused here instead: `step/1`,
  `multi_step/2` and `multi_step_cancellable/3` answer
  `{:error, {:parameters_unbound, %{expected: n}}}` until a bind succeeds or
  `clear_bindings/1` asks for NULLs on purpose.

  The rule, over a statement of `n` parameters:

    * a statement with no parameters runs at once;
    * a successful bind makes it runnable, and so does `clear_bindings/1`;
    * a refused bind changes nothing — an earlier successful bind stays in
      force and a statement that never had one stays unrunnable;
    * a refused clear changes nothing either: a statement that takes
      parameters and is mid-run — SQLite has stepped onto a row, answered or
      unreadable, and no `:done`, failed or cancelled step, or reset came
      after — rejects one and goes on carrying the values it was bound;
    * `reset/1` changes nothing either, SQLite keeping the bindings across it.

  "A refused bind changes nothing" is a rule about refusals the library makes
  itself, and it holds because every one of them judges the whole list before
  a single value reaches SQLite — the count, the names, a value no SQLite type
  can hold, and a value longer than the connection's own length limit. It is
  not a rule about SQLite: were a value to reach SQLite and be refused there,
  the values before it would stay bound, `reset/1` would not undo them (SQLite
  keeps bindings across a reset) and `clear_bindings/1` would replace every
  parameter with NULL rather than put back what was bound before.

  A bind on a statement that takes parameters and is mid-run falls under the
  rule too: the library rejects it with `:statement_mid_run` before it reads
  the list, so nothing is bound and the statement runs on with what it already
  held; a statement without parameters takes `[]` or `nil` mid-run and answers
  any other list as before the run, a list of values with the count error. A
  bind after `:done` or a failed step is not rejected: it resets the statement
  and binds, so the next step reruns with the new values.

  The law drives bind, clear, reset, step and both batch calls, a cancelled
  one included, over a read, a write and a write with `RETURNING`, and reads
  the table back through SQLite after each case; every write appends, so each
  run applied shows once. A signalled cancel token stops a batch only if
  SQLite reaches its progress check first, and SQLite checks once more after
  a write's last step has committed it: the law follows either answer, and
  reads the table when a cancelled batch had reached the end.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  @moduletag timeout: 300_000

  @overflow {:error, {:sqlite_failure, 1, 1}}
  @seed "CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, v, w, x, n); DELETE FROM t; " <>
          "INSERT INTO t VALUES (1, 'a', 'a', 'a', 1), (2, 'b', 'b', 'b', 2), (3, 'c', 'c', 'c', 3);"
  @select %{0 => "id, abs(n), v", 1 => "id, :a, abs(n), v", 3 => "id, :a, :b, :c, abs(n), v"}
  @set %{0 => "v = v || '!'", 1 => "v = v || :a", 3 => "v = v || :a, w = w || :b, x = x || :c"}

  # Low enough that a value one byte over it is cheap to build, and well above
  # the 30 SQLite silently raises a smaller `:length` to.
  @length_limit 64

  for_each_opener "a step before a bind" do
    test "the anchor: a statement that takes a parameter is refused", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
      assert {:error, {:parameters_unbound, %{expected: 1}}} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "the anchor: a statement that takes none runs at once", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT 'no_parameters'")
      assert {:row, ["no_parameters"]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "clear_bindings is how a caller asks for NULLs", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1, ?2")
      assert {:error, {:parameters_unbound, %{expected: 2}}} = Xqlite.step(stmt)
      assert :ok = Xqlite.clear_bindings(stmt)
      assert {:row, [nil, nil]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "a refused bind leaves an earlier successful one in force", %{conn: conn} do
      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1, ?2")
      assert :ok = Xqlite.bind(stmt, [7, 8])
      assert {:error, {:invalid_parameter_count, _}} = Xqlite.bind(stmt, [1])
      assert {:row, [7, 8]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "an UPDATE refused at the step writes nothing", %{conn: conn} do
      assert :ok = Xqlite.execute_batch(conn, seed_sql())
      assert {:ok, stmt} = Xqlite.prepare(conn, "UPDATE step_rows SET v = ?1")
      assert {:error, {:unsupported_data_type, :tuple}} = Xqlite.bind(stmt, [{:no}])
      assert {:error, {:parameters_unbound, %{expected: 1}}} = Xqlite.multi_step(stmt, 2)
      assert :ok = Xqlite.finalize(stmt)
      assert ["seed"] == stored(conn)
    end

    test "a bind refused for its length leaves an earlier one in force", %{conn: conn} do
      assert {:ok, _in_force} = Xqlite.put_limit(conn, :length, @length_limit)
      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1, ?2")
      assert :ok = Xqlite.bind(stmt, [7, 8])

      assert {:error, {:value_too_large, %{limit: @length_limit}}} =
               Xqlite.bind(stmt, [9, String.duplicate("x", @length_limit + 1)])

      assert {:row, [7, 8]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    property "a step answers the rule whatever came before it", %{conn: conn} do
      assert :ok = Xqlite.execute_batch(conn, @seed)
      assert {:ok, _in_force} = Xqlite.put_limit(conn, :length, @length_limit)

      check all(
              kind <- member_of([:read, :write, :returning]),
              n <- member_of([0, 1, 3]),
              trouble <- member_of(troubles(kind)),
              actions <- list_of(action(n), max_length: 6),
              max_runs: 2000
            ) do
        assert :ok = Xqlite.execute_batch(conn, @seed <> trouble_sql(trouble))
        assert {:ok, stmt} = Xqlite.prepare(conn, sql(kind, n))
        facts = %{conn: conn, kind: kind, n: n, trouble: trouble, set?: n == 0}
        start = Map.merge(facts, %{bound: [], round: 0, pos: 0, held: nil, applied: []})
        state = Enum.reduce(actions, start, &act(&1, stmt, &2))
        assert :ok = Xqlite.finalize(stmt)
        assert_table(state)
      end
    end
  end

  defp seed_sql do
    "CREATE TABLE step_rows (id INTEGER PRIMARY KEY, v TEXT); " <>
      "INSERT INTO step_rows (id, v) VALUES (1, 'seed');"
  end

  defp stored(conn) do
    assert {:ok, %{rows: [row]}} = Xqlite.query(conn, "SELECT v FROM step_rows WHERE id = 1")
    row
  end

  defp troubles(:read), do: [:none, :overflow, :unreadable]
  defp troubles(_write), do: [:none, :overflow]

  defp trouble_sql(:none), do: ""
  defp trouble_sql(:overflow), do: "UPDATE t SET n = -9223372036854775808 WHERE id = 3;"
  defp trouble_sql(:unreadable), do: "UPDATE t SET v = CAST(X'FF' AS TEXT) WHERE id = 3;"

  defp sql(:read, n), do: "SELECT #{@select[n]} FROM t ORDER BY id"
  defp sql(:write, n), do: "UPDATE t SET #{@set[n]} WHERE abs(n) > 0"
  defp sql(:returning, n), do: sql(:write, n) <> " RETURNING id, v, w, x"

  defp action(n) do
    one_of([
      tuple({constant(:bind), member_of(forms(n))}),
      tuple({constant(:rejected_bind), member_of(rejected_binds(n))}),
      member_of([:clear, :reset, :step]),
      tuple({member_of([:multi_step, :cancellable, :cancel]), member_of([1, 2, 10])})
    ])
  end

  defp forms(0), do: [:positional, nil]
  defp forms(_n), do: [:positional, :keyword]

  defp params(:positional, values), do: values
  defp params(:keyword, values), do: Enum.zip([:a, :b, :c], values)
  defp params(nil, _values), do: nil

  defp rejected_binds(n) do
    count = &{:invalid_parameter_count, %{provided: &1, expected: n}}

    [
      {values_for(n + 1, 0), count.(n + 1)},
      {[zzz: 1], {:invalid_parameter_name, ":zzz"}},
      {[1 | 2], {:expected_list, %{reason: :improper_tail, value_type: :integer}}},
      {42, {:expected_list, %{reason: :not_a_list, value_type: :integer}}}
      | with_parameters(n, count)
    ]
  end

  defp with_parameters(0, _count), do: []

  defp with_parameters(n, count) do
    too_long = String.duplicate("x", @length_limit + 1)
    too_large = {:value_too_large, %{byte_size: @length_limit + 1, limit: @length_limit}}

    [
      {[], count.(0)},
      {nil, count.(0)},
      {[a: 1, a: 2], {:duplicate_parameter_name, ":a"}},
      {last_value(n, {:no}), {:unsupported_data_type, :tuple}},
      {last_value(n, too_long), too_large}
      | missing(n)
    ]
  end

  defp missing(3), do: [{[a: 1, b: 2], {:missing_parameter, %{index: 3, name: ":c"}}}]
  defp missing(1), do: []

  defp last_value(n, value), do: n |> values_for(0) |> List.replace_at(n - 1, value)

  defp values_for(count, round), do: Enum.map(1..count//1, fn index -> round * 10 + index end)

  defp act({:bind, form}, stmt, s) do
    values = values_for(s.n, s.round + 1)
    answer = Xqlite.bind(stmt, params(form, values))
    assert mid_run_or(s, :ok) == answer
    set(answer, s, values)
  end

  defp act({:rejected_bind, {params, error}}, stmt, s) do
    assert mid_run_or(s, {:error, error}) == Xqlite.bind(stmt, params)
    s
  end

  defp act(:clear, stmt, s) do
    answer = Xqlite.clear_bindings(stmt)
    assert mid_run_or(s, :ok) == answer
    set(answer, s, List.duplicate(nil, s.n))
  end

  defp act(:reset, stmt, s) do
    assert :ok = Xqlite.reset(stmt)
    %{s | pos: 0, held: nil}
  end

  defp act(:step, stmt, s) do
    {expected, next} = gated(s, &advance/1)
    assert expected == shape(Xqlite.step(stmt))
    next
  end

  defp act({:cancel, k}, stmt, s) do
    {expected, next} = gated(s, &batch(&1, k, []))
    assert {:ok, token} = Xqlite.create_cancel_token()
    assert :ok = Xqlite.cancel_operation(token)

    case shape(Xqlite.multi_step_cancellable(stmt, k, [token])) do
      {:error, :operation_cancelled} when s.set? and s.held == nil ->
        cancelled(expected, next, rolled_back(s))

      answer ->
        assert expected == answer
        next
    end
  end

  defp act({call, k}, stmt, s) do
    {expected, next} = gated(s, &batch(&1, k, []))
    assert expected == shape(multi_step(call, stmt, k))
    next
  end

  defp mid_run_or(%{n: n, pos: pos}, _answer) when n > 0 and pos > 0,
    do: {:error, :statement_mid_run}

  defp mid_run_or(_s, answer), do: answer

  defp set(:ok, s, values), do: %{s | set?: true, bound: values, round: s.round + 1}
  defp set(_rejected, s, _values), do: s

  defp gated(%{set?: false} = s, _run),
    do: {{:error, {:parameters_unbound, %{expected: s.n}}}, s}

  defp gated(%{held: nil} = s, run), do: run.(s)
  defp gated(s, _run), do: {s.held, %{s | held: nil}}

  defp advance(s) do
    s = applying(s)
    answer = s |> run() |> Enum.at(s.pos)
    {answer, %{s | pos: next_pos(answer, s.pos)}}
  end

  defp applying(%{kind: kind, trouble: :none, pos: 0} = s) when kind != :read,
    do: %{s | applied: s.applied ++ [effect(s)]}

  defp applying(s), do: s

  defp run(%{kind: :read, trouble: :none} = s), do: read_rows(s, 3) ++ [:done]
  defp run(%{kind: :read, trouble: :overflow} = s), do: read_rows(s, 2) ++ [@overflow]

  defp run(%{kind: :read} = s),
    do: read_rows(s, 2) ++ [{:error, {:utf8_error, s.n + 2}}, :done]

  defp run(%{trouble: :overflow}), do: [@overflow]
  defp run(%{kind: :write}), do: [:done]
  defp run(s), do: for(row <- table(s.applied), do: {:row, row}) ++ [:done]

  defp read_rows(s, count),
    do: Enum.map(1..count, &{:row, [&1 | s.bound] ++ [&1, <<?a + &1 - 1>>]})

  defp next_pos({:row, _row}, pos), do: pos + 1
  defp next_pos({:error, {:utf8_error, _column}}, pos), do: pos + 1
  defp next_pos(_end, _pos), do: 0

  defp effect(%{n: 0}), do: ["!"]
  defp effect(s), do: s.bound

  defp batch(s, 0, rows), do: {{:ok, %{rows: Enum.reverse(rows), done: false}}, s}

  defp batch(s, k, rows) do
    case {advance(s), rows} do
      {{{:row, row}, next}, _rows} ->
        batch(next, k - 1, [row | rows])

      {{:done, next}, _rows} ->
        {{:ok, %{rows: Enum.reverse(rows), done: true}}, next}

      {{{:error, {:utf8_error, _column}} = error, next}, [_ | _]} ->
        {{:ok, %{rows: Enum.reverse(rows), done: false}}, %{next | held: error}}

      {{error, next}, _rows} ->
        {error, next}
    end
  end

  defp rolled_back(%{kind: :returning, pos: pos} = s) when pos > 0,
    do: %{s | pos: 0, applied: Enum.drop(s.applied, -1)}

  defp rolled_back(s), do: %{s | pos: 0}

  defp cancelled({:ok, %{done: true}}, next, back) when next.applied != back.applied do
    rows = stored_table(back)
    assert rows in [table(next.applied), table(back.applied)]
    Enum.find([next, back], &(table(&1.applied) == rows))
  end

  defp cancelled(_expected, _next, back), do: back

  defp table(applied) do
    for {id, letter} <- [{1, "a"}, {2, "b"}, {3, "c"}] do
      [id | Enum.reduce(applied, [letter, letter, letter], &append/2)]
    end
  end

  defp append(effect, columns) do
    {changed, kept} = Enum.split(columns, length(effect))
    Enum.zip_with(changed, effect, &concat/2) ++ kept
  end

  defp concat(nil, _value), do: nil
  defp concat(_text, nil), do: nil
  defp concat(text, value), do: text <> to_string(value)

  defp assert_table(%{kind: :read}), do: :ok
  defp assert_table(s), do: assert(table(s.applied) == stored_table(s))

  defp stored_table(s) do
    assert {:ok, %{rows: rows}} = Xqlite.query(s.conn, "SELECT id, v, w, x FROM t ORDER BY id")
    rows
  end

  defp multi_step(:multi_step, stmt, k), do: Xqlite.multi_step(stmt, k)
  defp multi_step(:cancellable, stmt, k), do: Xqlite.multi_step_cancellable(stmt, k, [])

  defp shape({:error, {:sqlite_failure, code, extended, _message}}),
    do: {:error, {:sqlite_failure, code, extended}}

  defp shape({:error, {:utf8_error, column, _reason}}), do: {:error, {:utf8_error, column}}
  defp shape(answer), do: answer
end
