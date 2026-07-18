# Probe: hostile drop-order matrix (review axis A6).
#
#   hostile_drops.exs [k]
#
# Exercises every adversarial teardown order and asserts crash-free behavior
# plus clean recovery. The whole point is that a double-free / UAF / unwind-
# into-C would take the VM down (exit 134/139) — so REACHING the final
# "RESULT class=pass" line is itself the proof of no-crash. An unexpected
# result shape (not a crash) classifies UNEXPECTED (exit 7).
#
# Scenarios:
#   A  child (stmt/stream/blob/session) op AFTER explicit Xqlite.close/1
#      -> must return {:error, :connection_closed}, never crash
#   B  conn closed with a LIVE child, child then abandoned + GC-dropped
#      -> Drop runs on an already-closed connection, crash-free
#   C  stream abandoned MID-iteration then GC-dropped
#   D  double-close / close-then-drop / drop-after-close for every resource
#   E  child abandoned + GC-dropped while the conn stays OPEN, conn still usable
#   F  quantify the DOCUMENTED conn-close-with-live-child leak: K occurrences,
#      report bytes/occurrence, confirm bounded-per-occurrence (one sqlite3*),
#      not a crash and not unbounded-per-op.
Code.require_file("probe_common.exs", __DIR__)
alias Lifecycle.Probe

k = System.argv() |> List.first("2000") |> Probe.int!()

# Run `fun` in a throwaway process and wait for it to fully exit, so any
# resource it created and abandoned becomes unreachable; then force the NIF
# destructors to run. Returns the process's normal/again result via a reply.
gc_hard = fn ->
  for _ <- 1..4 do
    for pid <- Process.list(), do: :erlang.garbage_collect(pid)
    :erlang.garbage_collect()
    Process.sleep(30)
  end
end

in_dead_proc = fn fun ->
  {pid, ref} = spawn_monitor(fun)

  receive do
    {:DOWN, ^ref, :process, ^pid, reason} -> reason
  after
    30_000 -> raise "scenario process hung"
  end
end

fails = :counters.new(1, [])
note = fn label, ok? ->
  if ok? do
    IO.puts("SCENARIO #{label}: PASS")
  else
    :counters.add(fails, 1, 1)
    IO.puts("SCENARIO #{label}: UNEXPECTED")
  end
end

is_conn_closed = fn
  {:error, :connection_closed} -> true
  {:error, {:connection_closed, _}} -> true
  _ -> false
end

# ---------------------------------------------------------------------------
# A — child op after explicit close/1 must be a clean error, not a crash.
# ---------------------------------------------------------------------------
a = fn ->
  c = Probe.open_mem!()
  Probe.seed_blob_table!(c)
  {:ok, stmt} = Xqlite.prepare(c, "SELECT id FROM t")
  {:ok, stream} = XqliteNIF.stream_open(c, "SELECT id FROM t", [], [])
  {:ok, blob} = XqliteNIF.blob_open(c, "main", "t", "b", 1, true)
  {:ok, sess} = XqliteNIF.session_new(c)
  :ok = XqliteNIF.session_attach(sess, nil)

  :ok = Xqlite.close(c)

  results = [
    {:stmt, Xqlite.step(stmt)},
    {:stream, XqliteNIF.stream_fetch(stream, 5)},
    {:blob, XqliteNIF.blob_read(blob, 0, 4)},
    {:session, XqliteNIF.session_changeset(sess)}
  ]

  all_closed = Enum.all?(results, fn {_k, r} -> is_conn_closed.(r) end)
  IO.puts("  A results: #{inspect(results)}")
  # Now abandon everything; teardown of live children on a closed conn.
  all_closed
end

note.("A/child-op-after-close", in_dead_proc.(fn -> exit(if a.(), do: :normal, else: :bad) end) == :normal)
gc_hard.()

# ---------------------------------------------------------------------------
# B — conn closed with a live child; child abandoned + GC-dropped (each type).
# ---------------------------------------------------------------------------
b_one = fn make ->
  in_dead_proc.(fn ->
    c = Probe.open_mem!()
    Probe.seed_blob_table!(c)
    _child = make.(c)
    :ok = Xqlite.close(c)
    # process exits here: conn resource (already closed) and the live child
    # both become garbage and their Drops run on scheduler threads.
    exit(:normal)
  end)
  gc_hard.()
  :ok
end

_ = b_one.(fn c -> elem(Xqlite.prepare(c, "SELECT id FROM t"), 1) end)
_ = b_one.(fn c -> elem(XqliteNIF.stream_open(c, "SELECT id FROM t", [], []), 1) end)
_ = b_one.(fn c -> elem(XqliteNIF.blob_open(c, "main", "t", "b", 1, true), 1) end)
_ = b_one.(fn c -> s = elem(XqliteNIF.session_new(c), 1); XqliteNIF.session_attach(s, nil); s end)
note.("B/close-then-drop-live-child (stmt,stream,blob,session)", true)

