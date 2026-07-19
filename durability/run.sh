#!/usr/bin/env bash
#
# Durability / corruption crash-harness orchestrator for xqlite (review axis
# A8 — the "crown jewel"). Proves that a hard crash (SIGKILL) of a writer
# process mid-write never corrupts the database nor loses a committed write,
# across BOTH journal modes (WAL and rollback/DELETE).
#
# For each iteration it: spawns a WRITER child (durability/writer.exs) that
# commits rows in per-row transactions through the xqlite public API; waits
# until the writer is actually committing; SIGKILLs it BY ITS EXACT PID at a
# random moment in the active-write window; reaps it; then reopens the DB in a
# FRESH process (durability/verify.exs, under an OS-level `timeout`) and checks
# durability + integrity invariants. Every reopen is classified PASS /
# CORRUPTION / LOSTWRITE / HANG.
#
# Each committed row also carries a guaranteed interior-NUL BLOB payload and an
# interior-NUL bound TEXT value, both deterministic from the id; the verifier
# recomputes and compares them BYTE-EXACT. This makes the harness an A8xA9
# cross-axis leg: a pathological typed value written mid-write must survive the
# SIGKILL byte-exact on reopen (or be cleanly absent), never a torn half-value.
#
# TEETH: before any real run, three deterministic negative controls must trip —
# a byte-smash must be classified CORRUPTION, a deleted committed row must be
# classified LOSTWRITE, and a tampered typed value (structurally valid, so
# integrity_check stays "ok") must be classified CORRUPTION by the byte-exact
# recompute — or the whole run aborts. A harness that stays green on a known-bad
# input is worthless.
#
# SAFETY: only ever SIGKILLs the exact PID of a child it spawned this loop,
# cross-checked against the writer's self-reported OS pid. Never pkill/killall,
# never a name/pattern match. All DBs live in a private mktemp dir under /tmp.
#
# Isolated from CI: lives under durability/ (not test/), never touched by
# `mix test.seq` or `mix verify`. Invoke explicitly:
#
#     bash durability/run.sh
#     ITER_SAFE=300 ITER_UNSAFE=150 bash durability/run.sh   # heavier
#     ITER_SAFE=3 ITER_UNSAFE=3 bash durability/run.sh        # smoke
#
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "${SCRIPT_DIR}")
cd "${REPO_DIR}"

# ---- config (env-overridable) ----------------------------------------------
ITER_SAFE=${ITER_SAFE:-200}
ITER_UNSAFE=${ITER_UNSAFE:-100}
SAFE_ROW_BYTES=${SAFE_ROW_BYTES:-256}
UNSAFE_ROW_BYTES=${UNSAFE_ROW_BYTES:-262144}
DELAY_MIN_MS=${DELAY_MIN_MS:-10}
DELAY_MAX_MS=${DELAY_MAX_MS:-400}
UNSAFE_DELAY_MIN_MS=${UNSAFE_DELAY_MIN_MS:-5}
UNSAFE_DELAY_MAX_MS=${UNSAFE_DELAY_MAX_MS:-150}
VERIFY_TIMEOUT=${VERIFY_TIMEOUT:-20}
READY_TIMEOUT_S=${READY_TIMEOUT_S:-30}

export MIX_ENV=dev
MIX_RUN=(env XQLITE_BUILD=true mix run --no-compile --no-start)

WORK=$(mktemp -d /tmp/xqlite_durability.XXXXXX)
RESULTS="${WORK}/results.tsv"
SUMMARY="${WORK}/summary.txt"
FAILDIR="${WORK}/failures"
mkdir -p "${FAILDIR}"
printf 'tag\ti\tmode\tsync\tdelay_ms\talive_at_kill\twatermark\tdb_max\tdb_count\tclass\tvcode\n' >"${RESULTS}"

# globals set by functions below
ALIVE_AT_KILL="" ; LAST_DELAY_MS="" ; DB="" ; ACK=""
VCLASS="" ; VCODE="" ; VWM="" ; VDBMAX="" ; VDBCOUNT="" ; VERIFY_OUT=""
TEETH_CX="" ; TEETH_LW="" ; TEETH_VT=""

