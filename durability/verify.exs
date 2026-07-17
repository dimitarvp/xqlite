# Durability crash-harness VERIFIER (fresh OS process, run under an OS-level
# `timeout` by the orchestrator so a hang on reopen is classified, never hung
# forever). Reopens the post-crash DB through the ACTUAL xqlite public API
# (which runs SQLite's WAL / rollback-journal recovery) and checks durability +
# integrity invariants against the writer's ack file.
#
# Classification is emitted as a single RESULT line plus a halt code:
#   0  PASS        — every invariant holds
#   3  CORRUPTION  — integrity_check fails, a row's checksum is wrong, or the
#                    DB cannot even be opened/read
#   4  LOSTWRITE   — a committed id is missing beneath the watermark (an ack'd
#                    row absent, or a gap in the 1..max prefix)
# A timeout (124/137 from the orchestrator's `timeout`) is HANG — counted
# separately; it is A7 territory, never conflated with corruption.
#
# argv: <db_path> <journal_mode> <synchronous> <ack_path> <row_bytes>
Code.require_file("harness_common.exs", __DIR__)

[db_path, jmode_s, sync_s, ack_path, row_bytes_s] = System.argv()

jmode = Durability.Row.journal_mode!(jmode_s)
sync = Durability.Row.synchronous!(sync_s)
row_bytes = Durability.Row.int!(row_bytes_s)

# --- watermark: complete ack lines only (drop any torn trailing line) --------
ack_ids =
  case File.read(ack_path) do
    {:ok, content} ->
      content
      |> String.split("\n")
      # The final element is either "" (file ended in \n) or a partial line
      # torn by the SIGKILL; never trust it.
      |> Enum.drop(-1)
      |> Enum.flat_map(fn line ->
        case Integer.parse(line) do
          {n, ""} -> [n]
          _ -> []
        end
      end)

    {:error, _} ->
      []
  end

watermark = Enum.max(ack_ids, fn -> 0 end)
ack_set = MapSet.new(ack_ids)

emit = fn class, code, db_min, db_max, db_count, detail ->
  IO.puts(
    "RESULT class=#{class} watermark=#{watermark} ack_count=#{MapSet.size(ack_set)} " <>
      "db_min=#{db_min} db_max=#{db_max} db_count=#{db_count} detail=#{inspect(detail)}"
  )

  System.halt(code)
end

# --- reopen (runs crash recovery) --------------------------------------------
open_opts = [journal_mode: jmode, synchronous: sync, foreign_keys: false, busy_timeout: 5_000]

conn =
  case Xqlite.open(db_path, open_opts) do
    {:ok, conn} -> conn
    {:error, reason} -> emit.("CORRUPTION", 3, -1, -1, -1, {:open_failed, reason})
  end

# --- integrity_check ---------------------------------------------------------
case Xqlite.query(conn, "PRAGMA integrity_check", []) do
  {:ok, %{rows: [["ok"]]}} -> :ok
  {:ok, %{rows: rows}} -> emit.("CORRUPTION", 3, -1, -1, -1, {:integrity_check, rows})
  {:error, reason} -> emit.("CORRUPTION", 3, -1, -1, -1, {:integrity_check_error, reason})
end

# --- read committed rows (guarding against a writer killed pre-CREATE) --------
table_exists? =
  case Xqlite.query(
         conn,
         "SELECT 1 FROM sqlite_master WHERE type='table' AND name='t' LIMIT 1",
         []
       ) do
    {:ok, %{rows: [[1]]}} -> true
    {:ok, %{rows: []}} -> false
    {:error, reason} -> emit.("CORRUPTION", 3, -1, -1, -1, {:master_read_error, reason})
  end

rows =
  if table_exists? do
    case Xqlite.query(conn, "SELECT id, payload, ck FROM t ORDER BY id", []) do
      {:ok, %{rows: rows}} -> rows
      {:error, reason} -> emit.("CORRUPTION", 3, -1, -1, -1, {:select_error, reason})
    end
  else
    []
  end

ids = Enum.map(rows, fn [id, _payload, _ck] -> id end)
db_count = length(ids)
db_min = Enum.min(ids, fn -> 0 end)
db_max = Enum.max(ids, fn -> 0 end)

# --- per-row checksum (torn / partial page write) ----------------------------
bad_checksum =
  Enum.find(rows, fn [id, payload, ck] ->
    expected = Durability.Row.payload(id, row_bytes)
    payload != expected or ck != Durability.Row.checksum(expected)
  end)

# --- contiguity: present ids must be exactly 1..db_max (no gap) ---------------
id_set = MapSet.new(ids)
missing_prefix = if db_count == 0, do: [], else: Enum.reject(1..db_max, &MapSet.member?(id_set, &1))

# --- watermark durability: every ack'd id must survive -----------------------
missing_acked = ack_ids |> Enum.reject(&MapSet.member?(id_set, &1)) |> Enum.sort()

Xqlite.close(conn)

cond do
  bad_checksum != nil ->
    [id, _p, _c] = bad_checksum
    emit.("CORRUPTION", 3, db_min, db_max, db_count, {:bad_checksum, id})

  missing_acked != [] ->
    emit.("LOSTWRITE", 4, db_min, db_max, db_count, {:acked_missing, Enum.take(missing_acked, 20)})

  missing_prefix != [] ->
    emit.("LOSTWRITE", 4, db_min, db_max, db_count, {:gap, Enum.take(missing_prefix, 20)})

  true ->
    emit.("PASS", 0, db_min, db_max, db_count, :ok)
end
