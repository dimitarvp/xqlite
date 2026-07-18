#!/usr/bin/env bash
#
# Cancellation-semantics probe harness for xqlite (review axis A5). Exercises
# the progress-handler cancel mechanism (Arc<AtomicBool> checked every 8 VM ops)
# and CLASSIFIES each probe:
#
#   latency    measure how quickly a cancel takes effect on an unbounded query
#              (end-to-end wall time from cancel_operation/1 to the NIF
#              returning :operation_cancelled). Distribution over N trials.
#   race       hammer the cancel-just-as-it-finishes window; every outcome must
#              be exactly {completed | cancelled}; a third shape is :torn (S0).
#              Both classes must occur or the window was not exercised.
#   reuse      DOCUMENT the token-reuse semantics: a signalled Arc<AtomicBool> is
#              never reset, so a reused token poisons the next op (single-use).
#   overhead   INFORMATIONAL (T4.7): marginal cost of a cancellable call vs a
#              plain one, tiny-query and heavy-query workloads.
#   teardown   cancel racing conn-close / stmt-finalize / GC-drop, many
#              iterations; crash/hang oracle for the W3 dangling-pointer question.
#
# TEETH FIRST (hard gate; the run ABORTS if any fails to trip):
#   * CRASH classifier: a control that forces exit 134 must classify CRASH
#     (proves the teardown crash oracle detects an abnormal exit — a real UAF
#     from cancel-vs-teardown would abort the same way).
#   * HANG classifier: a sleep-forever control must hit the OS timeout (124).
#   * latency validity: the "unbounded" slow query, run with NO cancel and no
#     internal timeout, must be killed by the OS timeout (124) — proving it does
#     not finish on its own, so a fast cancelled return is caused by the cancel.
#   * TORN classifier: the race probe with TEETH=torn injects one synthetic
#     torn outcome and must classify RACE_TORN (3) — proving the :torn detector
#     is not rubber-stamping.
# A harness that stays green on known-bad input proves nothing.
#
# SAFETY: the only OS processes are `mix run` children spawned here, each under
# `timeout`. No SIGKILL of anything but our own children via the OS timeout; no
# pkill/killall, no name/pattern matching. In-memory DBs only; a private mktemp
# dir is used for any scratch and removed on exit.
#
# Isolated from CI: lives under cancellation/ (not test/), not in elixirc_paths,
# not matched by the formatter inputs glob ({config,lib,test}/**) — never touched
# by `mix test.seq` or `mix verify`. Invoke explicitly:
#
#     bash cancellation/run.sh
#     SMOKE=1 bash cancellation/run.sh          # tiny/fast
#     RACE_ITERS=1000 bash cancellation/run.sh  # heavier race
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "${SCRIPT_DIR}")
cd "${REPO_DIR}"

# ---- config (env-overridable) ----------------------------------------------
if [ "${SMOKE:-0}" = "1" ]; then
  LAT_TRIALS=${LAT_TRIALS:-8}; RACE_ITERS=${RACE_ITERS:-40}; TD_ITERS=${TD_ITERS:-40}
  OVH_A=${OVH_A:-5000}; OVH_B=${OVH_B:-4}
else
  LAT_TRIALS=${LAT_TRIALS:-40}; RACE_ITERS=${RACE_ITERS:-300}; TD_ITERS=${TD_ITERS:-400}
  OVH_A=${OVH_A:-50000}; OVH_B=${OVH_B:-20}
fi
LAT_SETTLE_MS=${LAT_SETTLE_MS:-40}
OVH_B_BOUND=${OVH_B_BOUND:-3000000}
PROBE_TIMEOUT=${PROBE_TIMEOUT:-300}
TD_TIMEOUT=${TD_TIMEOUT:-300}
HANG_TIMEOUT=${HANG_TIMEOUT:-4}
NOCANCEL_TIMEOUT=${NOCANCEL_TIMEOUT:-6}

export MIX_ENV=dev
# Compile once so the probes can use --no-compile (fast, no rebuild races).
env XQLITE_BUILD=true mix compile >/dev/null 2>&1 || { echo "ABORT: mix compile failed"; exit 2; }
MIX_RUN=(env XQLITE_BUILD=true mix run --no-compile --no-start)

WORK=$(mktemp -d /tmp/xqlite_cancellation.XXXXXX)
SUMMARY="${WORK}/summary.txt"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

FAILED=0
note() { printf '%s\n' "$*" | tee -a "${SUMMARY}"; }
abort() { note "ABORT: $*"; exit 2; }

# run_probe TIMEOUT SCRIPT ARGS... -> sets RC, RESULT_LINE
run_probe() {
  local t=$1; shift
  local out
  out=$(timeout -k 5 "${t}" "${MIX_RUN[@]}" "$@" 2>&1)
  RC=$?
  RESULT_LINE=$(printf '%s\n' "${out}" | grep -E '^RESULT ' | tail -1)
  [ -z "${RESULT_LINE}" ] && RESULT_LINE=$(printf '%s\n' "${out}" | tail -3 | tr '\n' ' ')
  return 0
}

