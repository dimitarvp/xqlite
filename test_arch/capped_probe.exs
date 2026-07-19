# A14 CONSTRAINED-RAM probe for xqlite (the F-A14-1 deciding probe; see
# REVIEW_LEDGER.md Run 12 A14 + Run 14, and BACKLOG.md F-A14-1).
#
# Run 12's test_arch/probe.exs could not reproduce the spurious "out of memory"
# (SQLITE_NOMEM) behind gotcha #1 at dev-box scale with UNCONSTRAINED RAM. This
# probe re-runs the parallel-vs-serial comparison under an EXTERNAL memory cap
# (applied by test_arch/capped_run.sh via cgroup MemoryMax or prlimit --as) to
# see whether the parallel leg fails (SQLITE_NOMEM or OOM-kill) while the serial
# leg survives at the SAME cap. That differential is the mechanism behind
# gotcha #1: many parallel connections holding SQLite memory in ONE OS process
# raise the process's peak footprint to ~K x a single connection's, so a cap a
# sequential run survives can starve a parallel run — which is exactly what
# `mix test.seq` (one OS process per test file) removes.
#
# WHY a new probe instead of reusing probe.exs: probe.exs's per-cycle footprint
# (a 200 x 1 KB-row transaction) is far too small to differentiate under any
# sane cap. This probe instead makes each worker HOLD a large in-:memory:-DB
# allocation (zeroblob rows) and, for the parallel leg, rendezvous at a barrier
# so all K holds coexist — guaranteeing a K x peak the serial control never
# reaches. In-memory DBs keep their pages in SQLite's shared process-global heap
# (the exact global gotcha #1 names), so this stresses the SQLite allocator, and
# a malloc-NULL there surfaces as SQLITE_NOMEM (code 7), the literal symptom.
#
# MODES (env TA_MODE):
#   parallel  — K workers each open_in_memory + hold TA_HOLD_MB, barrier, release.
#   serial    — K sequential open/hold/close cycles (peak ~ 1 x TA_HOLD_MB).
#   alloc_tooth — single-shot: hold TOOTH_MB in one connection (cap-binding tooth).
#
# EXIT CODES (this process; the wrapper adds external ones):
#   0 = leg completed clean: every hold succeeded, integrity ok, 0 NOMEM.
#   3 = leg completed but observed >= 1 SQLITE_NOMEM (the differential signal).
#   1 = corruption / unexpected error / anomaly.
#   2 = setup failure.
# External (added by capped_run.sh from the wait status): 137 = SIGKILL (cgroup
# OOM-kill), 134/135/136 = BEAM/C abort (e.g. eheap_alloc — NOT the SQLite-NOMEM
# signature), 124 = timeout/hang.

