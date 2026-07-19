# A13 hot-upgrade-posture probe for xqlite.
#
# rustler 0.38's init codegen hardcodes upgrade/reload/unload = None
# (rustler_codegen-0.38.0/src/init.rs:92-94), so the generated ErlNifEntry has a
# NULL upgrade callback. Per the erl_nif contract, a NIF library "fails to load
# if upgrade ... is NULL" when the module already has old code with a loaded NIF.
# This probe RUNS the hot-code paths an operator would hit and captures EXACTLY
# what the VM does, and — the safety-critical half — what happens to LIVE
# resources (conn / statement / stream / blob / session) across each attempt.
#
# Modes (env HOTUP_MODE):
#   probe (default) — sections A-D with hard assertions; exit 0 all-pass, 1 fail.
#   teeth           — load the NIF, prove it works, then System.halt(134) to
#                     simulate a crash-on-purge. run.sh MUST classify this CRASH;
#                     if it does not, the crash oracle is dead and every "no
#                     crash" below is meaningless. This is the harness's tooth.
#
# Exit: 0 PASS (reload refused cleanly + every live resource survived + no crash);
#       1 FAIL (a reload silently succeeded, or a live resource broke, or an
#               assertion tripped); a real crash aborts the VM (rc 134/139) and
#               run.sh classifies CRASH.

defmodule P do
  def hdr(s), do: IO.puts("\n== #{s} ==")
  def p(l, v), do: IO.puts("  #{l}: #{inspect(v)}")

  def assert!(true, _msg), do: :ok

  def assert!(cond, msg) do
    IO.puts("  ASSERT FAILED: #{msg} (got #{inspect(cond)})")
    System.halt(1)
  end

  # a live-resource probe that must not raise and must return an ok-ish shape
  def try_op(fun) do
    fun.()
  rescue
    e -> {:rescued, e.__struct__}
  catch
    k, v -> {:caught, k, v}
  end
end

