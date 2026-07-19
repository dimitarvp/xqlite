# A11 feature-island probe: busy-policy `:max_elapsed_ms` is a PER-EVENT budget
# (F-A11-4 RESOLVED — maintainer decision 2026-07-20). The elapsed clock resets
# at the start of each fresh busy event (SQLite's `count == 0`), so a connection
# alive longer than the ceiling still retries a new contention through the lock
# release, exactly like `max_retries`. Before the fix the clock was anchored at
# the busy slot's INSTALL time, so an aged connection gave up with zero retries.
#
# Mechanism: two connections to one file. The holder grabs the write lock; a
# releaser task COMMITs after `release_ms`, freeing it. The probe installs a
# policy with a HUGE `max_retries` (so `max_retries` never gates — the elapsed
# budget is the sole discriminator) and sleeps between retries, optionally AGING
# the connection by `age_ms` before the contended write. A correct per-event
# budget retries through the release and SUCCEEDS whenever the release lands
# within `max_elapsed_ms` of the event's start, regardless of the slot's age.
#
# TEETH (must hold or the probe proves nothing — it discriminates the budget in
# BOTH directions):
#   * young  : age 0, ceiling 400,  release 150  -> MUST SUCCEED (retry works).
#   * aged+big: age 800, ceiling 100000, release 150 -> MUST SUCCEED (aging alone
#              does not break retries).
#   * starved: age 0, ceiling 40,   release 400  -> MUST GIVE UP fast (~ceiling
#              ms, before the release) — proves the per-event budget is a REAL
#              ceiling, not a disabled/removed check.
# FIX (the per-event budget — was the F-A11-4 footgun, now the asserted contract):
#   * aged   : age 800, ceiling 400, release 150 -> MUST SUCCEED (a fresh busy
#              event resets the clock; install-anchored would give up at 800>400).
#   * two_events: one conn, two contended writes 800 ms apart, ceiling 400,
#              release 150 each -> BOTH MUST SUCCEED (each event gets a full
#              budget; install-anchored would give up on the second).
#
# Exit: 0 teeth hold AND the per-event budget holds (fix confirmed); 1 teeth hold
# but an aged/second event GAVE UP (regression to install-anchored); 2 a tooth
# FAILED (probe invalid — retry broken or budget not enforced).

defmodule Probe do
  # A single contended write on a fresh {holder, probe} pair. Returns
  # {:SUCCEEDED | :GAVE_UP, elapsed_ms}.
  def run(dir, age_ms, max_elapsed_ms, release_ms) do
    {holder, probe, path} = setup(dir, max_elapsed_ms)
    if age_ms > 0, do: Process.sleep(age_ms)
    {outcome, dt} = contend(holder, probe, release_ms, 1)
    teardown(holder, probe, path)
    {outcome, dt}
  end

  # Two contended writes on ONE probe connection, `age_between_ms` apart, each
  # released within the ceiling. Per-event budget => both succeed; install-
  # anchored => the second gives up once the slot has aged past the ceiling.
  def two_events(dir, max_elapsed_ms, release_ms, age_between_ms) do
    {holder, probe, path} = setup(dir, max_elapsed_ms)
    {o1, _} = contend(holder, probe, release_ms, 1)
    if age_between_ms > 0, do: Process.sleep(age_between_ms)
    {o2, _} = contend(holder, probe, release_ms, 2)
    teardown(holder, probe, path)
    {o1, o2}
  end

  defp setup(dir, max_elapsed_ms) do
    path = Path.join(dir, "busy_#{:erlang.unique_integer([:positive])}.db")
    File.rm(path)
    {:ok, holder} = XqliteNIF.open(path)
    {:ok, probe} = XqliteNIF.open(path)
    {:ok, 0} = XqliteNIF.execute(holder, "CREATE TABLE t(id INTEGER)", [])

    :ok =
      Xqlite.set_busy_policy(probe,
        max_retries: 100_000,
        max_elapsed_ms: max_elapsed_ms,
        sleep_ms: 5
      )

    {holder, probe, path}
  end

  defp contend(holder, probe, release_ms, id) do
    {:ok, 0} = XqliteNIF.execute(holder, "BEGIN IMMEDIATE", [])

    spawn(fn ->
      Process.sleep(release_ms)
      # Ignore the result: on the give-up legs the holder may already be closed
      # (the probe gave up before this fires), which is a benign structured error.
      _ = XqliteNIF.execute(holder, "COMMIT", [])
    end)

    t0 = System.monotonic_time(:millisecond)
    result = XqliteNIF.execute(probe, "INSERT INTO t VALUES (#{id})", [])
    dt = System.monotonic_time(:millisecond) - t0
    outcome = if match?({:ok, _}, result), do: :SUCCEEDED, else: :GAVE_UP
    {outcome, dt}
  end

  defp teardown(holder, probe, path) do
    Process.sleep(30)
    XqliteNIF.close(holder)
    XqliteNIF.close(probe)
    File.rm(path)
  end
end

dir = System.get_env("FI_DIR") || System.tmp_dir!()

{young, young_ms} = Probe.run(dir, 0, 400, 150)
{aged_big, aged_big_ms} = Probe.run(dir, 800, 100_000, 150)
{starved, starved_ms} = Probe.run(dir, 0, 40, 400)
{aged, aged_ms} = Probe.run(dir, 800, 400, 150)
{ev1, ev2} = Probe.two_events(dir, 400, 150, 800)

IO.puts("RESULT young        outcome=#{young}    ms=#{young_ms}")
IO.puts("RESULT aged+big     outcome=#{aged_big} ms=#{aged_big_ms}")
IO.puts("RESULT starved      outcome=#{starved}   ms=#{starved_ms}")
IO.puts("RESULT aged(fix)    outcome=#{aged}    ms=#{aged_ms}")
IO.puts("RESULT two_events   ev1=#{ev1} ev2=#{ev2}")

teeth_ok =
  young == :SUCCEEDED and aged_big == :SUCCEEDED and starved == :GAVE_UP and starved_ms < 300

fix_ok = aged == :SUCCEEDED and ev1 == :SUCCEEDED and ev2 == :SUCCEEDED

cond do
  not teeth_ok ->
    IO.puts(
      "TEETH FAILED: young=#{young} aged+big=#{aged_big} starved=#{starved}/#{starved_ms}ms " <>
        "(retry or budget-enforcement broken; probe proves nothing)"
    )

    System.halt(2)

  fix_ok ->
    IO.puts(
      "PER-EVENT BUDGET CONFIRMED: aged conn retried through the release in #{aged_ms} ms " <>
        "and a second event 800 ms later also succeeded — max_elapsed_ms resets per busy event."
    )

    System.halt(0)

  true ->
    IO.puts(
      "REGRESSION: aged=#{aged}(#{aged_ms}ms) two_events ev1=#{ev1} ev2=#{ev2} — an aged/second " <>
        "event gave up; max_elapsed_ms is anchored at install again (F-A11-4 back)."
    )

    System.halt(1)
end
