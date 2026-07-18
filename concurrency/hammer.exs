# PROBE 1 — N-BEAM-process hammer on ONE shared connection handle.
#
# Opens a SINGLE file-backed connection and hands the identical handle to N
# concurrent BEAM processes (they run on real OS dirty-scheduler threads, so
# this is genuine multi-threaded contention on the one Mutex<Connection>).
# Workers issue a sustained mix of autocommit writes, reads, and prepared-
# statement ops; one sub-test drives a deliberate finalize-vs-step race on a
# SHARED statement handle to exercise the AtomicPtr swap-then-lock discipline
# head-on.
#
# After join: PRAGMA integrity_check must be "ok", and the set of rows in the
# DB must EXACTLY equal the set of inserts that returned :ok (no lost write,
# no phantom/duplicated row), with every payload matching its id checksum (no
# torn/wrong value). Any deviation is a data race made visible.
#
# Emits a single RESULT line + halt code: 0 PASS · 3 CORRUPTION · 4 WRONGRESULT.
# A crash (segfault/abort) exits non-zero via the VM; a true hang is caught by
# the orchestrator's outer `timeout`. Run only via concurrency/run.sh.
#
# argv: <db_path> <n_writers> <n_readers> <n_stmt> <ops_per_worker> <row_bytes>
Code.require_file("probe_common.exs", __DIR__)
alias Concurrency.Probe

[db_path, nw_s, nr_s, ns_s, ops_s, rb_s] = System.argv()
n_writers = Probe.int!(nw_s)
n_readers = Probe.int!(nr_s)
n_stmt = Probe.int!(ns_s)
ops = Probe.int!(ops_s)
row_bytes = Probe.int!(rb_s)

conn = Probe.open!(db_path, :wal)
Probe.create_table!(conn)

# --- writer tasks: autocommit INSERTs, disjoint id bands -----------------------
writer = fn w ->
  base = (w + 1) * 10_000_000

  Enum.reduce(0..(ops - 1), [], fn seq, acked ->
    id = base + seq

    case Probe.insert(conn, id, row_bytes) do
      :ok -> [id | acked]
      :busy -> acked
      {:error, reason} -> throw({:writer_error, id, reason})
    end
  end)
end

# --- reader tasks: concurrent SELECTs, must stay well-formed --------------------
reader = fn _r ->
  Enum.each(1..ops, fn _ ->
    case Xqlite.query(conn, "SELECT COUNT(*) FROM t", []) do
      {:ok, %{rows: [[n]]}} when is_integer(n) -> :ok
      other -> throw({:reader_bad_count, other})
    end

    case Xqlite.query(conn, "SELECT id, payload, ck FROM t ORDER BY id LIMIT 5", []) do
      {:ok, %{rows: rows}} when is_list(rows) ->
        Enum.each(rows, fn
          [id, p, ck] when is_integer(id) and is_binary(p) and is_integer(ck) -> :ok
          bad -> throw({:reader_bad_row, bad})
        end)

      other ->
        throw({:reader_bad_select, other})
    end
  end)

  :ok
end

# --- statement tasks: prepared INSERT stepped repeatedly (disjoint id band) -----
stmt_worker = fn s ->
  base = (100 + s) * 10_000_000
  {:ok, stmt} = Xqlite.prepare(conn, "INSERT INTO t(id, payload, ck) VALUES(?1, ?2, ?3)")

  acked =
    Enum.reduce(0..(ops - 1), [], fn seq, acc ->
      id = base + seq
      p = Probe.payload(id, row_bytes)
      ck = Probe.checksum(p)
      :ok = Xqlite.bind(stmt, [id, p, ck])

      case Xqlite.step(stmt) do
        :done -> :ok
        {:row, _} -> :ok
        other -> throw({:stmt_step_bad, id, other})
      end

      :ok = Xqlite.reset(stmt)
      [id | acc]
    end)

  :ok = Xqlite.finalize(stmt)
  acked
end