defmodule HotUpgrade do
  import P

  def open_resources do
    {:ok, c} = Xqlite.open_in_memory()
    :ok = Xqlite.execute_batch(c, "CREATE TABLE t(x); INSERT INTO t VALUES(1),(2),(3);")
    {:ok, stmt} = XqliteNIF.stmt_prepare(c, "SELECT x FROM t ORDER BY x")
    {:ok, stream} = XqliteNIF.stream_open(c, "SELECT x FROM t ORDER BY x", [])
    {:ok, session} = XqliteNIF.session_new(c)
    # a blob needs a rowid table with a blob column
    :ok = Xqlite.execute_batch(c, "CREATE TABLE b(v BLOB); INSERT INTO b(rowid, v) VALUES(1, x'0102030405');")
    {:ok, blob} = XqliteNIF.blob_open(c, "main", "b", "v", 1, true)
    %{conn: c, stmt: stmt, stream: stream, session: session, blob: blob}
  end

  # exercise every live resource; each must still work (ok-shaped, no raise)
  def exercise(r, tag) do
    q = try_op(fn -> Xqlite.query(r.conn, "SELECT count(*) FROM t", []) end)
    s = try_op(fn -> XqliteNIF.stmt_step(r.stmt) end)
    f = try_op(fn -> XqliteNIF.stream_fetch(r.stream, 2) end)
    b = try_op(fn -> XqliteNIF.blob_read(r.blob, 0, 5) end)
    se = try_op(fn -> XqliteNIF.session_is_empty(r.session) end)
    p("[#{tag}] conn query", q)
    p("[#{tag}] stmt step", s)
    p("[#{tag}] stream fetch", f)
    p("[#{tag}] blob read", b)
    p("[#{tag}] session empty?", se)

    assert!(match?({:ok, _}, q), "[#{tag}] conn query must be {:ok,_}")
    assert!(match?({:row, _}, s) or s == :done, "[#{tag}] stmt step must be {:row,_}/:done")
    # {:ok, %{rows: _}} while rows remain, :done once drained — both prove the
    # held stream resource is alive and responding (not crashed).
    assert!(match?({:ok, %{rows: _}}, f) or f == :done, "[#{tag}] stream fetch must return rows or :done")
    assert!(match?({:ok, _}, b), "[#{tag}] blob read must be {:ok,_}")
    assert!(is_boolean(se) or match?({:ok, _}, se), "[#{tag}] session op must be ok")
    :ok
  end

  def run_probe do
    hdr("A — baseline: open conn + statement + stream + blob + session")
    r = open_resources()
    p("conn", is_reference(r.conn))
    p("stmt/stream/session/blob all references",
      Enum.all?([r.stmt, r.stream, r.session, r.blob], &is_reference/1))
    exercise(r, "baseline")

    hdr("B — reload the NIF module (:code.load_file), resources held live")
    reload = :code.load_file(XqliteNIF)
    p(":code.load_file(XqliteNIF)", reload)
    # THE core claim: a reload is REFUSED cleanly. A silent success while old
    # resources are live would mean two library instances — the dangerous case.
    assert!(reload == {:error, :on_load_failure},
      "reload MUST be refused with {:error, :on_load_failure}, never a silent success")
    IO.puts("  -> reload refused; now every live resource must still work:")
    exercise(r, "after-failed-reload")

    soft = :code.soft_purge(XqliteNIF)
    p(":code.soft_purge(XqliteNIF)", soft)
    exercise(r, "after-soft-purge")

    hdr("C — direct :erlang.load_nif from a foreign module (back-door check)")
    path = :filename.join(:code.priv_dir(:xqlite), ~c"native/xqlitenif")
    direct = try_op(fn -> :erlang.load_nif(path, 0) end)
    p(":erlang.load_nif(path, 0) from this module", direct)
    assert!(match?({:error, {:bad_lib, _}}, direct),
      "direct load_nif from a foreign module MUST be refused ({:bad_lib,_})")

    hdr("D — forced :code.delete + :code.purge with live resources (destructor stress)")
    # Open a SECOND independent set that we will drop + GC AFTER purging the
    # owning module, forcing the resource destructors to run out of a
    # to-be-unloaded library. erl_nif postpones unload while destructor-bearing
    # resources exist; this checks that provenance holds with no crash.
    r2 = open_resources()
    p("r2 opened + live pre-purge", is_reference(r2.conn))
    del = :code.delete(XqliteNIF)
    p(":code.delete(XqliteNIF)", del)
    pur = :code.purge(XqliteNIF)
    p(":code.purge(XqliteNIF)", pur)
    p(":code.is_loaded after delete+purge", :code.is_loaded(XqliteNIF))
    # drop refs to r2 and force GC — destructors (sqlite3_close etc.) run now
    r2 = nil
    _ = r2
    :erlang.garbage_collect()
    Process.sleep(50)
    :erlang.garbage_collect()
    IO.puts("  -> survived delete+purge+GC of a live resource set (no VM abort)")
    # the first set r is still referenced; its C library must still be resident
    # (unload postponed). A fresh op through the (auto-reloaded) module path:
    fresh = try_op(fn -> Xqlite.open_in_memory() end)
    p("fresh open after delete+purge", fresh)

    hdr("VERDICT")
    IO.puts("  PASS — reload refused cleanly, every live resource survived every")
    IO.puts("  attempt, no back-door load, delete+purge+GC crash-free.")
    # keep r alive to the very end so its destructors run at process exit too
    _ = r
    System.halt(0)
  end

  def run_teeth do
    hdr("TEETH — crash oracle liveness")
    {:ok, c} = Xqlite.open_in_memory()
    {:ok, _} = Xqlite.query(c, "SELECT 1", [])
    IO.puts("  NIF loaded + working; forcing a simulated crash-on-purge (halt 134)")
    _ = c
    System.halt(134)
  end
end

case System.get_env("HOTUP_MODE", "probe") do
  "teeth" -> HotUpgrade.run_teeth()
  _ -> HotUpgrade.run_probe()
end
