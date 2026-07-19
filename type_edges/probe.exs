# A9 type/value-edge probe for xqlite. Drives real values end-to-end through
# the ACTUAL public API (open :memory: -> bind/insert -> read back via every
# read path) and PINS the observed behavior, asserting EXACT equality against
# the known input so a silent truncation/wrap/corruption FAILS the probe.
#
# Read paths under test (source-mapped):
#   * query/execute  -> core_query -> query.rs process_rows -> rusqlite safe API
#                       (row.get::<Value> -> TryFrom<ValueRef>, value_ref.rs:159)
#   * stream / step / multi_step -> process_single_step ->
#                       util.rs sqlite_row_to_elixir_terms (raw FFI)
#   * blob_read      -> nif.rs blob_read (raw sqlite3_blob_read bytes)
#
# Invocations:
#   mix run --no-compile type_edges/probe.exs selftest   # teeth: oracle must
#       flag planted corruption and must NOT false-positive a correct value.
#   mix run --no-compile type_edges/probe.exs            # all real edges.
#
# Exit codes: 0 = clean (only OK / defined / decision-debt / info pins);
#             1 = a real S0 silent wrong-value / truncation / corruption pin;
#             2 = harness/oracle broken;
#             3 = selftest mode detected the oracle has no teeth.

defmodule TE do
  # ---- strict equality oracle (the teeth key) -------------------------------
  # Byte/term identity. Truncation (<<1,0,2>> vs <<1>>), wrap, and type drift
  # (integer 1 vs float 1.0) all fail here.
  def same?(a, b), do: a === b

  def start, do: Agent.start_link(fn -> %{hard: 0, findings: []} end, name: __MODULE__)

  def pin(edge, verdict, observed) do
    vs = to_string(verdict)
    # hard-fail ONLY on a broken byte-exact round-trip / silent out-of-range
    # store (unambiguous silent corruption): verdict starting with "S0".
    hard? = String.starts_with?(vs, "S0")
    # a reported finding: any S0/S1/S2 or an explicit decision-debt pin.
    finding? = String.starts_with?(vs, ["S0", "S1", "S2"]) or verdict == :"DECISION-DEBT"

    Agent.update(__MODULE__, fn st ->
      st = if hard?, do: %{st | hard: st.hard + 1}, else: st
      if finding?, do: %{st | findings: [{edge, verdict} | st.findings]}, else: st
    end)

    IO.puts("PIN | #{pad(edge, 34)} | #{pad(vs, 26)} | #{observed}")
  end

  def hard_count, do: Agent.get(__MODULE__, & &1.hard)
  def findings, do: Agent.get(__MODULE__, &Enum.reverse(&1.findings))

  # expect_eq: round-trip must be byte-exact; a mismatch is an S0 silent
  # wrong-value finding.
  def expect_eq(edge, got, want, verdict_ok \\ :OK) do
    if same?(got, want) do
      pin(edge, verdict_ok, "round-trip exact: #{show(got)}")
      true
    else
      pin(edge, :S0, "SILENT WRONG VALUE got=#{show(got)} want=#{show(want)}")
      false
    end
  end

  def show(v), do: inspect(v, binaries: :as_binaries, limit: 12, printable_limit: 90)
  def showt(v), do: inspect(v, limit: :infinity, printable_limit: 220)
  defp pad(s, n), do: String.pad_trailing(String.slice(s, 0, n), n)

  # safe/1: capture value OR any raise/throw so a public-API crash is pinned.
  def safe(fun) do
    {:returned, fun.()}
  rescue
    e -> {:raised, e.__struct__, Exception.message(e)}
  catch
    kind, val -> {:caught, kind, inspect(val)}
  end

  def mem do
    {:ok, c} = Xqlite.open_in_memory()
    c
  end
end

