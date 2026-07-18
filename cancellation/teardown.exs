# A5 probe — cancel racing teardown (the deep W3 probe).
#
# Hammers cancel() (an off-Mutex Arc<AtomicBool> store) against the token /
# guard / connection / statement being closed, finalized, or GC-dropped
# concurrently, many iterations under an OS timeout. The raw *const AtomicBool
# in each CancelSubscriber must never dangle: the ProgressHandlerGuard holds its
# OWN Arc clone (t.0.clone()) so the pointee outlives the token resource, and it
# unregisters-before-releasing under the conn Mutex; the callback reads only
# under that Mutex. Sibling drivers shipped cancel-vs-teardown UAFs — this
# proves ours does not.
#
# Every iteration's in-flight cancellable step may legitimately observe:
#   :cancelled       the cancel storm won
#   :conn_closed     close(conn) landed first (Mutex-serialised)
#   :stmt_finalized  finalize(stmt) landed first (swap-then-lock)
#   :completed       (only for the bounded rerun tail; the never-query does not)
# ANY other shape is :torn -> S0 (exit 3). A UAF/double-free/unwind-into-C would
# abort the VM and never reach RESULT (run.sh: 134/139 CRASH). A wedge (deadlock
# on the conn Mutex) never returns (run.sh OS timeout: 124 HANG).
#
# Interleavings exercised, rotated per iteration:
#   * close(conn)      racing an in-flight multi_step_cancellable + 2 cancel storms
#   * finalize(stmt)   racing the same
#   * cancel-after-teardown  (store to a live Arc with the conn gone / no op)
#   * GC-drop-under-cancel   a holder process runs a step, a sibling cancels,
#                            the holder is killed mid-op -> resource destructors
#                            (conn/stmt/token) run while a cancel is live
#   * inter-iteration churn: 3 extra tokens cancelled and dropped each iteration
#     so token-resource destructors overlap the next iteration's activity.
Code.require_file("probe_common.exs", __DIR__)
alias Cancellation.Probe, as: P
alias XqliteNIF, as: NIF

[iters_s | _] = System.argv() ++ ["400"]
iters = P.int!(iters_s)
never = P.never_sql()

# One conn/stmt/token, an in-flight step, a cancel storm, and a teardown action
# all racing; returns the step's classified outcome.
run_iter = fn i ->
  conn = P.open_mem!()
  {:ok, stmt} = Xqlite.prepare(conn, never)
  token = P.token!()

  # churn: extra tokens signalled then abandoned -> destructors overlap below
  _churn = for _ <- 1..3, do: (t = P.token!(); NIF.cancel_operation(t); t)

  stepper = Task.async(fn -> Xqlite.multi_step_cancellable(stmt, 100, [token]) end)

  cancellers =
    for _ <- 1..2 do
      Task.async(fn ->
        for _ <- 1..200, do: NIF.cancel_operation(token)
        :done
      end)
    end

  # tiny jitter so teardown lands at varied points in the step loop
  Process.sleep(:rand.uniform(3) - 1)

  case rem(i, 3) do
    0 -> NIF.close(conn)
    1 -> Xqlite.finalize(stmt)
    2 -> NIF.close(conn)
  end

  res = Task.await(stepper, 20_000)
  for c <- cancellers, do: Task.await(c, 5_000)

  # cancel-after-teardown: store to a still-live Arc, no op in flight
  for _ <- 1..5, do: NIF.cancel_operation(token)

  # tear down the other handle too (idempotent)
  NIF.close(conn)
  _ = Xqlite.finalize(stmt)

  P.classify_result(res)
end

# A holder process opens conn+stmt+token and starts a step; a sibling cancels
# the shared token; the holder is killed mid-op. When the (cancelled) NIF
# returns, the dying holder drops the last conn/stmt refs and their destructors
# run WHILE a cancel is/was live against the shared token. Crash-free is the
# whole assertion (no RESULT is produced by this leg; it just must not crash).
gc_drop_iter = fn ->
  token = P.token!()

  holder =
    spawn(fn ->
      conn = P.open_mem!()
      {:ok, stmt} = Xqlite.prepare(conn, P.never_sql())
      _ = Xqlite.multi_step_cancellable(stmt, 100, [token])
      # keep the refs live until the process is killed
      Process.sleep(:infinity)
      _ = {conn, stmt}
    end)

  Process.sleep(:rand.uniform(3) - 1)
  for _ <- 1..50, do: NIF.cancel_operation(token)
  Process.exit(holder, :kill)
  :erlang.garbage_collect()
  :ok
end

tally =
  for i <- 1..iters, reduce: %{cancelled: 0, conn_closed: 0, stmt_finalized: 0, completed: 0, torn: 0, torn_detail: %{}} do
    acc ->
      if rem(i, 7) == 0, do: gc_drop_iter.()

      case run_iter.(i) do
        :cancelled -> %{acc | cancelled: acc.cancelled + 1}
        :conn_closed -> %{acc | conn_closed: acc.conn_closed + 1}
        :stmt_finalized -> %{acc | stmt_finalized: acc.stmt_finalized + 1}
        :completed -> %{acc | completed: acc.completed + 1}
        other -> %{acc | torn: acc.torn + 1, torn_detail: Map.update(acc.torn_detail, other, 1, &(&1 + 1))}
      end
  end

report = %{
  iters: iters,
  cancelled: tally.cancelled,
  conn_closed: tally.conn_closed,
  stmt_finalized: tally.stmt_finalized,
  completed: tally.completed,
  torn: tally.torn,
  torn_detail: tally.torn_detail
}

if tally.torn > 0 do
  P.finish("teardown", :race_torn, report)
else
  P.finish("teardown", :pass, report)
end
