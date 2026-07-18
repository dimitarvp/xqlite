#!/usr/bin/env bash
#
# Resource-lifecycle probe harness for xqlite (review axis A6). Drives every
# resource (conn / statement / stream / blob / session) through leak loops and
# a hostile drop-order matrix, and CLASSIFIES each:
#
#   leak-conn      open -> use -> close a connection x10^5 (in-memory AND a
#                  file-backed WAL DB). Bounded lifecycle -> RSS steady state.
#   leak-children  on ONE persistent connection, churn a child x10^5:
#                  {statement, stream, blob, session}. No persistent DB growth,
#                  so any monotonic RSS climb is a resource leak.
#   hostile-drops  every adversarial teardown order (child-op-after-close,
#                  close-with-live-child then GC-drop, stream abandoned mid-
#                  iteration, double-close, drop-after-close, child-GC-while-
#                  conn-open) + quantifies the DOCUMENTED conn-close-with-live-
#                  child leak. A crash (double-free / UAF / unwind-into-C) would
#                  take the VM down; reaching RESULT is the proof of no-crash.
#
# TEETH FIRST (hard gate; the run ABORTS if any fails to trip): retain variants
# plant a REAL leak (resources opened and never closed/GC'd) on the connection,
# statement, and blob instruments. Each MUST classify LEAK (exit 5). A leak
# probe that stays green on a planted leak proves nothing — if the teeth do not
# trip, the instrument is blind and the PASS runs below are worthless.
#
# SAFETY: the only OS processes are `mix run` children spawned here, each under
# `timeout`. No SIGKILL, no pkill/killall, no name/pattern matching. All file
# DBs live in a private mktemp dir under /tmp, removed on exit.
#
# Isolated from CI: lives under lifecycle/ (not test/), not in elixirc_paths,
# not matched by the formatter inputs glob — never touched by `mix test.seq` or
# `mix verify`. Invoke explicitly:
#
#     bash lifecycle/run.sh
#     SMOKE=1 bash lifecycle/run.sh          # tiny/fast
#     N_CONN=200000 bash lifecycle/run.sh    # heavier
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "${SCRIPT_DIR}")
cd "${REPO_DIR}"

# ---- config (env-overridable) ----------------------------------------------
if [ "${SMOKE:-0}" = "1" ]; then
  N_CONN=${N_CONN:-3000}; N_CONN_FILE=${N_CONN_FILE:-1500}; N_CHILD=${N_CHILD:-3000}
  # child teeth need enough retained handles to clear the 24 MB back-half
  # threshold: blob is the lightest (~2 KB each), so 45k keeps a margin.
  TEETH_CONN=${TEETH_CONN:-4000}; TEETH_CHILD=${TEETH_CHILD:-45000}; HOSTILE_K=${HOSTILE_K:-50}
else
  N_CONN=${N_CONN:-100000}; N_CONN_FILE=${N_CONN_FILE:-30000}; N_CHILD=${N_CHILD:-100000}
  TEETH_CONN=${TEETH_CONN:-15000}; TEETH_CHILD=${TEETH_CHILD:-60000}; HOSTILE_K=${HOSTILE_K:-2000}
fi
PROBE_TIMEOUT=${PROBE_TIMEOUT:-600}

export MIX_ENV=dev
MIX_RUN=(env XQLITE_BUILD=true mix run --no-compile --no-start)

WORK=$(mktemp -d /tmp/xqlite_lifecycle.XXXXXX)
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
  LEAKQUANT_LINE=$(printf '%s\n' "${out}" | grep -E '^LEAKQUANT ' | tail -1)
  [ -z "${RESULT_LINE}" ] && RESULT_LINE=$(printf '%s\n' "${out}" | tail -4 | tr '\n' ' ')
  return 0
}

class_of() {
  case $1 in
    0) echo PASS ;;
    5) echo LEAK ;;
    7) echo UNEXPECTED ;;
    124) echo HANG ;;
    134|139) echo CRASH ;;
    137) echo CRASH_OR_OOM ;;
    *) echo "ERROR(rc=$1)" ;;
  esac
}