class_of() {
  case $1 in
    0) echo PASS ;;
    3) echo RACE_TORN ;;
    4) echo NO_EFFECT ;;
    5) echo NOT_EXERCISED ;;
    7) echo UNEXPECTED ;;
    124) echo HANG ;;
    134|139) echo CRASH ;;
    137) echo CRASH_OR_OOM ;;
    *) echo "ERROR(rc=$1)" ;;
  esac
}

note "=== xqlite A5 cancellation harness ==="
note "work dir: ${WORK}"
note "config: lat(trials=${LAT_TRIALS} settle=${LAT_SETTLE_MS}ms) race(iters=${RACE_ITERS}) teardown(iters=${TD_ITERS}) overhead(a=${OVH_A} b=${OVH_B}x${OVH_B_BOUND})"
note ""

# ===========================================================================
# TEETH GATE — every oracle must trip on known-bad input before any real probe.
# ===========================================================================
note "--- TEETH GATE ---"

# (a) CRASH classifier: forced exit 134 must classify CRASH.
run_probe 30 cancellation/crash_control.exs
if [ "${RC}" -ne 134 ] && [ "${RC}" -ne 139 ]; then
  abort "crash control NOT classified CRASH (rc=${RC}): ${RESULT_LINE}"
fi
note "teeth CRASH(forced halt 134): TRIPPED (rc=${RC})"

# (b) HANG classifier: sleep-forever must hit the OS timeout.
run_probe "${HANG_TIMEOUT}" cancellation/hang_control.exs
if [ "${RC}" -ne 124 ]; then abort "hang control NOT classified HANG (rc=${RC}): ${RESULT_LINE}"; fi
note "teeth HANG(sleep-forever): TRIPPED (timeout fired, rc=124)"

# (c) latency validity: the unbounded query with no cancel must be killed by the
# OS timeout (proves it is genuinely long-running).
run_probe "${NOCANCEL_TIMEOUT}" cancellation/latency.exs nocancel
if [ "${RC}" -ne 124 ]; then
  abort "no-cancel unbounded query was NOT killed by timeout (rc=${RC}): ${RESULT_LINE} — query not actually slow, latency numbers would be invalid"
fi
note "teeth LATENCY-VALIDITY(unbounded query never self-completes): TRIPPED (rc=124)"

# (d) TORN classifier: injected synthetic torn outcome must classify RACE_TORN.
export TEETH=torn
run_probe "${PROBE_TIMEOUT}" cancellation/race.exs 20
unset TEETH
if [ "${RC}" -ne 3 ]; then abort "torn-injection did NOT classify RACE_TORN (rc=${RC}): ${RESULT_LINE}"; fi
note "teeth RACE_TORN(injected torn outcome): TRIPPED (rc=3) -> ${RESULT_LINE}"
note ""

# ===========================================================================
# REAL PROBES
# ===========================================================================
note "--- PROBES ---"

# Probe 1 — cancel latency
run_probe "${PROBE_TIMEOUT}" cancellation/latency.exs latency "${LAT_TRIALS}" "${LAT_SETTLE_MS}"
note "Probe 1 latency:   $(class_of "${RC}")  (rc=${RC})"
note "    ${RESULT_LINE}"
[ "${RC}" -eq 0 ] || FAILED=1

# Probe 2 — cancel-vs-completion race
run_probe "${PROBE_TIMEOUT}" cancellation/race.exs "${RACE_ITERS}"
note "Probe 2 race:      $(class_of "${RC}")  (rc=${RC})"
note "    ${RESULT_LINE}"
[ "${RC}" -eq 0 ] || FAILED=1

# Probe 3 — token reuse semantics
run_probe "${PROBE_TIMEOUT}" cancellation/reuse.exs
note "Probe 3 reuse:     $(class_of "${RC}")  (rc=${RC})"
note "    ${RESULT_LINE}"
[ "${RC}" -eq 0 ] || FAILED=1

# Probe 4 — never-cancelled overhead (INFORMATIONAL — never fails the run)
run_probe "${PROBE_TIMEOUT}" cancellation/overhead.exs "${OVH_A}" "${OVH_B}" "${OVH_B_BOUND}"
note "Probe 4 overhead:  $(class_of "${RC}")  (rc=${RC})  [INFORMATIONAL]"
note "    ${RESULT_LINE}"
[ "${RC}" -eq 0 ] || note "    (overhead probe errored — informational only, not counted as a finding)"

# Probe 5 — cancel racing teardown
run_probe "${TD_TIMEOUT}" cancellation/teardown.exs "${TD_ITERS}"
note "Probe 5 teardown:  $(class_of "${RC}")  (rc=${RC})"
note "    ${RESULT_LINE}"
[ "${RC}" -eq 0 ] || FAILED=1

note ""
note "=== VERDICT ==="
if [ "${FAILED}" -eq 0 ]; then
  note "ALL PROBES PASS — no torn/undefined result, no crash, no hang; cancel latency bounded; reuse semantics documented (single-use)."
  note "(Strength bounded by the teeth above, all of which TRIPPED.)"
  exit 0
else
  note "ONE OR MORE PROBES FAILED — inspect ${SUMMARY} (work dir removed on exit)."
  exit 1
fi
