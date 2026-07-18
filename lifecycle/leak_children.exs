# Probe: child-resource open/use/close leak loops on a PERSISTENT connection
# (review axis A6).
#
#   leak_children.exs <n> <kind>
#
# One connection is opened once and held for the whole run; only the child
# resource churns <n> times. None of the loop bodies grow persistent DB state,
# so any monotonic RSS climb is a resource leak, not table growth.
#
# kinds (real probes, expect PASS):
#   stmt    prepare -> step -> reset -> finalize
#   stream  stream_open -> stream_fetch* -> stream_close
#   blob    blob_open -> blob_read -> blob_write(same bytes) -> blob_close
#   session session_new -> attach -> changeset -> session_delete
#
# kinds (TEETH, expect LEAK — a planted leak the classifier must catch):
#   stmt_retain  prepare, never finalize, retain the handle
#   blob_retain  blob_open, never close, retain the handle
Code.require_file("probe_common.exs", __DIR__)
alias Lifecycle.Probe

[n_str, kind] = System.argv()
n = Probe.int!(n_str)

conn = Probe.open_mem!()

{:ok, _} =
  Xqlite.execute(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, b BLOB NOT NULL, v INTEGER)", [])

blob_bytes = :binary.copy(<<0xAB>>, 256)
{:ok, _} = Xqlite.execute(conn, "INSERT INTO t(id, b, v) VALUES (1, ?1, 7)", [blob_bytes])

warmup = max(1, div(n, 10))
checkpoints = [warmup] ++ Enum.map(1..5, fn k -> warmup + div((n - warmup) * k, 5) end)
checkpoints = checkpoints |> Enum.uniq() |> Enum.sort()

do_stmt = fn ->
  {:ok, stmt} = Xqlite.prepare(conn, "SELECT id, v FROM t WHERE id = 1")
  {:row, _} = Xqlite.step(stmt)
  :ok = Xqlite.reset(stmt)
  :ok = Xqlite.finalize(stmt)
end

do_stream = fn ->
  {:ok, s} = XqliteNIF.stream_open(conn, "SELECT id FROM t", [], [])
  drain = fn drain, acc ->
    case XqliteNIF.stream_fetch(s, 10) do
      :done -> acc
      {:ok, %{rows: rows}} -> drain.(drain, acc + length(rows))
      other -> raise "stream_fetch: #{inspect(other)}"
    end
  end
  _ = drain.(drain, 0)
  :ok = XqliteNIF.stream_close(s)
end

do_blob = fn ->
  {:ok, blob} = XqliteNIF.blob_open(conn, "main", "t", "b", 1, false)
  {:ok, _bytes} = XqliteNIF.blob_read(blob, 0, 256)
  :ok = XqliteNIF.blob_write(blob, 0, blob_bytes)
  :ok = XqliteNIF.blob_close(blob)
end

do_session = fn ->
  {:ok, sess} = XqliteNIF.session_new(conn)
  :ok = XqliteNIF.session_attach(sess, nil)
  {:ok, _changeset} = XqliteNIF.session_changeset(sess)
  :ok = XqliteNIF.session_delete(sess)
end

step = fn acc ->
  case kind do
    "stmt" -> do_stmt.() && acc
    "stream" -> do_stream.() && acc
    "blob" -> do_blob.() && acc
    "session" -> do_session.() && acc
    "stmt_retain" -> [elem(Xqlite.prepare(conn, "SELECT id, v FROM t WHERE id = 1"), 1) | acc]
    "blob_retain" -> [elem(XqliteNIF.blob_open(conn, "main", "t", "b", 1, true), 1) | acc]
  end
end

{_acc, samples} =
  Enum.reduce(1..n, {[], []}, fn i, {acc, samples} ->
    acc = step.(acc)

    samples =
      if i in checkpoints do
        [Probe.sample(i) | samples]
      else
        samples
      end

    {acc, samples}
  end)

samples = Enum.reverse(samples)
{class, report} = Probe.classify(samples)
# Keep the connection referenced until after the final sample so its own
# teardown never perturbs the measurement.
_ = conn
Probe.finish("children/#{kind}", class, report, samples)
