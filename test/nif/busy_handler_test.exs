defmodule Xqlite.NIF.BusyHandlerTest do
  # Not using the `connection_openers` for-loop because we specifically need
  # two connections to the SAME file-backed database to force real lock
  # contention; in-memory connections have separate lock domains.
  use ExUnit.Case, async: true

  import Xqlite.Telemetry.TestSupport, only: [attach_capture: 1, detach: 1]
  import Xqlite.TestUtil, only: [tmp_db_path: 1]

  alias XqliteNIF, as: NIF

  setup do
    {:ok, path: tmp_db_path("busy")}
  end

  # Build a probe connection ready for contention:
  # - holder opens the file and grabs a write intent (RESERVED lock)
  # - probe opens the same file with a retry policy and an observer
  #   pointed at `self()`
  defp prime_contention(path, policy_opts) do
    test_pid = self()
    {:ok, holder} = NIF.open(path)
    {:ok, probe} = NIF.open(path)

    {:ok, 0} = NIF.execute(holder, "CREATE TABLE t(id INTEGER)", [])
    {:ok, 0} = NIF.execute(holder, "BEGIN IMMEDIATE", [])

    :ok = Xqlite.set_busy_policy(probe, policy_opts)
    {:ok, _handle} = Xqlite.register_busy_observer(probe, test_pid)

    {holder, probe}
  end

  test "observer fires and the caller eventually succeeds after release", %{path: path} do
    # Generous retry window; we release the lock well before we'd run out.
    {holder, probe} =
      prime_contention(path, max_retries: 50, max_elapsed_ms: 1_000, sleep_ms: 10)

    probe_task =
      Task.async(fn ->
        NIF.execute(probe, "INSERT INTO t VALUES (1)", [])
      end)

    # Let the probe hit SQLITE_BUSY and retry a few times, then release.
    Process.sleep(30)
    {:ok, _} = NIF.execute(holder, "COMMIT", [])

    # We should have seen at least one {:xqlite_busy, retries, elapsed_ms}
    # message before the insert completed.
    assert_receive {:xqlite_busy, first_retries, first_elapsed}, 500
    assert is_integer(first_retries) and first_retries >= 0
    assert is_integer(first_elapsed) and first_elapsed >= 0

    # The insert should have succeeded after the holder released.
    assert {:ok, 1} = Task.await(probe_task, 1_000)

    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end

  test "policy gives up after max_retries; caller sees busy", %{path: path} do
    # Tight ceiling: 3 retries × 10 ms sleep = ~30 ms before surrender.
    {holder, probe} =
      prime_contention(path, max_retries: 3, max_elapsed_ms: 500, sleep_ms: 10)

    # Don't release. The insert should give up.
    result = NIF.execute(probe, "INSERT INTO t VALUES (1)", [])

    assert match?({:error, _}, result)

    # At least one busy notification was delivered before we surrendered.
    assert_receive {:xqlite_busy, _, _}, 200

    {:ok, _} = NIF.execute(holder, "COMMIT", [])
    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end

  test "policy gives up on max_elapsed_ms ceiling", %{path: path} do
    # Give room on retry count but limit wall time hard.
    {holder, probe} =
      prime_contention(path, max_retries: 1_000, max_elapsed_ms: 40, sleep_ms: 10)

    before_ms = System.monotonic_time(:millisecond)
    result = NIF.execute(probe, "INSERT INTO t VALUES (1)", [])
    elapsed = System.monotonic_time(:millisecond) - before_ms

    assert match?({:error, _}, result)
    # Should surrender reasonably close to the 40 ms cap, not 5s or 10s.
    assert elapsed < 200

    {:ok, _} = NIF.execute(holder, "COMMIT", [])
    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end

  test "observers fire without any policy installed; caller sees immediate busy",
       %{path: path} do
    test_pid = self()
    {:ok, holder} = NIF.open(path)
    {:ok, probe} = NIF.open(path)
    {:ok, 0} = NIF.execute(holder, "CREATE TABLE t(id INTEGER)", [])
    {:ok, 0} = NIF.execute(holder, "BEGIN IMMEDIATE", [])

    {:ok, _handle} = Xqlite.register_busy_observer(probe, test_pid)

    before_ms = System.monotonic_time(:millisecond)
    result = NIF.execute(probe, "INSERT INTO t VALUES (1)", [])
    elapsed = System.monotonic_time(:millisecond) - before_ms

    assert match?({:error, _}, result)
    # No policy → no retry loop; the observation fires, busy surfaces fast.
    assert elapsed < 100
    assert_receive {:xqlite_busy, _, _}, 200

    {:ok, _} = NIF.execute(holder, "COMMIT", [])
    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end

  test "remove_busy_policy keeps observers; caller sees fast busy", %{path: path} do
    {holder, probe} =
      prime_contention(path, max_retries: 1_000, max_elapsed_ms: 10_000, sleep_ms: 10)

    :ok = Xqlite.remove_busy_policy(probe)

    before_ms = System.monotonic_time(:millisecond)
    result = NIF.execute(probe, "INSERT INTO t VALUES (1)", [])
    elapsed = System.monotonic_time(:millisecond) - before_ms

    assert match?({:error, _}, result)
    # With no policy, SQLite surfaces BUSY without retrying or sleeping.
    assert elapsed < 100

    # The observer registered by prime_contention still fires.
    assert_receive {:xqlite_busy, _, _}, 200

    {:ok, _} = NIF.execute(holder, "COMMIT", [])
    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end

  test "empty slot (policy removed, observers unregistered) is silent and instant",
       %{path: path} do
    test_pid = self()
    {:ok, holder} = NIF.open(path)
    {:ok, probe} = NIF.open(path)
    {:ok, 0} = NIF.execute(holder, "CREATE TABLE t(id INTEGER)", [])
    {:ok, 0} = NIF.execute(holder, "BEGIN IMMEDIATE", [])

    :ok = Xqlite.set_busy_policy(probe, max_retries: 5, sleep_ms: 5)
    {:ok, handle} = Xqlite.register_busy_observer(probe, test_pid)
    :ok = Xqlite.remove_busy_policy(probe)
    :ok = Xqlite.unregister_busy_observer(probe, handle)

    before_ms = System.monotonic_time(:millisecond)
    result = NIF.execute(probe, "INSERT INTO t VALUES (1)", [])
    elapsed = System.monotonic_time(:millisecond) - before_ms

    assert match?({:error, _}, result)
    assert elapsed < 50
    refute_received {:xqlite_busy, _, _}

    {:ok, _} = NIF.execute(holder, "COMMIT", [])
    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end

  test "re-setting the policy replaces the previous one", %{path: path} do
    {:ok, holder} = NIF.open(path)
    {:ok, probe} = NIF.open(path)

    {:ok, 0} = NIF.execute(holder, "CREATE TABLE t(id INTEGER)", [])
    {:ok, 0} = NIF.execute(holder, "BEGIN IMMEDIATE", [])

    # Install, then replace with a narrower one.
    :ok = Xqlite.set_busy_policy(probe, max_retries: 100, sleep_ms: 20)

    :ok =
      Xqlite.set_busy_policy(probe,
        max_retries: 1,
        max_elapsed_ms: 500,
        sleep_ms: 5
      )

    # With the tight policy we should give up fast (≤ 1 retry × 5 ms).
    before_ms = System.monotonic_time(:millisecond)
    result = NIF.execute(probe, "INSERT INTO t VALUES (1)", [])
    elapsed = System.monotonic_time(:millisecond) - before_ms

    assert match?({:error, _}, result)
    assert elapsed < 100

    :ok = Xqlite.remove_busy_policy(probe)
    {:ok, _} = NIF.execute(holder, "COMMIT", [])
    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end

  test "multiple observers all receive; unregistering silences only that one",
       %{path: path} do
    first = spawn_collector()
    second = spawn_collector()

    {:ok, holder} = NIF.open(path)
    {:ok, probe} = NIF.open(path)
    {:ok, 0} = NIF.execute(holder, "CREATE TABLE t(id INTEGER)", [])
    {:ok, 0} = NIF.execute(holder, "BEGIN IMMEDIATE", [])

    :ok = Xqlite.set_busy_policy(probe, max_retries: 3, sleep_ms: 10)
    {:ok, first_handle} = Xqlite.register_busy_observer(probe, first)
    {:ok, _second_handle} = Xqlite.register_busy_observer(probe, second)

    {:error, _} = NIF.execute(probe, "INSERT INTO t VALUES (1)", [])

    refute Enum.empty?(get_collected(first))
    refute Enum.empty?(get_collected(second))

    # Unregister the first; only the second keeps receiving.
    :ok = Xqlite.unregister_busy_observer(probe, first_handle)
    first_count = length(get_collected(first))

    {:error, _} = NIF.execute(probe, "INSERT INTO t VALUES (1)", [])

    assert length(get_collected(first)) == first_count
    refute Enum.empty?(get_collected(second))

    {:ok, _} = NIF.execute(holder, "COMMIT", [])
    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end

  test "dead observer pid does not crash the NIF", %{path: path} do
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    receive do: ({:DOWN, ^ref, :process, ^dead, _} -> :ok)

    {:ok, holder} = NIF.open(path)
    {:ok, probe} = NIF.open(path)
    {:ok, 0} = NIF.execute(holder, "CREATE TABLE t(id INTEGER)", [])
    {:ok, 0} = NIF.execute(holder, "BEGIN IMMEDIATE", [])

    :ok = Xqlite.set_busy_policy(probe, max_retries: 3, sleep_ms: 10)
    {:ok, _handle} = Xqlite.register_busy_observer(probe, dead)

    # Should not blow up — enif_send to a dead pid is a no-op.
    assert match?({:error, _}, NIF.execute(probe, "INSERT INTO t VALUES (1)", []))

    {:ok, _} = NIF.execute(holder, "COMMIT", [])
    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end

  test "all four calls on a closed connection return structured errors", %{path: path} do
    {:ok, conn} = NIF.open(path)
    :ok = NIF.close(conn)

    assert {:error, :connection_closed} = Xqlite.set_busy_policy(conn, max_retries: 1)
    assert {:error, :connection_closed} = Xqlite.remove_busy_policy(conn)
    assert {:error, :connection_closed} = Xqlite.register_busy_observer(conn, self())
    assert {:error, :connection_closed} = Xqlite.unregister_busy_observer(conn, 0)
  end

  test "GenServer-like process forwards busy events", %{path: path} do
    test_pid = self()

    forwarder =
      spawn(fn ->
        receive do
          {:xqlite_busy, _, _} = event ->
            send(test_pid, {:forwarded_busy, event})
        end
      end)

    {:ok, holder} = NIF.open(path)
    {:ok, probe} = NIF.open(path)
    {:ok, 0} = NIF.execute(holder, "CREATE TABLE t(id INTEGER)", [])
    {:ok, 0} = NIF.execute(holder, "BEGIN IMMEDIATE", [])

    :ok = Xqlite.set_busy_policy(probe, max_retries: 3, sleep_ms: 5)
    {:ok, _handle} = Xqlite.register_busy_observer(probe, forwarder)

    {:error, _} = NIF.execute(probe, "INSERT INTO t VALUES (1)", [])

    assert_receive {:forwarded_busy, {:xqlite_busy, _, _}}, 500

    {:ok, _} = NIF.execute(holder, "COMMIT", [])
    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end

  test "survives 50 rapid policy/observer cycles on the same probe connection",
       %{path: path} do
    {:ok, probe} = NIF.open(path)

    for _ <- 1..50 do
      :ok = Xqlite.set_busy_policy(probe, max_retries: 1, sleep_ms: 1)
      {:ok, handle} = Xqlite.register_busy_observer(probe, self())
      :ok = Xqlite.unregister_busy_observer(probe, handle)
      :ok = Xqlite.remove_busy_policy(probe)
    end

    # Sanity: the connection is still usable after the churn.
    assert :ok = Xqlite.set_busy_policy(probe, max_retries: 1, sleep_ms: 1)
    assert :ok = Xqlite.remove_busy_policy(probe)

    :ok = NIF.close(probe)
  end

  test "elapsed_ms is monotonically non-decreasing across retries", %{path: path} do
    collector = spawn_collector()

    {:ok, holder} = NIF.open(path)
    {:ok, probe} = NIF.open(path)
    {:ok, 0} = NIF.execute(holder, "CREATE TABLE t(id INTEGER)", [])
    {:ok, 0} = NIF.execute(holder, "BEGIN IMMEDIATE", [])

    :ok = Xqlite.set_busy_policy(probe, max_retries: 10, sleep_ms: 5)
    {:ok, _handle} = Xqlite.register_busy_observer(probe, collector)

    {:error, _} = NIF.execute(probe, "INSERT INTO t VALUES (1)", [])

    events = get_collected(collector)
    assert length(events) > 1, "need multiple retries to test monotonicity"

    elapsed_sequence = Enum.map(events, fn {:xqlite_busy, _retries, elapsed} -> elapsed end)

    Enum.zip(elapsed_sequence, Enum.drop(elapsed_sequence, 1))
    |> Enum.each(fn {earlier, later} ->
      assert later >= earlier,
             "elapsed_ms went backwards: #{earlier} -> #{later}"
    end)

    retries_sequence = Enum.map(events, fn {:xqlite_busy, r, _} -> r end)
    # retries is the SQLite count param; it starts at 0 and monotonically grows.
    assert retries_sequence == Enum.sort(retries_sequence)

    {:ok, _} = NIF.execute(holder, "COMMIT", [])
    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end

  test "the telemetry bridge re-emits busy deliveries as [:xqlite, :hook, :busy]",
       %{path: path} do
    {:ok, holder} = NIF.open(path)
    {:ok, probe} = NIF.open(path)
    {:ok, 0} = NIF.execute(holder, "CREATE TABLE t(id INTEGER)", [])
    {:ok, 0} = NIF.execute(holder, "BEGIN IMMEDIATE", [])

    :ok = Xqlite.set_busy_policy(probe, max_retries: 3, sleep_ms: 5)
    {:ok, bridge} = Xqlite.Telemetry.bridge(probe, hooks: [:busy])

    handler_id = attach_capture([[:xqlite, :hook, :busy]])

    {:error, _} = NIF.execute(probe, "INSERT INTO t VALUES (1)", [])

    assert_receive {:telemetry_event, [:xqlite, :hook, :busy], measurements, metadata}, 500
    assert is_integer(measurements.retries)
    assert is_integer(measurements.elapsed)
    assert metadata.conn == probe

    detach(handler_id)
    :ok = Xqlite.Telemetry.unbridge(bridge)

    {:ok, _} = NIF.execute(holder, "COMMIT", [])
    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp spawn_collector do
    spawn(fn -> collector_loop([]) end)
  end

  defp collector_loop(acc) do
    receive do
      {:get, from} ->
        send(from, {:collected, Enum.reverse(acc)})
        collector_loop(acc)

      {:xqlite_busy, _, _} = event ->
        collector_loop([event | acc])
    end
  end

  defp get_collected(pid) do
    send(pid, {:get, self()})

    receive do
      {:collected, msgs} -> msgs
    after
      1_000 -> []
    end
  end
end
