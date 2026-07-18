# Shared helpers for the A5 cancellation-semantics probe harness.
#
# Required (via Code.require_file/2) by every probe .exs so the timing
# instrumentation, the statistics helpers, the slow/calibratable SQL, and the
# token/DB helpers live in exactly one place.
#
# This file is NOT under test/ and is never compiled by `mix compile` /
# `mix test.seq` — it is loaded only by `bash cancellation/run.sh`.
defmodule Cancellation.Probe do
  @moduledoc false

  alias XqliteNIF, as: NIF

  # ---- exit codes (mirrors concurrency/lifecycle run.sh class_of) -----------
  #   0   PASS
  #   3   RACE_TORN   (an ill-defined / third outcome — the S0 signal)
  #   4   NO_EFFECT   (a cancel that MUST take effect did not — teeth failure)
  #   5   NOT_EXERCISED (the race window produced only one outcome class — blind)
  #   7   UNEXPECTED  (a structural assertion failed)
  # 134/139 CRASH     (SIGABRT / SIGSEGV — set by the OS, not by us)
  # 124   HANG        (OS timeout)
  def code_pass, do: 0
  def code_race_torn, do: 3
  def code_no_effect, do: 4
  def code_not_exercised, do: 5
  def code_unexpected, do: 7

  # ---- timing ---------------------------------------------------------------

  def now_us, do: System.monotonic_time(:microsecond)

  def since_us(t0), do: now_us() - t0

  # ---- SQL ------------------------------------------------------------------

  # A CPU-bound recursive-CTE counter whose upper bound sets its runtime.
  # `bound` VM iterations of pure integer stepping — no memory pressure, no
  # I/O — so the progress handler (every 8 VM ops) fires ~bound/8 times.
  def counting_sql(bound) do
    "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<#{bound}) " <>
      "SELECT count(*) FROM n"
  end

  # A bound so large no machine finishes it inside any probe window (used for
  # latency + teardown: the op is effectively unbounded until cancelled/closed).
  def never_bound, do: 2_000_000_000

  def never_sql, do: counting_sql(never_bound())

  # ---- tokens / DB ----------------------------------------------------------

  def token! do
    case NIF.create_cancel_token() do
      {:ok, t} -> t
      other -> raise "create_cancel_token failed: #{inspect(other)}"
    end
  end

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

  def int!(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> raise ArgumentError, "expected integer, got #{inspect(str)}"
    end
  end

  # ---- statistics -----------------------------------------------------------

  def stats(values) when is_list(values) and values != [] do
    sorted = Enum.sort(values)
    n = length(sorted)

    %{
      n: n,
      min: List.first(sorted),
      max: List.last(sorted),
      mean: Float.round(Enum.sum(sorted) / n, 1),
      median: pct(sorted, 0.50),
      p95: pct(sorted, 0.95),
      p99: pct(sorted, 0.99)
    }
  end

  defp pct(sorted, q) do
    n = length(sorted)
    idx = min(n - 1, max(0, round(q * (n - 1))))
    Enum.at(sorted, idx)
  end

  # ---- start-synchronised cancellable run -----------------------------------
  #
  # Runs `fun` (a 0-arity closure returning the NIF result) inside a Task that
  # announces `:started` to the parent immediately before invoking the NIF, so
  # the caller can time a cancel relative to the step loop's start. Returns the
  # Task; the caller awaits it.
  def spawn_started(parent, fun) do
    Task.async(fn ->
      send(parent, {:started, self()})
      fun.()
    end)
  end

  def await_started(timeout_ms \\ 2_000) do
    receive do
      {:started, _pid} -> :ok
    after
      timeout_ms -> raise "task never signalled :started"
    end
  end

  # Classify a cancellable-op result into a coarse, well-defined bucket. Any
  # value that is NOT one of the defined shapes is `:torn` — the S0 signal.
  def classify_result(result) do
    case result do
      {:ok, %{rows: _}} -> :completed
      {:ok, n} when is_integer(n) -> :completed
      :ok -> :completed
      {:error, :operation_cancelled} -> :cancelled
      {:error, :connection_closed} -> :conn_closed
      {:error, :statement_finalized} -> :stmt_finalized
      _ -> :torn
    end
  end

  # ---- finish ---------------------------------------------------------------

  def finish(label, class, report) do
    IO.puts("PROBE #{label}")
    IO.puts("RESULT class=#{class} #{inspect(report, limit: :infinity)}")

    code =
      case class do
        :pass -> code_pass()
        :race_torn -> code_race_torn()
        :no_effect -> code_no_effect()
        :not_exercised -> code_not_exercised()
        :unexpected -> code_unexpected()
      end

    System.halt(code)
  end
end
