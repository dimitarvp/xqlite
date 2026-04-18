defmodule Xqlite.NIF.ExplainAnalyzeTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  defp setup_t(conn) do
    :ok =
      NIF.execute_batch(conn, """
      CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
      INSERT INTO t(name) VALUES ('a'), ('b'), ('c');
      CREATE INDEX t_name_idx ON t(name);
      """)

    conn
  end

  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "shape: returns all expected top-level keys", %{conn: conn} do
        setup_t(conn)

        assert {:ok, report} = NIF.explain_analyze(conn, "SELECT * FROM t", [])

        assert Map.has_key?(report, :wall_time_ns)
        assert Map.has_key?(report, :rows_produced)
        assert Map.has_key?(report, :stmt_counters)
        assert Map.has_key?(report, :scans)
        assert Map.has_key?(report, :query_plan)
      end

      test "counts rows produced by a plain SELECT", %{conn: conn} do
        setup_t(conn)

        assert {:ok, report} = NIF.explain_analyze(conn, "SELECT * FROM t", [])
        assert report.rows_produced == 3
      end

      test "filters with a bound parameter", %{conn: conn} do
        setup_t(conn)

        assert {:ok, report} =
                 NIF.explain_analyze(conn, "SELECT name FROM t WHERE name = ?", ["b"])

        assert report.rows_produced == 1
      end

      test "wall time is non-negative and reasonable for a trivial query", %{conn: conn} do
        setup_t(conn)

        assert {:ok, report} = NIF.explain_analyze(conn, "SELECT 1", [])
        assert is_integer(report.wall_time_ns)
        assert report.wall_time_ns >= 0
        # A literal SELECT should finish well under 100ms on any sane host.
        assert report.wall_time_ns < 100_000_000
      end

      test "query_plan entries have (id, parent, detail)", %{conn: conn} do
        setup_t(conn)

        assert {:ok, report} = NIF.explain_analyze(conn, "SELECT * FROM t", [])
        assert is_list(report.query_plan)
        assert length(report.query_plan) >= 1

        for row <- report.query_plan do
          assert Map.has_key?(row, :id)
          assert Map.has_key?(row, :parent)
          assert Map.has_key?(row, :detail)
          assert is_binary(row.detail)
        end
      end

      test "scans list is populated for a query with a plan", %{conn: conn} do
        setup_t(conn)

        assert {:ok, report} = NIF.explain_analyze(conn, "SELECT * FROM t", [])
        assert is_list(report.scans)
        assert length(report.scans) >= 1

        [first | _] = report.scans
        assert Map.has_key?(first, :loops)
        assert Map.has_key?(first, :rows_visited)
        assert Map.has_key?(first, :estimated_rows)
        assert Map.has_key?(first, :name)
        assert Map.has_key?(first, :explain)
        assert Map.has_key?(first, :selectid)
        assert Map.has_key?(first, :parentid)
      end

      test "indexed lookup picks the index (SEARCH, not SCAN)", %{conn: conn} do
        setup_t(conn)

        assert {:ok, report} =
                 NIF.explain_analyze(conn, "SELECT id FROM t WHERE name = ?", ["b"])

        joined = report.query_plan |> Enum.map(& &1.detail) |> Enum.join(" | ")
        assert joined =~ "SEARCH"
        assert joined =~ "t_name_idx"
      end

      test "unindexed query emits fullscan_step counts", %{conn: conn} do
        setup_t(conn)

        assert {:ok, report} =
                 NIF.explain_analyze(conn, "SELECT id FROM t WHERE id + 1 = 2", [])

        assert report.stmt_counters.fullscan_step > 0
      end

      test "reports wall time for COUNT queries", %{conn: conn} do
        setup_t(conn)

        assert {:ok, report} = NIF.explain_analyze(conn, "SELECT COUNT(*) FROM t", [])
        assert report.rows_produced == 1
        assert report.stmt_counters.vm_step > 0
      end

      test "errors bubble up like a normal query error for bad SQL", %{conn: conn} do
        assert {:error, _} = NIF.explain_analyze(conn, "SELECT * FROM does_not_exist", [])
      end

      test "DML without RETURNING reports rows_produced: 0", %{conn: conn} do
        setup_t(conn)

        assert {:ok, report} =
                 NIF.explain_analyze(conn, "INSERT INTO t(name) VALUES ('d')", [])

        assert report.rows_produced == 0
      end

      test "empty SQL (whitespace only) returns an empty report", %{conn: conn} do
        assert {:ok, report} = NIF.explain_analyze(conn, "   ", [])
        assert report.wall_time_ns == 0
        assert report.rows_produced == 0
        assert report.scans == []
      end
    end
  end
end
