# Durability crash-harness WRITER (separate OS process; the orchestrator
# SIGKILLs it mid-run). Opens a file-backed DB through the ACTUAL xqlite public
# API and inserts rows in a tight loop, each row in its OWN committed
# IMMEDIATE transaction with a monotonically increasing id and a content
# checksum.
#
# "Committed" is made externally observable: after `Xqlite.commit/1` returns,
# the id is appended to a raw (unbuffered) ack file. A raw write() reaches the
# OS page cache immediately, so every ack that reaches the file survives this
# process being SIGKILLed — it is a truthful record of a durably-committed row.
# The reverse (a committed row whose ack never lands) is fine: the orchestrator
# treats the ack file as a conservative lower bound (the watermark).
#
# argv: <db_path> <journal_mode> <synchronous> <ack_path> <row_bytes>
Code.require_file("harness_common.exs", __DIR__)

[db_path, jmode_s, sync_s, ack_path, row_bytes_s] = System.argv()

jmode = Durability.Row.journal_mode!(jmode_s)
sync = Durability.Row.synchronous!(sync_s)
row_bytes = Durability.Row.int!(row_bytes_s)
budget = 5_000_000

# Record our own OS pid so the orchestrator can cross-check its kill target
# against the exact process it spawned (defence against any exec-chain
# surprise; belt-and-braces with the shell's own $!).
File.write!(db_path <> ".pid", System.pid())

open_opts = [
  journal_mode: jmode,
  synchronous: sync,
  foreign_keys: false,
  busy_timeout: 5_000
]

conn =
  case Xqlite.open(db_path, open_opts) do
    {:ok, conn} ->
      conn

    {:error, reason} ->
      IO.puts(:stderr, "writer: open failed: #{inspect(reason)}")
      System.halt(2)
  end

{:ok, _} =
  Xqlite.execute(
    conn,
    "CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY, payload BLOB NOT NULL, ck INTEGER NOT NULL)",
    []
  )

# A secondary index means every insert touches a second B-tree; it widens the
# surface `PRAGMA integrity_check` covers (table vs index consistency) and, for
# the unsafe negative control, the surface a torn multi-page write can desync.
{:ok, _} = Xqlite.execute(conn, "CREATE INDEX IF NOT EXISTS idx_t_ck ON t(ck)", [])

{:ok, ack} = File.open(ack_path, [:write, :raw, :binary])

insert = "INSERT INTO t(id, payload, ck) VALUES (?1, ?2, ?3)"

commit_row = fn id ->
  payload = Durability.Row.payload(id, row_bytes)
  ck = Durability.Row.checksum(payload)

  :ok = Xqlite.begin(conn, :immediate)
  {:ok, _} = Xqlite.execute(conn, insert, [id, payload, ck])
  :ok = Xqlite.commit(conn)

  # Ack AFTER the commit returns: the row is durable before it is recorded.
  IO.binwrite(ack, [Integer.to_string(id), "\n"])
end

Enum.each(1..budget, commit_row)

# Only reached if the (huge) budget is exhausted before the kill lands — the
# orchestrator treats a writer that exits on its own as a non-mid-write sample.
File.close(ack)
Xqlite.close(conn)
