# Binary-crossing memory probe for xqlite (review axis A12, Run 11).
#
# Measures what happens to bytes crossing the NIF boundary OUTBOUND (Rust ->
# Elixir) for large result sets, and pins the copy-vs-refcount mechanism:
#
#   * query path  (XqliteNIF.query -> core_query/process_rows/encode_val):
#       TEXT -> str::encode (OwnedBinary copy, refc binary)
#       BLOB -> size-adaptive: >64B wraps the owned Vec in a
#               ResourceArc<BlobResource> (ZERO byte-copy resource binary via
#               enif_make_resource_binary); <=64B is copied into an OwnedBinary
#               (a cheap process-heap binary, matching the stream path)
#   * stream path (stream_open/stream_fetch -> sqlite_row_to_elixir_terms):
#       TEXT -> str::encode (copy)
#       BLOB -> OwnedBinary + copy_from_slice (copy; heap binary <=64B else refc)
#
# The instrument is the BEAM binary allocator counter :erlang.memory(:binary)
# (precise for refc + resource binaries; SQLite's own copy of the source data
# lives in SQLite's malloc heap, NOT here, so this counter isolates the
# crossing) plus OS RSS (/proc/self/status VmRSS) as corroboration.
#
# TEETH (hard gate, run FIRST): a deliberate-retention control MUST make
# :erlang.memory(:binary) grow and stay grown across a GC while referenced,
# then settle on release. If retention shows no growth the instrument is blind
# and every number below is meaningless -> the probe returns rc 2 (run.sh
# ABORTs). This is the A12 analogue of the lifecycle-harness leak teeth.
#
# Each crossing scenario runs inside a Task (its own process); it snapshots its
# OWN peak while holding the result, then returns ONLY scalars. The task's death
# frees every crossed binary, so a parent snapshot after await isolates any
# RETENTION LEAK (crossed binaries that outlive their holder) -> rc 1.
#
# Isolated from CI: under binary_crossing/ (not test/), not in elixirc_paths,
# not matched by the formatter inputs glob. Invoke via binary_crossing/run.sh.

