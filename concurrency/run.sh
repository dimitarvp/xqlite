#!/usr/bin/env bash
#
# Concurrency / interleaving probe harness for xqlite (review axis A7). Attacks
# the concurrency surface with four probes and CLASSIFIES each:
#
#   Probe 1  hammer      — N BEAM processes hammering ONE shared connection
#                          handle (writes/reads/stmt-ops + a finalize-vs-step
#                          race on a shared statement). Oracle: integrity_check
#                          + acked-vs-actual row-set diff + per-row checksum.
#   Probe 2  owner-death — a process opens a conn, BEGIN IMMEDIATE, is SIGKILLed
#                          mid-transaction; a fresh connection must recover and
#                          write (not wedged), with the uncommitted row rolled
#                          back.
#   Probe 3  busy        — two connections writing one file DB under a retry
#                          policy + observer; asserts retries fire, observers
#                          receive {:xqlite_busy,…}, no lost update, no deadlock.
#   Probe 4  churn       — concurrent open/close churn on one file DB (attempt
#                          to reproduce rusqlite#1860's VFS hang at our bundled
#                          SQLite); HANG vs clean, bounded by an OS timeout.
#
# TEETH FIRST (hard gate; the run ABORTS if any fails to trip):
#   * CORRUPTION oracle: a byte-smashed DB and a payload-tampered DB must both
#     classify CORRUPTION (proves integrity_check + checksum catch damage).
#   * LOST-WRITE oracle: hammer with a deliberately-dropped acked row must
#     classify WRONGRESULT.
#   * LOST-UPDATE oracle: busy with a deliberately-dropped row must classify
#     WRONGRESULT.
#   * HANG classifier: a never-terminating control must hit the OS timeout.
# A harness that stays green on known-bad input proves nothing.
#
# SAFETY: the only OS processes are children spawned here, each under `timeout`.
# Probe 2's SIGKILL targets the EXACT captured PID, cross-checked against the
# holder's self-reported System.pid(); on any mismatch it kills only that child
# and aborts. Never pkill/killall, never a name/pattern match. All DBs live in a
# private mktemp dir under /tmp, removed on exit.
#
# Isolated from CI: lives under concurrency/ (not test/), never touched by
# `mix test.seq` or `mix verify`. Invoke explicitly:
#
#     bash concurrency/run.sh
#     SMOKE=1 bash concurrency/run.sh          # tiny/fast
#     HAMMER_OPS=1000 bash concurrency/run.sh  # heavier
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "${SCRIPT_DIR}")
cd "${REPO_DIR}"

# ---- config (env-overridable) ----------------------------------------------
if [ "${SMOKE:-0}" = "1" ]; then
  HAMMER_WRITERS=${HAMMER_WRITERS:-4}; HAMMER_READERS=${HAMMER_READERS:-3}
  HAMMER_STMT=${HAMMER_STMT:-2}; HAMMER_OPS=${HAMMER_OPS:-60}
  BUSY_ROWS=${BUSY_ROWS:-30}; CHURN_WORKERS=${CHURN_WORKERS:-4}; CHURN_ITERS=${CHURN_ITERS:-30}
else
  HAMMER_WRITERS=${HAMMER_WRITERS:-8}; HAMMER_READERS=${HAMMER_READERS:-6}
  HAMMER_STMT=${HAMMER_STMT:-4}; HAMMER_OPS=${HAMMER_OPS:-400}
  BUSY_ROWS=${BUSY_ROWS:-150}; CHURN_WORKERS=${CHURN_WORKERS:-8}; CHURN_ITERS=${CHURN_ITERS:-150}
fi
HAMMER_ROWBYTES=${HAMMER_ROWBYTES:-128}
PROBE_TIMEOUT=${PROBE_TIMEOUT:-180}
VERIFY_TIMEOUT=${VERIFY_TIMEOUT:-60}
READY_TIMEOUT_S=${READY_TIMEOUT_S:-30}
HANG_TIMEOUT=${HANG_TIMEOUT:-4}

export MIX_ENV=dev
MIX_RUN=(env XQLITE_BUILD=true mix run --no-compile --no-start)

