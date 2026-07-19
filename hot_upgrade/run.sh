#!/usr/bin/env bash
#
# Hot-upgrade-posture probe harness for xqlite (review axis A13). rustler 0.38's
# init codegen hardcodes the ErlNifEntry upgrade/reload/unload callbacks to None
# (rustler_codegen-0.38.0/src/init.rs:92-94), so the NIF library has a NULL
# upgrade callback. Per the erl_nif contract a NIF library "fails to load if
# upgrade ... is NULL" once the module has old code with a loaded NIF. This
# harness RUNS the hot-code paths an operator would hit and captures EXACTLY what
# the VM does, and — the safety half — what happens to LIVE resources across each
# attempt. The deliverable is the documented policy (guides/gotchas.md "Hot code
# upgrades"); this harness is its evidence.
#
# The probe (hot_upgrade/probe.exs):
#   TEETH — a separate run (HOTUP_MODE=teeth) loads the NIF, proves it works,
#           then System.halt(134). run.sh MUST classify it CRASH. If it does not,
#           the crash oracle is dead and every "no crash" in the main probe is
#           meaningless — run.sh ABORTS (rc 2). This is what makes the main
#           probe's crash-free result trustworthy.
#   PROBE — sections A-D with hard assertions:
#           A  open conn + statement + stream + blob + session, exercise each.
#           B  :code.load_file(XqliteNIF) MUST be refused {:error,:on_load_failure}
#              (a silent success = two library instances = the dangerous case);
#              every live resource MUST still work afterward; soft_purge captured.
#           C  a direct :erlang.load_nif from a foreign module MUST be refused
#              ({:bad_lib,_}) — no back door around the failing on_load path.
#           D  forced :code.delete + :code.purge with a live resource set, then
#              drop + GC that set: destructors run out of a to-be-unloaded
#              library; MUST NOT abort the VM.
#
# SAFETY: the only OS processes are `mix run` children under `timeout`. In-memory
# DBs only; no files, no SIGKILL, no pkill/name-match. The teeth run halts its
# OWN child with 134 by design. Kills only PIDs this script spawns.
#
# Isolated from CI: lives under hot_upgrade/ (not test/), not in elixirc_paths,
# not matched by the formatter inputs glob ({config,lib,test}/**) — never touched
# by `mix test.seq` or `mix verify`. Invoke explicitly:
#
#     bash hot_upgrade/run.sh
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "${SCRIPT_DIR}")
cd "${REPO_DIR}"

PROBE_TIMEOUT=${PROBE_TIMEOUT:-180}
export MIX_ENV=dev
env XQLITE_BUILD=true mix compile >/dev/null 2>&1 || { echo "ABORT: mix compile failed"; exit 2; }
MIX_RUN=(env XQLITE_BUILD=true mix run --no-compile --no-start)

echo "=== xqlite A13 hot-upgrade-posture harness ==="

echo ""
echo "--- TEETH: crash-oracle liveness (expect CRASH rc=134) ---"
HOTUP_MODE=teeth timeout -k 5 "${PROBE_TIMEOUT}" "${MIX_RUN[@]}" hot_upgrade/probe.exs
TEETH_RC=$?
echo "teeth rc=${TEETH_RC}"
if [ "${TEETH_RC}" != "134" ] && [ "${TEETH_RC}" != "139" ]; then
  echo ""
  echo "TEETH_DEAD — the crash-oracle control did NOT abort the VM (rc=${TEETH_RC});"
  echo "the harness cannot detect a crash-on-purge, so the main probe's no-crash"
  echo "result would be meaningless. ABORTING."
  exit 2
fi
echo "teeth OK — the crash oracle detects a VM abort."

echo ""
echo "--- PROBE: reload refusal + live-resource survival + purge stress ---"
HOTUP_MODE=probe timeout -k 5 "${PROBE_TIMEOUT}" "${MIX_RUN[@]}" hot_upgrade/probe.exs
RC=$?

echo ""
echo "=== VERDICT ==="
case "${RC}" in
  0)
    echo "PASS — every NIF-module reload path is REFUSED cleanly"
    echo "({:error, :on_load_failure} / {:upgrade, \"Upgrade not supported ...\"}),"
    echo "no back-door load exists, live conn/statement/stream/blob/session"
    echo "resources survive every attempt, and a forced delete+purge+GC of live"
    echo "resources does not abort the VM. Hot upgrade is UNSUPPORTED and FAILS"
    echo "SAFE — the documented policy (guides/gotchas.md) is upheld."
    exit 0
    ;;
  1)
    echo "FAIL — an assertion tripped: either a reload SILENTLY SUCCEEDED (two"
    echo "library instances), a live resource broke after a reload attempt, or a"
    echo "back-door load_nif was accepted. Inspect the ASSERT FAILED line above."
    exit 1
    ;;
  124)
    echo "HANG — the probe was killed by the OS timeout (rc=124)."
    exit 1
    ;;
  134|139)
    echo "CRASH — a hot-code operation ABORTED the VM (rc=${RC}). This is the S1"
    echo "crash-on-purge the axis warns about — a VM crash reachable by a"
    echo "documented OTP operation. Investigate immediately."
    exit 1
    ;;
  *)
    echo "ERROR — probe exited rc=${RC}."
    exit 1
    ;;
esac
