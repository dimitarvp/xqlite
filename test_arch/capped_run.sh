#!/usr/bin/env bash
#
# CONSTRAINED-RAM cap-ladder orchestrator for xqlite review axis A14 — the
# F-A14-1 deciding probe (see REVIEW_LEDGER.md Run 12 A14 + Run 14, BACKLOG.md
# F-A14-1). Run 12's test_arch/run.sh could not reproduce the spurious
# "out of memory" (SQLITE_NOMEM) behind gotcha #1 under UNCONSTRAINED RAM. This
# script re-runs the parallel and serial legs (test_arch/capped_probe.exs) under
# an external MEMORY CAP mimicking a constrained CI runner, at a ladder of rungs,
# to see whether the parallel leg fails (SQLITE_NOMEM or OOM-kill) while the
# serial leg survives at the SAME cap — the differential predicted by gotcha #1.
#
# Two mechanisms (MECH env, default cgroup):
#   cgroup  — systemd-run --user --scope -p MemoryMax=<N> -p MemorySwapMax=0.
#             Caps RSS; when the workload exceeds it the cgroup OOM-killer
#             SIGKILLs the process (rc 137). This is a CGROUP KILL, distinct from
#             the SQLite-NOMEM signature; it tests peak-FOOTPRINT amplification.
#   prlimit — prlimit --as=<bytes>. Caps address space; when SQLite's malloc
#             returns NULL the NIF reports SQLITE_NOMEM (probe exit 3) — the
#             LITERAL gotcha symptom — instead of a kill.
#
# TOOTH (hard gate): before any ladder rung is trusted, the cap must be proven to
# BIND the real BEAM+xqlite process: alloc_tooth (hold TOOTH_MB) MUST succeed
# uncapped and MUST die/NOMEM under a tight cap. If it does not, the cap is not
# binding and no verdict is admissible — this script ABORTS (rc 2).
#
# Isolated from CI exactly like the rest of test_arch/: not under test/, not in
# elixirc_paths, not matched by the formatter inputs glob — never touched by
# `mix test.seq` or `mix verify`. Invoke explicitly:
#
#     bash test_arch/capped_run.sh                 # cgroup ladder (default)
#     MECH=prlimit bash test_arch/capped_run.sh    # address-space ladder
#
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "${SCRIPT_DIR}")
cd "${REPO_DIR}"

MECH=${MECH:-cgroup}
export TA_K=${TA_K:-24}
export TA_HOLD_MB=${TA_HOLD_MB:-30}
export TOOTH_MB=${TOOTH_MB:-600}
LEG_TIMEOUT=${LEG_TIMEOUT:-120}

# Cap ladder in MB, and the tooth cap. cgroup rungs are RSS caps (baseline
# ~100 MB); prlimit rungs are absolute address-space caps (BEAM reserves ~3.75 GB
# virtual just to boot, so prlimit rungs live just above that floor). The tooth
# cap must be tight enough to bind TOOTH_MB yet — for prlimit — still let BEAM
# boot, so it binds via the SQLite malloc-NULL path (SQLITE_NOMEM) rather than a
# boot-time super-carrier failure.
if [[ "${MECH}" == "prlimit" ]]; then
  CAPS_MB=${CAPS_MB:-"4500 4200 4000 3900 3850 3800"}
  TOOTH_CAP_MB=${TOOTH_CAP_MB:-4000}
else
  CAPS_MB=${CAPS_MB:-"1024 768 512 384 256 192 144"}
  TOOTH_CAP_MB=${TOOTH_CAP_MB:-256}
fi

export MIX_ENV=dev
env XQLITE_BUILD=true mix compile >/dev/null 2>&1 || { echo "ABORT: mix compile failed"; exit 2; }

# the probe with a fully explicit environment (never rely on inherited env
# surviving systemd-run/prlimit). TA_MODE is read from the caller's env.
probe_cmd() {
  echo env XQLITE_BUILD=true MIX_ENV=dev \
    "TA_MODE=${TA_MODE}" "TA_K=${TA_K}" "TA_HOLD_MB=${TA_HOLD_MB}" "TOOTH_MB=${TOOTH_MB}" \
    mix run --no-compile --no-start test_arch/capped_probe.exs
}

# run the probe under the chosen cap at CAP_MB; return the wait status.
run_capped() {
  local cap_mb="$1"
  if [[ "${MECH}" == "prlimit" ]]; then
    local as_bytes=$((cap_mb * 1024 * 1024))
    timeout -k 5 "${LEG_TIMEOUT}" prlimit --as="${as_bytes}" -- \
      $(probe_cmd) >/tmp/xqlite_a14_leg.out 2>&1
  else
    systemd-run --user --scope --quiet \
      -p MemoryMax="${cap_mb}M" -p MemorySwapMax=0 -p MemoryAccounting=yes \
      -p CollectMode=inactive-or-failed -- \
      timeout -k 5 "${LEG_TIMEOUT}" $(probe_cmd) \
      >/tmp/xqlite_a14_leg.out 2>&1
  fi
  return $?
}