WORK=$(mktemp -d /tmp/xqlite_concurrency.XXXXXX)
SUMMARY="${WORK}/summary.txt"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

FAILED=0
note() { printf '%s\n' "$*" | tee -a "${SUMMARY}"; }
abort() { note "ABORT: $*"; exit 2; }

# run_probe LABEL TIMEOUT SCRIPT ARGS... -> sets RC, RESULT_LINE
run_probe() {
  local label=$1 t=$2; shift 2
  local out
  out=$(timeout -k 5 "${t}" "${MIX_RUN[@]}" "$@" 2>&1)
  RC=$?
  RESULT_LINE=$(printf '%s\n' "${out}" | grep -E '^RESULT ' | tail -1)
  [ -z "${RESULT_LINE}" ] && RESULT_LINE=$(printf '%s\n' "${out}" | tail -3 | tr '\n' ' ')
  return 0
}

# class_of RC -> echoes a class name from the exit code
class_of() {
  case $1 in
    0) echo PASS ;;
    3) echo CORRUPTION ;;
    4) echo WRONGRESULT ;;
    6) echo NO_CONTENTION ;;
    124) echo HANG ;;
    134|139) echo CRASH ;;
    137) echo CRASH_OR_OOM ;;
    *) echo "ERROR(rc=$1)" ;;
  esac
}

note "=== xqlite A7 concurrency harness ==="
note "work dir: ${WORK}"
note "config: hammer(w=${HAMMER_WRITERS} r=${HAMMER_READERS} s=${HAMMER_STMT} ops=${HAMMER_OPS} rb=${HAMMER_ROWBYTES}) busy(rows=${BUSY_ROWS}) churn(w=${CHURN_WORKERS} iters=${CHURN_ITERS})"
note ""

# ===========================================================================
# TEETH GATE — every oracle must trip on known-bad input before any real probe.
# ===========================================================================
note "--- TEETH GATE ---"

# Build one clean hammer DB to damage (row_bytes=512 so it spans many pages).
TEETH_DB="${WORK}/teeth.db"
run_probe "teeth-seed" "${PROBE_TIMEOUT}" concurrency/hammer.exs "${TEETH_DB}" 4 2 2 40 512
[ "${RC}" -eq 0 ] || abort "teeth seed hammer did not PASS (rc=${RC}): ${RESULT_LINE}"

# Checkpoint + drop WAL so damage to the main file is what gets read.
cat > "${WORK}/ckpt.exs" <<'EOF'
[db] = System.argv()
{:ok, c} = Xqlite.open(db, journal_mode: :wal, synchronous: :normal)
Xqlite.query(c, "PRAGMA wal_checkpoint(TRUNCATE)", [])
Xqlite.close(c)
EOF
"${MIX_RUN[@]}" "${WORK}/ckpt.exs" "${TEETH_DB}" >/dev/null 2>&1
rm -f "${TEETH_DB}-wal" "${TEETH_DB}-shm"

# (a) byte-smash → CORRUPTION. Corrupt page 2+ (leave the page-1 header intact
# so the DB still opens and integrity_check itself is what fails).
SMASH_DB="${WORK}/smash.db"; cp "${TEETH_DB}" "${SMASH_DB}"
dd if=/dev/urandom bs=1 count=16384 seek=4096 conv=notrunc of="${SMASH_DB}" \
  2>/dev/null || abort "dd byte-smash failed"
run_probe "teeth-smash" "${VERIFY_TIMEOUT}" concurrency/check_db.exs "${SMASH_DB}" 512
if [ "${RC}" -ne 3 ]; then abort "byte-smash NOT classified CORRUPTION (rc=${RC}): ${RESULT_LINE}"; fi
note "teeth CORRUPTION(byte-smash): TRIPPED -> ${RESULT_LINE}"

