# A11 feature-island probe: busy-policy `:max_elapsed_ms` is anchored at the
# busy slot's INSTALL time, not at the start of each busy event (F-A11-4, S3).
#
# Mechanism: two connections to one file. The holder grabs the write lock; a
# releaser task COMMITs after `release_ms`, freeing it. The probe installs a
# policy with a HUGE `max_retries` (so max_retries never gates) and sleeps
# between retries, then optionally AGES the connection by `age_ms` before
# attempting the contended write. A correct *per-event* elapsed budget would
# retry through the release and SUCCEED whenever `max_elapsed_ms > release_ms`.
#
# TEETH (must hold or the probe proves nothing):
#   * young  : age 0,   ceiling 400,    release 150  -> MUST SUCCEED (retry works)
#   * aged+big: age 800, ceiling 100000, release 150 -> MUST SUCCEED (aging alone
#               does not break retries)
# FINDING (the footgun):
#   * aged   : age 800, ceiling 400,    release 150  -> gives up FAST, ~0 retries
#             because elapsed-since-INSTALL (800) already exceeds the ceiling.
#
# Exit: 0 teeth hold AND finding reproduces; 3 teeth hold but finding is GONE
# (bug fixed — informational); 2 a tooth FAILED (probe invalid).

defmodule Probe do
  def run(dir, age_ms, max_elapsed_ms, release_ms) do
    path = Path.join(dir, "busy_#{:erlang.unique_integer([:positive])}.db")
    File.rm(path)
    {:ok, holder} = XqliteNIF.open(path)
    {:ok, probe} = XqliteNIF.open(path)
    {:ok, 0} = XqliteNIF.execute(holder, "CREATE TABLE t(id INTEGER)", [])
    {:ok, 0} = XqliteNIF.execute(holder, "BEGIN IMMEDIATE", [])

    :ok =
      Xqlite.set_busy_policy(probe,
        max_retries: 100_000,
        max_elapsed_ms: max_elapsed_ms,
        sleep_ms: 5
      )

    if age_ms > 0, do: Process.sleep(age_ms)

    spawn(fn ->
      Process.sleep(release_ms)
      {:ok, _} = XqliteNIF.execute(holder, "COMMIT", [])
    end)

    t0 = System.monotonic_time(:millisecond)
    result = XqliteNIF.execute(probe, "INSERT INTO t VALUES (1)", [])
    dt = System.monotonic_time(:millisecond) - t0
    Process.sleep(30)
    XqliteNIF.close(holder)
    XqliteNIF.close(probe)
    File.rm(path)

    outcome = if match?({:ok, _}, result), do: :SUCCEEDED, else: :GAVE_UP
    {outcome, dt}
  end
end

dir = System.get_env("FI_DIR") || System.tmp_dir!()

{young, young_ms} = Probe.run(dir, 0, 400, 150)
{aged_big, aged_big_ms} = Probe.run(dir, 800, 100_000, 150)
{aged, aged_ms} = Probe.run(dir, 800, 400, 150)

IO.puts("RESULT young        outcome=#{young}    ms=#{young_ms}")
IO.puts("RESULT aged+big     outcome=#{aged_big} ms=#{aged_big_ms}")
IO.puts("RESULT aged(finding) outcome=#{aged}     ms=#{aged_ms}")

teeth_ok = young == :SUCCEEDED and aged_big == :SUCCEEDED

cond do
  not teeth_ok ->
    IO.puts("TEETH FAILED: young=#{young} aged+big=#{aged_big} (retry mechanism did not work)")
    System.halt(2)

  aged == :GAVE_UP and aged_ms < 60 ->
    IO.puts("FINDING REPRODUCED: aged conn gave up in #{aged_ms} ms (0 retries) — install-anchored max_elapsed_ms")
    System.halt(0)

  true ->
    IO.puts("FINDING GONE: aged conn -> #{aged} in #{aged_ms} ms (max_elapsed_ms now per-event?)")
    System.halt(3)
end