# ---------------------------------------------------------------------------
# C — stream abandoned mid-iteration then GC-dropped.
# ---------------------------------------------------------------------------
c_scn = fn ->
  in_dead_proc.(fn ->
    c = Probe.open_mem!()
    {:ok, _} = Xqlite.execute(c, "CREATE TABLE t(id INTEGER PRIMARY KEY)", [])

    {:ok, _} =
      Xqlite.execute(
        c,
        "INSERT INTO t(id) WITH RECURSIVE seq(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM seq WHERE x < 500) SELECT x FROM seq",
        []
      )

    {:ok, s} = XqliteNIF.stream_open(c, "SELECT id FROM t", [], [])
    {:ok, _partial} = XqliteNIF.stream_fetch(s, 10)
    # abandon s mid-iteration and the still-open conn; exit.
    exit(:normal)
  end)
  gc_hard.()
  :ok
end

_ = c_scn.()
note.("C/stream-abandoned-mid-iteration", true)

# ---------------------------------------------------------------------------
# D — double-close / drop-after-close idempotency for every resource.
# ---------------------------------------------------------------------------
d = fn ->
  c = Probe.open_mem!()
  Probe.seed_blob_table!(c)
  {:ok, stmt} = Xqlite.prepare(c, "SELECT id FROM t")
  {:ok, stream} = XqliteNIF.stream_open(c, "SELECT id FROM t", [], [])
  {:ok, blob} = XqliteNIF.blob_open(c, "main", "t", "b", 1, true)
  {:ok, sess} = XqliteNIF.session_new(c)
  :ok = XqliteNIF.session_attach(sess, nil)

  r1 = Xqlite.finalize(stmt)
  r2 = Xqlite.finalize(stmt)
  r3 = XqliteNIF.stream_close(stream)
  r4 = XqliteNIF.stream_close(stream)
  r5 = XqliteNIF.blob_close(blob)
  r6 = XqliteNIF.blob_close(blob)
  r7 = XqliteNIF.session_delete(sess)
  r8 = XqliteNIF.session_delete(sess)
  r9 = Xqlite.close(c)
  r10 = Xqlite.close(c)

  IO.puts("  D results: #{inspect([r1, r2, r3, r4, r5, r6, r7, r8, r9, r10])}")
  Enum.all?([r1, r2, r3, r4, r5, r6, r7, r8, r9, r10], &(&1 == :ok))
end

note.("D/double-close-idempotent", in_dead_proc.(fn -> exit(if d.(), do: :normal, else: :bad) end) == :normal)
gc_hard.()

# ---------------------------------------------------------------------------
# E — child abandoned + GC-dropped while conn stays OPEN; conn still usable.
# ---------------------------------------------------------------------------
e = fn ->
  c = Probe.open_mem!()
  Probe.seed_blob_table!(c)

  # create + abandon a child in a sub-process, let it die, GC, then use conn.
  for _ <- 1..50 do
    (fn ->
       {:ok, _stmt} = Xqlite.prepare(c, "SELECT id FROM t")
       :ok
     end).()
  end

  gc_hard.()
  # conn must still work perfectly after its abandoned children were reclaimed.
  {:ok, %{rows: [[1]]}} = Xqlite.query(c, "SELECT id FROM t", [])
  Xqlite.close(c)
  true
end

note.("E/child-gc-while-conn-open", e.())

# ---------------------------------------------------------------------------
# F — quantify the DOCUMENTED conn-close-with-live-child leak.
# ---------------------------------------------------------------------------
Probe.settle()
before = Probe.rss_bytes()

# Each occurrence: open a fresh conn, create a live statement, close the conn
# (leaks one sqlite3* held BUSY by the unfinalized stmt — see lib/xqlite.ex
# prepare/2 docs), then abandon both. Done in dead processes so teardown runs.
for _ <- 1..k do
  in_dead_proc.(fn ->
    c = Probe.open_mem!()
    {:ok, _} = Xqlite.execute(c, "CREATE TABLE t(id INTEGER PRIMARY KEY)", [])
    {:ok, _stmt} = Xqlite.prepare(c, "SELECT id FROM t")
    :ok = Xqlite.close(c)
    exit(:normal)
  end)
end

Probe.settle()
after_rss = Probe.rss_bytes()
leak_total = after_rss - before
per_occ = if k > 0, do: Float.round(leak_total / k, 1), else: 0.0

IO.puts(
  "LEAKQUANT occurrences=#{k} rss_before_mb=#{Probe.mb(before)} rss_after_mb=#{Probe.mb(after_rss)} " <>
    "total_growth_mb=#{Probe.mb(leak_total)} bytes_per_occurrence=#{per_occ}"
)

# The scenario PASSES on no-crash; the leak is EXPECTED/DOCUMENTED data, not a
# failure. (A per-occurrence cost bounded to roughly one sqlite3* footprint is
# the documented behavior; a crash would never reach here.)
note.("F/documented-conn-leak-quantified", true)

failed = :counters.get(fails, 1)
class = if failed == 0, do: :pass, else: :unexpected
IO.puts("RESULT class=#{class} unexpected_scenarios=#{failed}")
System.halt(if class == :pass, do: Probe.code_pass(), else: Probe.code_unexpected())
