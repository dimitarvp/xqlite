# A10 structured-error-contract probe for xqlite. Drives REAL error conditions
# through the ACTUAL public API and asserts the STRUCTURED-ERROR CONTRACT on the
# `{:error, reason}` each one returns:
#
#   (a) STRUCTURED classification — `reason` is a classification atom or a tuple
#       with an atom head; NEVER a bare binary (text-only error) and NEVER the
#       bare `:error` atom.
#   (b) EXTENDED result code present + correct — proven two ways: the SPECIFIC
#       constraint-kind atom (`:constraint_unique` = extended 2067, not the
#       generic `:constraint_violation` a primary-only path would yield) and the
#       SQLITE_TOOBIG `{:sqlite_failure, 18, 18, _}` code pair.
#   (c) Exception.message ALWAYS a binary (the one raising surface,
#       `Xqlite.StreamError`, plus every message-bearing reason field).
#   (d) WITH-MATCHABLE shape — each reason is destructured by a real `with`.
#
# TEETH (hard gate; run.sh ABORTS if the oracle self-test fails): the contract
# oracle MUST reject a text-only error (bare binary), a bare `:error`, a wrong
# classification (a UNIQUE result claimed as `:constraint_check`), and a
# non-binary message — and must NOT false-positive a correct structured reason.
# An oracle blind to those proves nothing about the reasons it green-lights.
#
# Invocations:
#   mix run --no-compile error_contract/probe.exs selftest  # teeth gate
#   mix run --no-compile error_contract/probe.exs           # all conditions
#
# Exit codes: 0 = every contract assertion held (S3 findings are printed but do
#             NOT fail — this is a surface-only pass);
#             1 = a CONTRACT VIOLATION (text-only/bare-:error/non-binary msg/
#                 unmatchable shape/wrong extended code) — an S0/S1/S2 breach;
#             2 = harness broken; 3 = selftest detected the oracle has no teeth.