echo "durability crash-harness"
echo "  work dir: ${WORK}"
echo "  safe iterations/mode: ${ITER_SAFE}   unsafe (neg-control): ${ITER_UNSAFE}"

abort() {
  echo "FATAL: $*" >&2
  echo "artifacts kept in ${WORK}" >&2
  exit 1
}

# spawn_kill_reap TAG I MODE SYNC ROWBYTES DELAY_MIN DELAY_MAX
# Spawns a writer, waits until it is committing, then SIGKILLs it by exact PID
# at a random moment. Sets DB, ACK, ALIVE_AT_KILL, LAST_DELAY_MS.
spawn_kill_reap() {
  local tag=$1 i=$2 mode=$3 sync=$4 rowbytes=$5 dmin=$6 dmax=$7
  DB="${WORK}/${tag}_${i}.db"
  ACK="${WORK}/${tag}_${i}.ack"
  local wout="${WORK}/${tag}_${i}.writer.out"
  rm -f "${DB}" "${DB}-wal" "${DB}-shm" "${DB}-journal" "${ACK}" "${DB}.pid"

  "${MIX_RUN[@]}" durability/writer.exs "${DB}" "${mode}" "${sync}" "${ACK}" "${rowbytes}" \
    >"${wout}" 2>&1 &
  local wpid=$!

  # readiness: >=1 complete ack line means the writer committed row 1
  local waited=0 nl ready=0
  local max_polls=$(( READY_TIMEOUT_S * 10 ))
  while [ "${waited}" -lt "${max_polls}" ]; do
    if ! kill -0 "${wpid}" 2>/dev/null; then break; fi
    if [ -f "${ACK}" ]; then
      nl=$(tr -cd '\n' <"${ACK}" 2>/dev/null | wc -c)
      if [ "${nl:-0}" -ge 1 ]; then ready=1; break; fi
    fi
    sleep 0.1
    waited=$(( waited + 1 ))
  done

  if [ "${ready}" -ne 1 ]; then
    if kill -0 "${wpid}" 2>/dev/null; then kill -9 "${wpid}" 2>/dev/null; fi
    wait "${wpid}" 2>/dev/null
    ALIVE_AT_KILL="never_ready"
    LAST_DELAY_MS="NA"
    return 0
  fi

  # randomized active-write delay, then kill
  local delay_ms=$(( dmin + RANDOM % (dmax - dmin + 1) ))
  LAST_DELAY_MS=${delay_ms}
  sleep "$(awk -v m="${delay_ms}" 'BEGIN{printf "%.3f", m/1000}')"

  # SAFETY cross-check: the writer self-reports its OS pid; it must match the
  # exact child pid we captured. If not, kill only our child and abort.
  local reported
  reported=$(cat "${DB}.pid" 2>/dev/null || true)
  if [ -n "${reported}" ] && [ "${reported}" != "${wpid}" ]; then
    kill -9 "${wpid}" 2>/dev/null
    wait "${wpid}" 2>/dev/null
    abort "writer pid mismatch: reported=${reported} spawned=${wpid}"
  fi

  if kill -0 "${wpid}" 2>/dev/null; then
    ALIVE_AT_KILL="yes"
    kill -9 "${wpid}" 2>/dev/null
  else
    ALIVE_AT_KILL="no"
  fi
  wait "${wpid}" 2>/dev/null
  return 0
}

