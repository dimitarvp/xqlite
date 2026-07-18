# PROBE 3 — busy contention: two connections writing the same file DB under a
# retry policy + observer.
#
# Two independent connections (A, B) to the SAME file each run a loop of
# `BEGIN IMMEDIATE; INSERT; COMMIT` over disjoint id bands, concurrently. In
# WAL mode only one writer holds the write lock at a time, so each connection
# repeatedly finds the other holding it → SQLITE_BUSY → the busy policy retries
# → the observer fires `{:xqlite_busy, retries, elapsed_ms}`. We assert:
#   * the observer fired at least once (else NO_CONTENTION — inconclusive),
#   * both id bands are fully present at the end (no lost update),
#   * integrity_check is "ok",
#   * the whole thing completes inside the orchestrator's bounded timeout
#     (a deadlock/livelock would instead HANG or lose writes).
#
# Emits: 0 PASS · 3 CORRUPTION · 4 WRONGRESULT (lost update) · 6 NO_CONTENTION.
#
# TEETH: XQLITE_PROBE_TAMPER=drop deletes one committed row before the invariant
# check → must report WRONGRESULT, proving the lost-update oracle fires.
#
# argv: <db_path> <rows_per_conn>
Code.require_file("probe_common.exs", __DIR__)
alias Concurrency.Probe

[db_path, rpc_s] = System.argv()
rows_per_conn = Probe.int!(rpc_s)
collector = self()

# One connection just to create the table up front.
setup = Probe.open!(db_path, :wal)
Probe.create_table!(setup)
Xqlite.close(setup)

# One writer connection: policy + observer (→ collector), then a contended
# BEGIN IMMEDIATE / INSERT / COMMIT loop over `ids`.
run_writer = fn ids ->
  conn = Probe.open!(db_path, :wal)
  :ok = Xqlite.set_busy_policy(conn, max_retries: 5_000, max_elapsed_ms: 60_000, sleep_ms: 1)
  {:ok, _h} = Xqlite.register_busy_observer(conn, collector)

  acked =
    Enum.reduce(ids, [], fn id, acc ->
      p = Probe.payload(id, 256)
      ck = Probe.checksum(p)

      # Retry the whole IMMEDIATE txn at the app level too, in case the policy
      # surrenders — so a legitimately-inserted row is never miscounted.
      insert_once = fn ->
        with {:ok, _} <- Xqlite.execute(conn, "BEGIN IMMEDIATE", []),
             {:ok, _} <-
               Xqlite.execute(conn, "INSERT INTO t(id,payload,ck) VALUES(?1,?2,?3)", [id, p, ck]),
             {:ok, _} <- Xqlite.execute(conn, "COMMIT", []) do
          :ok
        else
          err ->
            _ = Xqlite.execute(conn, "ROLLBACK", [])
            err
        end
      end

      case Stream.repeatedly(insert_once) |> Enum.find(&(&1 == :ok)) do
        :ok -> [id | acc]
      end
    end)

  Xqlite.close(conn)
  acked
end

band_a = 1..rows_per_conn |> Enum.to_list()
band_b = (1_000_000 + 1)..(1_000_000 + rows_per_conn) |> Enum.to_list()

ta = Task.async(fn -> run_writer.(band_a) end)
tb = Task.async(fn -> run_writer.(band_b) end)
acked_a = Task.await(ta, :infinity)
acked_b = Task.await(tb, :infinity)
expected = MapSet.new(acked_a ++ acked_b)

# Drain observer messages. Give any in-flight enif_send deliveries a moment to
# land before draining (they are dispatched from the dirty-scheduler thread).
Process.sleep(100)

count_busy = fn count_fn ->
  receive do
    {:xqlite_busy, r, e} when is_integer(r) and is_integer(e) -> count_fn.(count_fn) + 1
  after
    0 -> 0
  end
end

observer_count = count_busy.(count_busy)

verify = Probe.open!(db_path, :wal)

# TEETH: drop one committed row so the lost-update oracle must fire.
if System.get_env("XQLITE_PROBE_TAMPER") == "drop" and MapSet.size(expected) > 0 do
  victim = expected |> Enum.sort() |> hd()
  {:ok, _} = Xqlite.execute(verify, "DELETE FROM t WHERE id = ?1", [victim])
end

case Probe.integrity(verify) do
  {:bad, detail} ->
    Probe.emit("CORRUPTION", 3, detail)

  :ok ->
    case Probe.read_and_check_rows(verify, 256) do
      {:bad, detail} ->
        Probe.emit("CORRUPTION", 3, detail)

      {:ok, actual} ->
        missing = MapSet.difference(expected, actual)

        cond do
          MapSet.size(missing) > 0 ->
            Probe.emit("WRONGRESULT", 4, {:lost_update, Enum.take(Enum.sort(missing), 20)})

          observer_count == 0 ->
            Probe.emit("NO_CONTENTION", 6, {:no_busy_observed, MapSet.size(expected)})

          true ->
            Xqlite.close(verify)
            Probe.emit("PASS", 0, %{rows: MapSet.size(actual), busy_events: observer_count})
        end
    end
end