defmodule CappedA14 do
  @nomem 7
  @mb_blob "INSERT INTO t(id, b) VALUES(?, zeroblob(1048576))"

  def field(status, key) do
    status
    |> String.split("\n")
    |> Enum.find_value("?", fn line ->
      case String.split(line, ":", parts: 2) do
        [^key, v] -> String.trim(v)
        _ -> nil
      end
    end)
  end

  def mem(tag) do
    s = File.read!("/proc/self/status")
    IO.puts("  [mem #{tag}] VmRSS=#{field(s, "VmRSS")} VmHWM=#{field(s, "VmHWM")} VmSize=#{field(s, "VmSize")}")
  end

  # Fill `hold_mb` MB of 1 MB zeroblob rows into an open :memory: connection.
  # Returns :ok | {:nomem, row} | {:other, row, error}. A malloc-NULL inside
  # SQLite (under an address-space cap) returns SQLITE_NOMEM here rather than
  # killing the VM, which is the whole point of the prlimit --as mechanism.
  def fill(c, hold_mb) do
    Enum.reduce_while(1..hold_mb, :ok, fn i, _acc ->
      case Xqlite.query(c, @mb_blob, [i]) do
        {:ok, _} -> {:cont, :ok}
        {:error, {:sqlite_failure, @nomem, _, _}} -> {:halt, {:nomem, i}}
        {:error, e} -> {:halt, {:other, i, e}}
        other -> {:halt, {:other, i, other}}
      end
    end)
  end

  def open_and_fill(hold_mb) do
    case Xqlite.open_in_memory() do
      {:ok, c} ->
        Xqlite.execute_batch(c, "CREATE TABLE t(id INTEGER PRIMARY KEY, b BLOB)")
        {c, fill(c, hold_mb)}

      {:error, e} ->
        {nil, {:open_error, e}}
    end
  end

  def integ(nil), do: :no_conn
  def integ(c), do: Xqlite.query(c, "PRAGMA integrity_check", [])

  def ok_integ?(i), do: match?({:ok, %{rows: [["ok"]]}}, i)

  # --- barrier worker (parallel leg) ---
  def barrier_worker(coord, hold_mb) do
    {c, res} = open_and_fill(hold_mb)
    send(coord, {:filled, self(), res})

    receive do
      :release ->
        i = integ(c)
        if c, do: Xqlite.close(c)
        send(coord, {:released, self(), i})
    after
      180_000 -> :timeout
    end
  end

  def parallel(k, hold_mb) do
    coord = self()
    pids = for _ <- 1..k, do: spawn(fn -> barrier_worker(coord, hold_mb) end)

    fills =
      for _ <- pids do
        receive do
          {:filled, _pid, res} -> res
        after
          180_000 -> :fill_timeout
        end
      end

    IO.puts("  [parallel] all #{k} workers reached the barrier holding ~#{hold_mb} MB each")
    mem("parallel-peak (#{k} holds coexisting)")

    Enum.each(pids, fn p -> send(p, :release) end)

    integs =
      for _ <- pids do
        receive do
          {:released, _pid, i} -> i
        after
          180_000 -> :release_timeout
        end
      end

    verdict("parallel", fills, integs)
  end

  # --- serial leg (control): one hold at a time ---
  def serial(k, hold_mb) do
    {fills, integs} =
      Enum.reduce(1..k, {[], []}, fn _i, {fs, is} ->
        {c, res} = open_and_fill(hold_mb)
        i = integ(c)
        if c, do: Xqlite.close(c)
        :erlang.garbage_collect()
        {[res | fs], [i | is]}
      end)

    mem("serial-peak (1 hold at a time, #{k} cycles)")
    verdict("serial", Enum.reverse(fills), Enum.reverse(integs))
  end

  # tally + classification shared by both legs
  def verdict(tag, fills, integs) do
    nomem = Enum.count(fills, &match?({:nomem, _}, &1))
    clean = Enum.count(fills, &(&1 == :ok))
    others = Enum.filter(fills, fn r -> r != :ok and not match?({:nomem, _}, r) end)
    corruption = Enum.count(integs, fn i -> not ok_integ?(i) end)

    IO.puts("  [#{tag}] holds=#{length(fills)} clean=#{clean} nomem=#{nomem} other=#{length(others)} corruption=#{corruption}")
    if others != [], do: IO.inspect(Enum.take(others, 3), label: "  #{tag} first others")
    if corruption > 0, do: IO.inspect(Enum.reject(integs, &ok_integ?/1) |> Enum.take(3), label: "  #{tag} corruption detail")

    cond do
      corruption > 0 -> {1, "corruption in a completed leg"}
      others != [] -> {1, "unexpected non-NOMEM error"}
      nomem > 0 -> {3, "SQLITE_NOMEM observed (#{nomem}) — the differential signal"}
      true -> {0, "clean: all #{clean} holds succeeded"}
    end
  end

  def alloc_tooth(mb) do
    IO.puts("  [alloc_tooth] attempting to hold #{mb} MB in one :memory: connection")
    {c, res} = open_and_fill(mb)
    mem("alloc_tooth after fill")
    if c, do: Xqlite.close(c)

    case res do
      :ok ->
        IO.puts("  [alloc_tooth] HELD #{mb} MB — cap did NOT bind (expected uncapped)")
        System.halt(0)

      {:nomem, i} ->
        IO.puts("  [alloc_tooth] SQLITE_NOMEM at row #{i} — cap BOUND via malloc-NULL")
        System.halt(3)

      other ->
        IO.inspect(other, label: "  [alloc_tooth] unexpected")
        System.halt(1)
    end
  end

  def run do
    mode = System.get_env("TA_MODE", "parallel")
    k = String.to_integer(System.get_env("TA_K", "24"))
    hold_mb = String.to_integer(System.get_env("TA_HOLD_MB", "30"))
    tooth_mb = String.to_integer(System.get_env("TOOTH_MB", "600"))

    IO.puts("== capped A14 probe: mode=#{mode} k=#{k} hold_mb=#{hold_mb} ==")
    mem("boot")

    case mode do
      "alloc_tooth" ->
        alloc_tooth(tooth_mb)

      "parallel" ->
        {code, why} = parallel(k, hold_mb)
        IO.puts("== #{mode} verdict: exit #{code} — #{why} ==")
        System.halt(code)

      "serial" ->
        {code, why} = serial(k, hold_mb)
        IO.puts("== #{mode} verdict: exit #{code} — #{why} ==")
        System.halt(code)

      other ->
        IO.puts("unknown TA_MODE=#{other}")
        System.halt(2)
    end
  end
end

CappedA14.run()
