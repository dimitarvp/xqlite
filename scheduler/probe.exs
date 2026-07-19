# A4 scheduler-discipline probe for xqlite.
#
# Drives every NIF family under an `:erlang.system_monitor(_, [{:long_schedule,
# T}])` gate and attributes each delivered long_schedule event to the process
# that caused it (per-workload PID attribution — the NIF MFA at schedule-in is
# reported as :undefined by ERTS, so PID is the reliable key). A normal-scheduler
# NIF that runs longer than T trips the monitor; a Dirty NIF never does
# (long_schedule does not observe dirty schedulers — established this session).
#
# Sections:
#   TEETH  — a fix-independent pure-BEAM control (term_to_binary/[:compressed])
#            MUST deliver >0 long_schedule events, else the monitor is dead and
#            every "0 hits" below is meaningless. run.sh aborts (rc 2) if 0.
#   S1     — INTRINSIC discipline (PASS/FAIL): each NIF family runs worst-case-
#            shaped input on its OWN connection in a dedicated single-call
#            process (no contention). Every DB-touching / unbounded family MUST
#            be Dirty => 0 hits. A hit here means a normal-scheduler NIF ran long
#            on its own — a misclassification.
#   S2     — MUTEX-CONTENTION (INFORMATIONAL): a holder pins the conn Mutex with
#            a slow Dirty query; victim trivial normal readers on the SAME shared
#            handle are timed. Measures normal-scheduler block time under
#            cross-process handle sharing (the documented single-owner design
#            avoids it). Reported, not gated.
#   LAT    — micro-latency of the trivial normal readers (proves <1ms intrinsic).
#
# Exit: 0 PASS (teeth fired + zero intrinsic hits on must-be-dirty families);
#       1 FAIL (an intrinsic hit on a must-be-dirty family — the RED);
#       2 teeth dead (control delivered 0 events).

# --------------------------------------------------------------------------
# Monitor collector — PID-attributed long_schedule events.
# --------------------------------------------------------------------------
defmodule Mon do
  def start(threshold_ms) do
    me = self()
    pid = spawn(fn -> loop(me, []) end)
    :erlang.system_monitor(pid, [{:long_schedule, threshold_ms}])
    pid
  end

  def drain(pid) do
    send(pid, {:dump, self()})

    receive do
      {:events, evs} -> evs
    after
      3000 -> []
    end
  end

  defp loop(owner, acc) do
    receive do
      {:dump, from} ->
        send(from, {:events, Enum.reverse(acc)})
        loop(owner, acc)

      {:monitor, poop, :long_schedule, info} ->
        loop(owner, [{poop, info} | acc])

      _ ->
        loop(owner, acc)
    end
  end
end

# Run `fun` in a dedicated process; return {label, pid, wall_ms, result}. The
# process does ONLY `fun`, so any long_schedule for its pid is caused by `fun`.
run_one = fn label, fun ->
  parent = self()

  pid =
    spawn(fn ->
      t0 = System.monotonic_time(:microsecond)
      r = fun.()
      t1 = System.monotonic_time(:microsecond)
      send(parent, {:done, self(), (t1 - t0) / 1000, r})
    end)

  receive do
    {:done, ^pid, ms, r} -> {label, pid, ms, r}
  after
    120_000 -> {label, pid, :timeout, :timeout}
  end
end

env_int = fn name, default ->
  case System.get_env(name) do
    nil -> default
    s -> String.to_integer(s)
  end
end

threshold = env_int.("THRESHOLD_MS", 25)
blob_mb = env_int.("BLOB_MB", 64)
session_rows = env_int.("SESSION_ROWS", 400_000)
hold_rows = env_int.("HOLD_ROWS", 4_000_000)

blob_bytes = blob_mb * 1024 * 1024

IO.puts("=== A4 scheduler probe ===")
IO.puts(
  "threshold=#{threshold}ms schedulers=#{:erlang.system_info(:schedulers)} " <>
    "dirty_cpu=#{:erlang.system_info(:dirty_cpu_schedulers)} " <>
    "dirty_io=#{:erlang.system_info(:dirty_io_schedulers)} otp=#{System.otp_release()}"
)

IO.puts("blob=#{blob_mb}MB session_rows=#{session_rows} hold_rows=#{hold_rows}\n")

mon = Mon.start(threshold)

# Families that MUST be on a Dirty scheduler (0 intrinsic hits required). This is
# the A4 assertion set: every DB-file-touching op + every unbounded transform.
must_be_dirty =
  MapSet.new([
    "query",
    "execute",
    "stream",
    "step",
    "serialize",
    "backup",
    "schema_columns",
    "get_pragma",
    "blob_open",
    "blob_read",
    "blob_write",
    "blob_reopen",
    "session_changeset",
    "session_patchset",
    "session_delete",
    "changeset_invert",
    "changeset_concat"
  ])

