defmodule Xqlite.NIF.SessionAlgebraPropertyTest do
  @moduledoc """
  The four laws SQLite's session extension promises, checked with generated data.

  A changeset is a recorded set of row changes. SQLite lets you glue two
  changesets together (`changeset_concat/2`), flip one so that it undoes itself
  (`changeset_invert/1`), and replay one onto another database
  (`changeset_apply/3`). Four laws follow:

  1. Composition — applying `concat(a, b)` leaves a database exactly where
     applying `a` and then `b` would leave it.
  2. Associativity — `concat(a, concat(b, c))` and `concat(concat(a, b), c)`
     leave a database in the same state.
  3. Inversion — applying a changeset and then its inverse restores the
     original contents.
  4. Identity — a changeset captured over a session in which nothing happened
     is empty: applying it changes nothing, and concatenating it onto either
     side of another changeset changes nothing.

  Every law is judged by the resulting table contents (a full ordered SELECT
  of every column of every table), never by comparing changeset bytes: SQLite
  is free to lay those out however it likes, so byte equality would be a
  stricter claim than the laws make.

  Conflict-free by construction: the three generated change batches own
  disjoint slices of the primary keys, so no batch ever touches a row another
  batch touched. What SQLite does when changesets *do* collide is a different
  question with its own tests in `Xqlite.NIF.SessionTest`. Every apply here
  uses the `:abort` conflict strategy, so an unexpected collision fails loudly
  instead of being quietly skipped.

  The connection the sessions are captured on comes from the opener loop, so
  every law runs against every connection mode. The databases the changesets
  are replayed onto are throwaway private in-memory copies of the starting
  state; they exist only to be compared against each other, so their
  connection mode carries no information.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  # Two thousand runs of each law against each connection mode is far more work
  # than ExUnit's one-minute-per-test default leaves room for on a slow machine.
  @moduletag timeout: 180_000

  @runs 2_000
  @max_size 50

  @create_sql """
  CREATE TABLE algebra_t1 (id INTEGER PRIMARY KEY, label TEXT, weight REAL, tag INTEGER);
  CREATE TABLE algebra_t2 (id INTEGER PRIMARY KEY, note TEXT, payload BLOB);
  """

  @drop_sql """
  DROP TABLE IF EXISTS algebra_t1;
  DROP TABLE IF EXISTS algebra_t2;
  """

  @reset_sql @drop_sql <> @create_sql

  @tables [:t1, :t2]

  @insert_sql %{
    t1: "INSERT INTO algebra_t1 (id, label, weight, tag) VALUES (?1, ?2, ?3, ?4)",
    t2: "INSERT INTO algebra_t2 (id, note, payload) VALUES (?1, ?2, ?3)"
  }

  @update_sql %{
    t1: "UPDATE algebra_t1 SET label = ?2, weight = ?3, tag = ?4 WHERE id = ?1",
    t2: "UPDATE algebra_t2 SET note = ?2, payload = ?3 WHERE id = ?1"
  }

  @delete_sql %{
    t1: "DELETE FROM algebra_t1 WHERE id = ?1",
    t2: "DELETE FROM algebra_t2 WHERE id = ?1"
  }

  @select_sql %{
    t1: "SELECT id, label, weight, tag FROM algebra_t1 ORDER BY id",
    t2: "SELECT id, note, payload FROM algebra_t2 ORDER BY id"
  }

  # Every base row belongs to the batch matching its id modulo 3, and every
  # batch inserts new rows only from its own block of ids. Two batches can
  # therefore never touch the same row.
  @batches [:a, :b, :c]
  @owner_of_remainder %{0 => :a, 1 => :b, 2 => :c}
  @first_new_id %{a: 1_000, b: 2_000, c: 3_000}

  # The magnitudes worth pinning down for a REAL column: both zeroes, the
  # largest and smallest normal doubles, and the smallest subnormal one.
  @edge_floats [
    0.0,
    -0.0,
    1.0,
    -1.0,
    0.1,
    3.141592653589793,
    1.7976931348623157e308,
    -1.7976931348623157e308,
    2.2250738585072014e-308,
    5.0e-324
  ]

  # A NUL byte inside TEXT cannot survive SQLite's C string handling, so the
  # text column stays clear of it; the BLOB column carries arbitrary bytes.
  @exotic_text [
    "",
    " ",
    "plain",
    "it's quoted",
    ~s(has "double" quotes),
    "line\nbreak",
    "tab\tinside",
    "trailing space ",
    "🐿️ emoji 👨‍👩‍👧‍👦",
    "ünïcödé",
    "é combining accent",
    "日本語のテキスト",
    "мир",
    "back\\slash",
    "percent %like_ wildcards",
    "-- not a comment",
    String.duplicate("long", 100)
  ]

  for_each_opener "session algebra" do
    property "concat(a, b) lands where a then b lands", %{conn: conn} do
      check all(scenario <- generated_scenario(), max_runs: @runs) do
        %{a: a, b: b} = capture_batches(conn, scenario)

        assert {:ok, ab} = NIF.changeset_concat(a, b)
        assert replay(scenario.base, [ab]) == replay(scenario.base, [a, b])
      end
    end

    property "concat is associative", %{conn: conn} do
      check all(scenario <- generated_scenario(), max_runs: @runs) do
        %{a: a, b: b, c: c} = capture_batches(conn, scenario)

        assert {:ok, bc} = NIF.changeset_concat(b, c)
        assert {:ok, a_bc} = NIF.changeset_concat(a, bc)
        assert {:ok, ab} = NIF.changeset_concat(a, b)
        assert {:ok, ab_c} = NIF.changeset_concat(ab, c)

        assert replay(scenario.base, [a_bc]) == replay(scenario.base, [ab_c])
      end
    end

    property "a changeset followed by its inverse restores the contents", %{conn: conn} do
      check all(scenario <- generated_scenario(), max_runs: @runs) do
        %{a: a, b: b, c: c} = capture_batches(conn, scenario)

        assert {:ok, ab} = NIF.changeset_concat(a, b)
        assert {:ok, abc} = NIF.changeset_concat(ab, c)

        untouched = replay(scenario.base, [])

        for changeset <- [a, b, c, abc] do
          assert {:ok, inverted} = NIF.changeset_invert(changeset)
          assert replay(scenario.base, [changeset, inverted]) == untouched
        end
      end
    end

    property "a changeset over an unchanged session is an identity", %{conn: conn} do
      check all(scenario <- generated_scenario(), max_runs: @runs) do
        %{a: a} = capture_batches(conn, scenario)
        empty = capture(conn, %{t1: [], t2: []})

        assert byte_size(empty) == 0

        assert {:ok, empty_then_a} = NIF.changeset_concat(empty, a)
        assert {:ok, a_then_empty} = NIF.changeset_concat(a, empty)

        untouched = replay(scenario.base, [])
        only_a = replay(scenario.base, [a])

        assert replay(scenario.base, [empty]) == untouched
        assert replay(scenario.base, [empty_then_a]) == only_a
        assert replay(scenario.base, [a_then_empty]) == only_a
      end
    end
  end

  # ---------------------------------------------------------------------
  # Capturing the three batches
  # ---------------------------------------------------------------------

  # Each batch is captured in its own session, one after the other, on a
  # database reset to the generated starting state. Capturing them in sequence
  # is equivalent to capturing each one against the pristine starting state
  # precisely because the batches own disjoint rows: whatever an earlier batch
  # did, the rows a later batch reads and writes are still at their starting
  # values.
  defp capture_batches(conn, scenario) do
    assert :ok = NIF.execute_batch(conn, @reset_sql)
    :ok = seed(conn, scenario.base)
    Map.new(@batches, fn key -> {key, capture(conn, scenario.batches[key])} end)
  end

  defp capture(conn, ops_by_table) do
    assert {:ok, session} = NIF.session_new(conn)
    assert :ok = NIF.session_attach(session, nil)
    :ok = run_ops(conn, ops_by_table)
    assert {:ok, changeset} = NIF.session_changeset(session)
    assert :ok = NIF.session_delete(session)
    changeset
  end

  defp run_ops(conn, ops_by_table) do
    for {table, ops} <- ops_by_table, op <- ops, do: run_op(conn, table, op)
    :ok
  end

  defp run_op(conn, table, {:insert, id, values}) do
    assert {:ok, 1} = NIF.execute(conn, @insert_sql[table], [id | values])
  end

  defp run_op(conn, table, {:update, id, values}) do
    assert {:ok, 1} = NIF.execute(conn, @update_sql[table], [id | values])
  end

  defp run_op(conn, table, {:delete, id}) do
    assert {:ok, 1} = NIF.execute(conn, @delete_sql[table], [id])
  end

  # ---------------------------------------------------------------------
  # Replaying onto a scratch copy of the starting state
  # ---------------------------------------------------------------------

  defp replay(base, changesets) do
    assert {:ok, replica} = NIF.open_in_memory(":memory:")
    assert :ok = NIF.execute_batch(replica, @create_sql)
    :ok = seed(replica, base)

    for changeset <- changesets do
      assert :ok = NIF.changeset_apply(replica, changeset, :abort)
    end

    contents = read_all(replica)
    assert :ok = NIF.close(replica)
    contents
  end

  defp seed(conn, base) do
    for {table, rows} <- base, {id, values} <- rows do
      assert {:ok, 1} = NIF.execute(conn, @insert_sql[table], [id | values])
    end

    :ok
  end

  defp read_all(conn) do
    Map.new(@tables, fn table -> {table, read_table(conn, table)} end)
  end

  defp read_table(conn, table) do
    assert {:ok, %{rows: rows}} = NIF.query(conn, @select_sql[table], [])
    rows
  end

  # ---------------------------------------------------------------------
  # Generators
  # ---------------------------------------------------------------------

  # stream_data raises its size parameter by one after every successful run, and
  # `StreamData.float/0` costs time proportional to the square of that size (it
  # builds every power of two up to it, as arbitrary-precision integers, for
  # each value it hands out). Over thousands of runs the generator would eat
  # more wall clock than the database work it feeds. Every range in this file is
  # already stated outright rather than left to the size, and the interesting
  # float magnitudes are listed by hand, so holding the size down costs no
  # coverage.
  defp generated_scenario do
    StreamData.scale(scenario_data(), fn size -> min(size, @max_size) end)
  end

  defp scenario_data do
    gen all(
          base_size <- StreamData.integer(3..9),
          base <- generated_base(base_size),
          batches <- generated_batches(base_size)
        ) do
      %{base: base, batches: batches}
    end
  end

  defp generated_base(size) do
    ids = Enum.to_list(1..size)

    gen all(
          t1 <- StreamData.list_of(t1_values(), length: size),
          t2 <- StreamData.list_of(t2_values(), length: size)
        ) do
      %{t1: Enum.zip(ids, t1), t2: Enum.zip(ids, t2)}
    end
  end

  defp generated_batches(base_size) do
    @batches
    |> Map.new(fn key -> {key, generated_batch(key, base_size)} end)
    |> StreamData.fixed_map()
  end

  defp generated_batch(key, base_size) do
    owned = owned_ids(key, base_size)

    StreamData.fixed_map(%{
      t1: generated_ops(key, owned, t1_values()),
      t2: generated_ops(key, owned, t2_values())
    })
  end

  defp generated_ops(key, owned, values) do
    gen all(
          touches <- StreamData.list_of(generated_touch(values), length: length(owned)),
          new_rows <- StreamData.list_of(values, max_length: 2)
        ) do
      existing = owned |> Enum.zip(touches) |> Enum.flat_map(&existing_op/1)
      inserted = new_rows |> Enum.with_index(@first_new_id[key]) |> Enum.map(&insert_op/1)
      existing ++ inserted
    end
  end

  defp generated_touch(values) do
    StreamData.one_of([
      StreamData.constant(:keep),
      StreamData.map(values, fn row -> {:update, row} end),
      StreamData.constant(:delete)
    ])
  end

  defp existing_op({_id, :keep}), do: []
  defp existing_op({id, {:update, values}}), do: [{:update, id, values}]
  defp existing_op({id, :delete}), do: [{:delete, id}]

  defp insert_op({values, id}), do: {:insert, id, values}

  defp owned_ids(key, base_size) do
    Enum.filter(1..base_size, fn id -> @owner_of_remainder[rem(id, 3)] == key end)
  end

  defp t1_values do
    StreamData.fixed_list([maybe(text()), maybe(real()), maybe(number())])
  end

  defp t2_values do
    StreamData.fixed_list([maybe(text()), maybe(blob())])
  end

  defp maybe(values) do
    StreamData.frequency([{1, StreamData.constant(nil)}, {4, values}])
  end

  defp text do
    StreamData.one_of([StreamData.member_of(@exotic_text), random_text()])
  end

  defp random_text do
    StreamData.filter(
      StreamData.string(:utf8, max_length: 24),
      fn s -> not String.contains?(s, <<0>>) end
    )
  end

  defp number do
    StreamData.one_of([
      StreamData.integer(-1_000..1_000),
      StreamData.member_of([0, -1, 1, 9_223_372_036_854_775_807, -9_223_372_036_854_775_808])
    ])
  end

  defp real do
    StreamData.one_of([StreamData.float(), StreamData.member_of(@edge_floats)])
  end

  defp blob do
    StreamData.binary(max_length: 16)
  end
end