note "=== xqlite A6 resource-lifecycle harness ==="
note "work dir: ${WORK}"
note "config: n_conn=${N_CONN} n_conn_file=${N_CONN_FILE} n_child=${N_CHILD} teeth_conn=${TEETH_CONN} teeth_child=${TEETH_CHILD} hostile_k=${HOSTILE_K}"
note ""

# ===========================================================================
# TEETH GATE — a planted leak on each instrument must classify LEAK.
# ===========================================================================
note "--- TEETH GATE (planted leaks must trip) ---"

run_probe "${PROBE_TIMEOUT}" lifecycle/leak_conn.exs "${TEETH_CONN}" retain mem
[ "${RC}" -eq 5 ] || abort "conn-instrument teeth did NOT classify LEAK (rc=${RC}): ${RESULT_LINE}"
note "teeth LEAK(conn retain):  TRIPPED -> ${RESULT_LINE}"

run_probe "${PROBE_TIMEOUT}" lifecycle/leak_children.exs "${TEETH_CHILD}" stmt_retain
[ "${RC}" -eq 5 ] || abort "statement-instrument teeth did NOT classify LEAK (rc=${RC}): ${RESULT_LINE}"
note "teeth LEAK(stmt retain):  TRIPPED -> ${RESULT_LINE}"

run_probe "${PROBE_TIMEOUT}" lifecycle/leak_children.exs "${TEETH_CHILD}" blob_retain
[ "${RC}" -eq 5 ] || abort "blob-instrument teeth did NOT classify LEAK (rc=${RC}): ${RESULT_LINE}"
note "teeth LEAK(blob retain):  TRIPPED -> ${RESULT_LINE}"
note ""

# ===========================================================================
# REAL PROBES
# ===========================================================================
note "--- LEAK LOOPS (expect PASS: bounded steady-state RSS) ---"

run_probe "${PROBE_TIMEOUT}" lifecycle/leak_conn.exs "${N_CONN}" churn mem
note "leak-conn (in-memory)  x${N_CONN}:  $(class_of "${RC}")  (rc=${RC})"
note "    ${RESULT_LINE}"
[ "${RC}" -eq 0 ] || FAILED=1

run_probe "${PROBE_TIMEOUT}" lifecycle/leak_conn.exs "${N_CONN_FILE}" churn file "${WORK}/conn.db"
note "leak-conn (file WAL)   x${N_CONN_FILE}:  $(class_of "${RC}")  (rc=${RC})"
note "    ${RESULT_LINE}"
[ "${RC}" -eq 0 ] || FAILED=1
rm -f "${WORK}/conn.db" "${WORK}/conn.db-wal" "${WORK}/conn.db-shm"

for kind in stmt stream blob session; do
  run_probe "${PROBE_TIMEOUT}" lifecycle/leak_children.exs "${N_CHILD}" "${kind}"
  note "leak-children ${kind}  x${N_CHILD}:  $(class_of "${RC}")  (rc=${RC})"
  note "    ${RESULT_LINE}"
  [ "${RC}" -eq 0 ] || FAILED=1
done
note ""

note "--- HOSTILE DROP-ORDER MATRIX (expect PASS: no crash) ---"
run_probe "${PROBE_TIMEOUT}" lifecycle/hostile_drops.exs "${HOSTILE_K}"
note "hostile-drops:  $(class_of "${RC}")  (rc=${RC})"
note "    ${RESULT_LINE}"
[ -n "${LEAKQUANT_LINE}" ] && note "    ${LEAKQUANT_LINE}"
[ "${RC}" -eq 0 ] || FAILED=1
note ""

note "=== VERDICT ==="
if [ "${FAILED}" -eq 0 ]; then
  note "ALL PROBES PASS — no leak (monotonic growth) / crash / UAF / double-free observed."
  note "(Strength bounded by the teeth above, all of which TRIPPED LEAK on planted leaks.)"
  exit 0
else
  note "ONE OR MORE PROBES FAILED — inspect ${SUMMARY} (work dir removed on exit)."
  exit 1
fi
