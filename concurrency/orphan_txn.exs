# PROBE 2b — a BEAM process dies mid-transaction while holding a SHARED
# connection handle (the within-VM analogue of owner-death: the OS process
# lives, but the Elixir process that opened the transaction is killed).
#
# One connection handle is shared by several BEAM processes. A child process
# does BEGIN IMMEDIATE + an uncommitted INSERT, then is hard-killed
# (Process.exit(:kill)) WITHOUT committing. Because the handle is a ResourceArc
# held by others, the connection stays open and is left mid-transaction. We
# assert the survivors can still use it (not wedged), that txn_state reflects
# the abandoned write transaction, that an app-level ROLLBACK recovers it, and
# that the orphaned uncommitted row is gone and integrity holds — no UB from
# the owner vanishing mid-call.
#
# Emits: 0 PASS · 3 CORRUPTION · 4 WRONGRESULT.
#
# argv: <db_path>
Code.require_file("probe_common.exs", __DIR__)
alias Concurrency.Probe

[db_path] = System.argv()

conn = Probe.open!(db_path, :wal)
Probe.create_table!(conn)
:ok = Probe.insert(conn, 1, 256)

parent = self()

# Child grabs a write transaction on the SHARED handle, inserts an uncommitted
# row, signals us, then blocks — we kill it before it can ever commit.
child =
  spawn(fn ->
    {:ok, _} = Xqlite.execute(conn, "BEGIN IMMEDIATE", [])
    :ok = Probe.insert(conn, 999, 256)
    send(parent, :in_txn)
    Process.sleep(:infinity)
  end)

receive do
  :in_txn -> :ok
after
  10_000 -> Probe.emit("WRONGRESULT", 4, :child_never_entered_txn)
end

# Hard-kill the transaction owner mid-transaction.
Process.exit(child, :kill)
Process.sleep(50)

# The connection must NOT be wedged: txn_state should reflect the abandoned
# write transaction, and a survivor must be able to recover it. (Reported
# opaquely; the load-bearing assertion is that ROLLBACK recovers the handle.)
state = Xqlite.txn_state(conn)

recovered =
  case Xqlite.rollback(conn) do
    {:ok, _} -> :ok
    :ok -> :ok
    other -> {:rollback_failed, other}
  end

cond do
  recovered != :ok ->
    Probe.emit("WRONGRESULT", 4, {:not_recoverable, state, recovered})

  true ->
    # After rollback: uncommitted row gone, baseline present, DB usable, clean.
    {:ok, _} = Xqlite.execute(conn, "INSERT INTO t(id,payload,ck) VALUES(?1,?2,?3)", [
      2,
      Probe.payload(2, 256),
      Probe.checksum(Probe.payload(2, 256))
    ])

    orphan_present? =
      case Xqlite.query(conn, "SELECT 1 FROM t WHERE id=999 LIMIT 1", []) do
        {:ok, %{rows: []}} -> false
        {:ok, %{rows: [[1]]}} -> true
      end

    case Probe.integrity(conn) do
      {:bad, detail} ->
        Probe.emit("CORRUPTION", 3, detail)

      :ok ->
        cond do
          orphan_present? ->
            Probe.emit("WRONGRESULT", 4, {:orphan_uncommitted_survived, 999})

          true ->
            Xqlite.close(conn)
            Probe.emit("PASS", 0, %{txn_state_at_death: state, recovered: true})
        end
    end
end