defmodule Classify do
  # F1 (ruled + fixed 16ca65d): a non-finite REAL now reads back as a SANCTIONED
  # sentinel (+Inf -> :positive_infinity, -Inf -> :negative_infinity, NaN -> nil)
  # on every read path, so the nonfinite behavior is PINNED byte-exact by
  # `expect_eq` in edge_nonfinite rather than classified as unknown here.

  def utf8({:returned, {:error, {:utf8_error, _col, _}}}), do: :OK_structured_utf8_error
  def utf8({:returned, {:error, other}}), do: {:other_error_class, other}
  def utf8({:returned, {:ok, %{rows: rows}}}), do: {:S0_returned_lossy_or_raw, rows}
  def utf8({:returned, list}) when is_list(list), do: {:S0_returned_lossy_or_raw, list}
  def utf8({:returned, {:row, vals}}), do: {:S0_returned_lossy_or_raw, vals}
  def utf8({:raised, s, _}), do: {:S1_raise, s}
  def utf8(other), do: {:other, other}

  def err({:returned, {:error, _}}), do: :OK_clean_error
  def err({:returned, {:ok, _}}), do: :S2_unexpected_ok
  def err({:raised, _, _}), do: :S1_raise
  def err({:caught, _, _}), do: :S1_throw
  def err(_), do: :other
end

TE.start()
classify_utf8 = &Classify.utf8/1
classify_err = &Classify.err/1

# Extract the single scalar of a one-column, one-row read on each read path.
# A raise/regression returns the raw {:raised, ...} tuple so the === oracle in
# expect_eq flags it (a return to the pre-F1 ArgumentError never passes silently).
scalar_query = fn c, sql ->
  case TE.safe(fn -> Xqlite.query(c, sql, []) end) do
    {:returned, {:ok, %{rows: [[v]]}}} -> v
    other -> other
  end
end

scalar_step = fn c, sql ->
  case TE.safe(fn ->
         {:ok, st} = Xqlite.prepare(c, sql)
         Xqlite.step(st)
       end) do
    {:returned, {:row, [v]}} -> v
    other -> other
  end
end

scalar_stream = fn c, sql ->
  case TE.safe(fn -> Enum.to_list(Xqlite.stream(c, sql, [])) end) do
    {:returned, [row]} when is_map(row) -> row |> Map.values() |> hd()
    other -> other
  end
end

verdict_utf8 = fn
  :OK_structured_utf8_error -> :OK
  # stream returned rows/[] instead of an error: the error was SWALLOWED. Empty
  # = silent truncation (S1); non-empty = lossy/raw bytes surfaced as a value (S0).
  {:S0_returned_lossy_or_raw, []} -> :S1_stream_swallowed_error
  {:S0_returned_lossy_or_raw, [_ | _]} -> :S0_returned_lossy_value
  {:S1_raise, _} -> :S1_raise
  {:other_error_class, _} -> :S2_wrong_error_class
  _ -> :INFO
end

# ===========================================================================
# SELFTEST — prove the oracle has teeth and does not false-positive.
# ===========================================================================
run_selftest = fn ->
  planted = [
    {"truncated-at-nul", <<1>>, <<1, 0, 2>>, true},
    {"int-wrap", -9_223_372_036_854_775_808, 9_223_372_036_854_775_808, true},
    {"int-vs-float", 1, 1.0, true},
    {"nul-text-trunc", "a", "a\0b", true},
    {"correct-blob", <<1, 0, 2>>, <<1, 0, 2>>, false},
    {"correct-int", 9_223_372_036_854_775_807, 9_223_372_036_854_775_807, false}
  ]

  results =
    Enum.map(planted, fn {desc, got, want, must_flag} ->
      flagged = not TE.same?(got, want)

      cond do
        must_flag and flagged ->
          IO.puts("  teeth OK   | #{desc}: oracle FLAGGED planted mismatch")
          :ok

        not must_flag and not flagged ->
          IO.puts("  teeth OK   | #{desc}: oracle accepted correct value")
          :ok

        must_flag ->
          IO.puts("  TEETH GONE | #{desc}: oracle MISSED a planted mismatch")
          :no_teeth

        true ->
          IO.puts("  TEETH BAD  | #{desc}: oracle false-positived a correct value")
          :no_teeth
      end
    end)

  if Enum.all?(results, &(&1 == :ok)) do
    IO.puts("RESULT SELFTEST_PASS oracle has teeth (#{length(planted)} controls)")
    System.halt(0)
  else
    IO.puts("RESULT SELFTEST_FAIL oracle has no teeth")
    System.halt(3)
  end
