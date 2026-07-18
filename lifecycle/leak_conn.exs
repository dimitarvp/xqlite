# Probe: connection open/use/close leak loop (review axis A6).
#
#   leak_conn.exs <n> <churn|retain> <mem|file> [db_path]
#
# churn  : open -> create table -> insert -> query -> close, repeated <n> times.
#          The real probe. A bounded connection lifecycle must reach RSS steady
#          state -> PASS.
# retain : open + populate, but KEEP every connection alive in an accumulator
#          (never closed, never GC'd). The negative control / TEETH — a genuine
#          leak of both BEAM resource structs and C-side sqlite3* state. The
#          trend classifier MUST flag this as LEAK, or the instrument is blind.
#
# mem  uses Xqlite.open_in_memory/0 (fast; exercises the full XqliteConn open
#      path: 5 hook master-callbacks installed, busy slot, Drop teardown).
# file uses a WAL file DB (adds the VFS/OS-fd close path; fd_count catches a
#      descriptor leak that RSS might hide).
Code.require_file("probe_common.exs", __DIR__)
alias Lifecycle.Probe

[n_str, mode, backing | rest] = System.argv()
n = Probe.int!(n_str)
db_path = List.first(rest)

opener =
  case backing do
    "mem" -> fn -> Probe.open_mem!() end
    "file" -> fn -> Probe.open_file!(db_path) end
  end

# Checkpoints: post-warmup baseline at 10%, then evenly to 100%.
warmup = max(1, div(n, 10))
checkpoints = [warmup] ++ Enum.map(1..5, fn k -> warmup + div((n - warmup) * k, 5) end)
checkpoints = checkpoints |> Enum.uniq() |> Enum.sort()

use_one = fn conn ->
  {:ok, _} =
    Xqlite.execute(conn, "CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY, v INTEGER)", [])

  {:ok, _} = Xqlite.execute(conn, "INSERT INTO t(v) VALUES (?1)", [:rand.uniform(1_000_000)])
  {:ok, _} = Xqlite.query(conn, "SELECT count(*) FROM t", [])
  :ok
end

{_acc, samples} =
  Enum.reduce(1..n, {[], []}, fn i, {acc, samples} ->
    conn = opener.()
    use_one.(conn)

    acc =
      case mode do
        "churn" ->
          Xqlite.close(conn)
          acc

        "retain" ->
          [conn | acc]
      end

    samples =
      if i in checkpoints do
        [Probe.sample(i) | samples]
      else
        samples
      end

    {acc, samples}
  end)

samples = Enum.reverse(samples)
{class, report} = Probe.classify(samples)
Probe.finish("conn/#{mode}/#{backing}", class, report, samples)