# do_verify DB MODE SYNC ACK ROWBYTES -> sets VCLASS VCODE VWM VDBMAX VDBCOUNT VERIFY_OUT
do_verify() {
  local db=$1 mode=$2 sync=$3 ack=$4 rowbytes=$5 out code rline
  out=$(timeout -k 5 "${VERIFY_TIMEOUT}" "${MIX_RUN[@]}" \
    durability/verify.exs "${db}" "${mode}" "${sync}" "${ack}" "${rowbytes}" 2>&1)
  code=$?
  VCODE=${code}
  case "${code}" in
    0) VCLASS="PASS" ;;
    3) VCLASS="CORRUPTION" ;;
    4) VCLASS="LOSTWRITE" ;;
    124 | 137) VCLASS="HANG" ;;
    *) VCLASS="ERROR" ;;
  esac
  VERIFY_OUT="${out}"
  rline=$(printf '%s\n' "${out}" | grep '^RESULT ' | head -1 || true)
  VWM=$(printf '%s' "${rline}" | grep -oE 'watermark=[0-9]+' | cut -d= -f2 || true); VWM=${VWM:-NA}
  VDBMAX=$(printf '%s' "${rline}" | grep -oE 'db_max=-?[0-9]+' | cut -d= -f2 || true); VDBMAX=${VDBMAX:-NA}
  VDBCOUNT=$(printf '%s' "${rline}" | grep -oE 'db_count=-?[0-9]+' | cut -d= -f2 || true); VDBCOUNT=${VDBCOUNT:-NA}
}

