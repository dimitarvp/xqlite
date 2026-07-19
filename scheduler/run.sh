#!/usr/bin/env bash
#
# Scheduler-discipline probe harness for xqlite (review axis A4). Every NIF must
# run <1ms on a normal scheduler OR be flagged Dirty (CPU vs IO chosen right). A
# normal-scheduler NIF that runs long hogs a normal scheduler and degrades the
# whole VM's latency; the mechanical gate is `erlang:system_monitor` with
# `{long_schedule, T}`, which fires for a long NORMAL-scheduler run and never for
# a Dirty one (established this session — a 1.5s Dirty query delivers 0 events).
#
# The probe (scheduler/probe.exs):
#   TEETH — a fix-independent pure-BEAM control (term_to_binary/[:compressed])
#           MUST deliver >0 long_schedule events. If it delivers 0 the monitor is
#           dead and every "0 hits" is meaningless — run.sh ABORTS (rc 2). This
#           is what makes the silence below trustworthy.
#   S1    — INTRINSIC discipline (PASS/FAIL): each NIF family, worst-case input,
#           own connection, dedicated single-call process (PID-attributed). Every
#           DB-file-touching / unbounded family MUST be Dirty => 0 hits. A hit is
#           a normal-scheduler hog (the RED). Pre-fix, blob_read/blob_write/
#           session_changeset/session_patchset/session_delete/changeset_invert/
#           changeset_concat/blob_open/blob_reopen tripped this; the flag flips to
#           DirtyIo (REVIEW_LEDGER Run 10) silence them.
#   S2    — MUTEX-CONTENTION (informational): a holder pins the conn Mutex with a
#           slow Dirty query on a SHARED handle; trivial normal readers on the
#           same handle are timed. Shows the documented single-owner-handle
#           tradeoff (a shared handle serializes, and a normal reader then blocks
#           on a normal scheduler). Reported, not gated (BACKLOG F-A4-1).
#   LAT   — micro-latency of the trivial normal readers (proves <1ms intrinsic).
#
# SAFETY: the only OS process is one `mix run` child under `timeout`. In-memory
# DBs except one backup target in a private mktemp dir removed on exit. No
# SIGKILL, no pkill/name-match. Large but bounded transient RAM (a 64 MB blob +
# read buffer, a ~16 MB changeset).
#
# Isolated from CI: lives under scheduler/ (not test/), not in elixirc_paths, not
# matched by the formatter inputs glob ({config,lib,test}/**) — never touched by
# `mix test.seq` or `mix verify`. Invoke explicitly:
#
#     bash scheduler/run.sh
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "${SCRIPT_DIR}")
cd "${REPO_DIR}"

PROBE_TIMEOUT=${PROBE_TIMEOUT:-300}
export THRESHOLD_MS=${THRESHOLD_MS:-25}

SCHED_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/xqlite_a4.XXXXXX")
export SCHED_TMPDIR
cleanup() { rm -rf "${SCHED_TMPDIR}"; }
trap cleanup EXIT

export MIX_ENV=dev
env XQLITE_BUILD=true mix compile >/dev/null 2>&1 || { echo "ABORT: mix compile failed"; exit 2; }
MIX_RUN=(env XQLITE_BUILD=true mix run --no-compile --no-start)

echo "=== xqlite A4 scheduler-discipline harness (threshold=${THRESHOLD_MS}ms) ==="
echo ""

timeout -k 5 "${PROBE_TIMEOUT}" "${MIX_RUN[@]}" scheduler/probe.exs
RC=$?

echo ""
echo "=== VERDICT ==="
case "${RC}" in
  0)
    echo "PASS — the monitor fired on the control (armed + delivering) AND every"
    echo "DB-file-touching / unbounded NIF family ran on a Dirty scheduler (0"
    echo "long_schedule hits). The S2 Mutex-contention numbers above are the"
    echo "documented shared-handle tradeoff (BACKLOG F-A4-1), not a gate failure."
    exit 0
    ;;
  1)
    echo "FAIL — a must-be-dirty NIF family hogged a NORMAL scheduler (a"
    echo "long_schedule hit). Inspect the FAIL families above: the fix is a"
    echo "schedule = \"DirtyIo\" flag on that NIF in native/xqlitenif/src/nif.rs."
    exit 1
    ;;
  2)
    echo "TEETH_DEAD — the fix-independent control delivered 0 long_schedule"
    echo "events, so the monitor is not observing. Every '0 hits' is meaningless;"
    echo "no conclusion can be drawn. (Also raised on mix compile failure.)"
    exit 2
    ;;
  124)
    echo "HANG — the probe was killed by the OS timeout (rc=124)."
    exit 1
    ;;
  134|139)
    echo "CRASH — the probe aborted the VM (rc=${RC})."
    exit 1
    ;;
  *)
    echo "ERROR — probe exited rc=${RC}."
    exit 1
    ;;
esac