end

# ===========================================================================
# EDGE 1 — Elixir bignums beyond i64
# ===========================================================================
edge_bignum = fn ->
  c = TE.mem()
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE t(x)", [])

  imax = 9_223_372_036_854_775_807
  imin = -9_223_372_036_854_775_808
  {:ok, _} = Xqlite.execute(c, "INSERT INTO t(rowid, x) VALUES (1, ?)", [imax])
  {:ok, _} = Xqlite.execute(c, "INSERT INTO t(rowid, x) VALUES (2, ?)", [imin])
  {:ok, rmax} = Xqlite.query(c, "SELECT x FROM t WHERE rowid=1", [])
  {:ok, rmin} = Xqlite.query(c, "SELECT x FROM t WHERE rowid=2", [])
  TE.expect_eq("bignum_i64_max_roundtrip", hd(hd(rmax.rows)), imax)
  TE.expect_eq("bignum_i64_min_roundtrip", hd(hd(rmin.rows)), imin)

  over = 9_223_372_036_854_775_808
  under = -9_223_372_036_854_775_809
  ro = Xqlite.execute(c, "INSERT INTO t(rowid, x) VALUES (10, ?)", [over])
  ru = Xqlite.execute(c, "INSERT INTO t(rowid, x) VALUES (11, ?)", [under])
  {:ok, chk} = Xqlite.query(c, "SELECT count(*) FROM t WHERE rowid IN (10,11)", [])
  stored = hd(hd(chk.rows))

  case {ro, ru, stored} do
    {{:error, _}, {:error, _}, 0} ->
      TE.pin("bignum_over_i64", :OK, "clean error, nothing stored: #{TE.showt(ro)}")

    {_, _, n} when n > 0 ->
      TE.pin("bignum_over_i64", :S0, "SILENTLY STORED #{n} out-of-range row(s): #{TE.showt(ro)}")

    other ->
      TE.pin("bignum_over_i64", :S2, "non-error, nothing stored: #{TE.showt(other)}")
  end

  dt2300 = %DateTime{
    year: 2300, month: 1, day: 1, hour: 0, minute: 0, second: 0,
    microsecond: {0, 0}, time_zone: "Etc/UTC", zone_abbr: "UTC", utc_offset: 0, std_offset: 0
  }

  ns = DateTime.to_unix(dt2300, :nanosecond)

  rf =
    Xqlite.execute(c, "INSERT INTO t(rowid, x) VALUES (20, ?)", [dt2300],
      type_extensions: [Xqlite.TypeExtension.Instant]
    )

  verdict = if match?({:error, _}, rf), do: :OK, else: :S2
  TE.pin("instant_far_future_ns_over_i64", verdict, "ns=#{ns} (>i64) -> #{TE.showt(rf)}")
end

