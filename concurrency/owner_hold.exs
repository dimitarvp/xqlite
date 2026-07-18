# PROBE 2 (holder half) — owner-process death mid-transaction.
#
# Opens a file-backed DB, commits a baseline row, then opens a write
# transaction (BEGIN IMMEDIATE, grabbing the write lock) and inserts an
# UNCOMMITTED row — then parks forever. The orchestrator SIGKILLs THIS process
# (by its exact captured PID, cross-checked against the pid file below) while
# the transaction is open. Nothing here ever commits the second row: after the
# kill, crash recovery must roll it back, and the write lock must be released
# by the OS so a fresh connection is not wedged.
#
# argv: <db_path> <ready_path>
Code.require_file("probe_common.exs", __DIR__)
alias Concurrency.Probe

[db_path, ready_path] = System.argv()

conn = Probe.open!(db_path, :wal)
Probe.create_table!(conn)

# Baseline committed row (id=1) — must survive; proves the DB is usable.
:ok = Probe.insert(conn, 1, 256)

# Open a write transaction and insert an UNCOMMITTED row (id=999).
{:ok, _} = Xqlite.execute(conn, "BEGIN IMMEDIATE", [])
:ok = Probe.insert(conn, 999, 256)

# Announce readiness: write our own OS pid so the orchestrator can cross-check
# its kill target, then an unbuffered marker line. Both reach the OS at once.
File.write!(db_path <> ".holderpid", System.pid())
File.write!(ready_path, "holding txn, uncommitted id=999 present in-txn\n")

# Park until SIGKILLed. Never commits.
Process.sleep(:infinity)
