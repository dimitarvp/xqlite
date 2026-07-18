# PROBE 2 (verifier half) — reopen after the owner's death and prove the DB is
# neither corrupt nor wedged.
#
# Opens a SECOND connection to the same file (bounded busy_timeout so a truly
# wedged lock is CLASSIFIED, never hung forever), then:
#   1. PRAGMA integrity_check must be "ok".
#   2. The baseline committed row (id=1) must be present.
#   3. The uncommitted row (id=999) must be ABSENT (rolled back by recovery).
#   4. Attempt a fresh write (id=2). Report WROTE or BUSY.
#
# The orchestrator runs this verifier TWICE for teeth:
#   * CONTROL (holder still alive, still holding the write lock) → expect BUSY
#     on step 4: proves the write path genuinely needs the lock the dead owner
#     held, and that the detector distinguishes wedged from free.
#   * TEST (holder SIGKILLed) → expect WROTE: proves death released the lock
#     and recovery is clean.
#
# argv: <db_path>
Code.require_file("probe_common.exs", __DIR__)
alias Concurrency.Probe

[db_path] = System.argv()

# Short busy_timeout: a wedged lock returns BUSY in ~2s, never hangs.
conn =
  case Xqlite.open(db_path,
         journal_mode: :wal,
         synchronous: :normal,
         foreign_keys: false,
         busy_timeout: 2_000
       ) do
    {:ok, c} -> c
    {:error, reason} -> Probe.emit("CORRUPTION", 3, {:open_failed, reason})
  end

case Probe.integrity(conn) do
  :ok -> :ok
  {:bad, detail} -> Probe.emit("CORRUPTION", 3, detail)
end

present? = fn id ->
  case Xqlite.query(conn, "SELECT 1 FROM t WHERE id = ?1 LIMIT 1", [id]) do
    {:ok, %{rows: [[1]]}} -> true
    {:ok, %{rows: []}} -> false
    other -> Probe.emit("CORRUPTION", 3, {:present_query_failed, id, other})
  end
end

cond do
  not present?.(1) ->
    Probe.emit("CORRUPTION", 3, {:baseline_missing, 1})

  present?.(999) ->
    Probe.emit("WRONGRESULT", 4, {:uncommitted_survived, 999})

  true ->
    write_outcome =
      case Probe.insert(conn, 2, 256) do
        :ok -> :wrote
        :busy -> :busy
        {:error, reason} -> Probe.emit("CORRUPTION", 3, {:write_error, reason})
      end

    Xqlite.close(conn)
    # class encodes the write outcome so the orchestrator can assert the
    # control/test contrast; halt code is 0 either way (both are valid
    # observations — the orchestrator decides pass/fail on the contrast).
    case write_outcome do
      :wrote -> Probe.emit("RECOVERED_WROTE", 0, :ok)
      :busy -> Probe.emit("RECOVERED_BUSY", 0, :lock_held)
    end
end