# ===========================================================================
# EDGE 2 — NaN / +Inf / -Inf floats
# ===========================================================================
edge_nonfinite = fn ->
  inf_etf = <<131, 70, 0x7F, 0xF0, 0, 0, 0, 0, 0, 0>>
  nan_etf = <<131, 70, 0x7F, 0xF8, 0, 0, 0, 0, 0, 0>>
  TE.pin("nonfinite_bind_construct_inf", :INFO, "binary_to_term(+Inf ETF) -> #{TE.showt(TE.safe(fn -> :erlang.binary_to_term(inf_etf) end))}")
  TE.pin("nonfinite_bind_construct_nan", :INFO, "binary_to_term(NaN ETF)  -> #{TE.showt(TE.safe(fn -> :erlang.binary_to_term(nan_etf) end))}")

  c = TE.mem()

  # F1 (ruled + fixed 16ca65d): reading a non-finite REAL returns a SANCTIONED
  # sentinel on EVERY read path — +Inf -> :positive_infinity,
  # -Inf -> :negative_infinity, NaN -> nil — never the pre-fix ArgumentError.
  # Byte-exact assertions: a regression to a raise, a different atom, or a raw
  # float all break the === oracle.
  TE.expect_eq("inf_read_via_query", scalar_query.(c, "SELECT 9e999"), :positive_infinity)
  TE.expect_eq("inf_read_via_stream", scalar_stream.(c, "SELECT 9e999"), :positive_infinity)
  TE.expect_eq("inf_read_via_step", scalar_step.(c, "SELECT 9e999"), :positive_infinity)
  TE.expect_eq("neg_inf_read_via_query", scalar_query.(c, "SELECT -9e999"), :negative_infinity)

  {:ok, _} = Xqlite.execute(c, "CREATE TABLE f(x REAL)", [])
  {:ok, _} = Xqlite.execute(c, "INSERT INTO f VALUES (9e999)", [])
  TE.expect_eq("stored_inf_read_via_query", scalar_query.(c, "SELECT x FROM f"), :positive_infinity)

  # The connection stays usable after reading a non-finite (the conn Mutex drops
  # cleanly before the sentinel encode returns; a wedged conn would be S0).
  after_inf = TE.safe(fn -> Xqlite.query(c, "SELECT 1", []) end)
  usable = match?({:returned, {:ok, _}}, after_inf)
  TE.pin("inf_read_conn_still_usable", if(usable, do: :OK, else: :S0), TE.showt(after_inf))

  # Stored NaN silently becomes NULL (SQLite has no NaN storage class) — D2
  # decision-debt, documented in guides/gotchas.md.
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE g(x REAL)", [])
  {:ok, _} = Xqlite.execute(c, "INSERT INTO g VALUES (9e999 - 9e999)", [])
  {:ok, gr} = Xqlite.query(c, "SELECT x, typeof(x) FROM g", [])
  [[gval, gtype]] = gr.rows
  nan_verdict = if gval == nil, do: :"DECISION-DEBT", else: :S2
  TE.pin("stored_nan_becomes_null", nan_verdict, "value=#{TE.show(gval)} typeof=#{TE.show(gtype)}")

  # Computed NaN reads back as nil (F1 NaN arm of encode_f64).
  TE.expect_eq("computed_nan_read_via_query", scalar_query.(c, "SELECT 9e999 - 9e999"), nil)
end

