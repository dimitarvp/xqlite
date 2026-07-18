# A5 probe — never-cancelled overhead (INFORMATIONAL; feeds T4.7).
#
# The SQLite progress handler is installed ONCE at connection open and stays
# installed for the connection's life, firing every 8 VM ops regardless of
# whether any cancel token is registered. So the meaningful, Elixir-measurable
# question is the MARGINAL cost of a cancellable call over a plain one:
#
#   baseline    NIF.query/3            — callback fires with an EMPTY cancels
#                                         list (a null-check no-op per fire) and
#                                         no ProgressHandlerGuard register/unreg.
#   cancellable NIF.query_cancellable  — one live (never-signalled) token: the
#                                         guard registers+unregisters one
#                                         subscriber per call, and the callback
#                                         Acquire-loads that flag every 8 ops.
#
# Two workloads isolate the two cost components:
#   A  many tiny queries (SELECT 1)     -> dominated by per-CALL guard reg/unreg.
#   B  few heavy counting queries       -> dominated by per-FIRE flag loads
#                                          amortised over millions of progress
#                                          invocations.
#
# This is NOT a security finding either way — a large delta is a perf note for
# the maintainer. The ABSOLUTE cost of the always-on progress handler (vs a
# hypothetical no-handler build) is NOT measurable from Elixir; that needs a
# recompile and is called out as an honest gap.
Code.require_file("probe_common.exs", __DIR__)
alias Cancellation.Probe, as: P
alias XqliteNIF, as: NIF

argv = System.argv()
a_iters = (Enum.at(argv, 0) || "50000") |> P.int!()
b_iters = (Enum.at(argv, 1) || "20") |> P.int!()
b_bound = (Enum.at(argv, 2) || "3000000") |> P.int!()

conn = P.open_mem!()
tok = P.token!()

time_us = fn f ->
  t0 = P.now_us()
  f.()
  P.since_us(t0)
end

# warm both code paths
{:ok, _} = NIF.query(conn, "SELECT 1", [])
{:ok, _} = NIF.query_cancellable(conn, "SELECT 1", [], [tok])

# --- Workload A: many tiny queries -----------------------------------------
a_base =
  time_us.(fn ->
    for _ <- 1..a_iters, do: {:ok, _} = NIF.query(conn, "SELECT 1", [])
  end)

a_canc =
  time_us.(fn ->
    for _ <- 1..a_iters, do: {:ok, _} = NIF.query_cancellable(conn, "SELECT 1", [], [tok])
  end)

# --- Workload B: few heavy queries -----------------------------------------
heavy = P.counting_sql(b_bound)

b_base =
  time_us.(fn ->
    for _ <- 1..b_iters, do: {:ok, _} = NIF.query(conn, heavy, [])
  end)

b_canc =
  time_us.(fn ->
    for _ <- 1..b_iters, do: {:ok, _} = NIF.query_cancellable(conn, heavy, [], [tok])
  end)

r2 = fn x -> Float.round(x, 2) end
pct = fn base, canc -> if base > 0, do: r2.((canc - base) / base * 100), else: 0.0 end

report = %{
  informational: true,
  workload_a_tiny: %{
    iters: a_iters,
    baseline_ns_per_call: r2.(a_base * 1000 / a_iters),
    cancellable_ns_per_call: r2.(a_canc * 1000 / a_iters),
    overhead_pct: pct.(a_base, a_canc),
    overhead_ns_per_call: r2.((a_canc - a_base) * 1000 / a_iters)
  },
  workload_b_heavy: %{
    iters: b_iters,
    bound: b_bound,
    baseline_ms_per_call: r2.(b_base / 1000 / b_iters),
    cancellable_ms_per_call: r2.(b_canc / 1000 / b_iters),
    overhead_pct: pct.(b_base, b_canc)
  },
  note:
    "marginal cost of one registered cancel token vs a plain call; " <>
      "absolute always-on progress-handler cost needs a no-handler recompile (not measured)"
}

P.finish("overhead", :pass, report)
