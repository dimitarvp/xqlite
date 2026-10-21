defmodule Xqlite.StaleSchemaBusyTest do
  # Every connection here opens one shared file so that their locks contend;
  # the `connection_openers()` loop gives each connection a database of its own.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.TestUtil, only: [tmp_db_path: 1]

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  @reset "DROP TABLE IF EXISTS t1; DROP TABLE IF EXISTS t2; CREATE TABLE t1(a)"
  @new_table "CREATE TABLE t2(v); INSERT INTO t2 VALUES (1)"
  @batch "INSERT INTO log VALUES (7); INSERT INTO t2(v) VALUES (8)"

  # Each schema change, with the table and column a statement names to meet it.
  @changes [
    {@new_table, "t2", "v"},
    {"ALTER TABLE t1 ADD COLUMN w", "t1", "w"},
    {"DROP TABLE t1; CREATE TABLE t1(x)", "t1", "x"},
    {"DROP TABLE t1", "t1", "a"}
  ]

  setup do
    {:ok, path: tmp_db_path("stale_schema_busy")}
  end

  property "a call on what another connection changed answers busy, then what the schema says",
           %{path: path} do
    [maker, holder] = [open!(path), open!(path)]

    check all(
            {change, table, column} <- StreamData.member_of(@changes),
            call <- StreamData.member_of([:query, :execute, :step, :stream]),
            max_runs: 2_000
          ) do
      probe = stale_probe(path, maker, change, busy_timeout: 0)
      :ok = Xqlite.begin(holder, :exclusive)
      locked = run(call, probe, table, column)
      :ok = Xqlite.commit(holder)
      assert {:error, {:database_busy, %{retry: :call}}} = locked
      assert run(call, probe, table, column) == run(call, maker, table, column)
      :ok = Xqlite.close(probe)
    end
  end

  test "the anchor: query/4 waits out the lock, then reads the table another connection made",
       %{path: path} do
    assert {:ok, %Xqlite.Result{rows: [[1]]}} =
             waited(path, &Xqlite.query(&1, "SELECT v FROM t2"))
  end

  test "a query that asked and failed for a real reason answers that reason after the wait",
       %{path: path} do
    assert {:error, {:no_such_table, "never"}} =
             waited(path, &Xqlite.query(&1, "SELECT v FROM never"))
  end

  test "a batch whose schema check meets a lock answers busy with the text still to run",
       %{path: path} do
    {probe, holder} = locked_probe(path, busy_timeout: 0)
    answer = NIF.execute_batch(probe, @batch)
    :ok = Xqlite.commit(holder)
    assert {:error, {:database_busy, %{retry: :call, sql: rest}}} = answer
    assert String.trim(rest) == "INSERT INTO t2(v) VALUES (8)"
    assert values(probe, "log") == [[7]]
  end

  test "execute_batch/3 waits out the lock, then runs the batch from that statement on",
       %{path: path} do
    batch = fn probe ->
      {Xqlite.execute_batch(probe, @batch), values(probe, "log"), values(probe, "t2")}
    end

    assert {:ok, [[7]], [[1], [8]]} = waited(path, batch)
  end

  # The moment the call waits is its first busy message, which only a wait sends.
  defp waited(path, call) do
    {probe, holder} = locked_probe(path)
    {:ok, _} = Xqlite.register_busy_observer(probe, self())
    task = Task.async(fn -> call.(probe) end)
    assert_receive {:xqlite_busy, 0, _}, 5_000
    :ok = Xqlite.commit(holder)
    Task.await(task)
  end

  # A probe whose copy of the schema predates t2, with a temp table the lock on the file
  # does not reach, and a holder that has just taken that lock.
  defp locked_probe(path, opts \\ []) do
    [maker, holder] = [open!(path), open!(path)]
    probe = stale_probe(path, maker, @new_table, opts)
    :ok = Xqlite.execute_batch(probe, "CREATE TEMP TABLE log(v)")
    :ok = Xqlite.begin(holder, :exclusive)
    {probe, holder}
  end

  # The probe reads t1, so its schema is loaded, before the maker changes the schema.
  defp stale_probe(path, maker, change, opts) do
    :ok = Xqlite.execute_batch(maker, @reset)
    probe = open!(path, opts)
    {:ok, _} = Xqlite.query(probe, "SELECT a FROM t1")
    :ok = Xqlite.execute_batch(maker, change)
    probe
  end

  defp run(:query, conn, table, column),
    do: Xqlite.query(conn, "SELECT #{column} FROM #{table}")

  defp run(:execute, conn, table, column),
    do: Xqlite.execute(conn, "INSERT INTO #{table}(#{column}) VALUES (1)")

  defp run(:step, conn, table, column) do
    with {:ok, stmt} <- NIF.stmt_prepare(conn, "SELECT #{column} FROM #{table}") do
      answer = Xqlite.multi_step(stmt, 10)
      :ok = Xqlite.finalize(stmt)
      answer
    end
  end

  # A stream answers an error at its open, or as the one element its first fetch gives.
  defp run(:stream, conn, table, column) do
    case Xqlite.stream(conn, "SELECT #{column} FROM #{table}", [], on_error: :emit_error) do
      {:error, _reason} = error -> error
      stream -> with [{:error, _reason} = error] <- Enum.to_list(stream), do: error
    end
  end

  defp values(conn, table) do
    {:ok, %Xqlite.Result{rows: rows}} = Xqlite.query(conn, "SELECT v FROM #{table}")
    rows
  end

  # In rollback-journal mode `BEGIN EXCLUSIVE` keeps every other connection from reading
  # the file, its schema included; the journal stays in memory, as the law writes each run.
  defp open!(path, opts \\ []) do
    {:ok, conn} = Xqlite.open(path, [journal_mode: :memory, synchronous: :off] ++ opts)
    conn
  end
end
