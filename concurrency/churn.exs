# PROBE 4 — open/close churn (rusqlite#1860 reproduction attempt).
#
# rusqlite#1860 (OPEN upstream) reports a VFS deadlock under concurrent
# open/close churn against one file DB. This spawns N BEAM workers that each
# open a FRESH connection to the same WAL file, do one trivial op, and close —
# repeated M times, all concurrently on real OS threads. If the bundled SQLite
# (3.53.2, THREADSAFE=1) hits that hang, this child never terminates and the
# orchestrator's outer `timeout` classifies it HANG. A clean run completes far
# under the timeout and integrity_check stays "ok".
#
# Emits (when it terminates): 0 PASS · 3 CORRUPTION. A HANG is detected by the
# orchestrator (exit 124), never by this script.
#
# argv: <db_path> <n_workers> <iters_per_worker>
Code.require_file("probe_common.exs", __DIR__)
alias Concurrency.Probe

[db_path, nw_s, iters_s] = System.argv()
n_workers = Probe.int!(nw_s)
iters = Probe.int!(iters_s)

setup = Probe.open!(db_path, :wal)
Probe.create_table!(setup)
:ok = Probe.insert(setup, 1, 256)
Xqlite.close(setup)

worker = fn w ->
  Enum.each(1..iters, fn i ->
    conn = Probe.open!(db_path, :wal)

    if rem(w, 2) == 0 do
      # Writer path: touches the -wal/-shm files on open+close.
      id = (w + 2) * 100_000 + i
      _ = Probe.insert(conn, id, 64)
    else
      # Reader path.
      {:ok, %{rows: [[n]]}} = Xqlite.query(conn, "SELECT COUNT(*) FROM t", [])
      true = is_integer(n)
    end

    :ok = Xqlite.close(conn)
  end)

  :ok
end

tasks = for w <- 0..(n_workers - 1), do: Task.async(fn -> worker.(w) end)
_ = Task.await_many(tasks, :infinity)

final = Probe.open!(db_path, :wal)

case Probe.integrity(final) do
  {:bad, detail} ->
    Probe.emit("CORRUPTION", 3, detail)

  :ok ->
    {:ok, %{rows: [[n]]}} = Xqlite.query(final, "SELECT COUNT(*) FROM t", [])
    Xqlite.close(final)
    Probe.emit("PASS", 0, %{opens: n_workers * iters, rows: n})
end