# --------------------------------------------------------------------------
# TEETH — fix-independent control must deliver long_schedule events.
# --------------------------------------------------------------------------
control_term = Enum.map(1..2_000_000, &{&1, &1 * 2})

{_l, control_pid, control_ms, _} =
  run_one.("CONTROL_term_to_binary", fn ->
    byte_size(:erlang.term_to_binary(control_term, [{:compressed, 6}]))
  end)

# --------------------------------------------------------------------------
# Prepare shared artifacts (in the MAIN process; setup ops are Dirty and never
# produce long_schedule events, so they don't pollute attribution).
# --------------------------------------------------------------------------
{:ok, conn} = Xqlite.open_in_memory()
{:ok, _} = Xqlite.execute(conn, "CREATE TABLE b(x BLOB)", [])
{:ok, _} = Xqlite.execute(conn, "INSERT INTO b(rowid, x) VALUES(1, zeroblob(#{blob_bytes}))", [])
{:ok, blob_ro} = XqliteNIF.blob_open(conn, "main", "b", "x", 1, true)
{:ok, blob_rw} = XqliteNIF.blob_open(conn, "main", "b", "x", 1, false)
payload = :binary.copy(<<0>>, blob_bytes)

# Session capturing `session_rows` inserts, plus its serialized changeset.
{:ok, sconn} = Xqlite.open_in_memory()
{:ok, _} = Xqlite.execute(sconn, "CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, c TEXT)", [])
{:ok, sess} = XqliteNIF.session_new(sconn)
:ok = XqliteNIF.session_attach(sess, "t")

{:ok, _} =
  Xqlite.execute(
    sconn,
    "INSERT INTO t(id, a, c) " <>
      "SELECT n, n, 'row-payload-' || n FROM " <>
      "(WITH RECURSIVE g(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM g WHERE n < #{session_rows}) SELECT n FROM g)",
    []
  )

# A second, independent session for the destructive session_delete measurement.
{:ok, sconn2} = Xqlite.open_in_memory()
{:ok, _} = Xqlite.execute(sconn2, "CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, c TEXT)", [])
{:ok, sess2} = XqliteNIF.session_new(sconn2)
:ok = XqliteNIF.session_attach(sess2, "t")

{:ok, _} =
  Xqlite.execute(
    sconn2,
    "INSERT INTO t(id, a, c) " <>
      "SELECT n, n, 'row-payload-' || n FROM " <>
      "(WITH RECURSIVE g(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM g WHERE n < #{session_rows}) SELECT n FROM g)",
    []
  )

# Materialize the big changeset once (used by invert/concat).
{:ok, changeset} = XqliteNIF.session_changeset(sess)
IO.puts("prepared: blob=#{blob_bytes}B changeset=#{byte_size(changeset)}B\n")

# A large table for stream/step/schema/serialize/backup worst cases.
{:ok, wconn} = Xqlite.open_in_memory()
{:ok, _} = Xqlite.execute(wconn, "CREATE TABLE w(id INTEGER PRIMARY KEY, a INTEGER, c TEXT)", [])

{:ok, _} =
  Xqlite.execute(
    wconn,
    "INSERT INTO w(id, a, c) SELECT n, n*2, 'payload-text-' || n FROM " <>
      "(WITH RECURSIVE g(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM g WHERE n < 500000) SELECT n FROM g)",
    []
  )

backup_dir = System.get_env("SCHED_TMPDIR") || System.tmp_dir!()
backup_path = Path.join(backup_dir, "sched_backup_#{System.unique_integer([:positive])}.db")

# --------------------------------------------------------------------------
# S1 — INTRINSIC discipline. Each family, worst-case input, dedicated process.
# --------------------------------------------------------------------------
slow_sql =
  "WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n < #{hold_rows}) " <>
    "SELECT count(*) FROM c"