# ===========================================================================
# EDGE 3 — interior-NUL round-trips through EVERY read path
# ===========================================================================
edge_interior_nul = fn ->
  c = TE.mem()
  text = "a\0b\0c"
  blob = <<1, 0, 0xFF, 0, 2>>
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE t(x TEXT, y BLOB)", [])
  {:ok, _} = Xqlite.execute(c, "INSERT INTO t(rowid, x, y) VALUES (1, ?, ?)", [text, blob])

  {:ok, tr} = Xqlite.query(c, "SELECT typeof(x), typeof(y), length(x), length(y) FROM t", [])
  TE.pin("nul_storage_classes", :INFO, TE.show(hd(tr.rows)))

  {:ok, r1} = Xqlite.query(c, "SELECT x, y FROM t", [])
  [[qt, qb]] = r1.rows
  TE.expect_eq("nul_text_via_query", qt, text)
  TE.expect_eq("nul_blob_via_query", qb, blob)

  # NOTE: Xqlite.stream yields rows as MAPS keyed by column name (unlike step,
  # which yields lists). Pinned here so the read-path shape is on record.
  [srow] = Enum.to_list(Xqlite.stream(c, "SELECT x, y FROM t", []))
  TE.pin("stream_row_shape", :INFO, "map keys=#{inspect(Map.keys(srow))}")
  TE.expect_eq("nul_text_via_stream", srow["x"], text)
  TE.expect_eq("nul_blob_via_stream", srow["y"], blob)

  {:ok, ps} = Xqlite.prepare(c, "SELECT x, y FROM t")
  {:row, [pt, pb]} = Xqlite.step(ps)
  TE.expect_eq("nul_text_via_step", pt, text)
  TE.expect_eq("nul_blob_via_step", pb, blob)

  {:ok, bh} = XqliteNIF.blob_open(c, "main", "t", "y", 1, true)
  {:ok, bsz} = XqliteNIF.blob_size(bh)
  {:ok, bbytes} = XqliteNIF.blob_read(bh, 0, bsz)
  TE.expect_eq("nul_blob_via_blob_read", bbytes, blob)

  # Adaptive blob backing (F-A12-1): the query encode_val path copies blobs
  # <= 64 B into a heap OwnedBinary and zero-copy-wraps blobs > 64 B in a
  # BlobResource. Prove an interior-NUL blob survives BYTE-EXACT across the
  # 64-byte threshold on every read path (query/step/blob_read) — the
  # size-adaptive branch must never truncate at a NUL nor drop a byte.
  nul_blob = fn n -> <<1, 0, 0xFF, 0, 2>> |> :binary.copy(div(n, 5) + 1) |> binary_part(0, n) end
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE tb(id INTEGER PRIMARY KEY, y BLOB)", [])

  Enum.each([1, 63, 64, 65, 200], fn n ->
    b = nul_blob.(n)
    {:ok, _} = Xqlite.execute(c, "INSERT INTO tb(id, y) VALUES (?, ?)", [n, b])

    {:ok, rq} = Xqlite.query(c, "SELECT y FROM tb WHERE id = ?", [n])
    TE.expect_eq("nul_blob_query_#{n}B", hd(hd(rq.rows)), b)

    {:ok, ps} = Xqlite.prepare(c, "SELECT y FROM tb WHERE id = ?")
    :ok = Xqlite.bind(ps, [n])
    {:row, [sb]} = Xqlite.step(ps)
    TE.expect_eq("nul_blob_step_#{n}B", sb, b)

    {:ok, bh2} = XqliteNIF.blob_open(c, "main", "tb", "y", n, true)
    {:ok, sz2} = XqliteNIF.blob_size(bh2)
    {:ok, rr} = XqliteNIF.blob_read(bh2, 0, sz2)
    TE.expect_eq("nul_blob_read_#{n}B", rr, b)
  end)

  # Run 9 distinction (reject_interior_nul, F-A11-3): a NUL in a bound VALUE
  # round-trips byte-exact (above), but a NUL in the SQL TEXT itself is REJECTED
  # with :null_byte_in_string on query/execute/execute_batch — never silently
  # truncated at the NUL (SQLite's tokenizer stops at a NUL, shortening the
  # statement into something unintended).
  nul_sql = "SELECT 1" <> <<0>> <> " , 2"
  rq_nul = Xqlite.query(c, nul_sql, [])
  re_nul = Xqlite.execute(c, nul_sql, [])
  rb_nul = Xqlite.execute_batch(c, nul_sql)

  reject_ok =
    match?({:error, :null_byte_in_string}, rq_nul) and
      match?({:error, :null_byte_in_string}, re_nul) and
      match?({:error, :null_byte_in_string}, rb_nul)

  TE.pin(
    "nul_in_sql_text_rejected",
    if(reject_ok, do: :OK, else: :S1_nul_sql_not_rejected),
    "query=#{TE.showt(rq_nul)} execute=#{TE.showt(re_nul)} batch=#{TE.showt(rb_nul)}"
  )
end

