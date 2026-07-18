# TEETH for the CORRUPTION oracle (Probes 1, 3, 4 all reuse Probe.integrity +
# Probe.read_and_check_rows). Opens a DB and runs exactly those two checks,
# classifying CORRUPTION vs PASS. The orchestrator points this at deliberately
# damaged DBs — a mid-file byte-smash (integrity_check must fail) and a
# payload-tampered row (checksum must fail) — and REQUIRES CORRUPTION. This
# proves the same oracle that green-lights the real runs actually fails on a
# corrupt DB.
#
# argv: <db_path> <row_bytes>
Code.require_file("probe_common.exs", __DIR__)
alias Concurrency.Probe

[db_path, rb_s] = System.argv()
row_bytes = Probe.int!(rb_s)

conn =
  case Xqlite.open(db_path, journal_mode: :wal, synchronous: :normal, busy_timeout: 2_000) do
    {:ok, c} -> c
    {:error, reason} -> Probe.emit("CORRUPTION", 3, {:open_failed, reason})
  end

case Probe.integrity(conn) do
  {:bad, detail} ->
    Probe.emit("CORRUPTION", 3, detail)

  :ok ->
    case Probe.read_and_check_rows(conn, row_bytes) do
      {:bad, detail} -> Probe.emit("CORRUPTION", 3, detail)
      {:ok, _actual} -> Probe.emit("PASS", 0, :ok)
    end
end