# --- finalize-vs-step race: many steppers vs one finalizer on ONE shared stmt ---
# Directly exercises take_and_finalize_raw (swap-then-lock) racing with_live_stmt
# (lock-then-load). No row invariant here — the target is UB/crash freedom.
finalize_race = fn ->
  Enum.each(1..20, fn _round ->
    {:ok, stmt} =
      Xqlite.prepare(conn, "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c LIMIT 100000) SELECT x FROM c")

    steppers =
      for _ <- 1..6 do
        Task.async(fn ->
          Stream.repeatedly(fn -> Xqlite.step(stmt) end)
          |> Enum.reduce_while(:ok, fn
            {:row, _}, _ -> {:cont, :ok}
            :done, _ -> {:halt, :ok}
            {:error, _}, _ -> {:halt, :ok}
            other, _ -> {:halt, {:bad, other}}
          end)
        end)
      end

    finisher =
      Task.async(fn ->
        Process.sleep(:rand.uniform(3))
        Xqlite.finalize(stmt)
      end)

    results = Task.await_many([finisher | steppers], :infinity)

    Enum.each(results, fn
      :ok -> :ok
      {:bad, other} -> throw({:finalize_race_bad, other})
    end)
  end)

  :ok
end

# --- run everything concurrently ----------------------------------------------
result =
  try do
    writer_tasks = for w <- 0..(n_writers - 1), do: Task.async(fn -> writer.(w) end)
    reader_tasks = for r <- 0..(n_readers - 1), do: Task.async(fn -> reader.(r) end)
    stmt_tasks = for s <- 0..(n_stmt - 1), do: Task.async(fn -> stmt_worker.(s) end)
    race_task = Task.async(finalize_race)

    writer_acked = writer_tasks |> Task.await_many(:infinity) |> List.flatten()
    reader_res = Task.await_many(reader_tasks, :infinity)
    stmt_acked = stmt_tasks |> Task.await_many(:infinity) |> List.flatten()
    :ok = Task.await(race_task, :infinity)

    Enum.each(reader_res, fn :ok -> :ok end)
    {:ok, MapSet.new(writer_acked ++ stmt_acked)}
  catch
    {:writer_error, id, reason} -> {:err, {:writer_error, id, reason}}
    {:reader_bad_count, o} -> {:err, {:reader_bad_count, o}}
    {:reader_bad_row, o} -> {:err, {:reader_bad_row, o}}
    {:reader_bad_select, o} -> {:err, {:reader_bad_select, o}}
    {:stmt_step_bad, id, o} -> {:err, {:stmt_step_bad, id, o}}
    {:finalize_race_bad, o} -> {:err, {:finalize_race_bad, o}}
  end

case result do
  {:err, detail} ->
    Probe.emit("WRONGRESULT", 4, detail)

  {:ok, expected0} ->
    # TEETH: when XQLITE_PROBE_TAMPER=drop, delete one acked row before the
    # invariant check. The set-diff detector MUST then report WRONGRESULT —
    # proving the lost-write oracle actually fires (a probe that can't fail is
    # worthless). The orchestrator asserts this run exits 4.
    expected =
      if System.get_env("XQLITE_PROBE_TAMPER") == "drop" and MapSet.size(expected0) > 0 do
        victim = expected0 |> Enum.sort() |> hd()
        {:ok, _} = Xqlite.execute(conn, "DELETE FROM t WHERE id = ?1", [victim])
        expected0
      else
        expected0
      end

    case Probe.integrity(conn) do
      {:bad, detail} ->
        Probe.emit("CORRUPTION", 3, detail)

      :ok ->
        case Probe.read_and_check_rows(conn, row_bytes) do
          {:bad, detail} ->
            Probe.emit("CORRUPTION", 3, detail)

          {:ok, actual} ->
            missing = MapSet.difference(expected, actual)
            phantom = MapSet.difference(actual, expected)

            cond do
              MapSet.size(missing) > 0 ->
                Probe.emit("WRONGRESULT", 4, {:lost_writes, Enum.take(Enum.sort(missing), 20)})

              MapSet.size(phantom) > 0 ->
                Probe.emit("WRONGRESULT", 4, {:phantom_rows, Enum.take(Enum.sort(phantom), 20)})

              true ->
                Xqlite.close(conn)
                Probe.emit("PASS", 0, %{acked: MapSet.size(expected), rows: MapSet.size(actual)})
            end
        end
    end
end
