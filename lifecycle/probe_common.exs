# Shared helpers for the A6 resource-lifecycle probe harness.
#
# Required (via Code.require_file/2) by every probe .exs so the memory/RSS
# instrumentation, the leak-trend classifier, and the DB helpers live in
# exactly one place.
#
# This file is NOT under test/ and is never compiled by `mix compile` /
# `mix test.seq` — it is loaded only by `bash lifecycle/run.sh`.
defmodule Lifecycle.Probe do
  @moduledoc false

  # ---- exit codes (mirrors concurrency/run.sh's class_of) -------------------
  #   0   PASS
  #   5   LEAK        (monotonic growth in the back half of the run)
  #   7   UNEXPECTED  (an assertion in a hostile-drop scenario failed)
  # 134/139 CRASH     (SIGABRT / SIGSEGV — set by the OS, not by us)
  # 137   CRASH_OR_OOM
  def code_pass, do: 0
  def code_leak, do: 5
  def code_unexpected, do: 7

  # ---- OS / BEAM memory instruments -----------------------------------------

  # Resident set size in bytes, straight from the kernel. Captures BOTH
  # BEAM-managed memory AND the C-side SQLite allocations (page cache, schema,
  # prepared VDBE programs, sqlite3* structs) — the only instrument that sees
  # a leak on either side of the FFI boundary.
  def rss_bytes do
    "/proc/self/status"
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_value(0, fn line ->
      case line do
        "VmRSS:" <> rest ->
          rest |> String.trim() |> String.split() |> hd() |> String.to_integer() |> Kernel.*(1024)

        _ ->
          false
      end
    end)
  end

  # Open file descriptors. A leaked file-backed connection or blob that never
  # closed its OS handle shows up here even if RSS drift is small.
  def fd_count do
    case File.ls("/proc/self/fd") do
      {:ok, entries} -> length(entries)
      {:error, _} -> -1
    end
  end

  def erlang_total, do: :erlang.memory(:total)
  def erlang_binary, do: :erlang.memory(:binary)

  # Force every reclamation path we can before sampling: GC every process (NIF
  # resources are freed when the last Reference to them is collected, and those
  # references live on process heaps), yield, repeat. Without this a "leak"
  # could be nothing but resources awaiting the next GC.
  def settle(rounds \\ 3) do
    for _ <- 1..rounds do
      for pid <- Process.list(), do: :erlang.garbage_collect(pid)
      :erlang.garbage_collect()
      Process.sleep(20)
    end

    :ok
  end

  def sample(iter) do
    settle()
    %{iter: iter, rss: rss_bytes(), total: erlang_total(), bin: erlang_binary(), fd: fd_count()}
  end

  def mb(bytes), do: Float.round(bytes / 1_048_576, 2)

  # ---- leak-trend classifier ------------------------------------------------
  #
  # A bounded loop reaches a steady state: allocator arenas warm up once, then
  # RSS plateaus. A real leak keeps climbing for as long as the loop runs. So
  # we do NOT classify on total growth (that would flag one-time warmup); we
  # classify on the BACK HALF. `samples` is a list of %{iter,rss,...}, ordered,
  # the first taken AFTER a warmup window.
  #
  # LEAK iff the RSS still climbs by > abs_mb across the back half of the run
  # (the second measured sample to the last). Otherwise PASS. Returns
  # {class, report_map}.
  def classify(samples, opts \\ []) do
    abs_mb = Keyword.get(opts, :abs_mb, 24)
    first = List.first(samples)
    last = List.last(samples)
    mid = Enum.at(samples, div(length(samples), 2))

    front = mid.rss - first.rss
    back = last.rss - mid.rss
    total = last.rss - first.rss
    iters_back = last.iter - mid.iter
    bpi_back = if iters_back > 0, do: Float.round(back / iters_back, 1), else: 0.0

    class = if back > abs_mb * 1_048_576, do: :leak, else: :pass

    report = %{
      baseline_rss_mb: mb(first.rss),
      mid_rss_mb: mb(mid.rss),
      final_rss_mb: mb(last.rss),
      front_half_growth_mb: mb(front),
      back_half_growth_mb: mb(back),
      total_growth_mb: mb(total),
      back_half_bytes_per_iter: bpi_back,
      fd_baseline: first.fd,
      fd_final: last.fd,
      erlang_total_baseline_mb: mb(first.total),
      erlang_total_final_mb: mb(last.total)
    }

    {class, report}
  end

  # ---- DB helpers -----------------------------------------------------------

  def open_mem! do
    case Xqlite.open_in_memory() do
      {:ok, c} -> c
      other -> raise "open_in_memory failed: #{inspect(other)}"
    end
  end

  def open_file!(path) do
    case Xqlite.open(path, journal_mode: :wal, synchronous: :normal, busy_timeout: 5_000) do
      {:ok, c} -> c
      other -> raise "open #{path} failed: #{inspect(other)}"
    end
  end

  def seed_blob_table!(conn) do
    {:ok, _} = Xqlite.execute(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, b BLOB NOT NULL)", [])
    {:ok, _} = Xqlite.execute(conn, "INSERT INTO t(id, b) VALUES (1, ?1)", [:binary.copy(<<0xAB>>, 256)])
    :ok
  end

  def int!(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> raise ArgumentError, "expected integer, got #{inspect(str)}"
    end
  end

  # Print the ordered samples as one line each (so run.sh logs carry the raw
  # trend), then a single RESULT line and halt with the class's exit code.
  def finish(label, class, report, samples) do
    IO.puts("PROBE #{label}")

    for s <- samples do
      IO.puts(
        "SAMPLE iter=#{s.iter} rss_mb=#{mb(s.rss)} total_mb=#{mb(s.total)} bin_mb=#{mb(s.bin)} fd=#{s.fd}"
      )
    end

    IO.puts("RESULT class=#{class} #{inspect(report)}")

    code =
      case class do
        :pass -> code_pass()
        :leak -> code_leak()
        :unexpected -> code_unexpected()
      end

    System.halt(code)
  end
end
