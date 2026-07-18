# A5 probe — token reuse / stale-cancel semantics.
#
# The cancel flag is an Arc<AtomicBool> set once to true by cancel() and NEVER
# reset (there is no reset path in the crate). This probe DOCUMENTS the
# resulting reuse semantics by observation, and has a teeth control proving the
# observed immediate-cancel is caused by the stale flag (not a broken path).
#
# Scenarios (all on a fast, naturally-completing query):
#   S1 stale_poisons_next  fresh token; op1 (no cancel) completes; cancel the
#                          token; op2 with the SAME token is immediately
#                          cancelled. => a signalled token poisons reuse.
#   S2 never_auto_reset    cancel; op1 cancelled; op2 with the SAME token again
#                          still cancelled. => the flag never auto-resets between
#                          ops.
#   S3 fresh_token_control TEETH: a FRESH (unsignalled) token on the same query
#                          completes normally. Proves S1/S2's immediate cancel is
#                          the stale flag, not a broken query path.
#   S4 multi_step_reuse    a pre-signalled token cancels multi_step before
#                          stepping; after reset/1 a fresh (empty) token reruns
#                          to completion — the documented recovery path.
#
# Verdict semantics reported: single_use / stale_poisons_next / auto_reset.
Code.require_file("probe_common.exs", __DIR__)
alias Cancellation.Probe, as: P
alias XqliteNIF, as: NIF

conn = P.open_mem!()
# small, always-completes-fast query
quick = P.counting_sql(50_000)

fail = fn tag, detail ->
  P.finish("reuse", :unexpected, %{scenario: tag, detail: detail})
end

# S1 — a signalled token poisons the next op.
tok1 = P.token!()

case NIF.query_cancellable(conn, quick, [], [tok1]) do
  {:ok, %{rows: _}} -> :ok
  other -> fail.(:s1_op1_precancel, inspect(other))
end

:ok = NIF.cancel_operation(tok1)

s1 =
  case NIF.query_cancellable(conn, quick, [], [tok1]) do
    {:error, :operation_cancelled} -> :poisoned
    {:ok, %{rows: _}} -> :not_poisoned
    other -> fail.(:s1_op2, inspect(other))
  end

# S2 — the flag never auto-resets: reuse the SAME already-signalled token again.
s2 =
  case NIF.query_cancellable(conn, quick, [], [tok1]) do
    {:error, :operation_cancelled} -> :still_cancelled
    {:ok, %{rows: _}} -> :auto_reset
    other -> fail.(:s2, inspect(other))
  end

# S3 — TEETH: a fresh token completes normally on the very same query.
tok_fresh = P.token!()

s3 =
  case NIF.query_cancellable(conn, quick, [], [tok_fresh]) do
    {:ok, %{rows: _}} -> :fresh_completes
    other -> fail.(:s3_fresh_control, inspect(other))
  end

# S4 — multi_step: pre-signalled token cancels before stepping; reset + empty
# token reruns to completion (mirrors statement_cancel_test's recovery path).
{:ok, stmt} = Xqlite.prepare(conn, P.counting_sql(1_000_000))
tok4 = P.token!()
:ok = NIF.cancel_operation(tok4)

s4_cancel =
  case Xqlite.multi_step_cancellable(stmt, 1, [tok4]) do
    {:error, :operation_cancelled} -> :cancelled_before_step
    other -> fail.(:s4_cancel, inspect(other))
  end

:ok = Xqlite.reset(stmt)

s4_rerun =
  case Xqlite.multi_step_cancellable(stmt, 2, []) do
    {:ok, %{rows: [[_]], done: true}} -> :rerun_ok
    other -> fail.(:s4_rerun, inspect(other))
  end

:ok = Xqlite.finalize(stmt)

# S5 — multi-token OR-semantics: three tokens, only the MIDDLE one signalled,
# the op must still cancel (any signalled token in the list wins).
{a, b, c} = {P.token!(), P.token!(), P.token!()}
:ok = NIF.cancel_operation(b)

s5 =
  case NIF.query_cancellable(conn, P.never_sql(), [], [a, b, c]) do
    {:error, :operation_cancelled} -> :or_cancels
    other -> fail.(:s5_or, inspect(other))
  end

# S6 — OR teeth: three FRESH tokens, none signalled, the op completes normally.
# Proves S5's cancel is the one signalled token, not the mere presence of a list.
s6 =
  case NIF.query_cancellable(conn, quick, [], [P.token!(), P.token!(), P.token!()]) do
    {:ok, %{rows: _}} -> :none_signalled_completes
    other -> fail.(:s6_or_control, inspect(other))
  end

# --- verdict ---------------------------------------------------------------
single_use = s1 == :poisoned and s2 == :still_cancelled
teeth_ok = s3 == :fresh_completes and s6 == :none_signalled_completes
or_ok = s5 == :or_cancels

report = %{
  s1_stale_poisons_next: s1,
  s2_never_auto_reset: s2,
  s3_fresh_token_control: s3,
  s4_multi_step_cancel: s4_cancel,
  s4_multi_step_rerun_after_reset: s4_rerun,
  s5_multi_token_or: s5,
  s6_or_none_signalled_control: s6,
  semantics: %{
    single_use: single_use,
    stale_poisons_next: s1 == :poisoned,
    auto_reset: s2 == :auto_reset,
    multi_token_or: or_ok
  },
  teeth_fresh_and_or_controls_complete: teeth_ok
}

cond do
  not teeth_ok ->
    # A fresh token being cancelled would mean the query path itself is broken —
    # the reuse observations would then be meaningless.
    P.finish("reuse", :no_effect, Map.put(report, :note, "fresh-token control did not complete"))

  single_use and or_ok ->
    P.finish("reuse", :pass, report)

  true ->
    P.finish("reuse", :unexpected, Map.put(report, :note, "reuse/OR semantics unexpected"))
end
