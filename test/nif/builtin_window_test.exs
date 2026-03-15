defmodule Xqlite.NIF.BuiltinWindowTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "window functions using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE wf (id INTEGER PRIMARY KEY, dept TEXT, name TEXT, salary INTEGER);
          INSERT INTO wf VALUES (1, 'eng', 'alice', 100);
          INSERT INTO wf VALUES (2, 'eng', 'bob', 120);
          INSERT INTO wf VALUES (3, 'eng', 'carol', 110);
          INSERT INTO wf VALUES (4, 'sales', 'dave', 90);
          INSERT INTO wf VALUES (5, 'sales', 'eve', 95);
          INSERT INTO wf VALUES (6, 'hr', 'frank', 80);
          """)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # row_number()
      # -------------------------------------------------------------------

      test "row_number() assigns sequential numbers", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name, row_number() OVER (ORDER BY salary DESC) AS rn FROM wf",
                   []
                 )

        assert length(rows) == 6
        row_nums = Enum.map(rows, fn [_, rn] -> rn end)
        assert row_nums == [1, 2, 3, 4, 5, 6]
      end

      test "row_number() with PARTITION BY", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT dept, name, row_number() OVER (PARTITION BY dept ORDER BY salary DESC) AS rn FROM wf ORDER BY dept, rn",
                   []
                 )

        eng_rows = Enum.filter(rows, fn [dept, _, _] -> dept == "eng" end)
        eng_nums = Enum.map(eng_rows, fn [_, _, rn] -> rn end)
        assert eng_nums == [1, 2, 3]

        sales_rows = Enum.filter(rows, fn [dept, _, _] -> dept == "sales" end)
        sales_nums = Enum.map(sales_rows, fn [_, _, rn] -> rn end)
        assert sales_nums == [1, 2]
      end

      # -------------------------------------------------------------------
      # rank() and dense_rank()
      # -------------------------------------------------------------------

      test "rank() assigns rank with gaps for ties", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE wf_rank (id INTEGER PRIMARY KEY, score INTEGER);
          INSERT INTO wf_rank VALUES (1, 100);
          INSERT INTO wf_rank VALUES (2, 100);
          INSERT INTO wf_rank VALUES (3, 90);
          """)

        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT id, rank() OVER (ORDER BY score DESC) AS r FROM wf_rank ORDER BY id",
                   []
                 )

        assert rows == [[1, 1], [2, 1], [3, 3]]
      end

      test "dense_rank() assigns rank without gaps", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE wf_drank (id INTEGER PRIMARY KEY, score INTEGER);
          INSERT INTO wf_drank VALUES (1, 100);
          INSERT INTO wf_drank VALUES (2, 100);
          INSERT INTO wf_drank VALUES (3, 90);
          """)

        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT id, dense_rank() OVER (ORDER BY score DESC) AS dr FROM wf_drank ORDER BY id",
                   []
                 )

        assert rows == [[1, 1], [2, 1], [3, 2]]
      end

      # -------------------------------------------------------------------
      # ntile()
      # -------------------------------------------------------------------

      test "ntile() distributes rows into buckets", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name, ntile(3) OVER (ORDER BY salary DESC) AS bucket FROM wf",
                   []
                 )

        buckets = Enum.map(rows, fn [_, b] -> b end)
        assert Enum.count(buckets, &(&1 == 1)) == 2
        assert Enum.count(buckets, &(&1 == 2)) == 2
        assert Enum.count(buckets, &(&1 == 3)) == 2
      end

      # -------------------------------------------------------------------
      # lag() and lead()
      # -------------------------------------------------------------------

      test "lag() accesses previous row value", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name, salary, lag(salary) OVER (ORDER BY salary) AS prev_sal FROM wf ORDER BY salary",
                   []
                 )

        [first | _] = rows
        assert Enum.at(first, 2) == nil

        second = Enum.at(rows, 1)
        assert Enum.at(second, 2) == Enum.at(first, 1)
      end

      test "lag() with offset and default", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name, lag(salary, 2, -1) OVER (ORDER BY salary) AS prev2 FROM wf ORDER BY salary",
                   []
                 )

        first_two_lags = rows |> Enum.take(2) |> Enum.map(fn [_, lag] -> lag end)
        assert first_two_lags == [-1, -1]
      end

      test "lead() accesses next row value", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name, salary, lead(salary) OVER (ORDER BY salary) AS next_sal FROM wf ORDER BY salary",
                   []
                 )

        last = List.last(rows)
        assert Enum.at(last, 2) == nil

        first = hd(rows)
        second = Enum.at(rows, 1)
        assert Enum.at(first, 2) == Enum.at(second, 1)
      end

      # -------------------------------------------------------------------
      # first_value(), last_value(), nth_value()
      # -------------------------------------------------------------------

      test "first_value() returns first in window", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name, first_value(name) OVER (PARTITION BY dept ORDER BY salary DESC) AS top FROM wf ORDER BY id",
                   []
                 )

        eng_tops =
          rows
          |> Enum.filter(fn [name, _] -> name in ["alice", "bob", "carol"] end)
          |> Enum.map(fn [_, top] -> top end)
          |> Enum.uniq()

        assert eng_tops == ["bob"]
      end

      test "last_value() with explicit frame", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   """
                   SELECT name, last_value(name) OVER (
                     PARTITION BY dept ORDER BY salary
                     ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
                   ) AS bottom
                   FROM wf ORDER BY id
                   """,
                   []
                 )

        eng_bottoms =
          rows
          |> Enum.filter(fn [name, _] -> name in ["alice", "bob", "carol"] end)
          |> Enum.map(fn [_, b] -> b end)
          |> Enum.uniq()

        assert eng_bottoms == ["bob"]
      end

      test "nth_value() returns the nth row value", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name, nth_value(name, 2) OVER (ORDER BY salary DESC) AS second FROM wf ORDER BY salary DESC",
                   []
                 )

        # First row has no 2nd value yet
        assert Enum.at(hd(rows), 1) == nil
        # Second row onwards should have the 2nd value
        second_vals = rows |> Enum.drop(1) |> Enum.map(fn [_, v] -> v end) |> Enum.uniq()
        assert length(second_vals) == 1
      end

      # -------------------------------------------------------------------
      # Aggregate window functions
      # -------------------------------------------------------------------

      test "SUM() as window function with running total", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name, salary, SUM(salary) OVER (ORDER BY salary) AS running FROM wf ORDER BY salary",
                   []
                 )

        running_totals = Enum.map(rows, fn [_, _, rt] -> rt end)
        # Each running total should be >= previous
        assert running_totals == Enum.sort(running_totals)
        assert List.last(running_totals) == 595
      end

      test "AVG() OVER partition", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT dept, name, AVG(salary) OVER (PARTITION BY dept) AS dept_avg FROM wf ORDER BY id",
                   []
                 )

        eng_avgs =
          rows
          |> Enum.filter(fn [dept, _, _] -> dept == "eng" end)
          |> Enum.map(fn [_, _, avg] -> avg end)
          |> Enum.uniq()

        assert_in_delta hd(eng_avgs), 110.0, 0.01
      end

      test "COUNT() OVER with ROWS frame", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   """
                   SELECT name, COUNT(*) OVER (
                     ORDER BY salary ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING
                   ) AS nearby
                   FROM wf ORDER BY salary
                   """,
                   []
                 )

        counts = Enum.map(rows, fn [_, c] -> c end)
        assert hd(counts) == 2
        assert Enum.at(counts, 1) == 3
        assert List.last(counts) == 2
      end

      # -------------------------------------------------------------------
      # Named windows
      # -------------------------------------------------------------------

      test "named window definition", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   """
                   SELECT name,
                     row_number() OVER w AS rn,
                     SUM(salary) OVER w AS running
                   FROM wf
                   WINDOW w AS (ORDER BY salary)
                   ORDER BY salary
                   """,
                   []
                 )

        assert length(rows) == 6
        first_rn = Enum.at(hd(rows), 1)
        assert first_rn == 1
      end

      # -------------------------------------------------------------------
      # Edge cases
      # -------------------------------------------------------------------

      test "window function on empty result set", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE wf_empty (id INTEGER, val INTEGER);")

        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(
                   conn,
                   "SELECT val, row_number() OVER (ORDER BY val) FROM wf_empty",
                   []
                 )
      end

      test "window function with single row", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE wf_one (id INTEGER, val INTEGER);
          INSERT INTO wf_one VALUES (1, 42);
          """)

        assert {:ok, %{rows: [[42, 1, nil, nil]]}} =
                 NIF.query(
                   conn,
                   "SELECT val, row_number() OVER w, lag(val) OVER w, lead(val) OVER w FROM wf_one WINDOW w AS (ORDER BY val)",
                   []
                 )
      end

      test "percent_rank() and cume_dist()", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name, percent_rank() OVER (ORDER BY salary) AS pr, cume_dist() OVER (ORDER BY salary) AS cd FROM wf ORDER BY salary",
                   []
                 )

        prs = Enum.map(rows, fn [_, pr, _] -> pr end)
        cds = Enum.map(rows, fn [_, _, cd] -> cd end)

        assert_in_delta hd(prs), 0.0, 0.001
        assert_in_delta List.last(prs), 1.0, 0.001
        assert_in_delta List.last(cds), 1.0, 0.001
        assert Enum.all?(cds, fn cd -> cd > 0.0 and cd <= 1.0 end)
      end
    end
  end
end
