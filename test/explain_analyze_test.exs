defmodule Xqlite.ExplainAnalyzeTest do
  use ExUnit.Case, async: true

  describe "Xqlite.explain_analyze/3" do
    test "returns an %Xqlite.ExplainAnalyze{} struct" do
      {:ok, conn} = Xqlite.open_in_memory()

      :ok =
        XqliteNIF.execute_batch(conn, """
        CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);
        INSERT INTO t(name) VALUES ('a'), ('b'), ('c');
        """)

      assert {:ok, %Xqlite.ExplainAnalyze{} = report} =
               Xqlite.explain_analyze(conn, "SELECT * FROM t", [])

      assert is_integer(report.wall_time_ns)
      assert report.rows_produced == 3
      assert is_map(report.stmt_counters)
      assert is_list(report.scans)
      assert is_list(report.query_plan)

      :ok = XqliteNIF.close(conn)
    end

    test "plumbs errors through" do
      {:ok, conn} = Xqlite.open_in_memory()

      assert {:error, _} = Xqlite.explain_analyze(conn, "SELECT * FROM bogus", [])

      :ok = XqliteNIF.close(conn)
    end
  end
end