# run_iteration TAG I MODE SYNC ROWBYTES DELAY_MIN DELAY_MAX
run_iteration() {
  local tag=$1 i=$2 mode=$3 sync=$4 rowbytes=$5 dmin=$6 dmax=$7
  spawn_kill_reap "${tag}" "${i}" "${mode}" "${sync}" "${rowbytes}" "${dmin}" "${dmax}"
  local delay_ms=${LAST_DELAY_MS:-NA}

  if [ "${ALIVE_AT_KILL}" = "never_ready" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${tag}" "${i}" "${mode}" "${sync}" "NA" "never_ready" "0" "NA" "NA" "SKIP_BOOT" "NA" >>"${RESULTS}"
    rm -f "${DB}" "${DB}-wal" "${DB}-shm" "${DB}-journal" "${ACK}" "${DB}.pid" "${WORK}/${tag}_${i}.writer.out"
    return 0
  fi

  do_verify "${DB}" "${mode}" "${sync}" "${ACK}" "${rowbytes}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${tag}" "${i}" "${mode}" "${sync}" "${delay_ms}" "${ALIVE_AT_KILL}" \
    "${VWM}" "${VDBMAX}" "${VDBCOUNT}" "${VCLASS}" "${VCODE}" >>"${RESULTS}"

  if [ "${VCLASS}" != "PASS" ]; then
    echo "  [${tag} #${i}] ${VCLASS} (vcode=${VCODE}) wm=${VWM} db_max=${VDBMAX}"
    printf '%s\n' "${VERIFY_OUT}" | grep '^RESULT ' | head -1 || true
    # preserve genuine safe-mode findings for repro (unsafe corruption is expected)
    if [ "${tag}" = "wal" ] || [ "${tag}" = "delete" ]; then
      local fd="${FAILDIR}/${tag}_${i}"
      mkdir -p "${fd}"
      cp -a "${DB}" "${DB}-wal" "${DB}-shm" "${DB}-journal" "${ACK}" \
        "${WORK}/${tag}_${i}.writer.out" "${fd}/" 2>/dev/null || true
      printf 'tag=%s i=%s mode=%s sync=%s delay_ms=%s class=%s\n%s\n' \
        "${tag}" "${i}" "${mode}" "${sync}" "${delay_ms}" "${VCLASS}" "${VERIFY_OUT}" >"${fd}/report.txt"
    fi
  fi
  rm -f "${DB}" "${DB}-wal" "${DB}-shm" "${DB}-journal" "${ACK}" "${DB}.pid" "${WORK}/${tag}_${i}.writer.out"
  return 0
}

teeth_corrupt() {
  echo "== teeth self-test 1/2: CORRUPTION detection =="
  spawn_kill_reap teeth_cx 0 delete normal "${SAFE_ROW_BYTES}" 300 500
  [ "${ALIVE_AT_KILL}" = "never_ready" ] && abort "teeth_corrupt: writer never ready"
  do_verify "${DB}" delete normal "${ACK}" "${SAFE_ROW_BYTES}"
  [ "${VCLASS}" = "PASS" ] || abort "teeth_corrupt baseline expected PASS, got ${VCLASS}: ${VERIFY_OUT}"
  local fsize offset len
  fsize=$(stat -c%s "${DB}")
  offset=$(( fsize > 12288 ? 4096 : fsize / 4 ))
  len=$(( fsize / 2 )); [ "${len}" -gt 16384 ] && len=16384; [ "${len}" -lt 1 ] && len=1
  tr '\0' '\377' </dev/zero | head -c "${len}" | dd of="${DB}" bs=1 seek="${offset}" conv=notrunc status=none
  do_verify "${DB}" delete normal "${ACK}" "${SAFE_ROW_BYTES}"
  [ "${VCLASS}" = "CORRUPTION" ] || abort "teeth_corrupt: expected CORRUPTION after ${len}B smash, got ${VCLASS}: ${VERIFY_OUT}"
  echo "  OK: ${len}B mid-file smash at offset ${offset} -> CORRUPTION (vcode ${VCODE})"
  TEETH_CX="PASS (${len}B smash -> CORRUPTION)"
  rm -f "${DB}" "${DB}-wal" "${DB}-shm" "${DB}-journal" "${ACK}" "${DB}.pid"
}

teeth_lostwrite() {
  echo "== teeth self-test 2/2: LOSTWRITE detection =="
  spawn_kill_reap teeth_lw 0 delete normal "${SAFE_ROW_BYTES}" 300 500
  [ "${ALIVE_AT_KILL}" = "never_ready" ] && abort "teeth_lostwrite: writer never ready"
  do_verify "${DB}" delete normal "${ACK}" "${SAFE_ROW_BYTES}"
  [ "${VCLASS}" = "PASS" ] || abort "teeth_lostwrite baseline expected PASS, got ${VCLASS}: ${VERIFY_OUT}"
  local w=${VWM}
  { [ "${w}" != "NA" ] && [ "${w}" -ge 2 ]; } 2>/dev/null || abort "teeth_lostwrite: watermark too small (${w})"
  "${MIX_RUN[@]}" durability/inject_delete.exs "${DB}" delete normal "${w}" \
    || abort "teeth_lostwrite: inject_delete failed"
  do_verify "${DB}" delete normal "${ACK}" "${SAFE_ROW_BYTES}"
  [ "${VCLASS}" = "LOSTWRITE" ] || abort "teeth_lostwrite: expected LOSTWRITE after deleting acked id ${w}, got ${VCLASS}: ${VERIFY_OUT}"
  echo "  OK: deleting acked id ${w} -> LOSTWRITE (vcode ${VCODE})"
  TEETH_LW="PASS (deleted acked id ${w} -> LOSTWRITE)"
  rm -f "${DB}" "${DB}-wal" "${DB}-shm" "${DB}-journal" "${ACK}" "${DB}.pid"
}

# Typed-value teeth (A8xA9 cross-axis leg): corrupt one row's interior-NUL TEXT
# value WITHOUT touching the file structure (integrity_check stays "ok"), and
# prove the verifier's byte-exact typed-value recompute still classifies it
# CORRUPTION. A torn/wrong typed value that integrity_check cannot see must not
# slip past.
teeth_value_tamper() {
  echo "== teeth self-test 3/3: typed-value CORRUPTION detection =="
  spawn_kill_reap teeth_vt 0 delete normal "${SAFE_ROW_BYTES}" 300 500
  [ "${ALIVE_AT_KILL}" = "never_ready" ] && abort "teeth_value_tamper: writer never ready"
  do_verify "${DB}" delete normal "${ACK}" "${SAFE_ROW_BYTES}"
  [ "${VCLASS}" = "PASS" ] || abort "teeth_value_tamper baseline expected PASS, got ${VCLASS}: ${VERIFY_OUT}"
  local w=${VWM}
  { [ "${w}" != "NA" ] && [ "${w}" -ge 2 ]; } 2>/dev/null || abort "teeth_value_tamper: watermark too small (${w})"
  "${MIX_RUN[@]}" durability/inject_tamper.exs "${DB}" delete normal "${w}" \
    || abort "teeth_value_tamper: inject_tamper failed"
  do_verify "${DB}" delete normal "${ACK}" "${SAFE_ROW_BYTES}"
  [ "${VCLASS}" = "CORRUPTION" ] || abort "teeth_value_tamper: expected CORRUPTION after tampering typed value of id ${w}, got ${VCLASS}: ${VERIFY_OUT}"
  echo "  OK: tampering interior-NUL TEXT value of id ${w} -> CORRUPTION (vcode ${VCODE})"
  TEETH_VT="PASS (tampered typed value id ${w} -> CORRUPTION)"
  rm -f "${DB}" "${DB}-wal" "${DB}-shm" "${DB}-journal" "${ACK}" "${DB}.pid"
}

# ---- run --------------------------------------------------------------------
echo "compiling once (XQLITE_BUILD=true mix compile)..."
XQLITE_BUILD=true mix compile >/dev/null 2>&1 || abort "mix compile failed"

teeth_corrupt
teeth_lostwrite
teeth_value_tamper

echo "== negative control: journal_mode=off synchronous=off, ${UNSAFE_ROW_BYTES}B rows x ${ITER_UNSAFE} =="
for i in $(seq 1 "${ITER_UNSAFE}"); do
  run_iteration unsafe "${i}" off off "${UNSAFE_ROW_BYTES}" "${UNSAFE_DELAY_MIN_MS}" "${UNSAFE_DELAY_MAX_MS}"
  (( i % 25 == 0 )) && echo "  unsafe: ${i}/${ITER_UNSAFE}"
done

echo "== WAL: journal_mode=wal synchronous=normal x ${ITER_SAFE} =="
for i in $(seq 1 "${ITER_SAFE}"); do
  run_iteration wal "${i}" wal normal "${SAFE_ROW_BYTES}" "${DELAY_MIN_MS}" "${DELAY_MAX_MS}"
  (( i % 25 == 0 )) && echo "  wal: ${i}/${ITER_SAFE}"
done

echo "== DELETE: journal_mode=delete synchronous=normal x ${ITER_SAFE} =="
for i in $(seq 1 "${ITER_SAFE}"); do
  run_iteration delete "${i}" delete normal "${SAFE_ROW_BYTES}" "${DELAY_MIN_MS}" "${DELAY_MAX_MS}"
  (( i % 25 == 0 )) && echo "  delete: ${i}/${ITER_SAFE}"
done

# ---- summary ----------------------------------------------------------------
{
  echo "# xqlite durability crash-harness summary"
  echo "work_dir=${WORK}"
  echo "teeth_corruption_control=${TEETH_CX}"
  echo "teeth_lostwrite_control=${TEETH_LW}"
  echo "teeth_value_tamper_control=${TEETH_VT}"
  echo
  awk -F'\t' '
    NR==1 { next }
    {
      tag=$1; alive=$6; wm=$7; class=$10;
      total[tag]++; seen[tag]=1; cls[tag"|"class]++;
      if (class!="SKIP_BOOT" && alive=="yes" && wm!="NA") {
        n=wm+0; mid[tag]++; wsum[tag]+=n;
        if (!(tag in wmin) || n<wmin[tag]) wmin[tag]=n;
        if (!(tag in wmax) || n>wmax[tag]) wmax[tag]=n;
      }
    }
    END {
      for (t in seen) {
        printf "tag=%-8s total=%d  PASS=%d CORRUPTION=%d LOSTWRITE=%d HANG=%d ERROR=%d SKIP_BOOT=%d\n",
          t, total[t], cls[t"|PASS"]+0, cls[t"|CORRUPTION"]+0, cls[t"|LOSTWRITE"]+0,
          cls[t"|HANG"]+0, cls[t"|ERROR"]+0, cls[t"|SKIP_BOOT"]+0;
        if (t in mid)
          printf "  landed-mid-write=%d  committed-at-kill(min..max, mean)=%d..%d, %.0f\n",
            mid[t], wmin[t], wmax[t], wsum[t]/mid[t];
      }
    }
  ' "${RESULTS}"
} | tee "${SUMMARY}"

echo
echo "results tsv: ${RESULTS}"
echo "summary:     ${SUMMARY}"
echo "failures:    ${FAILDIR} (empty == no safe-mode findings)"