# ===========================================================================
# EDGE 4 — invalid-UTF-8 in a TEXT column, read-back end-to-end
# ===========================================================================
edge_bad_utf8 = fn ->
  c = TE.mem()
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE u(x TEXT)", [])
  {:ok, _} = Xqlite.execute(c, "INSERT INTO u(rowid, x) VALUES (1, CAST(X'ff41' AS TEXT))", [])
  {:ok, tc} = Xqlite.query(c, "SELECT typeof(x), length(x) FROM u WHERE rowid=1", [])
  TE.pin("bad_utf8_storage_class", :INFO, TE.show(hd(tc.rows)))

  {:ok, _} = Xqlite.execute(c, "INSERT INTO u(rowid, x) VALUES (2, 'valid')", [])
  {:ok, vr} = Xqlite.query(c, "SELECT x FROM u WHERE rowid=2", [])
  TE.expect_eq("bad_utf8_negctl_valid_text", hd(hd(vr.rows)), "valid")

  q = TE.safe(fn -> Xqlite.query(c, "SELECT x FROM u WHERE rowid=1", []) end)

  p =
    TE.safe(fn ->
      {:ok, st} = Xqlite.prepare(c, "SELECT x FROM u WHERE rowid=1")
      Xqlite.step(st)
    end)

  # query + step surface the structured 3-tuple {:utf8_error, col, detail}.
  TE.pin("bad_utf8_read_via_query", verdict_utf8.(classify_utf8.(q)), TE.showt(q))
  TE.pin("bad_utf8_read_via_step", verdict_utf8.(classify_utf8.(p)), TE.showt(p))

  # Stream (F2 default :raise, fixed 16ca65d) raises Xqlite.StreamError whose
  # STRUCTURED :reason field carries the SAME 3-tuple. Assert on :reason, never
  # the message string. Pre-fix this error was swallowed into Logger + silent
  # truncation; a regression to that makes stream_raise :no_raise -> flagged.
  stream_raise =
    try do
      _ = Enum.to_list(Xqlite.stream(c, "SELECT x FROM u WHERE rowid=1", []))
      :no_raise
    rescue
      e in Xqlite.StreamError -> {:stream_error_reason, e.reason}
    end

  sr_ok = match?({:stream_error_reason, {:utf8_error, 0, _}}, stream_raise)

  TE.pin(
    "bad_utf8_read_via_stream_raises",
    if(sr_ok, do: :OK, else: :S1_stream_swallowed),
    TE.showt(stream_raise)
  )

  # The three ruled on_error modes over a table whose row 3 is invalid UTF-8
  # (rows 1,2 good; row 4 good but unreachable once row 3 fails). batch_size: 1
  # forces the error mid-stream. Each mode's shape is DISTINCT — a collapse is
  # flagged.
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE w(x TEXT)", [])

  {:ok, _} =
    Xqlite.execute(
      c,
      "INSERT INTO w(rowid,x) VALUES (1,'g1'),(2,'g2'),(3,CAST(X'ff' AS TEXT)),(4,'g4')",
      []
    )

  # :raise (default) — a mid-stream error raises; a failed read can never
  # masquerade as a completed stream.
  raise_mode =
    try do
      _ = Enum.to_list(Xqlite.stream(c, "SELECT x FROM w ORDER BY rowid", [], batch_size: 1))
      :no_raise
    rescue
      e in Xqlite.StreamError -> {:raised, e.reason}
    end

  TE.pin(
    "stream_on_error_raise",
    if(match?({:raised, {:utf8_error, _, _}}, raise_mode), do: :OK, else: :S1_no_raise),
    TE.showt(raise_mode)
  )

  # :halt (opt-in, documented LOSSY) — yields the good prefix, logs, stops.
  halt_labels =
    c
    |> Xqlite.stream("SELECT x FROM w ORDER BY rowid", [], batch_size: 1, on_error: :halt)
    |> Enum.map(& &1["x"])

  TE.pin(
    "stream_on_error_halt_lossy",
    if(halt_labels == ["g1", "g2"], do: :OK, else: :S2_halt_shape),
    "yielded #{TE.showt(halt_labels)} (documented lossy truncation)"
  )

  # :emit_error — uniform {:ok, row} elements then a terminal {:error, reason}.
  emit_rows =
    c
    |> Xqlite.stream("SELECT x FROM w ORDER BY rowid", [], batch_size: 1, on_error: :emit_error)
    |> Enum.to_list()

  emit_ok =
    match?([{:ok, %{"x" => "g1"}}, {:ok, %{"x" => "g2"}}, {:error, {:utf8_error, 0, _}}], emit_rows)

  TE.pin(
    "stream_on_error_emit_error",
    if(emit_ok, do: :OK, else: :S1_emit_shape),
    TE.showt(emit_rows)
  )