run_uncapped() {
  timeout -k 5 "${LEG_TIMEOUT}" $(probe_cmd) >/tmp/xqlite_a14_leg.out 2>&1
  return $?
}

# map a wait status to a classification label (exit-code / atom, not vibes)
classify() {
  case "$1" in
    0)   echo "PASS" ;;
    3)   echo "NOMEM" ;;       # SQLITE_NOMEM observed in a completed leg
    1)   echo "ANOMALY" ;;     # corruption / unexpected error
    2)   echo "SETUP" ;;
    124) echo "HANG" ;;        # OS timeout
    134|135|136) echo "ABORT" ;;  # BEAM/C abort (e.g. eheap_alloc) — NOT SQLite-NOMEM
    137) echo "OOMKILL" ;;     # SIGKILL from the cgroup OOM-killer
    139) echo "SEGV" ;;
    *)   echo "rc$1" ;;
  esac
}

echo "=== xqlite A14 constrained-RAM cap ladder (MECH=${MECH} K=${TA_K} hold=${TA_HOLD_MB}MB) ==="
echo "    ladder(MB): ${CAPS_MB}"
echo ""

# ---- TOOTH: prove the cap binds the real BEAM+xqlite process ----
# (2>/dev/null only silences bash's own "Killed" reap report for a SIGKILLed
# child — the leg's real output is captured in /tmp/xqlite_a14_leg.out and the
# classified exit code is what the verdict uses.)
echo "== TOOTH: cap-binding control (alloc_tooth holds ${TOOTH_MB} MB) =="
TA_MODE=alloc_tooth run_uncapped 2>/dev/null
T_UNCAP=$?
echo "  uncapped  -> rc=${T_UNCAP} ($(classify ${T_UNCAP}))   [expect PASS: the alloc fits]"
TA_MODE=alloc_tooth run_capped "${TOOTH_CAP_MB}" 2>/dev/null
T_CAP=$?
echo "  capped ${TOOTH_CAP_MB}MB -> rc=${T_CAP} ($(classify ${T_CAP}))   [expect OOMKILL/NOMEM/ABORT: cap binds]"
sed 's/^/    tooth| /' /tmp/xqlite_a14_leg.out | tail -6

if [[ "${T_UNCAP}" -ne 0 ]]; then
  echo "TEETH_DEAD: alloc_tooth failed UNCAPPED (rc=${T_UNCAP}); box cannot hold ${TOOTH_MB}MB. ABORT."
  exit 2
fi
case "${T_CAP}" in
  0) echo "TEETH_DEAD: cap did NOT bind (alloc_tooth held ${TOOTH_MB}MB under a ${TOOTH_CAP_MB}MB cap). ABORT."; exit 2 ;;
  *) echo "  TOOTH OK — the cap binds the real process (uncapped holds, capped dies)." ;;
esac
echo ""

# ---- LADDER: parallel vs serial at each rung ----
echo "== CAP LADDER (parallel vs serial at each rung) =="
printf "  %-8s | %-10s | %-10s\n" "cap(MB)" "parallel" "serial"
printf "  %-8s-+-%-10s-+-%-10s\n" "--------" "----------" "----------"

DIFFERENTIAL_CAP=""
DIFFERENTIAL_KIND=""
for cap in ${CAPS_MB}; do
  TA_MODE=parallel run_capped "${cap}" 2>/dev/null; pc=$?; pl=$(classify ${pc})
  TA_MODE=serial   run_capped "${cap}" 2>/dev/null; sc=$?; sl=$(classify ${sc})
  printf "  %-8s | %-10s | %-10s\n" "${cap}" "${pl}(${pc})" "${sl}(${sc})"
  # differential = parallel fails while serial passes at the SAME cap
  if [[ "${sc}" -eq 0 && "${pc}" -ne 0 ]]; then
    if [[ -z "${DIFFERENTIAL_CAP}" ]]; then
      DIFFERENTIAL_CAP="${cap}"
      DIFFERENTIAL_KIND="${pl}"
    fi
  fi
done

echo ""
echo "=== VERDICT (${MECH}) ==="
if [[ -n "${DIFFERENTIAL_CAP}" ]]; then
  echo "DIFFERENTIAL at ${DIFFERENTIAL_CAP} MB: parallel=${DIFFERENTIAL_KIND}, serial=PASS."
  case "${DIFFERENTIAL_KIND}" in
    NOMEM)
      echo "Parallel leg hit SQLITE_NOMEM while serial survived at the same cap —"
      echo "the LITERAL gotcha #1 symptom reproduced under constrained RAM." ;;
    OOMKILL|ABORT|SEGV|HANG)
      echo "Parallel leg died (${DIFFERENTIAL_KIND}) while serial survived at the same cap —"
      echo "peak-FOOTPRINT amplification confirmed (K coexisting connections vs 1)."
      echo "NOTE: an OOMKILL is a cgroup SIGKILL, NOT the SQLite-NOMEM atom; it"
      echo "confirms the footprint mechanism, not the literal NOMEM signature." ;;
  esac
  exit 0
else
  echo "NO DIFFERENTIAL across the ladder: no cap made parallel fail while serial"
  echo "passed. Record the honest bound from the table above."
  exit 0
fi
