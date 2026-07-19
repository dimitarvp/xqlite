#!/usr/bin/env bash
#
# Binary-crossing memory probe harness for xqlite (review axis A12, Run 11).
# What happens to bytes crossing the NIF boundary, both directions.
#
# The static inbound/outbound copy-vs-refcount map lives in REVIEW_LEDGER.md
# Run 11 (source-verified against rustler 0.38.0 Binary/OwnedBinary/resource-
# binary semantics). This harness measures the ONE thing a read cannot settle:
# the large-result MEMORY PROFILE and whether crossed binaries are reclaimed.
#
# The probe (binary_crossing/probe.exs):
#   TEETH — a deliberate-retention control MUST make :erlang.memory(:binary)
#           grow while referenced and settle on release. If it does not grow,
#           the binary allocator counter is blind and every number below is
#           meaningless -> run.sh ABORTS (rc 2). This is the A12 analogue of the
#           lifecycle-harness leak teeth.
#   S1    — large result (100k rows x [256B TEXT + 256B BLOB]) QUERY vs STREAM
#           full materialization: held binary bytes, held total, peak RSS, per
#           row cost. RETENTION-LEAK gate: after the holder process dies, the
#           binary counter MUST return to baseline (crossed binaries reclaimed)
#           -> a residual above the ceiling is an S1 leak (rc 1).
#   S2    — streaming consume-and-discard: peak binary MUST stay bounded far
#           below full materialization (the streaming memory advantage).
#   S3    — many small blobs (100k x 16B): query path (encode_val, size-adaptive
#           -> a <=64B blob is copied into a process-heap OwnedBinary) vs stream
#           path (sqlite_row_to_elixir_terms -> OwnedBinary). Both land on the
#           process heap for small blobs, so the paths should track closely.
#           A >=10x total-memory difference for the same data is an S2 cliff
#           (rc 1); anything less is documented characterization.
#   S4    — refc classification micro-probe (>64B -> binary allocator,
#           <=64B -> process heap).
#
# SAFETY: the only OS process is one `mix run` child under `timeout`. In-memory
# DBs only (source data generated inside SQLite via a recursive CTE; no big
# inbound crossing). No files, no SIGKILL, no pkill/name-match. Transient RAM is
# bounded (~50-100 MB of result binaries at peak).
#
# Isolated from CI: lives under binary_crossing/ (not test/), not in
# elixirc_paths (["lib"]), not matched by the formatter inputs glob
# ({config,lib,test}/**) — never touched by `mix test.seq` or `mix verify`.
# Invoke explicitly:
#
#     bash binary_crossing/run.sh
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "${SCRIPT_DIR}")
cd "${REPO_DIR}"

PROBE_TIMEOUT=${PROBE_TIMEOUT:-300}

export MIX_ENV=dev
env XQLITE_BUILD=true mix compile >/dev/null 2>&1 || { echo "ABORT: mix compile failed"; exit 2; }
MIX_RUN=(env XQLITE_BUILD=true mix run --no-compile --no-start)

echo "=== xqlite A12 binary-crossing harness ==="
echo ""

# Phase 1 — correctness edges (inbound/outbound audit runtime teeth). A failed
# edge (escaped view, sub-binary corruption, iodata silently mangled) is a hard
# stop before any memory characterization is trusted.
echo "--- phase 1: correctness edges ---"
timeout -k 5 120 "${MIX_RUN[@]}" binary_crossing/edges.exs
EDGES_RC=$?
if [ "${EDGES_RC}" -ne 0 ]; then
  echo ""
  echo "=== VERDICT ==="
  echo "FAIL — a correctness edge failed (rc=${EDGES_RC}); see above. Memory phase skipped."
  exit 1
fi

# Phase 2 — large-result memory profile (the measurement).
echo ""
echo "--- phase 2: memory profile ---"
timeout -k 5 "${PROBE_TIMEOUT}" "${MIX_RUN[@]}" binary_crossing/probe.exs
RC=$?

echo ""
echo "=== VERDICT ==="
case "${RC}" in
  0)
    echo "PASS — the retention teeth fired (binary counter armed), the large"
    echo "result leak gate held (crossed binaries reclaimed on holder death),"
    echo "streaming kept a bounded peak, and the query-vs-stream small-blob"
    echo "difference is below the >=10x cliff. Characterization only, no S0-S2."
    exit 0
    ;;
  1)
    echo "FAIL — a memory finding: either a RETENTION LEAK (crossed binaries"
    echo "outlived their holder, S1) or a >=10x query-vs-stream memory CLIFF"
    echo "(S2). Inspect the S1/S3 sections above."
    exit 1
    ;;
  2)
    echo "TEETH_DEAD — the retention control did not grow :erlang.memory(:binary),"
    echo "so the instrument is blind. No conclusion can be drawn. (Also raised on"
    echo "mix compile failure.)"
    exit 2
    ;;
  3)
    echo "PROBE_ERROR — the probe raised (see stacktrace above)."
    exit 1
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