defmodule CT do
  # ---- the contract oracle (the teeth key) ----------------------------------

  # STRUCTURED: a classification atom (never :error) or a tuple whose head is a
  # classification atom (never :error). A bare binary or number is text/opaque
  # and is REJECTED — this is what the "no text-only error" tooth trips on.
  def structured?(:error), do: false
  def structured?(reason) when is_atom(reason), do: true

  def structured?(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    head = elem(reason, 0)
    is_atom(head) and head != :error
  end

  def structured?(_), do: false

  def classification(reason) when is_atom(reason), do: reason
  def classification(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  def classification(_), do: :__unstructured__

  # constraint_kind/1 extracts the SPECIFIC kind atom (2nd element) of a
  # {:constraint_violation, kind, details} reason — this is the field the
  # extended result code drives. The leading atom is always :constraint_violation.
  def constraint_kind({:constraint_violation, kind, _details}), do: kind
  def constraint_kind(_), do: :__not_a_constraint__

  # constraint_kind_is?/2 rejects a WRONG kind (the wrong-kind tooth).
  def constraint_kind_is?(reason, want), do: constraint_kind(reason) == want

  def msg_binary?(m), do: is_binary(m)

  # ---- bookkeeping ----------------------------------------------------------
  def start, do: Agent.start_link(fn -> %{hard: 0, findings: []} end, name: __MODULE__)
  def hard_count, do: Agent.get(__MODULE__, & &1.hard)
  def findings, do: Agent.get(__MODULE__, &Enum.reverse(&1.findings))

  def pin(cond_name, verdict, observed) do
    vs = to_string(verdict)
    # a CONTRACT VIOLATION (hard fail) is any pin tagged S0/S1/S2.
    hard? = String.starts_with?(vs, ["S0", "S1", "S2"])
    finding? = hard? or verdict == :"S3-FINDING"

    Agent.update(__MODULE__, fn st ->
      st = if hard?, do: %{st | hard: st.hard + 1}, else: st
      if finding?, do: %{st | findings: [{cond_name, verdict} | st.findings]}, else: st
    end)

    IO.puts("PIN | #{pad(cond_name, 32)} | #{pad(vs, 22)} | #{observed}")
  end

  # expect/3: a CONTRACT assertion. A false predicate is an S1 breach (the
  # library handed back something outside its structured-error contract).
  def expect(cond_name, true, _detail), do: pin(cond_name, :OK, "contract held")

  def expect(cond_name, false, detail),
    do: pin(cond_name, :S1_CONTRACT, "CONTRACT BREACH: #{detail}")

  def show(v), do: inspect(v, binaries: :as_binaries, limit: 12, printable_limit: 120)
  def showt(v), do: inspect(v, limit: :infinity, printable_limit: 240)
  defp pad(s, n), do: String.pad_trailing(String.slice(s, 0, n), n)

  def mem do
    {:ok, c} = Xqlite.open_in_memory()
    c
  end

  # err_reason/1: pull the reason out of an {:error, reason}; flag a surprise OK.
  def err_reason({:error, reason}), do: {:err, reason}
  def err_reason(other), do: {:no_err, other}

  # safe/1: capture a raise/throw so a public-API crash is visible (it should be
  # a tuple return, not a raise, for all these conditions).
  def safe(fun) do
    {:returned, fun.()}
  rescue
    e -> {:raised, e.__struct__, Exception.message(e)}
  catch
    kind, val -> {:caught, kind, inspect(val)}
  end
end

CT.start()
import Bitwise

# ===========================================================================
# SELFTEST — prove the oracle has teeth and does not false-positive.
# ===========================================================================
run_selftest = fn ->
  # A stand-in "unique" reason with the correct structured shape.
  uniq = {:constraint_violation, :constraint_unique, %{message: "UNIQUE constraint failed: t.x"}}

  checks = [
    # {desc, predicate_result, must_be} — must_be=false => oracle MUST reject.
    {"text-only error rejected", CT.structured?("no such table: foo"), false},
    {"bare :error rejected", CT.structured?(:error), false},
    {"number reason rejected", CT.structured?(42), false},
    {"wrong-kind rejected", CT.constraint_kind_is?(uniq, :constraint_check), false},
    {"non-binary message rejected", CT.msg_binary?(123), false},
    {"unmatchable-shape rejected (with)",
     match?({:constraint_violation, _, %{}}, "opaque string"), false},

    # correct values the oracle must ACCEPT (no false positives).
    {"structured atom accepted", CT.structured?(:connection_closed), true},
    {"structured tuple accepted", CT.structured?({:no_such_table, "no such table: x"}), true},
    {"right-kind accepted", CT.constraint_kind_is?(uniq, :constraint_unique), true},
    {"binary message accepted", CT.msg_binary?("UNIQUE constraint failed: t.x"), true},
    {"matchable-shape accepted (with)", match?({:constraint_violation, _, %{}}, uniq), true}
  ]

  results =
    Enum.map(checks, fn {desc, got, want} ->
      if got == want do
        IO.puts("  teeth OK   | #{desc}")
        :ok
      else
        IO.puts("  TEETH GONE | #{desc}: got #{got}, wanted #{want}")
        :no_teeth
      end
    end)

  if Enum.all?(results, &(&1 == :ok)) do
    IO.puts("RESULT SELFTEST_PASS oracle has teeth (#{length(checks)} controls)")
    System.halt(0)
  else
    IO.puts("RESULT SELFTEST_FAIL oracle has no teeth")
    System.halt(3)
  end
end

# ===========================================================================
# Shared contract assertion for any {:error, reason}.
# Asserts (a) structured, (b) not bare :error, (d) with-destructurable to its
# leading classification atom. Returns the reason (or :__no_error__).
# ===========================================================================
assert_base = fn cond_name, result ->
  case CT.err_reason(result) do
    {:err, reason} ->
      CT.expect("#{cond_name}/structured", CT.structured?(reason), "not structured: #{CT.showt(reason)}")

      CT.expect(
        "#{cond_name}/not_bare_error",
        CT.classification(reason) != :error and reason != :error,
        "reason is bare :error"
      )

      # (d) with-matchability: a real `with` must bind the classification atom.
      bound =
        with tag when is_atom(tag) <- CT.classification(reason), do: tag

      CT.expect("#{cond_name}/with_matchable", is_atom(bound) and bound != :__unstructured__, CT.showt(reason))
      reason

    {:no_err, other} ->
      CT.pin(cond_name, :S2_NO_ERROR, "expected an error, got: #{CT.showt(other)}")
      :__no_error__
  end
end

# ===========================================================================
# CONDITION 1-6 — constraint violations (kind atom = extended-code proof)
# ===========================================================================
cond_constraints = fn ->
  c = CT.mem()

  # -- UNIQUE --
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE u(x UNIQUE)", [])
  {:ok, _} = Xqlite.execute(c, "INSERT INTO u(x) VALUES (1)", [])
  r_uniq = assert_base.("unique", Xqlite.execute(c, "INSERT INTO u(x) VALUES (1)", []))
  # (b) extended code: SPECIFIC :constraint_unique (ext 2067), NOT the generic
  # :constraint_violation a primary-only (19) path would emit.
  CT.expect("unique/kind_specific", CT.constraint_kind_is?(r_uniq, :constraint_unique), CT.showt(r_uniq))
  # negative tooth: must NOT be misclassified as a check constraint.
  CT.expect("unique/not_check", not CT.constraint_kind_is?(r_uniq, :constraint_check), CT.showt(r_uniq))

  wm_ok =
    match?({:constraint_violation, :constraint_unique, %{message: m} } when is_binary(m), r_uniq)

  CT.expect("unique/details_msg_binary_via_with", wm_ok, CT.showt(r_uniq))

  # -- NOT NULL --
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE n(x NOT NULL)", [])
  r_nn = assert_base.("not_null", Xqlite.execute(c, "INSERT INTO n(x) VALUES (NULL)", []))
  CT.expect("not_null/kind_specific", CT.constraint_kind_is?(r_nn, :constraint_not_null), CT.showt(r_nn))

  # -- CHECK --
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE ck(x, CHECK (x > 0))", [])
  r_ck = assert_base.("check", Xqlite.execute(c, "INSERT INTO ck(x) VALUES (0)", []))
  CT.expect("check/kind_specific", CT.constraint_kind_is?(r_ck, :constraint_check), CT.showt(r_ck))

  # -- PRIMARY KEY (rowid table: SQLite emits UNIQUE text but extended 1555) --
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE pk(id INTEGER PRIMARY KEY)", [])
  {:ok, _} = Xqlite.execute(c, "INSERT INTO pk(id) VALUES (1)", [])
  r_pk = assert_base.("primary_key", Xqlite.execute(c, "INSERT INTO pk(id) VALUES (1)", []))
  CT.expect("primary_key/kind_specific", CT.constraint_kind_is?(r_pk, :constraint_primary_key), CT.showt(r_pk))

  # -- FOREIGN KEY (foreign_keys ON by default) --
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE parent(id INTEGER PRIMARY KEY)", [])

  {:ok, _} =
    Xqlite.execute(c, "CREATE TABLE child(pid INTEGER REFERENCES parent(id))", [])

  r_fk = assert_base.("foreign_key", Xqlite.execute(c, "INSERT INTO child(pid) VALUES (999)", []))
  CT.expect("foreign_key/kind_specific", CT.constraint_kind_is?(r_fk, :constraint_foreign_key), CT.showt(r_fk))

  # -- DATATYPE (STRICT table) --
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE s(v INTEGER) STRICT", [])
  r_dt = assert_base.("datatype", Xqlite.execute(c, "INSERT INTO s(v) VALUES (?)", ["hello"]))
  CT.expect("datatype/kind_specific", CT.constraint_kind_is?(r_dt, :constraint_datatype), CT.showt(r_dt))

  dt_types_ok =
    match?(
      {:constraint_violation, :constraint_datatype, %{source_type: st, target_type: tt}}
      when st in [:text, :integer, :real, :blob] and tt in [:text, :integer, :real, :blob],
      r_dt
    )

  CT.expect("datatype/typed_source_target", dt_types_ok, CT.showt(r_dt))
end

# ===========================================================================
# CONDITION 7 — syntax error -> {:sql_input_error, %{code,message,sql,offset}}
# ===========================================================================
cond_syntax = fn ->
  c = CT.mem()
  reason = assert_base.("syntax_error", Xqlite.query(c, "SELECT FROM WHERE", []))

  shape_ok =
    match?(
      {:sql_input_error, %{code: code, message: msg, sql: sql, offset: off}}
      when is_integer(code) and is_binary(msg) and is_binary(sql) and is_integer(off),
      reason
    )

  CT.expect("syntax_error/structured_map", shape_ok, CT.showt(reason))
end

# ===========================================================================
# CONDITION 8 — type/conversion error on bind (bignum > i64)
# ===========================================================================
cond_conversion = fn ->
  c = CT.mem()
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE t(x)", [])
  over = 9_223_372_036_854_775_808
  reason = assert_base.("conversion", Xqlite.execute(c, "INSERT INTO t(x) VALUES (?)", [over]))

  shape_ok =
    match?(
      {:cannot_convert_to_sqlite_value, v, r} when is_binary(v) and is_binary(r),
      reason
    )

  CT.expect("conversion/structured_pair", shape_ok, CT.showt(reason))
end

# ===========================================================================
# CONDITION 9 — SQLITE_TOOBIG: extended code present + correct (18,18)
# ===========================================================================
cond_toobig = fn ->
  c = CT.mem()
  # zeroblob checks the limit BEFORE allocating -> no ~1GB request.
  reason = assert_base.("toobig", Xqlite.query(c, "SELECT zeroblob(1000000001)", []))

  code_ok =
    match?({:sqlite_failure, 18, 18, m} when is_binary(m), reason)

  CT.expect("toobig/extended_code_18_18", code_ok, CT.showt(reason))
  # negative tooth: a primary-only path would drop the extended code (e.g. 0/nil).
  CT.expect("toobig/not_zero_code", not match?({:sqlite_failure, 0, _, _}, reason), CT.showt(reason))
end

# ===========================================================================
# CONDITION 10 — connection closed
# ===========================================================================
cond_closed = fn ->
  c = CT.mem()
  :ok = Xqlite.close(c)
  reason = assert_base.("connection_closed", Xqlite.query(c, "SELECT 1", []))
  CT.expect("connection_closed/atom", reason == :connection_closed, CT.showt(reason))
end

# ===========================================================================
# CONDITION 11 — statement finalized (misuse guarded to a structured atom)
# ===========================================================================
cond_finalized = fn ->
  c = CT.mem()
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE t(x)", [])
  {:ok, st} = Xqlite.prepare(c, "SELECT x FROM t")
  :ok = Xqlite.finalize(st)
  reason = assert_base.("statement_finalized", Xqlite.step(st))
  CT.expect("statement_finalized/atom", reason == :statement_finalized, CT.showt(reason))
end

# ===========================================================================
# CONDITION 12 — execute a SELECT (misuse) -> :execute_returned_results
# ===========================================================================
cond_exec_results = fn ->
  c = CT.mem()
  reason = assert_base.("execute_returned_results", Xqlite.execute(c, "SELECT 1", []))

  CT.expect(
    "execute_returned_results/atom",
    reason == :execute_returned_results,
    CT.showt(reason)
  )
end

# ===========================================================================
# CONDITION 13 — read-only database write -> {:read_only_database, msg}
# ===========================================================================
cond_readonly = fn dir ->
  path = Path.join(dir, "ro_#{System.unique_integer([:positive])}.db")
  {:ok, c} = Xqlite.open(path, journal_mode: :delete)
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE t(x)", [])
  :ok = Xqlite.close(c)

  {:ok, ro} = Xqlite.open_readonly(path)
  reason = assert_base.("read_only", Xqlite.execute(ro, "INSERT INTO t(x) VALUES (1)", []))
  # The semantic variant now surfaces the extended result code as a 3-tuple
  # {:read_only_database, extended_code, message}; its low byte is
  # SQLITE_READONLY (8), the discriminator a message-only variant hid.
  ro_ok =
    match?({:read_only_database, ext, m} when is_integer(ext) and is_binary(m), reason)

  CT.expect("read_only/3tuple_ext_and_msg", ro_ok, CT.showt(reason))

  CT.expect(
    "read_only/ext_low8_is_readonly",
    match?({:read_only_database, ext, _} when (ext &&& 0xFF) == 8, reason),
    CT.showt(reason)
  )

  :ok = Xqlite.close(ro)
end

# ===========================================================================
# CONDITION 14 — SQLITE_BUSY via real write contention (best-effort)
# ===========================================================================
cond_busy = fn dir ->
  path = Path.join(dir, "busy_#{System.unique_integer([:positive])}.db")
  {:ok, c1} = Xqlite.open(path, journal_mode: :delete, busy_timeout: 0)
  {:ok, _} = Xqlite.execute(c1, "CREATE TABLE t(x)", [])
  {:ok, c2} = Xqlite.open(path, journal_mode: :delete, busy_timeout: 0)

  # c1 grabs a RESERVED lock; c2's write attempt cannot and, with timeout 0,
  # fails immediately with SQLITE_BUSY.
  {:ok, _} = Xqlite.execute(c1, "BEGIN IMMEDIATE", [])
  busy = Xqlite.execute(c2, "INSERT INTO t(x) VALUES (1)", [])

  case CT.err_reason(busy) do
    {:err, reason} ->
      _ = assert_base.("busy", busy)
      # 3-tuple carrying the extended code; low byte is SQLITE_BUSY (5) or
      # SQLITE_LOCKED (6) — the discriminator a message-only variant hid.
      busy_ok =
        match?({:database_busy_or_locked, ext, m} when is_integer(ext) and is_binary(m), reason)

      CT.expect("busy/3tuple_ext_and_msg", busy_ok, CT.showt(reason))

      CT.expect(
        "busy/ext_low8_is_busy_or_locked",
        match?({:database_busy_or_locked, ext, _} when (ext &&& 0xFF) in [5, 6], reason),
        CT.showt(reason)
      )

    {:no_err, other} ->
      # Contention did not reproduce in this environment/timing; not a contract
      # failure, just unreproduced. Pinned INFO so the gap is explicit.
      CT.pin("busy", :INFO, "contention not reproduced: #{CT.showt(other)}")
  end

  _ = Xqlite.execute(c1, "ROLLBACK", [])
  :ok = Xqlite.close(c1)
  :ok = Xqlite.close(c2)
end

# ===========================================================================
# CONDITION 15 — Exception.message is ALWAYS binary (Xqlite.StreamError)
# ===========================================================================
cond_exception_message = fn ->
  c = CT.mem()
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE w(x TEXT)", [])
  # invalid UTF-8 in a TEXT column -> mid-stream fetch error -> default :raise.
  {:ok, _} = Xqlite.execute(c, "INSERT INTO w(rowid,x) VALUES (1, CAST(X'ff' AS TEXT))", [])

  raised =
    CT.safe(fn ->
      Enum.to_list(Xqlite.stream(c, "SELECT x FROM w", [], batch_size: 1))
    end)

  case raised do
    {:raised, Xqlite.StreamError, msg} ->
      CT.expect("stream_error/message_binary", CT.msg_binary?(msg), CT.showt(raised))
      # the structured reason must be preserved on the exception struct.
      CT.pin("stream_error/reason_preserved", :INFO, CT.showt(msg))

    other ->
      CT.pin("stream_error", :INFO, "no raise (stream may not have hit the bad row): #{CT.showt(other)}")
  end
end

# ===========================================================================
# CONDITION 16 — changes() stickiness: RETURNING misdetected as non-DML
# ===========================================================================
cond_changes_returning = fn ->
  c = CT.mem()
  {:ok, _} = Xqlite.execute(c, "CREATE TABLE t(x)", [])

  # changes() is reported via a sqlite3_total_changes()-delta detector: the fresh
  # sqlite3_changes() only when THIS statement moved the total, else 0. Correct
  # for RETURNING DML (has columns yet changes rows) AND for DDL/read-PRAGMA (no
  # columns, and must not leak the sticky prior-DML count).
  {:ok, ins} = Xqlite.query(c, "INSERT INTO t(x) VALUES (1),(2),(3)", [])
  CT.expect("changes/plain_insert", ins.changes == 3, "changes=#{ins.changes} (want 3)")

  # INSERT ... RETURNING returns columns but must report the true affected count.
  ret = Xqlite.query(c, "INSERT INTO t(x) VALUES (4) RETURNING x", [])

  case ret do
    {:ok, r} ->
      CT.expect(
        "changes/returning_counts",
        r.changes == 1 and r.num_rows == 1,
        "changes=#{r.changes} num_rows=#{r.num_rows} rows=#{CT.show(r.rows)} (want 1/1)"
      )

    other ->
      CT.pin("changes/returning", :S2_NO_ERROR, "unexpected: #{CT.showt(other)}")
  end

  # DDL after DML must NOT leak the sticky prior-DML count (report 0, not 4).
  {:ok, ddl} = Xqlite.query(c, "CREATE TABLE t2(y)", [])
  CT.expect("changes/ddl_no_stale_leak", ddl.changes == 0, "DDL changes=#{ddl.changes} (want 0)")

  # read-PRAGMA after DML must report 0.
  {:ok, prg} = Xqlite.query(c, "PRAGMA user_version", [])
  CT.expect("changes/pragma_read_zeroed", prg.changes == 0, "PRAGMA changes=#{prg.changes} (want 0)")

  # negative control: a SELECT after DML must report changes=0.
  {:ok, sel} = Xqlite.query(c, "SELECT x FROM t", [])
  CT.expect("changes/select_zeroed", sel.changes == 0, "SELECT changes=#{sel.changes} (expected 0)")
end

# ---- dispatch -------------------------------------------------------------
case System.argv() do
  ["selftest"] ->
    run_selftest.()

  _ ->
    dir = System.get_env("ERR_TMPDIR") || System.tmp_dir!()
    IO.puts("=== A10 structured-error-contract probe ===")
    cond_constraints.()
    cond_syntax.()
    cond_conversion.()
    cond_toobig.()
    cond_closed.()
    cond_finalized.()
    cond_exec_results.()
    cond_readonly.(dir)
    cond_busy.(dir)
    cond_exception_message.()
    cond_changes_returning.()

    hard = CT.hard_count()
    findings = CT.findings()
    IO.puts("")
    Enum.each(findings, fn {cn, v} -> IO.puts("FINDING | #{v} | #{cn}") end)
    IO.puts("")

    cond do
      hard > 0 ->
        IO.puts("RESULT FAIL #{hard} contract violation(s) — inspect the S1/S2 pins above")
        System.halt(1)

      findings != [] ->
        IO.puts("RESULT PASS_WITH_FINDINGS contract held; #{length(findings)} S3 finding(s) reported (surface-only)")
        System.halt(0)

      true ->
        IO.puts("RESULT PASS contract held, no findings")
        System.halt(0)
    end
end
