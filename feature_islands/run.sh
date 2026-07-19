#!/usr/bin/env bash
#
# A11 feature-island probe harness. Demonstrates F-A11-4 (S3): a busy retry
# policy's `:max_elapsed_ms` ceiling is anchored at the busy slot's INSTALL
# time, not at the start of each busy event, so on a connection older than the
# ceiling the policy gives up with zero retries.
#
# The three S0-S2 findings from this axis (F-A11-1 backup hang on
# pages_per_step<1, F-A11-2 changeset :replace misuse->abort, F-A11-3 interior
# NUL in SQL truncation) were FIXED and are covered by permanent regression
# tests in test/ (backup_progress_test.exs, session_test.exs,
# error_input_test.exs). This dir carries only the S3 busy-elapsed footgun,
# which is documented-and-correct behavior (so not a test/ regression) but worth
# a reproducible, teeth-backed artifact.
#
# TEETH (hard gate): the probe SELF-ABORTS (rc 2) unless the retry mechanism is
# proven to work — a young connection AND an aged connection with a huge ceiling
# both succeed by retrying through the lock release. Only against that control
# does the aged+small-ceiling instant give-up mean anything.
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
    echo "REPRODUCED — teeth held (retry mechanism works) and the aged connection"
    echo "gave up instantly with zero retries: max_elapsed_ms is install-anchored"
    echo "(F-A11-4, S3). Documented in guides/gotchas.md + BACKLOG.md."
    exit 0
    ;;
  3)
    echo "FINDING GONE — teeth held but the aged connection no longer gives up"
    echo "instantly; max_elapsed_ms may now be per-event. Update BACKLOG.md."
    exit 0
    ;;
  2)
    echo "TEETH FAILED — the retry mechanism did not work even on a young/huge-"
    echo "ceiling connection; the probe proves nothing. Investigate before trust."
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
