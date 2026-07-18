#!/usr/bin/env bash
#
# Structured-error-contract probe harness for xqlite (review axis A10). Drives
# REAL error conditions through the ACTUAL public API and asserts the contract on
# every returned `{:error, reason}`:
#
#   (a) STRUCTURED classification atom — never a bare binary (text-only error),
#       never the bare `:error` atom.
#   (b) EXTENDED result code present + correct — the SPECIFIC constraint-kind
#       atom (`:constraint_unique` = extended 2067, not the generic
#       `:constraint_violation`) and the SQLITE_TOOBIG `{:sqlite_failure,18,18,_}`
#       code pair both prove the extended code survived the boundary.
#   (c) Exception.message ALWAYS a binary (`Xqlite.StreamError`).
#   (d) WITH-MATCHABLE shape — each reason is destructured by a real `with`.
#
# Conditions: unique / not-null / check / primary-key / foreign-key / datatype
# constraint violations, syntax error, bind type-conversion error, SQLITE_TOOBIG,
# connection-closed, statement-finalized, execute-returned-results (misuse),
# read-only write, SQLITE_BUSY via real two-connection write contention, the
# StreamError raising surface, and changes()-stickiness (RETURNING) edge.
#
# TEETH FIRST (hard gate; the run ABORTS if the oracle self-test fails): the
# contract oracle MUST reject a text-only error, a bare `:error`, a wrong
# classification, an unmatchable shape, and a non-binary message — and must NOT
# false-positive a correct structured reason. An oracle blind to those proves
# nothing about the reasons it green-lights.
#
# SAFETY: the only OS processes are `mix run` children under `timeout`. The BUSY
# and read-only conditions need real files; they live in a private mktemp dir
# removed on exit. No SIGKILL, no pkill/name-match, no ~1GB allocation (the
# MAX_LENGTH boundary uses zeroblob, rejected with SQLITE_TOOBIG before alloc).
#
# Isolated from CI: lives under error_contract/ (not test/), not in
# elixirc_paths, not matched by the formatter inputs glob ({config,lib,test}/**)
# — never touched by `mix test.seq` or `mix verify`. Invoke explicitly:
#
#     bash error_contract/run.sh
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "${SCRIPT_DIR}")
cd "${REPO_DIR}"

PROBE_TIMEOUT=${PROBE_TIMEOUT:-180}

ERR_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/xqlite_a10.XXXXXX")
export ERR_TMPDIR
cleanup() { rm -rf "${ERR_TMPDIR}"; }
trap cleanup EXIT

export MIX_ENV=dev
env XQLITE_BUILD=true mix compile >/dev/null 2>&1 || { echo "ABORT: mix compile failed"; exit 2; }
MIX_RUN=(env XQLITE_BUILD=true mix run --no-compile --no-start)

echo "=== xqlite A10 structured-error-contract harness ==="
echo ""

# ---------------------------------------------------------------------------
# TEETH GATE — the contract oracle must reject bad shapes first.
# ---------------------------------------------------------------------------
echo "--- TEETH GATE (oracle self-test) ---"
timeout -k 5 30 "${MIX_RUN[@]}" error_contract/probe.exs selftest
ST=$?
if [ "${ST}" -ne 0 ]; then
  echo "ABORT: oracle self-test failed (rc=${ST}) — the contract oracle has no teeth."
  exit 2
fi
echo ""

# ---------------------------------------------------------------------------
# REAL PROBE
# ---------------------------------------------------------------------------
echo "--- PROBE ---"
timeout -k 5 "${PROBE_TIMEOUT}" "${MIX_RUN[@]}" error_contract/probe.exs
RC=$?

echo ""
echo "=== VERDICT ==="
case "${RC}" in
  0)
    echo "PASS — every structured-error contract assertion held (teeth proven). Any"
    echo "S3 findings are printed above as FINDING lines and recorded in"
    echo "REVIEW_LEDGER.md Run 8 + BACKLOG.md; they are NOT contract violations."
    exit 0
    ;;
  1)
    echo "FAIL — a contract assertion broke (text-only error / bare :error /"
    echo "non-binary message / unmatchable shape / wrong extended code). Inspect the"
    echo "S1/S2 pin(s) above."
    exit 1
    ;;
  124)
    echo "HANG — the probe was killed by the OS timeout (rc=124)."
    exit 1
    ;;
  134|139)
    echo "CRASH — the probe aborted the VM (rc=${RC}); an error path faulted the BEAM."
    exit 1
    ;;
  *)
    echo "ERROR — probe exited rc=${RC}."
    exit 1
    ;;
esac
