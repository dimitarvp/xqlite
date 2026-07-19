#!/usr/bin/env bash
#
# Test-architecture probe harness for xqlite (review axis A14). Re-derives
# gotcha #1: parallel tests contend on / corrupt the per-OS-process SQLite C
# globals (allocator, VFS list, page cache, PRNG, memstatus, temp-file
# namespace), which is why `mix test.seq` runs each test file in its OWN OS
# process. The bundled SQLite is statically linked => ONE OS process = ONE set of
# C globals shared by every BEAM process in that VM.
#
# The probe (test_arch/probe.exs) hammers realistic isolated-DB NIF workloads
# across many concurrent BEAM processes in ONE OS process and compares to the
# same work done serially:
#   SUBSTRATE — prints THREADSAFE/MUTEX (THREADSAFE=1 => global mutexes on even
#               for NOMUTEX conns => contention, not hard corruption, expected).
#   TEETH     — a byte-smashed file DB MUST fail integrity_check and a clean one
#               MUST pass; else the corruption oracle is dead and every clean
#               parallel run is meaningless — run.sh ABORTS (rc 2).
#   PARALLEL  — K workers concurrently, each an isolated-DB churn loop.
#   SERIAL    — the same total work one-at-a-time (control; MUST stay clean).
#   CHURN     — open/close churn (the rusqlite#1860 angle), parallel vs serial.
# A crash / corruption / parallel-only "out of memory" (SQLITE_NOMEM=code 7) that
# the serial control does not produce is the positive signal for the mechanism.
#
# SAFETY: the only OS process is one `mix run` child under `timeout`. File DBs
# live in a private mktemp dir removed on exit. No SIGKILL, no pkill/name-match.
# Bounded transient RAM (K x ~1 MB page cache + ~200 KB rows).
#
# Isolated from CI: lives under test_arch/ (not test/), not in elixirc_paths, not
# matched by the formatter inputs glob ({config,lib,test}/**) — never touched by
# `mix test.seq` or `mix verify`. Invoke explicitly:
#
#     bash test_arch/run.sh
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "${SCRIPT_DIR}")
cd "${REPO_DIR}"

PROBE_TIMEOUT=${PROBE_TIMEOUT:-420}
export TA_WORKERS=${TA_WORKERS:-36}
export TA_ITERS=${TA_ITERS:-60}
export TA_CHURN=${TA_CHURN:-150}

TA_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/xqlite_a14.XXXXXX")
export TA_TMPDIR
cleanup() { rm -rf "${TA_TMPDIR}"; }
trap cleanup EXIT

export MIX_ENV=dev
env XQLITE_BUILD=true mix compile >/dev/null 2>&1 || { echo "ABORT: mix compile failed"; exit 2; }
MIX_RUN=(env XQLITE_BUILD=true mix run --no-compile --no-start)

echo "=== xqlite A14 test-architecture harness (workers=${TA_WORKERS} iters=${TA_ITERS} churn=${TA_CHURN}) ==="

timeout -k 5 "${PROBE_TIMEOUT}" "${MIX_RUN[@]}" test_arch/probe.exs
RC=$?

echo ""
echo "=== VERDICT ==="
case "${RC}" in
  0)
    echo "PASS — no VM crash and no DB corruption across the parallel workload on"
    echo "isolated DBs (teeth proved the corruption oracle live). Any parallel-only"
    echo "NOMEM/BUSY tally above is the CONTENTION signal behind gotcha #1; test.seq"
    echo "(one OS process per test file) removes the shared-globals surface entirely."
    exit 0
    ;;
  1)
    echo "SIGNAL — corruption or an anomaly appeared in a leg. If it is parallel-only,"
    echo "the mechanism reproduced; inspect the tallies above."
    exit 1
    ;;
  2)
    echo "TEETH_DEAD — the corruption oracle did not trip; no conclusion. (Also"
    echo "raised on mix compile failure.)"
    exit 2
    ;;
  124)
    echo "HANG — the probe was killed by the OS timeout (rc=124). A parallel-leg"
    echo "hang is itself the rusqlite#1860 deadlock signal — inspect which leg."
    exit 1
    ;;
  134|139)
    echo "CRASH — the workload ABORTED the VM (rc=${RC}). A parallel-only crash is"
    echo "the strongest form of the mechanism (global-state corruption -> UB)."
    exit 1
    ;;
  *)
    echo "ERROR — probe exited rc=${RC}."
    exit 1
    ;;
esac