# (b) payload-tamper → CORRUPTION (checksum leg; integrity_check still ok)
TAMPER_DB="${WORK}/tamper.db"; cp "${TEETH_DB}" "${TAMPER_DB}"
cat > "${WORK}/tamper.exs" <<'EOF'
[db] = System.argv()
{:ok, c} = Xqlite.open(db, journal_mode: :wal, synchronous: :normal)
{:ok, _} = Xqlite.execute(c, "UPDATE t SET payload = ?1 WHERE id = (SELECT MIN(id) FROM t)", [<<0,1,2,3>>])
Xqlite.close(c)
EOF
"${MIX_RUN[@]}" "${WORK}/tamper.exs" "${TAMPER_DB}" >/dev/null 2>&1
run_probe "teeth-tamper" "${VERIFY_TIMEOUT}" concurrency/check_db.exs "${TAMPER_DB}" 512
if [ "${RC}" -ne 3 ]; then abort "payload-tamper NOT classified CORRUPTION (rc=${RC}): ${RESULT_LINE}"; fi
note "teeth CORRUPTION(payload-tamper): TRIPPED -> ${RESULT_LINE}"

# (c) lost-write oracle: hammer with a dropped acked row → WRONGRESULT
export XQLITE_PROBE_TAMPER=drop
run_probe "teeth-lostwrite" "${PROBE_TIMEOUT}" concurrency/hammer.exs "${WORK}/lw.db" 4 2 2 40 64
unset XQLITE_PROBE_TAMPER
if [ "${RC}" -ne 4 ]; then abort "lost-write tamper NOT classified WRONGRESULT (rc=${RC}): ${RESULT_LINE}"; fi
note "teeth LOSTWRITE(hammer drop): TRIPPED -> ${RESULT_LINE}"

# (d) lost-update oracle: busy with a dropped row → WRONGRESULT
export XQLITE_PROBE_TAMPER=drop
run_probe "teeth-lostupdate" "${PROBE_TIMEOUT}" concurrency/busy.exs "${WORK}/lu.db" 20
unset XQLITE_PROBE_TAMPER
if [ "${RC}" -ne 4 ]; then abort "lost-update tamper NOT classified WRONGRESULT (rc=${RC}): ${RESULT_LINE}"; fi
note "teeth LOSTUPDATE(busy drop): TRIPPED -> ${RESULT_LINE}"

# (e) HANG classifier: a never-terminating control must hit the OS timeout
run_probe "teeth-hang" "${HANG_TIMEOUT}" concurrency/hang_control.exs
if [ "${RC}" -ne 124 ]; then abort "hang control NOT classified HANG (rc=${RC}): ${RESULT_LINE}"; fi
note "teeth HANG(sleep-forever): TRIPPED (timeout fired, rc=124)"
note ""

# ===========================================================================
# REAL PROBES
# ===========================================================================
note "--- PROBES ---"

# Probe 1 — hammer
run_probe "hammer" "${PROBE_TIMEOUT}" concurrency/hammer.exs \
  "${WORK}/hammer.db" "${HAMMER_WRITERS}" "${HAMMER_READERS}" "${HAMMER_STMT}" "${HAMMER_OPS}" "${HAMMER_ROWBYTES}"
P1_CLASS=$(class_of "${RC}")
note "Probe 1 hammer:      ${P1_CLASS}  (rc=${RC})  ${RESULT_LINE}"
[ "${RC}" -eq 0 ] || FAILED=1

# Probe 3 — busy contention
run_probe "busy" "${PROBE_TIMEOUT}" concurrency/busy.exs "${WORK}/busy.db" "${BUSY_ROWS}"
P3_CLASS=$(class_of "${RC}")
note "Probe 3 busy:        ${P3_CLASS}  (rc=${RC})  ${RESULT_LINE}"
[ "${RC}" -eq 0 ] || FAILED=1

# Probe 4 — open/close churn
run_probe "churn" "${PROBE_TIMEOUT}" concurrency/churn.exs \
  "${WORK}/churn.db" "${CHURN_WORKERS}" "${CHURN_ITERS}"
P4_CLASS=$(class_of "${RC}")
note "Probe 4 churn:       ${P4_CLASS}  (rc=${RC})  ${RESULT_LINE}"
[ "${RC}" -eq 0 ] || FAILED=1

# Probe 2 — owner death mid-transaction (control + kill + test)
OD_DB="${WORK}/ownerdeath.db"
OD_READY="${WORK}/ownerdeath.ready"
rm -f "${OD_DB}" "${OD_DB}-wal" "${OD_DB}-shm" "${OD_DB}.holderpid" "${OD_READY}"

