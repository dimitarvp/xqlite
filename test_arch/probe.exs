# A14 test-architecture probe for xqlite.
#
# Re-derives gotcha #1: "parallel tests corrupt/contend on global C state;
# bundled = single global VFS/allocator per OS process; mix test.seq (one OS
# process per test file) is the permanent solution." The bundled SQLite is
# statically linked, so ONE OS process = ONE set of SQLite C globals (allocator,
# VFS registration list, page cache, PRNG, memstatus counter, temp-file
# namespace) shared by every BEAM process in that VM. mix test runs test files
# concurrently as async ExUnit processes IN ONE OS PROCESS; test.seq runs each
# file in its OWN OS process (own globals).
#
# This probe hammers realistic NIF workloads across many concurrent BEAM
# processes on ISOLATED DBs (private :memory: + per-iteration temp files, exactly
# like the test suite's two openers — so no DB-level sharing; the only shared
# surface is the per-OS-process C globals) and compares it to the same work done
# serially. A crash / corruption / spurious "out of memory" (SQLITE_NOMEM = code
# 7) in the parallel leg that the serial leg does not produce is the positive
# signal for the mechanism.
#
# Sections:
#   SUBSTRATE — print THREADSAFE / MUTEX compile options (proves what protects
#               the globals: THREADSAFE=1 => global mutexes on even for NOMUTEX
#               connections => contention, not hard corruption, is the expected
#               mechanism).
#   TEETH     — corruption oracle: a byte-smashed file DB MUST fail
#               integrity_check; a clean one MUST pass. run.sh aborts (rc 2) if
#               the oracle does not trip, since then a real corruption would be
#               invisible.
#   PARALLEL  — K concurrent workers, each an isolated-DB churn loop.
#   SERIAL    — the same total work, one worker at a time (the control: MUST be
#               clean; if it errors too, the workload is broken, not parallelism).
#   CHURN     — open/close churn (the rusqlite#1860 angle) parallel vs serial.
#
# Exit: 0 = parallel produced no crash and no corruption (report NOMEM/BUSY
#           tallies for both legs); 1 = corruption or an anomaly in a leg;
#           2 = teeth dead. A VM crash aborts (rc 134/139), caught by run.sh.

