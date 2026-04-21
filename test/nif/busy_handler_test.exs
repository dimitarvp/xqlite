defmodule Xqlite.NIF.BusyHandlerTest do
  # Not using the `connection_openers` for-loop because we specifically need
  # two connections to the SAME file-backed database to force real lock
  # contention; in-memory connections have separate lock domains.
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF

  setup do
    path =
      Path.join(System.tmp_dir!(), "xqlite_busy_#{:erlang.unique_integer([:positive])}.db")

    on_exit(fn ->
      for ext <- ["", "-wal", "-shm", "-journal"], do: File.rm(path <> ext)
    end)

    {:ok, path: path}
  end

  # Build a probe connection ready for contention:
  # - holder opens the file and grabs a write intent (RESERVED lock)
  # - probe opens the same file and gets a busy handler pointed at `self()`
  defp prime_contention(path, handler_opts) do
    test_pid = self()
    {:ok, holder} = NIF.open(path)
    {:ok, probe} = NIF.open(path)

    {:ok, 0} = NIF.execute(holder, "CREATE TABLE t(id INTEGER)", [])
    {:ok, 0} = NIF.execute(holder, "BEGIN IMMEDIATE", [])

    :ok = NIF.set_busy_handler(probe, test_pid, handler_opts)

    {holder, probe}
  end

  test "handler fires and eventually succeeds after the holder releases", %{path: path} do
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

  test "handler gives up after max_retries; caller sees busy", %{path: path} do
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

  test "handler gives up on max_elapsed_ms ceiling", %{path: path} do
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

  test "remove_busy_handler reverts to immediate SQLITE_BUSY", %{path: path} do
    {holder, probe} =
      prime_contention(path, max_retries: 1_000, max_elapsed_ms: 10_000, sleep_ms: 10)

    :ok = NIF.remove_busy_handler(probe)

    before_ms = System.monotonic_time(:millisecond)
    result = NIF.execute(probe, "INSERT INTO t VALUES (1)", [])
    elapsed = System.monotonic_time(:millisecond) - before_ms

    assert match?({:error, _}, result)
    # With no handler and nothing else providing a timeout, SQLite should
    # surface BUSY almost instantly — no retry, no sleep.
    assert elapsed < 50

    # No {:xqlite_busy, …} messages should have been delivered.
    refute_received {:xqlite_busy, _, _}

    {:ok, _} = NIF.execute(holder, "COMMIT", [])
    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end

  test "re-installing a handler replaces the previous one", %{path: path} do
    test_pid = self()
    {:ok, holder} = NIF.open(path)
    {:ok, probe} = NIF.open(path)

    {:ok, 0} = NIF.execute(holder, "CREATE TABLE t(id INTEGER)", [])
    {:ok, 0} = NIF.execute(holder, "BEGIN IMMEDIATE", [])

    # Install, then replace with a narrower one.
    :ok = NIF.set_busy_handler(probe, test_pid, max_retries: 100, sleep_ms: 20)

    :ok =
      NIF.set_busy_handler(probe, test_pid,
        max_retries: 1,
        max_elapsed_ms: 500,
        sleep_ms: 5
      )

    # With the tight handler we should give up fast (≤ 1 retry × 5 ms).
    before_ms = System.monotonic_time(:millisecond)
    result = NIF.execute(probe, "INSERT INTO t VALUES (1)", [])
    elapsed = System.monotonic_time(:millisecond) - before_ms

    assert match?({:error, _}, result)
    assert elapsed < 100

    :ok = NIF.remove_busy_handler(probe)
    {:ok, _} = NIF.execute(holder, "COMMIT", [])
    :ok = NIF.close(holder)
    :ok = NIF.close(probe)
  end
end