"${MIX_RUN[@]}" concurrency/owner_hold.exs "${OD_DB}" "${OD_READY}" \
  >"${WORK}/holder.out" 2>&1 &
HPID=$!

# wait for readiness (holder is holding the open write transaction)
waited=0; ready=0; max_polls=$(( READY_TIMEOUT_S * 10 ))
while [ "${waited}" -lt "${max_polls}" ]; do
  if ! kill -0 "${HPID}" 2>/dev/null; then break; fi
  [ -f "${OD_READY}" ] && { ready=1; break; }
  sleep 0.1; waited=$(( waited + 1 ))
done
if [ "${ready}" -ne 1 ]; then
  kill -0 "${HPID}" 2>/dev/null && kill -9 "${HPID}" 2>/dev/null
  wait "${HPID}" 2>/dev/null
  note "Probe 2 owner-death: ERROR (holder never became ready)"
  FAILED=1
else
  # CONTROL: holder ALIVE, still holding the write lock → verifier should see BUSY
  run_probe "od-control" "${VERIFY_TIMEOUT}" concurrency/owner_verify.exs "${OD_DB}"
  OD_CTRL_LINE="${RESULT_LINE}"; OD_CTRL_RC=${RC}

  # SAFETY cross-check before the kill: holder self-reported pid must match $!
  reported=$(cat "${OD_DB}.holderpid" 2>/dev/null || true)
  if [ -n "${reported}" ] && [ "${reported}" != "${HPID}" ]; then
    kill -9 "${HPID}" 2>/dev/null; wait "${HPID}" 2>/dev/null
    abort "holder pid mismatch: reported=${reported} spawned=${HPID}"
  fi

  # SIGKILL the holder by its exact PID, mid-transaction.
  if kill -0 "${HPID}" 2>/dev/null; then kill -9 "${HPID}" 2>/dev/null; fi
  wait "${HPID}" 2>/dev/null

  # TEST: holder dead → verifier must recover, write, and see the uncommitted
  # row rolled back.
  run_probe "od-test" "${VERIFY_TIMEOUT}" concurrency/owner_verify.exs "${OD_DB}"
  OD_TEST_LINE="${RESULT_LINE}"; OD_TEST_RC=${RC}

  note "Probe 2 owner-death:"
  note "    control (holder alive): rc=${OD_CTRL_RC} ${OD_CTRL_LINE}"
  note "    test    (holder killed): rc=${OD_TEST_RC} ${OD_TEST_LINE}"

  # Verdict: control must show the lock was held (RECOVERED_BUSY) OR at least
  # not corrupt; test MUST show recovery + successful write (RECOVERED_WROTE).
  if printf '%s' "${OD_TEST_LINE}" | grep -q 'RECOVERED_WROTE'; then
    if printf '%s' "${OD_CTRL_LINE}" | grep -q 'RECOVERED_BUSY'; then
      note "    -> PASS (death released the lock; alive-holder control saw BUSY = teeth)"
    else
      note "    -> PASS-WEAK (recovered+wrote, but control did not observe BUSY contention)"
    fi
  else
    note "    -> FAIL (post-kill recovery did not write cleanly)"
    FAILED=1
  fi
fi

# Probe 2b — a BEAM process dies mid-transaction while holding a SHARED handle
run_probe "orphan-txn" "${VERIFY_TIMEOUT}" concurrency/orphan_txn.exs "${WORK}/orphan.db"
P2B_CLASS=$(class_of "${RC}")
note "Probe 2b orphan-txn: ${P2B_CLASS}  (rc=${RC})  ${RESULT_LINE}"
[ "${RC}" -eq 0 ] || FAILED=1

note ""
note "=== VERDICT ==="
if [ "${FAILED}" -eq 0 ]; then
  note "ALL PROBES PASS — no crash / corruption / lost-write / wrong-result / deadlock-hang observed."
  note "(Strength bounded by the teeth above, all of which TRIPPED.)"
  exit 0
else
  note "ONE OR MORE PROBES FAILED — inspect ${SUMMARY} and the .out files (dir removed on exit)."
  exit 1
fi