end

# ===========================================================================
# EDGE 5 — SQLITE_MAX_LENGTH / MAX_VARIABLE_NUMBER boundaries
# ===========================================================================
edge_limits = fn ->
  c = TE.mem()

  n = 40_000
  many_sql = "SELECT " <> Enum.map_join(1..n, ",", fn _ -> "?" end)
  many = TE.safe(fn -> Xqlite.query(c, many_sql, List.duplicate(1, n)) end)
  TE.pin("max_variable_number_over", classify_err.(many), "#{n} binds -> #{TE.showt(many)}")

  ok_sql = "SELECT " <> Enum.map_join(1..100, ",", fn _ -> "?" end)
  okv = TE.safe(fn -> Xqlite.query(c, ok_sql, List.duplicate(7, 100)) end)

  ok_verdict =
    case okv do
      {:returned, {:ok, %{rows: [row]}}} when length(row) == 100 -> :OK
      _ -> :S2
    end

  TE.pin("max_variable_number_negctl_100", ok_verdict, TE.show(okv))

  # zeroblob checks the limit BEFORE allocating (sqlite3_result_zeroblob64 ->
  # SQLITE_TOOBIG), so this drives the boundary WITHOUT allocating ~1GB.
  big = TE.safe(fn -> Xqlite.query(c, "SELECT zeroblob(1000000001)", []) end)
  TE.pin("max_length_over_toobig", classify_err.(big), TE.showt(big))

  small = TE.safe(fn -> Xqlite.query(c, "SELECT zeroblob(1000)", []) end)

  small_verdict =
    case small do
      {:returned, {:ok, %{rows: [[b]]}}} when byte_size(b) == 1000 -> :OK
      _ -> :S2
    end

  TE.pin("max_length_negctl_1000", small_verdict, "1000-byte blob ok? -> #{TE.show(small_verdict)}")
end

