#!/usr/bin/env bash
#
# A11 feature-island probe harness. Verifies F-A11-4 RESOLVED (maintainer
# decision 2026-07-20): a busy retry policy's `:max_elapsed_ms` is a PER-EVENT
# budget — the elapsed clock resets at the start of each fresh busy event, so a
# connection alive longer than the ceiling still retries a new contention
# through the lock release. Before the fix the ceiling was anchored at the busy
# slot's INSTALL time, so an aged connection gave up with zero retries.
#
# The three S0-S2 findings from this axis (F-A11-1 backup hang on
# pages_per_step<1, F-A11-2 changeset :replace misuse->abort, F-A11-3 interior
# NUL in SQL truncation) were FIXED and are covered by permanent regression
# tests in test/ (backup_progress_test.exs, session_test.exs,
# error_input_test.exs); the busy per-event budget likewise has a permanent
# regression test (busy_handler_test.exs). This dir carries the teeth-backed
# adversarial artifact for the per-event budget.
#
# TEETH (hard gate): the probe SELF-ABORTS (rc 2) unless the mechanism
# discriminates the budget in BOTH directions — a young connection and an aged
# connection with a huge ceiling both SUCCEED by retrying through the release,
# AND a starved connection (ceiling smaller than the release) GIVES UP fast.
# Only against that control does the aged-conn success mean anything.
#
# SAFETY: the only OS processes are `mix run` children under `timeout`. File DBs
# live in a private mktemp dir removed on exit. No SIGKILL, no pkill/name-match.
#
# Isolated from CI: lives under feature_islands/ (not test/), not in
# elixirc_paths, not matched by the formatter inputs glob ({config,lib,test}/**)
# — never touched by `mix test.seq` or `mix verify`. Invoke explicitly:
#
#     bash feature_islands/run.sh
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "${SCRIPT_DIR}")
cd "${REPO_DIR}"

PROBE_TIMEOUT=${PROBE_TIMEOUT:-120}

FI_DIR=$(mktemp -d "${TMPDIR:-/tmp}/xqlite_a11.XXXXXX")
export FI_DIR
cleanup() { rm -rf "${FI_DIR}"; }
trap cleanup EXIT

export MIX_ENV=dev
env XQLITE_BUILD=true mix compile >/dev/null 2>&1 || { echo "ABORT: mix compile failed"; exit 2; }

echo "=== xqlite A11 feature-island probe: busy-policy max_elapsed_ms anchoring ==="
echo ""
timeout -k 5 "${PROBE_TIMEOUT}" env XQLITE_BUILD=true mix run --no-compile --no-start \
  feature_islands/busy_elapsed.exs
RC=$?

echo ""
echo "=== VERDICT ==="
case "${RC}" in
  0)
    echo "PER-EVENT BUDGET CONFIRMED — teeth held (retry works AND the budget"
    echo "still bites) and the aged connection retried through the release, as did"
    echo "a second event 800 ms later: max_elapsed_ms resets per busy event"
    echo "(F-A11-4 resolved). Regression-tested in test/nif/busy_handler_test.exs."
    exit 0
    ;;
  1)
    echo "REGRESSION — teeth held but an aged / second busy event GAVE UP;"
    echo "max_elapsed_ms is anchored at install again (F-A11-4 has regressed)."
    echo "Inspect busy_handler.rs busy_callback (the count==0 clock reset)."
    exit 1
    ;;
  2)
    echo "TEETH FAILED — the mechanism did not discriminate the budget (retry did"
    echo "not work, or the budget was not enforced); the probe proves nothing."
    echo "Investigate before trust."
    exit 1
    ;;
  124)
    echo "HANG — probe killed by the OS timeout (rc=124)."
    exit 1
    ;;
  134|139)
    echo "CRASH — probe aborted the VM (rc=${RC})."
    exit 1
    ;;
  *)
    echo "ERROR — probe exited rc=${RC}."
    exit 1
    ;;
esac