defmodule TA do
  @nomem 7

  def hdr(s), do: IO.puts("\n== #{s} ==")
  def p(l, v), do: IO.puts("  #{l}: #{inspect(v)}")

  def substrate do
    hdr("SUBSTRATE (runtime, this process)")
    {:ok, c} = Xqlite.open_in_memory()
    {:ok, r} = Xqlite.query(c, "PRAGMA compile_options", [])
    opts = List.flatten(r.rows)
    p("THREADSAFE", Enum.filter(opts, &String.contains?(&1, "THREADSAFE")))
    p("MUTEX", Enum.filter(opts, &String.contains?(&1, "MUTEX")))
    p("sqlite", XqliteNIF.sqlite_version())
    p("schedulers_online", :erlang.system_info(:schedulers_online))
    Xqlite.close(c)
  end

  # classify one op result into a tally-key
  def classify({:ok, _}), do: :ok
  def classify(:ok), do: :ok
  def classify({:row, _}), do: :ok
  def classify(:done), do: :ok
  def classify({:error, {:sqlite_failure, @nomem, _, _}}), do: :nomem
  def classify({:error, {:sqlite_failure, 5, _, _}}), do: :busy
  def classify({:error, {:sqlite_failure, 6, _, _}}), do: :busy
  def classify({:error, {:database_busy_or_locked, _}}), do: :busy
  def classify({:error, other}), do: {:other_error, other}
  def classify(other), do: {:weird, other}

  def merge(t, key) do
    case key do
      :ok -> Map.update(t, :ok, 1, &(&1 + 1))
      :nomem -> Map.update(t, :nomem, 1, &(&1 + 1))
      :busy -> Map.update(t, :busy, 1, &(&1 + 1))
      {:other_error, r} -> t |> Map.update(:other, 1, &(&1 + 1)) |> Map.put(:last_other, r)
      {:weird, r} -> t |> Map.update(:weird, 1, &(&1 + 1)) |> Map.put(:last_weird, r)
    end
  end

  # one isolated-DB workload cycle; returns a tally map. Alternates a private
  # in-memory DB and a fresh temp file (the two suite openers). Touches the
  # shared allocator (1 MB page cache like the suite + ~200 KB of blob rows) and,
  # on the file leg, verifies integrity to catch any real corruption.
  def cycle(kind, tmpdir, seq) do
    t = %{ok: 0}

    # System.unique_integer guarantees a fresh file per cycle regardless of
    # process or seq, so the serial control leg never reuses a path (mirrors the
    # suite: each test gets its own temp DB). seq is kept only for readability.
    open =
      case kind do
        :mem -> Xqlite.open_in_memory()
        :file -> Xqlite.open(Path.join(tmpdir, "w#{seq}_#{System.unique_integer([:positive])}.db"), [])
      end

    case open do
      {:ok, c} ->
        # mirror the suite's connection config (1 MB cache + FK)
        XqliteNIF.set_pragma(c, "cache_size", -1000)
        XqliteNIF.set_pragma(c, "foreign_keys", true)
        t = merge(t, classify(Xqlite.execute_batch(c, "CREATE TABLE t(id INTEGER PRIMARY KEY, payload BLOB)")))
        # a transaction of ~200 x ~1 KB rows — real allocator/pcache pressure
        Xqlite.execute_batch(c, "BEGIN")

        t =
          Enum.reduce(1..200, t, fn i, acc ->
            r = Xqlite.query(c, "INSERT INTO t(id, payload) VALUES(?, zeroblob(1024))", [i])
            merge(acc, classify(r))
          end)

        t = merge(t, classify(Xqlite.execute_batch(c, "COMMIT")))
        t = merge(t, classify(Xqlite.query(c, "SELECT count(*), sum(length(payload)) FROM t", [])))

        t =
          if kind == :file do
            case Xqlite.query(c, "PRAGMA integrity_check", []) do
              {:ok, %{rows: [["ok"]]}} -> merge(t, :ok)
              other -> Map.update(Map.put(t, :corruption_detail, other), :corruption, 1, &(&1 + 1))
            end
          else
            t
          end

        Xqlite.close(c)
        t

      err ->
        merge(t, classify(err))
    end
  end

  def churn_cycle(tmpdir, _seq) do
    # rapid open+trivial-op+close on a fresh temp file (the #1860 angle)
    case Xqlite.open(Path.join(tmpdir, "c#{System.unique_integer([:positive])}.db"), []) do
      {:ok, c} ->
        Xqlite.query(c, "SELECT 1", [])
        Xqlite.close(c)
        :ok

      err ->
        classify(err)
    end
  end

  def worker(iters, tmpdir, reply) do
    t =
      Enum.reduce(1..iters, %{ok: 0}, fn i, acc ->
        kind = if rem(i, 2) == 0, do: :file, else: :mem
        c = cycle(kind, tmpdir, i)
        Map.merge(acc, c, fn _k, a, b -> if is_integer(a) and is_integer(b), do: a + b, else: b end)
      end)

    send(reply, {:done, self(), t})
  end

  def sum_tallies(list) do
    Enum.reduce(list, %{}, fn m, acc ->
      Map.merge(acc, m, fn _k, a, b -> if is_integer(a) and is_integer(b), do: a + b, else: b end)
    end)
  end

  def run_parallel(k, iters, tmpdir) do
    me = self()
    pids = for _ <- 1..k, do: spawn(fn -> worker(iters, tmpdir, me) end)

    tallies =
      for _ <- pids do
        receive do
          {:done, _pid, t} -> t
        after
          120_000 -> %{timeout: 1}
        end
      end

    sum_tallies(tallies)
  end

  def run_serial(k, iters, tmpdir) do
    tallies = for _ <- 1..k, do: (fn -> t = Enum.reduce(1..iters, %{ok: 0}, fn i, acc ->
      kind = if rem(i, 2) == 0, do: :file, else: :mem
      Map.merge(acc, cycle(kind, tmpdir, i), fn _k, a, b -> if is_integer(a) and is_integer(b), do: a + b, else: b end)
    end); t end).()
    sum_tallies(tallies)
  end

  def run_churn(k, iters, tmpdir, parallel?) do
    me = self()

    if parallel? do
      pids = for _ <- 1..k, do: spawn(fn ->
        res = for i <- 1..iters, do: churn_cycle(tmpdir, i)
        bad = Enum.reject(res, &(&1 == :ok))
        send(me, {:churn, self(), length(bad), List.first(bad)})
      end)
      for _ <- pids, do: (receive do {:churn, _, n, ex} -> {n, ex} after 120_000 -> {:timeout, nil} end)
    else
      for _ <- 1..k do
        res = for i <- 1..iters, do: churn_cycle(tmpdir, i)
        bad = Enum.reject(res, &(&1 == :ok))
        {length(bad), List.first(bad)}
      end
    end
  end

  def teeth(tmpdir) do
    hdr("TEETH — corruption oracle")
    good = Path.join(tmpdir, "teeth_good.db")
    bad = Path.join(tmpdir, "teeth_bad.db")

    for path <- [good, bad] do
      {:ok, c} = Xqlite.open(path, [])
      Xqlite.execute_batch(c, "CREATE TABLE t(x); INSERT INTO t VALUES(1),(2),(3);")
      Xqlite.close(c)
    end

    # clean DB must pass
    {:ok, cg} = Xqlite.open(good, [])
    clean = Xqlite.query(cg, "PRAGMA integrity_check", [])
    Xqlite.close(cg)
    p("clean integrity_check", clean)

    # byte-smash the middle of the bad DB
    data = File.read!(bad)
    mid = div(byte_size(data), 2)
    smashed = binary_part(data, 0, mid) <> :binary.copy(<<0xFF>>, 256) <> binary_part(data, mid + 256, byte_size(data) - mid - 256)
    File.write!(bad, smashed)

    smashed_res =
      case Xqlite.open(bad, []) do
        {:ok, cb} ->
          r = Xqlite.query(cb, "PRAGMA integrity_check", [])
          Xqlite.close(cb)
          r

        e ->
          e
      end

    p("smashed integrity_check/open", smashed_res)

    clean_ok = match?({:ok, %{rows: [["ok"]]}}, clean)
    smash_caught = not match?({:ok, %{rows: [["ok"]]}}, smashed_res)

    if clean_ok and smash_caught do
      IO.puts("  TEETH OK — oracle passes a clean DB and catches a smashed one.")
      :ok
    else
      IO.puts("  TEETH DEAD — clean_ok=#{clean_ok} smash_caught=#{smash_caught}")
      System.halt(2)
    end
  end

  def report(tag, t) do
    IO.puts("  [#{tag}] ok=#{Map.get(t, :ok, 0)} nomem=#{Map.get(t, :nomem, 0)} busy=#{Map.get(t, :busy, 0)} other=#{Map.get(t, :other, 0)} weird=#{Map.get(t, :weird, 0)} corruption=#{Map.get(t, :corruption, 0)} timeout=#{Map.get(t, :timeout, 0)}")
    if Map.has_key?(t, :last_other), do: p("  last_other", Map.get(t, :last_other))
    if Map.has_key?(t, :corruption_detail), do: p("  corruption_detail", Map.get(t, :corruption_detail))
    t
  end

  def run do
    k = String.to_integer(System.get_env("TA_WORKERS", "36"))
    iters = String.to_integer(System.get_env("TA_ITERS", "60"))
    churn_iters = String.to_integer(System.get_env("TA_CHURN", "150"))
    tmpdir = System.get_env("TA_TMPDIR") || raise "TA_TMPDIR not set"

    substrate()
    teeth(tmpdir)

    hdr("WORKLOAD (#{k} workers x #{iters} iters, isolated DBs)")
    IO.puts("  running PARALLEL leg...")
    par = report("parallel", run_parallel(k, iters, tmpdir))
    IO.puts("  running SERIAL control leg...")
    ser = report("serial", run_serial(k, iters, tmpdir))

    hdr("OPEN/CLOSE CHURN (#{k} workers x #{churn_iters}, rusqlite#1860 angle)")
    pc = run_churn(k, churn_iters, tmpdir, true)
    sc = run_churn(k, churn_iters, tmpdir, false)
    p("parallel churn (bad_count, first_bad) per worker", pc)
    p("serial churn per worker", sc)
    par_churn_bad = Enum.reduce(pc, 0, fn {n, _}, acc -> if is_integer(n), do: acc + n, else: acc end)
    ser_churn_bad = Enum.reduce(sc, 0, fn {n, _}, acc -> if is_integer(n), do: acc + n, else: acc end)

    hdr("VERDICT")
    corruption = Map.get(par, :corruption, 0) + Map.get(ser, :corruption, 0)
    weird = Map.get(par, :weird, 0) + Map.get(ser, :weird, 0)
    par_nomem = Map.get(par, :nomem, 0)
    ser_nomem = Map.get(ser, :nomem, 0)

    p("parallel NOMEM", par_nomem)
    p("serial NOMEM", ser_nomem)
    p("parallel churn failures", par_churn_bad)
    p("serial churn failures", ser_churn_bad)
    p("total corruption", corruption)

    cond do
      corruption > 0 ->
        IO.puts("  CORRUPTION observed — the mechanism reproduced (integrity failure).")
        System.halt(1)

      weird > 0 ->
        IO.puts("  ANOMALY — an unclassified result appeared.")
        System.halt(1)

      true ->
        IO.puts("  NO crash, NO corruption. NOMEM/BUSY tallies reported above are")
        IO.puts("  the contention signal (if any); a non-zero parallel-only NOMEM")
        IO.puts("  supports the CONTENTION reading of gotcha #1.")
        System.halt(0)
    end
  end
end

TA.run()