workloads = [
  # Dirty families (must stay silent) — driven at worst case for completeness.
  {"query", fn -> Xqlite.query(wconn, slow_sql, []) end},
  {"execute", fn -> Xqlite.execute(wconn, "UPDATE w SET a = a + 1", []) end},
  {"stream",
   fn ->
     wconn
     |> Xqlite.stream("SELECT * FROM w", [], batch_size: 256)
     |> Enum.reduce(0, fn _r, acc -> acc + 1 end)
   end},
  {"step",
   fn ->
     {:ok, st} = XqliteNIF.stmt_prepare(wconn, "SELECT * FROM w")
     drain = fn drain, acc ->
       case XqliteNIF.stmt_multi_step(st, 512) do
         {:rows, rows} -> drain.(drain, acc + length(rows))
         {:done, rows} -> acc + length(rows)
         other -> {:err, other}
       end
     end
     drain.(drain, 0)
   end},
  {"serialize", fn -> byte_size(elem(XqliteNIF.serialize(wconn, "main"), 1)) end},
  {"backup", fn -> XqliteNIF.backup(wconn, "main", backup_path) end},
  {"schema_columns", fn -> XqliteNIF.schema_columns(wconn, "w") end},
  {"get_pragma", fn -> XqliteNIF.get_pragma(wconn, "page_count") end},
  # Blob family — the misclassification suspects.
  {"blob_open", fn -> XqliteNIF.blob_open(conn, "main", "b", "x", 1, true) end},
  {"blob_read", fn -> byte_size(elem(XqliteNIF.blob_read(blob_ro, 0, blob_bytes), 1)) end},
  {"blob_write", fn -> XqliteNIF.blob_write(blob_rw, 0, payload) end},
  {"blob_reopen", fn -> XqliteNIF.blob_reopen(blob_ro, 1) end},
  # Session / changeset family — the misclassification suspects.
  {"session_changeset", fn -> byte_size(elem(XqliteNIF.session_changeset(sess), 1)) end},
  {"session_patchset", fn -> byte_size(elem(XqliteNIF.session_patchset(sess), 1)) end},
  {"changeset_invert", fn -> byte_size(elem(XqliteNIF.changeset_invert(changeset), 1)) end},
  {"changeset_concat",
   fn -> byte_size(elem(XqliteNIF.changeset_concat(changeset, changeset), 1)) end},
  {"session_delete", fn -> XqliteNIF.session_delete(sess2) end}
]

results =
  Enum.map(workloads, fn {label, fun} ->
    {^label, pid, ms, _} = run_one.(label, fun)
    {label, pid, ms}
  end)

# --------------------------------------------------------------------------
# S2 — MUTEX-CONTENTION (informational). Holder pins the conn Mutex with a slow
# Dirty query on a SHARED handle; victims are trivial normal readers.
# --------------------------------------------------------------------------
{:ok, shared} = Xqlite.open_in_memory()
{:ok, _} = Xqlite.execute(shared, "CREATE TABLE z(id INTEGER PRIMARY KEY)", [])
{:ok, _} = Xqlite.execute(shared, "INSERT INTO z VALUES(1)", [])

# Per victim: spawn a FRESH holder that pins the conn Mutex with a slow Dirty
# query on the SHARED handle, wait until it is provably mid-flight, then time the
# victim's trivial normal-reader call. Each victim faces a live holder, so the
# whole `with_conn` reader class is shown to block (not just the first one).
measure_contended = fn label, fun ->
  me = self()

  h =
    spawn(fn ->
      send(me, {:holding, self()})
      t0 = System.monotonic_time(:microsecond)
      {:ok, _} = Xqlite.query(shared, slow_sql, [])
      t1 = System.monotonic_time(:microsecond)
      send(me, {:held_ms, (t1 - t0) / 1000})
    end)

  receive do
    {:holding, ^h} -> :ok
  after
    5000 -> :ok
  end

  # head start so the holder's query is provably holding the Mutex
  Process.sleep(100)
  {_rl, pid, ms, _} = run_one.("contend_" <> label, fun)

  hm =
    receive do
      {:held_ms, v} -> v
    after
      30_000 -> :unknown
    end

  {label, pid, ms, hm}
end

contention =
  Enum.map(
    [
      {"changes", fn -> XqliteNIF.changes(shared) end},
      {"db_path", fn -> XqliteNIF.db_path(shared) end},
      {"txn_state", fn -> XqliteNIF.txn_state(shared, nil) end},
      {"total_changes", fn -> XqliteNIF.total_changes(shared) end}
    ],
    fn {label, fun} -> measure_contended.(label, fun) end
  )

# --------------------------------------------------------------------------
# LAT — micro-latency of trivial normal readers on an UNCONTENDED handle.
# --------------------------------------------------------------------------
{:ok, lconn} = Xqlite.open_in_memory()
{:ok, _} = Xqlite.execute(lconn, "CREATE TABLE q(a,b,c,d,e)", [])
{:ok, lstmt} = XqliteNIF.stmt_prepare(lconn, "SELECT a,b,c,d,e FROM q")

