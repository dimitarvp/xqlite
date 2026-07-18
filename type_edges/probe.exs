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
  # Is a BEAM float finite? Arithmetic on a non-finite float raises, so a
  # raise here also means non-finite.
  defp finite_float?(v) when is_float(v) do
    v == v and v - v == 0.0
  rescue
    _ -> false
  end

  defp tag(v) when is_float(v), do: if(finite_float?(v), do: :finite_float, else: :nonfinite_float)
  defp tag(v) when is_atom(v) and v not in [nil, true, false], do: :suspicious_atom
  defp tag(nil), do: :null
  defp tag(_), do: :other

  defp rows_of({:returned, {:ok, %{rows: rows}}}), do: {:ok, List.flatten(rows)}
  defp rows_of({:returned, list}) when is_list(list), do: {:ok, List.flatten(list)}
  defp rows_of({:returned, {:row, vals}}), do: {:ok, vals}
  defp rows_of(other), do: {:no, other}

  def nonfinite(res) do
    case rows_of(res) do
      {:ok, vals} ->
        tags = Enum.map(vals, &tag/1)

        cond do
          :suspicious_atom in tags -> :S0_returned_atom
          :nonfinite_float in tags -> :S2_returned_nonfinite_float
          :null in tags -> :returned_null
          true -> :returned_value
        end

      {:no, {:returned, {:error, _}}} -> :clean_error
      {:no, {:raised, _, _}} -> :S1_public_api_raise
      {:no, {:caught, _, _}} -> :S1_public_api_throw
      {:no, _} -> :other
    end
  end

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
classify_nonfinite = &Classify.nonfinite/1
classify_utf8 = &Classify.utf8/1
classify_err = &Classify.err/1

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

  q_inf = TE.safe(fn -> Xqlite.query(c, "SELECT 9e999", []) end)
  TE.pin("inf_read_via_query", classify_nonfinite.(q_inf), TE.showt(q_inf))

  s_inf = TE.safe(fn -> Enum.to_list(Xqlite.stream(c, "SELECT 9e999", [])) end)
  TE.pin("inf_read_via_stream", classify_nonfinite.(s_inf), TE.showt(s_inf))

  p_inf =
    TE.safe(fn ->
      {:ok, st} = Xqlite.prepare(c, "SELECT 9e999")
      Xqlite.step(st)
    end)

  TE.pin("inf_read_via_step", classify_nonfinite.(p_inf), TE.showt(p_inf))

  q_ninf = TE.safe(fn -> Xqlite.query(c, "SELECT -9e999", []) end)
  TE.pin("neg_inf_read_via_query", classify_nonfinite.(q_ninf), TE.showt(q_ninf))

  {:ok, _} = Xqlite.execute(c, "CREATE TABLE f(x REAL)", [])
  {:ok, _} = Xqlite.execute(c, "INSERT INTO f VALUES (9e999)", [])
  st_inf = TE.safe(fn -> Xqlite.query(c, "SELECT x, typeof(x) FROM f", []) end)
  TE.pin("stored_inf_read_via_query", classify_nonfinite.(st_inf), TE.showt(st_inf))

  # severity bound: is the connection still usable AFTER an Inf-raise, or is it
  # wedged/poisoned? (enif_make_double badarg is a return-time BEAM raise, so
  # the conn Mutex should drop cleanly.) Wedged would be far worse (S0).
  after_raise = TE.safe(fn -> Xqlite.query(c, "SELECT 1", []) end)
  usable = match?({:returned, {:ok, _}}, after_raise)
  TE.pin("inf_raise_conn_still_usable", if(usable, do: :OK, else: :S0), TE.showt(after_raise))

  {:ok, _} = Xqlite.execute(c, "CREATE TABLE g(x REAL)", [])
  {:ok, _} = Xqlite.execute(c, "INSERT INTO g VALUES (9e999 - 9e999)", [])
  {:ok, gr} = Xqlite.query(c, "SELECT x, typeof(x) FROM g", [])
  [[gval, gtype]] = gr.rows
  nan_verdict = if gval == nil, do: :"DECISION-DEBT", else: :S2
  TE.pin("stored_nan_becomes_null", nan_verdict, "value=#{TE.show(gval)} typeof=#{TE.show(gtype)}")

  q_nan = TE.safe(fn -> Xqlite.query(c, "SELECT 9e999 - 9e999", []) end)
  TE.pin("computed_nan_read_via_query", classify_nonfinite.(q_nan), TE.showt(q_nan))
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
  s = TE.safe(fn -> Enum.to_list(Xqlite.stream(c, "SELECT x FROM u WHERE rowid=1", [])) end)

  p =
    TE.safe(fn ->
      {:ok, st} = Xqlite.prepare(c, "SELECT x FROM u WHERE rowid=1")
      Xqlite.step(st)
    end)

  TE.pin("bad_utf8_read_via_query", verdict_utf8.(classify_utf8.(q)), TE.showt(q))
  TE.pin("bad_utf8_read_via_stream", verdict_utf8.(classify_utf8.(s)), TE.showt(s))
  TE.pin("bad_utf8_read_via_step", verdict_utf8.(classify_utf8.(p)), TE.showt(p))

  # SILENT TRUNCATION demo: good rows BEFORE a bad row are yielded, then the
  # stream halts on the bad row (Logger.error, no error to the consumer) and
  # the trailing good row is never seen. query surfaces the error instead.
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE w(x TEXT)", [])

  {:ok, _} =
    Xqlite.execute(
      c,
      "INSERT INTO w(rowid,x) VALUES (1,'g1'),(2,'g2'),(3,CAST(X'ff' AS TEXT)),(4,'g4')",
      []
    )

  trunc = Enum.to_list(Xqlite.stream(c, "SELECT x FROM w ORDER BY rowid", [], batch_size: 1))
  q_all = TE.safe(fn -> Xqlite.query(c, "SELECT x FROM w ORDER BY rowid", []) end)
  got_labels = Enum.map(trunc, & &1["x"])

  verdict =
    if length(trunc) == 4, do: :OK, else: :S1_stream_silent_truncation

  TE.pin(
    "stream_silent_truncation",
    verdict,
    "stream yielded #{length(trunc)}/4 rows #{TE.showt(got_labels)}; query -> #{TE.showt(q_all)}"
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
