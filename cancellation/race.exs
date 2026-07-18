# A5 probe — cancel-vs-completion race.
#
# Hammers the window where a cancel `store(true)` lands in the same instant the
# query finishes. Each iteration classifies the caller-observed result into one
# of exactly two well-defined buckets:
#
#   :completed  {:ok, %{rows: ...}}              — the query finished first
#   :cancelled  {:error, :operation_cancelled}   — the cancel won the race
#
# ANY other shape is :torn — a partial/garbage/undefined result — which is the
# S0 signal (exit 3 RACE_TORN). A crash (UAF from cancel racing the last step)
# would take the VM down and never reach RESULT (run.sh sees 134/139).
#
# TEETH:
#   * The window must actually be exercised: BOTH :completed and :cancelled must
#     occur across the run. If only one class appears the race window is not
#     real and the PASS proves nothing -> exit 5 NOT_EXERCISED. To keep this
#     robust across machine speeds the query bound is CALIBRATED at runtime to a
#     target natural runtime R, and the cancel jitter is uniform(0, 2R) so some
#     cancels land clearly-before and some clearly-after completion.
#   * TEETH=torn injects one synthetic torn outcome into the tally to prove the
#     :torn classifier is not rubber-stamping (must yield exit 3).
Code.require_file("probe_common.exs", __DIR__)
alias Cancellation.Probe, as: P
alias XqliteNIF, as: NIF

[iters_s | _] = System.argv() ++ ["300"]
iters = P.int!(iters_s)
teeth = System.get_env("TEETH")

conn = P.open_mem!()

# --- calibrate: find a bound whose natural (uncancelled) runtime R is in a
# timer-friendly band so ms-granularity jitter can straddle completion.
calibrate = fn bound ->
  sql = P.counting_sql(bound)
  # median of a few uncancelled runs
  runs =
    for _ <- 1..3 do
      t0 = P.now_us()
      {:ok, _} = NIF.query_cancellable(conn, sql, [], [])
      P.since_us(t0)
    end

  P.stats(runs).median
end

target_lo_us = 15_000
target_hi_us = 250_000

{bound, r_us} =
  Enum.reduce_while(0..12, {200_000, nil}, fn _, {b, _} ->
    r = calibrate.(b)

    cond do
      r < target_lo_us -> {:cont, {b * 2, r}}
      r > target_hi_us -> {:cont, {max(1, div(b, 2)), r}}
      true -> {:halt, {b, r}}
    end
  end)

r_us = r_us || calibrate.(bound)
sql = P.counting_sql(bound)
r_ms = max(1, div(r_us, 1000))
parent = self()

tally =
  for _ <- 1..iters, reduce: %{completed: 0, cancelled: 0, torn: 0, other: %{}} do
    acc ->
      token = P.token!()

      task =
        P.spawn_started(parent, fn ->
          NIF.query_cancellable(conn, sql, [], [token])
        end)

      P.await_started()
      # jitter uniform in [0, 2R]: straddles the completion instant.
      Process.sleep(:rand.uniform(2 * r_ms + 1) - 1)
      :ok = NIF.cancel_operation(token)
      result = Task.await(task, 30_000)

      case P.classify_result(result) do
        :completed ->
          %{acc | completed: acc.completed + 1}

        :cancelled ->
          %{acc | cancelled: acc.cancelled + 1}

        torn_class ->
          # Any non-{completed,cancelled} shape here is undefined for a
          # query_cancellable: it takes no conn-closed / stmt-finalized path.
          %{
            acc
            | torn: acc.torn + 1,
              other: Map.update(acc.other, {torn_class, inspect(result)}, 1, &(&1 + 1))
          }
      end
  end

# TEETH: inject a synthetic torn outcome to prove the classifier bites.
tally =
  if teeth == "torn" do
    %{tally | torn: tally.torn + 1, other: Map.put(tally.other, {:injected, "TEETH"}, 1)}
  else
    tally
  end

report = %{
  iters: iters,
  calibrated_bound: bound,
  natural_runtime_ms: Float.round(r_us / 1000, 2),
  completed: tally.completed,
  cancelled: tally.cancelled,
  torn: tally.torn,
  torn_detail: tally.other
}

cond do
  tally.torn > 0 ->
    P.finish("race", :race_torn, report)

  tally.completed == 0 or tally.cancelled == 0 ->
    P.finish("race", :not_exercised, Map.put(report, :note, "only one outcome class observed"))

  true ->
    P.finish("race", :pass, report)
end