# ===========================================================================
# EDGE 6 — offset-preserving DateTime TEXT vs ORDER BY (decision-debt)
# ===========================================================================
edge_datetime_orderby = fn ->
  dtA = %DateTime{
    year: 2024, month: 6, day: 1, hour: 23, minute: 0, second: 0,
    microsecond: {0, 0}, time_zone: "Etc/UTC", zone_abbr: "UTC", utc_offset: 0, std_offset: 0
  }

  dtB = %DateTime{
    year: 2024, month: 6, day: 2, hour: 0, minute: 0, second: 0,
    microsecond: {0, 0}, time_zone: "Etc/GMT-2", zone_abbr: "+02", utc_offset: 7200, std_offset: 0
  }

  ext = [Xqlite.TypeExtension.DateTime]
  isoA = Xqlite.TypeExtension.DateTime.encode(dtA)
  isoB = Xqlite.TypeExtension.DateTime.encode(dtB)
  TE.pin("datetime_iso_A", :INFO, "A ts=#{TE.show(isoA)} unix=#{DateTime.to_unix(dtA)}")
  TE.pin("datetime_iso_B", :INFO, "B ts=#{TE.show(isoB)} unix=#{DateTime.to_unix(dtB)} (B is earlier)")

  c = TE.mem()
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE dt(label TEXT, ts TEXT)", [])
  {:ok, _} = Xqlite.execute(c, "INSERT INTO dt VALUES (?, ?)", ["A", dtA], type_extensions: ext)
  {:ok, _} = Xqlite.execute(c, "INSERT INTO dt VALUES (?, ?)", ["B", dtB], type_extensions: ext)

  {:ok, ob} = Xqlite.query(c, "SELECT label FROM dt ORDER BY ts ASC", [])
  sql_order = Enum.map(ob.rows, &hd/1)

  chrono_order =
    [{"A", dtA}, {"B", dtB}]
    |> Enum.sort(fn {_, x}, {_, y} -> DateTime.compare(x, y) != :gt end)
    |> Enum.map(&elem(&1, 0))

  {:ok, rb} = Xqlite.query(c, "SELECT ts FROM dt WHERE label='B'", [], type_extensions: ext)
  decoded_b = hd(hd(rb.rows))
  roundtrips = match?(%DateTime{}, decoded_b) and DateTime.compare(decoded_b, dtB) == :eq
  TE.expect_eq("datetime_value_roundtrip", roundtrips, true)

  if sql_order == chrono_order do
    TE.pin("datetime_orderby_mixed_offsets", :OK, "ORDER BY==chronological #{TE.show(sql_order)}")
  else
    TE.pin(
      "datetime_orderby_mixed_offsets",
      :"DECISION-DEBT",
      "ORDER BY ts=#{TE.show(sql_order)} but chronological=#{TE.show(chrono_order)} (lexical TEXT sort != time)"
    )
  end
end

# ===========================================================================
# EDGE 7 — encode-only type-extension read-back story (Instant)
# ===========================================================================
edge_encode_only = fn ->
  c = TE.mem()
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE i(ts)", [])

  dt = %DateTime{
    year: 2024, month: 6, day: 1, hour: 12, minute: 0, second: 0,
    microsecond: {0, 0}, time_zone: "Etc/UTC", zone_abbr: "UTC", utc_offset: 0, std_offset: 0
  }

  ext = [Xqlite.TypeExtension.Instant]
  {:ok, _} = Xqlite.execute(c, "INSERT INTO i VALUES (?)", [dt], type_extensions: ext)

  {:ok, r} = Xqlite.query(c, "SELECT ts FROM i", [], type_extensions: ext)
  got = hd(hd(r.rows))
  want_ns = DateTime.to_unix(dt, :nanosecond)
  TE.expect_eq("instant_encode_only_readback", got, want_ns)

  verdict = if is_integer(got), do: :OK, else: :S2
  TE.pin("instant_readback_is_raw_int_defined", verdict, "is_integer? #{is_integer(got)} (no decode by design)")
end

# ---- dispatch -------------------------------------------------------------
case System.argv() do
  ["selftest"] ->
    run_selftest.()

  _ ->
    IO.puts("=== A9 type/value-edge probe ===")
    edge_bignum.()
    edge_nonfinite.()
    edge_interior_nul.()
    edge_bad_utf8.()
    edge_limits.()
    edge_datetime_orderby.()
    edge_encode_only.()

    hard = TE.hard_count()
    findings = TE.findings()
    IO.puts("")

    Enum.each(findings, fn {edge, v} -> IO.puts("FINDING | #{v} | #{edge}") end)
    IO.puts("")

    cond do
      hard > 0 ->
        IO.puts("RESULT FAIL #{hard} S0 silent round-trip corruption pin(s) — inspect above")
        System.halt(1)

      findings != [] ->
        IO.puts("RESULT PASS_WITH_FINDINGS round-trips byte-exact; #{length(findings)} S1/S2/decision-debt finding(s) reported above")
        System.halt(0)

      true ->
        IO.puts("RESULT PASS no silent corruption, no findings")
        System.halt(0)
    end
end
