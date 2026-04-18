defmodule Xqlite.ExplainAnalyze do
  @moduledoc """
  Structured report from `Xqlite.explain_analyze/3`.

  Combines SQLite's static plan (`EXPLAIN QUERY PLAN`) with runtime stats
  collected via `sqlite3_stmt_scanstatus_v2` and `sqlite3_stmt_status`, plus
  a wall-clock timer around the execution.

  ## Fields

    * `:wall_time_ns` — nanoseconds the statement spent inside `sqlite3_step`,
      measured with `std::time::Instant` on the Rust side.
    * `:rows_produced` — how many rows the statement returned. Always 0 for
      DML without `RETURNING`.
    * `:stmt_counters` — statement-level counters. See
      [`sqlite3_stmt_status`](https://sqlite.org/c3ref/stmt_status.html).
      Notable entries:
        * `:fullscan_step` — rows iterated via full-table scan, index included.
          Non-zero generally means a missing index.
        * `:vm_step` — total VDBE instructions executed.
        * `:sort` — rows sorted by `ORDER BY` / `GROUP BY`.
        * `:memused_bytes` — peak memory used by the statement.
    * `:scans` — per-loop runtime stats. One entry per scan node in the
      executed plan. Keys per entry: `:loops`, `:rows_visited`,
      `:estimated_rows`, `:name`, `:explain`, `:selectid`, `:parentid`. A big
      gap between `:rows_visited` and `:estimated_rows` hints at stale
      `ANALYZE` data or a mis-estimated join.
    * `:query_plan` — rows from `EXPLAIN QUERY PLAN`. One entry per plan node,
      with `:id`, `:parent`, and `:detail` (the human-readable "SCAN table"
      / "SEARCH table USING INDEX ..." line).

  ## SQLite has no per-operator wall time

  Postgres's `EXPLAIN (ANALYZE)` attributes wall time to every plan node.
  SQLite does not. We report a whole-statement wall time plus per-loop row
  counts and estimates, and you infer hot spots from the combination.
  """

  @enforce_keys [
    :wall_time_ns,
    :rows_produced,
    :stmt_counters,
    :scans,
    :query_plan
  ]
  defstruct [
    :wall_time_ns,
    :rows_produced,
    :stmt_counters,
    :scans,
    :query_plan
  ]

  @type scan :: %{
          loops: non_neg_integer(),
          rows_visited: non_neg_integer(),
          estimated_rows: float(),
          name: String.t(),
          explain: String.t(),
          selectid: integer(),
          parentid: integer()
        }

  @type query_plan_row :: %{
          id: integer(),
          parent: integer(),
          detail: String.t()
        }

  @type stmt_counters :: %{
          fullscan_step: integer(),
          sort: integer(),
          autoindex: integer(),
          vm_step: integer(),
          reprepare: integer(),
          run: integer(),
          filter_miss: integer(),
          filter_hit: integer(),
          memused_bytes: integer()
        }

  @type t :: %__MODULE__{
          wall_time_ns: non_neg_integer(),
          rows_produced: non_neg_integer(),
          stmt_counters: stmt_counters(),
          scans: [scan()],
          query_plan: [query_plan_row()]
        }

  @doc """
  Converts the raw NIF report map into an `%Xqlite.ExplainAnalyze{}` struct.
  """
  @spec from_map(map()) :: t()
  def from_map(%{
        wall_time_ns: wall,
        rows_produced: rows,
        stmt_counters: counters,
        scans: scans,
        query_plan: plan
      }) do
    %__MODULE__{
      wall_time_ns: wall,
      rows_produced: rows,
      stmt_counters: counters,
      scans: scans,
      query_plan: plan
    }
  end
end