defmodule A12.Probe do
  alias XqliteNIF

  @big_rows String.to_integer(System.get_env("A12_BIG_ROWS") || "100000")
  @big_text_bytes String.to_integer(System.get_env("A12_TEXT_BYTES") || "256")
  @big_blob_bytes String.to_integer(System.get_env("A12_BLOB_BYTES") || "256")
  @small_rows String.to_integer(System.get_env("A12_SMALL_ROWS") || "100000")
  @small_blob_bytes String.to_integer(System.get_env("A12_SMALL_BLOB_BYTES") || "16")
  @batch String.to_integer(System.get_env("A12_BATCH") || "500")

  # ---- measurement primitives -------------------------------------------

  def rss_bytes do
    case File.read("/proc/self/status") do
      {:ok, s} ->
        case Regex.run(~r/VmRSS:\s+(\d+)\s+kB/, s) do
          [_, kb] -> String.to_integer(kb) * 1024
          _ -> 0
        end

      _ ->
        0
    end
  end

  # Raw snapshot — NO gc, for capturing a live peak while data is held.
  def raw_snap do
    %{
      bin: :erlang.memory(:binary),
      total: :erlang.memory(:total),
      proc: :erlang.memory(:processes),
      rss: rss_bytes()
    }
  end

  # Sweep every process heap then read — for a settled baseline / post measure.
  def settle do
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
    Process.sleep(60)
    Enum.each(Process.list(), &:erlang.garbage_collect/1)
    Process.sleep(60)
  end

  def snap do
    settle()
    raw_snap()
  end

  defp mb(bytes), do: Float.round(bytes / 1_048_576, 2)

  # Force full traversal of every crossed binary (defeats any laziness and
  # proves the values are real, materialized binaries) without allocating new
  # large data: sum byte_size of every binary cell.
  def sum_binary_bytes(rows) do
    Enum.reduce(rows, 0, fn row, acc ->
      Enum.reduce(row, acc, fn
        v, a when is_binary(v) -> a + byte_size(v)
        _v, a -> a
      end)
    end)
  end

  # ---- table builders (data generated INSIDE SQLite; no big inbound crossing)

  def build_table(conn, table, n, text_bytes, blob_bytes) do
    {:ok, _} =
      XqliteNIF.query(conn, "CREATE TABLE #{table}(id INTEGER PRIMARY KEY, txt TEXT, blb BLOB)", [])

    # hex(randomblob(k)) yields 2k ASCII chars; halve to hit the target text len.
    half = max(div(text_bytes, 2), 1)

    sql = """
    WITH RECURSIVE seq(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM seq WHERE i < ?1)
    INSERT INTO #{table}(id, txt, blb)
    SELECT i, hex(randomblob(?2)), randomblob(?3) FROM seq
    """

    {:ok, _} = XqliteNIF.query(conn, sql, [n, half, blob_bytes])
    :ok
  end

  # ---- crossing drivers (run INSIDE a task; return scalars + own peak) ----

  # Full-materialization QUERY: holds the entire result, snapshots peak.
  def cross_query_full(conn, sql) do
    start = raw_snap()
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, sql, [])
    peak = raw_snap()
    checksum = sum_binary_bytes(rows)
    n = length(rows)
    # keep `rows` live until after the peak snapshot
    _ = rows
    %{start: start, peak: peak, rows: n, payload: checksum}
  end

  # Full-materialization STREAM (Enum.to_list-equivalent): accumulates every
  # batch into one list, holds it, snapshots peak.
  def cross_stream_full(conn, sql) do
    start = raw_snap()
    {:ok, handle} = XqliteNIF.stream_open(conn, sql, [], [])
    rows = drain_stream(handle, [])
    :ok = XqliteNIF.stream_close(handle)
    peak = raw_snap()
    checksum = sum_binary_bytes(rows)
    n = length(rows)
    _ = rows
    %{start: start, peak: peak, rows: n, payload: checksum}
  end

  defp drain_stream(handle, acc) do
    case XqliteNIF.stream_fetch(handle, @batch) do
      # acc is a list of batches (each batch a list of rows). Concat preserves
      # each row list intact — never List.flatten (that would merge row cells).
      {:ok, %{rows: rows}} -> drain_stream(handle, [rows | acc])
      :done -> acc |> Enum.reverse() |> Enum.concat()
    end
  end

  # Streaming CONSUME-and-DISCARD: never retains more than one batch; samples
  # the binary counter each batch and tracks the max (the bounded peak).
  def cross_stream_discard(conn, sql) do
    start = raw_snap()
    {:ok, handle} = XqliteNIF.stream_open(conn, sql, [], [])
    {n, payload, peak_bin, peak_rss} = discard_loop(handle, 0, 0, start.bin, start.rss)
    :ok = XqliteNIF.stream_close(handle)

    %{
      start: start,
      rows: n,
      payload: payload,
      peak_bin: peak_bin,
      peak_rss: peak_rss
    }
  end

  defp discard_loop(handle, n, payload, peak_bin, peak_rss) do
    case XqliteNIF.stream_fetch(handle, @batch) do
      {:ok, %{rows: rows}} ->
        # process the batch (sum bytes) then DROP it — nothing retained
        add = sum_binary_bytes(rows)
        cur = raw_snap()

        discard_loop(
          handle,
          n + length(rows),
          payload + add,
          max(peak_bin, cur.bin),
          max(peak_rss, cur.rss)
        )

      :done ->
        {n, payload, peak_bin, peak_rss}
    end
  end

  # ---- scenario runner: crossing in a child process, leak-gated ----------

  def run_in_child(fun) do
    pre = snap()
    task = Task.async(fun)
    result = Task.await(task, :infinity)
    # task process has terminated; its crossed binaries are now unreferenced
    post = snap()
    {pre, result, post}
  end

  # =======================================================================
  # TEETH — retention control (MUST show growth) + release control
  # =======================================================================

  def teeth do
    IO.puts("== TEETH: binary-allocator retention control ==")
    # 20k refc binaries of 512 B each ~= 10 MB. 512 > 64 so each is a refc
    # binary counted in :erlang.memory(:binary), never a heap binary.
    count = 20_000
    size = 512
    expected = count * size

    base = snap()
    # build + RETAIN across a gc
    retained = for _ <- 1..count, do: :binary.copy(<<0>>, size)
    held = snap()
    # keep retained alive past the snapshot
    live_bytes = Enum.reduce(retained, 0, fn b, a -> a + byte_size(b) end)
    _ = live_bytes

    grow = held.bin - base.bin
    IO.puts("   retained #{count}x#{size}B (#{mb(expected)} MB): binary grew #{mb(grow)} MB")

    # release + gc
    retained = nil
    _ = retained
    released = snap()
    settle_back = held.bin - released.bin
    IO.puts("   released: binary fell #{mb(settle_back)} MB back toward baseline")

    grew_ok = grow >= expected * 0.7
    released_ok = released.bin - base.bin <= expected * 0.3

    cond do
      not grew_ok ->
        IO.puts("   TEETH DEAD: retention did not grow the counter (#{mb(grow)} < #{mb(expected * 0.7)} MB)")
        :dead

      not released_ok ->
        # instrument still valid (it grew); release not settling is itself
        # suspicious but does not blind the measurement — report, don't abort.
        IO.puts("   NOTE: release did not fully settle (residual #{mb(released.bin - base.bin)} MB)")
        :ok

      true ->
        IO.puts("   TEETH LIVE: counter tracks retained refc binaries and settles on release.")
        :ok
    end
  end

  # =======================================================================
  # Scenario 1 — large result: QUERY vs STREAM full materialization
  # =======================================================================

  def scenario_big(conn) do
    IO.puts("\n== S1: large result (#{@big_rows} rows x [#{@big_text_bytes}B TEXT + #{@big_blob_bytes}B BLOB]) ==")
    payload_est = @big_rows * (@big_text_bytes + @big_blob_bytes)
    IO.puts("   nominal payload ~= #{mb(payload_est)} MB")
    sql = "SELECT id, txt, blb FROM big"

    {qpre, q, qpost} = run_in_child(fn -> cross_query_full(conn, sql) end)
    report_full("query ", qpre, q, qpost)

    {spre, s, spost} = run_in_child(fn -> cross_stream_full(conn, sql) end)
    report_full("stream", spre, s, spost)

    # leak gate: crossed binaries must be freed once the holder dies
    q_leak = qpost.bin - qpre.bin
    s_leak = spost.bin - spre.bin
    leak_ceiling = max(payload_est * 0.25, 8_388_608)

    IO.puts("   RETENTION-LEAK gate (binary counter must return to baseline after holder death):")
    IO.puts("     query  residual: #{mb(q_leak)} MB   stream residual: #{mb(s_leak)} MB   ceiling: #{mb(leak_ceiling)} MB")

    if q_leak > leak_ceiling or s_leak > leak_ceiling do
      IO.puts("     LEAK: crossed binaries outlived their holder process -> S1")
      {:finding, :leak}
    else
      IO.puts("     OK: no retention leak on either path")
      {:ok,
       %{
         query_held_bin: q.peak.bin - q.start.bin,
         stream_held_bin: s.peak.bin - s.start.bin,
         rows: q.rows
       }}
    end
  end

  defp report_full(label, pre, r, _post) do
    held_bin = r.peak.bin - r.start.bin
    held_total = r.peak.total - r.start.total
    peak_rss = r.peak.rss - pre.rss

    IO.puts(
      "   #{label}: rows=#{r.rows} held(binary)=#{mb(held_bin)} MB held(total)=#{mb(held_total)} MB " <>
        "peak_rss_delta=#{mb(peak_rss)} MB per_row(binary)=#{Float.round(held_bin / max(r.rows, 1), 1)} B"
    )
  end

  # =======================================================================
  # Scenario 2 — streaming bounded peak (the memory advantage)
  # =======================================================================

  def scenario_bounded(conn, query_held_bin) do
    IO.puts("\n== S2: streaming consume-and-discard bounded peak (batch=#{@batch}) ==")
    sql = "SELECT id, txt, blb FROM big"

    {pre, r, _post} = run_in_child(fn -> cross_stream_discard(conn, sql) end)
    peak_delta = r.peak_bin - r.start.bin
    peak_rss_delta = r.peak_rss - pre.rss

    IO.puts(
      "   rows=#{r.rows} peak(binary above start)=#{mb(peak_delta)} MB peak_rss_delta=#{mb(peak_rss_delta)} MB"
    )

    IO.puts(
      "   vs full-materialization query held(binary)=#{mb(query_held_bin)} MB " <>
        "-> streaming peak is #{ratio(query_held_bin, peak_delta)}x smaller"
    )

    if peak_delta < query_held_bin * 0.5 do
      IO.puts("   OK: streaming keeps a bounded peak far below full materialization.")
    else
      IO.puts("   NOTE: streaming peak not clearly bounded below full materialization (investigate).")
    end

    :ok
  end

  # =======================================================================
  # Scenario 3 — small-blob backing: both paths land on the process heap
  # (query's encode_val copies <=64B into an OwnedBinary, matching stream)
  # =======================================================================

  def scenario_small(conn) do
    IO.puts("\n== S3: many small blobs (#{@small_rows} rows x #{@small_blob_bytes}B BLOB) — both paths -> process-heap binary ==")
    sql = "SELECT blb FROM small"

    {qpre, q, _qpost} = run_in_child(fn -> cross_query_full(conn, sql) end)
    {spre, s, _spost} = run_in_child(fn -> cross_stream_full(conn, sql) end)

    q_held = q.peak.bin - q.start.bin
    s_held = s.peak.bin - s.start.bin
    q_total = q.peak.total - q.start.total
    s_total = s.peak.total - s.start.total
    q_rss = q.peak.rss - qpre.rss
    s_rss = s.peak.rss - spre.rss

    IO.puts("   query  (encode_val <=64B -> OwnedBinary heap binary): held(binary)=#{mb(q_held)} MB " <>
      "held(total)=#{mb(q_total)} MB rss_delta=#{mb(q_rss)} MB #{per_row(q_held, q.rows)} B/row")

    IO.puts("   stream (sqlite_row_to_elixir_terms -> OwnedBinary): held(binary)=#{mb(s_held)} MB " <>
      "held(total)=#{mb(s_total)} MB rss_delta=#{mb(s_rss)} MB #{per_row(s_held, s.rows)} B/row")

    # The apples-to-apples cross-boundary cost is (binary + process) memory,
    # which captures whichever backing each path picks — process-heap binaries
    # here (both paths, <=64B), so the two should track closely.
    q_cross = q_total
    s_cross = s_total
    cliff = ratio(max(q_cross, s_cross), min(q_cross, s_cross))
    IO.puts("   total-memory ratio between the two paths: #{cliff}x")

    if cliff >= 10.0 do
      IO.puts("   CLIFF: >=10x memory difference between query and stream for the same data -> S2")
      {:finding, :cliff}
    else
      IO.puts("   OK: paths within #{cliff}x (documented characterization, not a >=10x cliff)")
      {:ok, %{ratio: cliff, query_per_row: per_row(q_total, q.rows), stream_per_row: per_row(s_total, s.rows)}}
    end
  end

  defp per_row(bytes, rows), do: Float.round(bytes / max(rows, 1), 1)
  defp ratio(_a, b) when b <= 0, do: "inf"
  defp ratio(a, b), do: Float.round(a / b, 1)

  # =======================================================================
  # Scenario 4 — refc classification micro-probe (>64B vs <=64B)
  # =======================================================================

  def scenario_classification(conn) do
    IO.puts("\n== S4: refc classification (>64B -> binary heap, <=64B -> process heap) ==")
    {:ok, _} = XqliteNIF.query(conn, "CREATE TABLE cls(big BLOB, small BLOB)", [])
    {:ok, _} = XqliteNIF.query(conn, "INSERT INTO cls VALUES(randomblob(1000), randomblob(8))", [])

    base = snap()
    {:ok, %{rows: [[big, small]]}} = XqliteNIF.query(conn, "SELECT big, small FROM cls", [])
    held = raw_snap()
    _ = {byte_size(big), byte_size(small)}

    IO.puts("   1000B blob + 8B blob held: binary_delta=#{mb(held.bin - base.bin)} MB " <>
      "(#{held.bin - base.bin} B) proc_delta=#{held.proc - base.proc} B")
    IO.puts("   (a 1000B resource binary lands in the binary allocator; an 8B value in the process heap)")
    :ok
  end

  # =======================================================================

  def main do
    IO.puts("=== xqlite A12 binary-crossing memory probe ===")
    IO.puts("wordsize=#{:erlang.system_info(:wordsize) * 8}bit schedulers=#{:erlang.system_info(:schedulers)}")

    case teeth() do
      :dead ->
        System.halt(2)

      :ok ->
        {:ok, conn} = Xqlite.open_in_memory()
        IO.puts("\nbuilding tables (data generated inside SQLite)...")
        :ok = build_table(conn, "big", @big_rows, @big_text_bytes, @big_blob_bytes)
        :ok = build_table(conn, "small", @small_rows, 2, @small_blob_bytes)

        s1 = scenario_big(conn)

        qheld =
          case s1 do
            {:ok, %{query_held_bin: v}} -> v
            _ -> 0
          end

        s2 = scenario_bounded(conn, qheld)
        s3 = scenario_small(conn)
        _s4 = scenario_classification(conn)

        any_finding =
          Enum.any?([s1, s2, s3], fn
            {:finding, _} -> true
            _ -> false
          end)

        s3_ratio =
          case s3 do
            {:ok, %{ratio: r}} -> r
            _ -> :finding
          end

        IO.puts("\n=== SUMMARY ===")
        IO.puts("teeth: LIVE   leak-gate: #{if match?({:ok, _}, s1), do: "PASS", else: "FAIL"}")
        IO.puts("small-blob query/stream total-memory ratio: #{inspect(s3_ratio)}x (>=10x = S2 cliff)")

        if any_finding do
          IO.puts("RESULT: FINDING")
          System.halt(1)
        else
          IO.puts("RESULT: CLEAN (characterization complete, no S0-S2)")
          System.halt(0)
        end
    end
  catch
    kind, reason ->
      IO.puts("PROBE ERROR: #{inspect(kind)} #{inspect(reason)}")
      IO.puts(Exception.format_stacktrace(__STACKTRACE__))
      System.halt(3)
  end
end

A12.Probe.main()
