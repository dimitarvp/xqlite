# A5 probe — cancel latency + its negative control (teeth).
#
# modes:
#   latency         run an effectively-unbounded slow query, let it step for a
#                   settle window, then cancel and measure wall time from the
#                   cancel_operation/1 call to the NIF returning
#                   {:error, :operation_cancelled}. Repeat N times; report the
#                   distribution. PASS iff every trial actually cancelled and
#                   the latency is bounded.
#   nocancel        TEETH: the same unbounded slow query, NEVER cancelled and
#                   with NO internal timeout. run.sh gives it a short OS timeout;
#                   it MUST be killed (rc=124 HANG). If it returns on its own the
#                   query is not actually slow and the latency numbers would be
#                   meaningless — so this control proves the query is genuinely
#                   long-running and a sub-second cancelled return is caused by
#                   the cancel, not by the query finishing.
#
# The measured latency is end-to-end (store -> dirty-scheduler detects at the
# next <=8-VM-op progress fire -> sqlite3_step returns SQLITE_INTERRUPT ->
# NIF returns -> Task message delivered). It is therefore an UPPER bound on the
# pure progress-handler detection latency; the <=8-VM-op cadence is the
# theoretical floor.
Code.require_file("probe_common.exs", __DIR__)
alias Cancellation.Probe, as: P
alias XqliteNIF, as: NIF

[mode | rest] = System.argv()
trials = (rest |> List.first() || "40") |> P.int!()
settle_ms = (rest |> Enum.at(1) || "40") |> P.int!()

conn = P.open_mem!()
sql = P.never_sql()

case mode do
  "nocancel" ->
    # Negative control: run the unbounded query with no cancel and no timeout.
    # This call is expected NEVER to return; run.sh's OS timeout classifies it
    # HANG (rc=124). Reaching any RESULT line here would itself be the teeth
    # failure (the "slow" query wasn't slow).
    IO.puts("PROBE latency-nocancel-control (expected to be killed by OS timeout)")
    {:ok, _} = NIF.query_cancellable(conn, sql, [], [])
    # Unreachable unless the query completed — which means it is not unbounded.
    P.finish("latency-nocancel-control", :no_effect, %{
      note: "unbounded query returned on its own — latency measurement invalid"
    })

  "latency" ->
    parent = self()

    latencies =
      for _ <- 1..trials do
        token = P.token!()

        task =
          P.spawn_started(parent, fn ->
            NIF.query_cancellable(conn, sql, [], [token])
          end)

        P.await_started()
        # Let the query get deep into its step loop so the cancel lands
        # mid-flight (not before stepping begins).
        Process.sleep(settle_ms)

        t0 = P.now_us()
        :ok = NIF.cancel_operation(token)
        result = Task.await(task, 30_000)
        lat = P.since_us(t0)

        case P.classify_result(result) do
          :cancelled ->
            lat

          other ->
            P.finish("latency", :no_effect, %{
              trial_outcome: other,
              raw: inspect(result),
              note: "a settled mid-flight cancel did not produce :operation_cancelled"
            })
        end
      end

    st = P.stats(latencies)
    us_to_ms = fn us -> Float.round(us / 1000, 2) end

    report = %{
      trials: st.n,
      settle_ms: settle_ms,
      cancel_latency_ms: %{
        min: us_to_ms.(st.min),
        median: us_to_ms.(st.median),
        p95: us_to_ms.(st.p95),
        p99: us_to_ms.(st.p99),
        max: us_to_ms.(st.max),
        mean: us_to_ms.(st.mean)
      },
      cancel_latency_us_median: st.median,
      theoretical_floor: "<=8 VM ops after the store is observed by the progress handler",
      all_trials_cancelled: true
    }

    P.finish("latency", :pass, report)

  other ->
    IO.puts("unknown mode: #{other}")
    System.halt(2)
end
