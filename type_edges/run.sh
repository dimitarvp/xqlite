#!/usr/bin/env bash
#
# Type/value-edge probe harness for xqlite (review axis A9). Drives real values
# end-to-end through the ACTUAL public API (open :memory: -> bind/insert -> read
# back via every read path: query, stream, prepared step, incremental blob_read)
# and PINS the observed behavior, asserting BYTE-EXACT equality against the known
# input so a silent truncation / wrap / corruption FAILS the probe. The failure
# class this axis hunts is silent WRONG RESULTS on values — among the worst for a
# DB library.
#
# Edges covered:
#   * Elixir bignums beyond i64 (clean error vs silent wrap/truncate)
#   * NaN / +Inf / -Inf floats (bind-path reachability + every read path)
#   * interior-NUL round-trips through query/stream/step/blob_read (TEXT + BLOB)
#   * invalid-UTF-8 TEXT read-back (clean error vs lossy vs swallowed)
#   * SQLITE_MAX_LENGTH / MAX_VARIABLE_NUMBER boundaries (structured error)
#   * offset-preserving DateTime TEXT vs ORDER BY (lexical sort != chronological)
#   * encode-only type-extension read-back (Instant)
#
# TEETH FIRST (hard gate; the run ABORTS if the oracle self-test fails):
#   the byte-exact equality oracle must FLAG planted corruption (truncate-at-NUL,
#   int wrap, int-vs-float drift, NUL-text truncation) and must NOT false-positive
#   a correct value. A harness whose oracle is blind to a wrong value proves
#   nothing about the round-trips it green-lights.
#
# SAFETY: the only OS process is a `mix run` child under `timeout`. In-memory DBs
# only; no files, no SIGKILL, no pkill/name-match. The MAX_LENGTH probe uses
# `zeroblob(1000000001)`, which SQLite rejects with SQLITE_TOOBIG BEFORE
# allocating (sqlite3_result_zeroblob64 checks the limit first), so the box is
# never asked for ~1GB.
#
# Isolated from CI: lives under type_edges/ (not test/), not in elixirc_paths,
# not matched by the formatter inputs glob ({config,lib,test}/**) — never touched
# by `mix test.seq` or `mix verify`. Invoke explicitly:
#
#     bash type_edges/run.sh
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "${SCRIPT_DIR}")
cd "${REPO_DIR}"

PROBE_TIMEOUT=${PROBE_TIMEOUT:-180}

export MIX_ENV=dev
env XQLITE_BUILD=true mix compile >/dev/null 2>&1 || { echo "ABORT: mix compile failed"; exit 2; }
MIX_RUN=(env XQLITE_BUILD=true mix run --no-compile --no-start)

echo "=== xqlite A9 type/value-edge harness ==="
echo ""

# ---------------------------------------------------------------------------
# TEETH GATE — the equality oracle must trip on planted corruption first.
# ---------------------------------------------------------------------------
echo "--- TEETH GATE (oracle self-test) ---"
timeout -k 5 30 "${MIX_RUN[@]}" type_edges/probe.exs selftest
ST=$?
if [ "${ST}" -ne 0 ]; then
  echo "ABORT: oracle self-test failed (rc=${ST}) — the equality oracle has no teeth."
  exit 2
fi
echo ""

# ---------------------------------------------------------------------------
# REAL PROBE
# ---------------------------------------------------------------------------
echo "--- PROBE ---"
timeout -k 5 "${PROBE_TIMEOUT}" "${MIX_RUN[@]}" type_edges/probe.exs
RC=$?

echo ""
echo "=== VERDICT ==="
case "${RC}" in
  0)
    echo "PASS — every byte-exact round-trip held (teeth proven). Any S1/decision-debt"
    echo "findings are printed above as FINDING lines and recorded in REVIEW_LEDGER.md"
    echo "Run 7; they are NOT silent value corruption (round-trips are exact)."
    exit 0
    ;;
  1)
    echo "FAIL — a byte-exact round-trip broke (S0 silent value corruption). Inspect the"
    echo "S0 pin(s) above: a value came back truncated/wrapped/changed from what went in."
    exit 1
    ;;
  124)
    echo "HANG — the probe was killed by the OS timeout (rc=124)."
    exit 1
    ;;
  134|139)
    echo "CRASH — the probe aborted the VM (rc=${RC}); a read path faulted the BEAM."
    exit 1
    ;;
  *)
    echo "ERROR — probe exited rc=${RC}."
    exit 1
    ;;
esac