lat = fn label, fun ->
  # warmup
  Enum.each(1..100, fn _ -> fun.() end)
  samples =
    Enum.map(1..2000, fn _ ->
      t0 = System.monotonic_time(:microsecond)
      fun.()
      System.monotonic_time(:microsecond) - t0
    end)

  {label, Enum.max(samples), Enum.sum(samples) / length(samples)}
end

latencies = [
  lat.("changes", fn -> XqliteNIF.changes(lconn) end),
  lat.("db_path", fn -> XqliteNIF.db_path(lconn) end),
  lat.("txn_state", fn -> XqliteNIF.txn_state(lconn, nil) end),
  lat.("autocommit", fn -> XqliteNIF.autocommit(lconn) end),
  lat.("blob_size", fn -> XqliteNIF.blob_size(blob_ro) end),
  lat.("session_is_empty", fn -> XqliteNIF.session_is_empty(sess) end),
  lat.("stmt_column_names", fn -> XqliteNIF.stmt_column_names(lstmt) end),
  lat.("create_cancel_token", fn -> XqliteNIF.create_cancel_token() end)
]

# --------------------------------------------------------------------------
# Collect + report.
# --------------------------------------------------------------------------
Process.sleep(400)
events = Mon.drain(mon)
hits = fn pid -> Enum.count(events, fn {p, _} -> p == pid end) end
control_hits = hits.(control_pid)

IO.puts("--- TEETH (fix-independent control) ---")
IO.puts(
  "  CONTROL_term_to_binary: #{Float.round(control_ms, 1)}ms  long_schedule_hits=#{control_hits}" <>
    if(control_hits > 0, do: "  [monitor ARMED + DELIVERING]", else: "  [!! MONITOR DEAD !!]")
)

IO.puts("\n--- S1 INTRINSIC discipline (each NIF, own conn, worst case) ---")
IO.puts(String.pad_trailing("  family", 24) <> "wall_ms   hits   verdict")

{intrinsic_fail, s1_rows} =
  Enum.reduce(results, {false, []}, fn {label, pid, ms}, {fail?, rows} ->
    h = hits.(pid)
    dirty_required = MapSet.member?(must_be_dirty, label)
    bad = dirty_required and h > 0
    verdict =
      cond do
        bad -> "FAIL(normal-sched hog)"
        dirty_required -> "ok(dirty:silent)"
        true -> "ok(fast-normal)"
      end

    ms_str = if is_number(ms), do: Float.round(ms, 1), else: ms

    IO.puts(
      "  " <>
        String.pad_trailing(label, 22) <>
        String.pad_trailing("#{ms_str}", 10) <>
        String.pad_trailing("#{h}", 7) <> verdict
    )

    {fail? or bad, [{label, ms, h, bad} | rows]}
  end)

IO.puts("\n--- S2 MUTEX-CONTENTION (informational; shared handle across processes) ---")
IO.puts("  victim normal reader blocked on the conn Mutex held by a slow Dirty query:")

Enum.each(contention, fn {label, pid, ms, hm} ->
  h = hits.(pid)
  ms_str = if is_number(ms), do: Float.round(ms, 1), else: ms
  hm_str = if is_number(hm), do: Float.round(hm, 1), else: hm

  IO.puts(
    "  " <>
      String.pad_trailing(label, 16) <>
      "blocked=#{ms_str}ms   (holder held #{hm_str}ms)   long_schedule_hits=#{h}"
  )
end)

IO.puts("\n--- LAT micro-latency (uncontended trivial normal readers, µs) ---")
IO.puts(String.pad_trailing("  reader", 26) <> "max_us   mean_us")

Enum.each(latencies, fn {label, mx, mean} ->
  IO.puts(
    "  " <>
      String.pad_trailing(label, 24) <>
      String.pad_trailing("#{mx}", 9) <> "#{Float.round(mean, 2)}"
  )
end)

File.rm(backup_path)

IO.puts("\n=== SUMMARY ===")
IO.puts("control_hits=#{control_hits} intrinsic_fail=#{intrinsic_fail}")

failed_families =
  s1_rows
  |> Enum.filter(fn {_l, _ms, _h, bad} -> bad end)
  |> Enum.map(fn {l, ms, h, _} -> "#{l}(#{Float.round(ms, 0)}ms/#{h}hits)" end)

if failed_families != [] do
  IO.puts("FAIL families: " <> Enum.join(failed_families, " "))
end

cond do
  control_hits == 0 ->
    IO.puts("VERDICT: TEETH_DEAD")
    System.halt(2)

  intrinsic_fail ->
    IO.puts("VERDICT: FAIL (normal-scheduler hog on a must-be-dirty family)")
    System.halt(1)

  true ->
    IO.puts("VERDICT: PASS (teeth fired; every must-be-dirty family silent)")
    System.halt(0)
end
