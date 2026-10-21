defmodule Xqlite.BusyWaitTest do
  # Every connection here opens one shared file so that their locks contend;
  # the `connection_openers()` loop gives each connection a database of its own.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.TestUtil, only: [tmp_db_path: 1]

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  @insert "INSERT INTO t(v) VALUES (?1)"
  @reset "DELETE FROM t; INSERT INTO t(v) VALUES (1), (2), (3)"
  @seed [1, 2, 3]
  @writes %{
    insert: @insert,
    update: "UPDATE t SET v = ?1 WHERE rowid = 2",
    delete: "DELETE FROM t WHERE v = 3 OR v = ?1"
  }

  setup do
    {:ok, path: tmp_db_path("busy_wait")}
  end

  property "no lock wait holds a VM thread: more waiters than dirty I/O threads stall nothing",
           %{path: path} do
    {holder, waiters, canary} =
      stall_setup(path, :erlang.system_info(:dirty_io_schedulers) + 1)

    check all(
            call <- StreamData.member_of([:insert, :transaction, :returning]),
            sleep_ms <- StreamData.integer(1..3),
            max_runs: 2_000
          ) do
      policy = [max_retries: 1_000_000, max_elapsed_ms: 10_000, sleep_ms: sleep_ms]
      for conn <- waiters, do: :ok = Xqlite.set_busy_policy(conn, policy)
      assert_stall_free(holder, waiters, canary, call)
    end
  end

  test "the anchor: twelve writers waiting out a 10 s busy timeout stall nothing",
       %{path: path} do
    {holder, waiters, canary} = stall_setup(path, 12)
    for conn <- waiters, do: :ok = Xqlite.put_busy_timeout(conn, 10_000)
    assert_stall_free(holder, waiters, canary, :insert)
  end

  for journal <- [:wal, :delete] do
    property "a busy answer says what it left, and the call run again means the same, #{journal}",
             %{path: path} do
      {a, b} = pair(path, unquote(journal))
      {control, _} = pair(tmp_db_path("busy_wait_control"), unquote(journal))
      {:ok, _} = Xqlite.register_busy_observer(a, self())

      check all(
              position <- StreamData.member_of([:autocommit, :deferred, :read]),
              call <-
                StreamData.member_of([
                  :begin,
                  :batch,
                  :multi_step,
                  :returning | Map.keys(@writes)
                ]),
              value <- hostile(),
              pause <- StreamData.integer(0..5),
              max_runs: 2_000
            ) do
        position = if call == :begin, do: :autocommit, else: position
        retry = if position == :read, do: :transaction, else: :call
        for conn <- [a, control], do: :ok = Xqlite.execute_batch(conn, @reset)
        :ok = Xqlite.begin(b, :immediate)
        :ok = enter(position, a)
        {raw, again} = attempts(call, a, value, position)
        assert {:error, {:database_busy, %{retry: ^retry, retries: 0, elapsed_ms: 0}}} = raw.()
        assert rows(b) == @seed
        assert_run_again(retry, {a, b, control}, {position, call, value}, again, pause)
      end
    end
  end

  test "the anchor: a raw insert answers retry: :call at once, the Xqlite call waits for the lock",
       %{path: path} do
    {a, b} = pair(path, :wal)
    :ok = Xqlite.begin(b, :immediate)

    assert {:error, {:database_busy, %{code: 5, retry: :call, retries: 0, elapsed_ms: 0}}} =
             NIF.execute(a, @insert, [9])

    later(100, fn -> Xqlite.commit(b) end)
    assert {:ok, %Xqlite.Result{changes: 1}} = Xqlite.execute(a, @insert, [9])
  end

  test "a write stepped by hand loses its rows when its commit meets a reader: retry :none",
       %{path: path} do
    {a, b} = pair(path, :delete)
    {:ok, stmt} = Xqlite.prepare(a, "INSERT INTO t(v) VALUES (7), (8), (9) RETURNING v")
    assert {:ok, %{rows: [[7]], done: false}} = Xqlite.multi_step(stmt, 1)
    :ok = Xqlite.execute_batch(b, "BEGIN; SELECT count(*) FROM t")
    assert {:error, {:database_busy, %{retry: :none}}} = Xqlite.multi_step(stmt, 10)
    assert [:ok, :ok] = [Xqlite.finalize(stmt), Xqlite.rollback(b)]
    assert rows(b) == @seed
  end

  test "a streamed write stopped by an unreadable row after handing back rows: retry :none",
       %{path: path} do
    {a, b} = pair(path, :delete)
    sql = "INSERT INTO t(v) VALUES (7), (CAST(X'FF' AS TEXT)) RETURNING v"
    {:ok, stream} = NIF.stream_open(a, sql, [])
    assert {:ok, %{rows: [[7]]}} = NIF.stream_fetch(stream, 1)
    :ok = Xqlite.execute_batch(b, "BEGIN; SELECT count(*) FROM t")
    assert {:error, {:database_busy, %{retry: :none}}} = NIF.stream_fetch(stream, 1)
    assert [:ok, :ok] = [NIF.stream_close(stream), Xqlite.rollback(b)]
    assert rows(b) == @seed
  end

  test "a batch's busy answer names the text still to run, and execute_batch/3 runs only that",
       %{path: path} do
    {a, _b} = pair(path, :wal)
    holder = attached(a, :wal)
    :ok = Xqlite.begin(holder, :immediate)
    batch = "INSERT INTO main.t(v) VALUES (7); INSERT INTO aux.u(v) VALUES (8)"
    assert {:error, {:database_busy, %{retry: :call, sql: rest}}} = NIF.execute_batch(a, batch)
    assert String.trim(rest) == "INSERT INTO aux.u(v) VALUES (8)"
    :ok = Xqlite.execute_batch(a, @reset)
    later(50, fn -> Xqlite.commit(holder) end)
    assert :ok = Xqlite.execute_batch(a, batch)
    assert rows(a) == [1, 2, 3, 7]
    assert {:ok, %Xqlite.Result{rows: [[8]]}} = Xqlite.query(a, "SELECT v FROM aux.u")
  end

  property "a wait follows the busy settings, observers hear every retry, and a token ends it",
           %{path: path} do
    {a, b} = pair(path, :wal)
    {:ok, _} = Xqlite.register_busy_observer(a, self())
    :ok = Xqlite.begin(b, :immediate)

    check all(
            settings <- busy_settings(),
            signal <- StreamData.one_of([StreamData.constant(nil), StreamData.integer(0..8)]),
            max_runs: 2_000
          ) do
      {budget, max_retries} = apply_settings(a, settings)
      {:ok, token} = Xqlite.create_cancel_token()
      if signal, do: later(signal, fn -> Xqlite.cancel_operation(token) end)
      started = System.monotonic_time(:millisecond)
      answer = Xqlite.execute(a, @insert, [1], cancel_tokens: token)
      assert System.monotonic_time(:millisecond) - started < budget + 1_000
      heard = busy_messages()
      assert for({retries, _} <- heard, do: retries) == Enum.to_list(0..(length(heard) - 1)//1)
      elapsed = for {_, elapsed_ms} <- heard, do: elapsed_ms
      assert elapsed == Enum.sort(elapsed)
      assert_wait_answer(answer, heard, max_retries, signal)
      assert rows(b) == @seed
    end
  end

  test "the anchor: a token signalled during a 3 s wait ends it at once, nothing written",
       %{path: path} do
    {a, b} = pair(path, :wal)
    :ok = Xqlite.put_busy_timeout(a, 3_000)
    :ok = Xqlite.begin(b, :immediate)
    {:ok, token} = Xqlite.create_cancel_token()
    task = Task.async(fn -> Xqlite.execute(a, @insert, [1], cancel_tokens: token) end)
    Process.sleep(200)
    :ok = Xqlite.cancel_operation(token)
    assert {:ok, {:error, :operation_cancelled}} = Task.yield(task, 1_000)
    assert rows(b) == @seed
  end

  test "a SQL COMMIT beside the connection's own running write answers :statement_mid_run",
       %{path: path} do
    {a, _b} = pair(path, :wal)
    :ok = Xqlite.begin(a, :deferred)
    {:ok, stmt} = Xqlite.prepare(a, "INSERT INTO t(v) VALUES (7), (8) RETURNING v")
    {:row, [7]} = Xqlite.step(stmt)
    assert {:error, :statement_mid_run} = Xqlite.execute(a, "COMMIT")
    assert [:ok, :ok] = [Xqlite.finalize(stmt), Xqlite.rollback(a)]
  end

  test "after a busy answer the next statement asks again, so it is judged :call",
       %{path: path} do
    {_a, b} = pair(path, :delete)
    {:ok, raw} = NIF.open(path)
    :ok = Xqlite.begin(b, :exclusive)
    :ok = NIF.execute_batch(raw, "BEGIN")

    assert {:error, {:database_busy, %{retry: :call}}} =
             NIF.query(raw, "PRAGMA user_version", [])

    assert {:error, {:database_busy, %{retry: :call}}} = NIF.query(raw, "SELECT v FROM t", [])
    assert :ok = Xqlite.rollback(b)
  end

  test "a cache spill in one batch statement leaves the next statement's upgrade :transaction",
       %{path: path} do
    {a, reader} = pair(path, :delete)
    holder = attached(a, :delete)
    rows = "WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 2000)"

    batch =
      rows <>
        " INSERT INTO main.t(v) SELECT randomblob(100) FROM s; INSERT INTO aux.u VALUES (1)"

    :ok = Xqlite.execute_batch(a, "PRAGMA cache_size = 10; BEGIN; SELECT count(*) FROM aux.u")
    :ok = Xqlite.execute_batch(reader, "BEGIN; SELECT count(*) FROM t")
    :ok = Xqlite.begin(holder, :immediate)
    assert {:error, {:database_busy, %{retry: :transaction}}} = NIF.execute_batch(a, batch)
    assert [:ok, :ok] = [Xqlite.rollback(holder), Xqlite.rollback(reader)]
  end

  test "a stream whose first fetch met a lock fetches from the start, its column check again",
       %{path: path} do
    {a, b} = pair(path, :delete)
    {:ok, stream} = NIF.stream_open(a, "SELECT * FROM t", [])
    :ok = Xqlite.begin(b, :exclusive)
    assert {:error, {:database_busy, %{retry: :call}}} = NIF.stream_fetch(stream, 10)
    :ok = Xqlite.commit(b)
    assert {:ok, %{rows: [[1], [2], [3]]}} = NIF.stream_fetch(stream, 10)
    {:ok, renamed} = NIF.stream_open(a, "SELECT * FROM t", [])
    :ok = Xqlite.begin(b, :exclusive)
    assert {:error, {:database_busy, %{retry: :call}}} = NIF.stream_fetch(renamed, 10)
    :ok = Xqlite.execute_batch(b, "ALTER TABLE t RENAME COLUMN v TO w; COMMIT")
    changed = %{expected: ["v"], live: ["w"]}
    assert {:error, {:columns_changed, ^changed}} = NIF.stream_fetch(renamed, 10)
    assert [:ok, :ok] = [NIF.stream_close(stream), NIF.stream_close(renamed)]
  end

  test "busy_delay/4 answers what it cannot read with structured errors", %{path: path} do
    {:ok, conn} = NIF.open(path)
    assert {:error, {:invalid_cancel_tokens, _}} = NIF.busy_delay(conn, 0, 0, [:no_token])

    for {retries, elapsed_ms, argument, value} <- [
          {-1, 0, :retries, -1},
          {2 ** 64, 0, :retries, 2 ** 64},
          {0, 1.5, :elapsed_ms, 1.5}
        ] do
      assert {:error, {:invalid_busy_delay_argument, %{argument: ^argument, value: ^value}}} =
               NIF.busy_delay(conn, retries, elapsed_ms, [])
    end

    assert {:error, {:invalid_busy_delay_argument, %{argument: :handle, value: :no_handle}}} =
             NIF.busy_delay(:no_handle, 0, 0, [])

    :ok = NIF.close(conn)
    assert {:error, :connection_closed} = NIF.busy_delay(conn, 0, 0, [])
  end

  test "a busy_timeout written in SQL sets the wait and keeps xqlite's callback",
       %{path: path} do
    {a, b} = pair(path, :wal)
    {:ok, _} = Xqlite.register_busy_observer(a, self())
    assert {:ok, %Xqlite.Result{}} = Xqlite.execute(a, "PRAGMA busy_timeout = 50")
    assert {:ok, 50} = Xqlite.get_busy_timeout(a)
    :ok = Xqlite.begin(b, :immediate)
    assert {:error, {:database_busy, %{retry: :call}}} = Xqlite.execute(a, @insert, [7])
    assert_received {:xqlite_busy, 0, _}
    :ok = Xqlite.begin(a, :deferred)
    batch = "PRAGMA busy_timeout = 60; INSERT INTO t(v) VALUES (7)"
    assert {:error, {:database_busy, %{retry: :call}}} = NIF.execute_batch(a, batch)
    assert {:ok, 60} = Xqlite.get_busy_timeout(a)
    assert {:error, {:database_busy, %{retry: :call}}} = NIF.execute(a, @insert, [7])
    assert [:ok, :ok] = [Xqlite.rollback(a), Xqlite.rollback(b)]
  end

  test "a table lock of the connection's own answers :database_locked at once", %{path: path} do
    {a, _b} = pair(path, :wal)
    {:ok, _} = Xqlite.register_busy_observer(a, self())
    {:ok, stmt} = Xqlite.prepare(a, "SELECT v FROM t")
    {:row, _} = Xqlite.step(stmt)
    assert {:error, {:database_locked, %{code: 6}}} = Xqlite.execute(a, "DROP TABLE t")
    refute_received {:xqlite_busy, _, _}
    :ok = Xqlite.finalize(stmt)
  end

  test "a truncating checkpoint runs again while a reader holds it, as the busy settings say",
       %{path: path} do
    {a, reader} = pair(path, :wal)
    :ok = Xqlite.put_busy_timeout(a, 200)
    :ok = Xqlite.execute_batch(reader, "BEGIN; SELECT count(*) FROM t")
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{busy: true}} = Xqlite.wal_checkpoint(a, :truncate)
    assert System.monotonic_time(:millisecond) - started >= 150
    later(50, fn -> Xqlite.rollback(reader) end)
    assert {:ok, %{busy: false}} = Xqlite.wal_checkpoint(a, :truncate)
  end

  test "open/2 waits for the lock its journal-mode change needs", %{path: path} do
    {:ok, holder} = Xqlite.open(path, journal_mode: :delete)
    :ok = Xqlite.begin(holder, :immediate)
    later(100, fn -> Xqlite.commit(holder) end)
    assert {:ok, _conn} = Xqlite.open(path, journal_mode: :wal)
  end

  test "backup/3 waits for a destination another connection holds", %{path: path} do
    {a, _b} = pair(path, :wal)
    dest = tmp_db_path("busy_wait_dest")
    {:ok, holder} = Xqlite.open(dest, journal_mode: :delete)
    :ok = Xqlite.begin(holder, :immediate)
    later(100, fn -> Xqlite.commit(holder) end)
    assert :ok = Xqlite.backup(a, dest)
  end

  defp stall_setup(path, count) do
    {holder, _b} = pair(path, :wal)
    waiters = for _ <- 1..count, do: open!(path, :wal)
    for conn <- waiters, do: {:ok, _} = Xqlite.register_busy_observer(conn, self())
    small = tmp_db_path("busy_wait_small")
    File.write!(small, "hello")
    {:ok, other} = Xqlite.open(tmp_db_path("busy_wait_other"))
    {holder, waiters, {other, small}}
  end

  defp assert_stall_free(holder, waiters, {other, small}, call) do
    before = length(rows(holder))
    :ok = Xqlite.begin(holder, :immediate)
    tasks = Enum.map(waiters, fn conn -> Task.async(fn -> write(call, conn) end) end)
    for _ <- waiters, do: assert_receive({:xqlite_busy, 0, _}, 5_000)
    query = Task.async(fn -> Xqlite.query(other, "SELECT 1") end)
    read = Task.async(fn -> File.read(small) end)
    canaries = Task.yield_many([query, read], 1_000)
    assert [{_, {:ok, {:ok, _}}}, {_, {:ok, {:ok, "hello"}}}] = canaries
    :ok = Xqlite.commit(holder)
    assert Enum.all?(Task.await_many(tasks, 10_000), &(&1 == :ok))
    assert length(rows(holder)) == before + length(waiters)
    busy_messages()
  end

  defp write(:insert, conn), do: ok(Xqlite.execute(conn, @insert, [1]))
  defp write(:returning, conn), do: ok(Xqlite.query(conn, @insert <> " RETURNING v", [1]))

  defp write(:transaction, conn) do
    with :ok <- Xqlite.begin(conn, :immediate),
         :ok <- write(:insert, conn),
         do: Xqlite.commit(conn)
  end

  defp attempts(:begin, conn, _value, _position) do
    {fn -> NIF.begin(conn, :immediate) end,
     fn -> with :ok <- Xqlite.begin(conn, :immediate), do: Xqlite.commit(conn) end}
  end

  defp attempts(:batch, conn, _value, position) do
    two = "INSERT INTO t(v) VALUES (7); INSERT INTO t(v) VALUES (8)"
    sql = if position == :autocommit, do: "BEGIN; #{two}; COMMIT", else: two
    {fn -> NIF.execute_batch(conn, sql) end, fn -> Xqlite.execute_batch(conn, sql) end}
  end

  defp attempts(:multi_step, conn, value, _position) do
    {:ok, stmt} = Xqlite.prepare(conn, @insert <> " RETURNING v")
    :ok = Xqlite.bind(stmt, [value])

    {fn -> NIF.stmt_multi_step(stmt, 10) end,
     fn -> finish(Xqlite.multi_step(stmt, 10), stmt) end}
  end

  defp attempts(:returning, conn, value, _position) do
    sql = @insert <> " RETURNING v"
    {fn -> NIF.query(conn, sql, [value]) end, fn -> ok(Xqlite.query(conn, sql, [value])) end}
  end

  defp attempts(write, conn, value, _position) do
    sql = Map.fetch!(@writes, write)

    {fn -> NIF.execute(conn, sql, [value]) end,
     fn -> ok(Xqlite.execute(conn, sql, [value])) end}
  end

  defp assert_run_again(:call, {a, b, control}, {position, call, value}, again, pause) do
    later(pause, fn -> Xqlite.commit(b) end)
    assert :ok = again.()
    :ok = leave(position, a)
    {_raw, control_call} = attempts(call, control, value, :autocommit)
    :ok = control_call.()
    assert rows(a) == rows(control)
    busy_messages()
  end

  defp assert_run_again(:transaction, {a, b, _control}, _run, again, _pause) do
    assert {:error, {:database_busy, %{retry: :transaction}}} = again.()
    refute_received {:xqlite_busy, _, _}
    assert [:ok, :ok] = [Xqlite.rollback(a), Xqlite.commit(b)]
    assert rows(a) == @seed
  end

  defp assert_wait_answer({:error, {:database_busy, busy}}, heard, max_retries, _signal) do
    assert %{retry: :call, retries: retries} = busy
    assert {retries, retries <= max_retries} == {length(heard) - 1, true}
  end

  defp assert_wait_answer({:error, :operation_cancelled}, _heard, _max_retries, signal),
    do: assert(is_integer(signal))

  defp busy_settings do
    StreamData.one_of([
      StreamData.tuple({StreamData.constant(:timeout), StreamData.integer(0..12)}),
      StreamData.tuple(
        {StreamData.constant(:policy), StreamData.integer(0..6), StreamData.integer(0..12),
         StreamData.integer(0..4)}
      )
    ])
  end

  defp apply_settings(conn, {:timeout, ms}) do
    assert [:ok, :ok] = [Xqlite.remove_busy_policy(conn), Xqlite.put_busy_timeout(conn, ms)]
    {ms, 1_000_000}
  end

  defp apply_settings(conn, {:policy, retries, elapsed_ms, sleep_ms}) do
    policy = [max_retries: retries, max_elapsed_ms: elapsed_ms, sleep_ms: sleep_ms]
    :ok = Xqlite.set_busy_policy(conn, policy)
    {elapsed_ms, retries}
  end

  defp hostile do
    StreamData.one_of([
      StreamData.binary(max_length: 16),
      StreamData.member_of([<<0, ?', ?">>, <<255, 254>>, "", :binary.copy("x", 65_536)]),
      StreamData.member_of([-9_223_372_036_854_775_808, 9_223_372_036_854_775_807])
    ])
  end

  defp enter(:autocommit, _conn), do: :ok
  defp enter(:deferred, conn), do: Xqlite.begin(conn, :deferred)
  defp enter(:read, conn), do: Xqlite.execute_batch(conn, "BEGIN; SELECT count(*) FROM t")

  defp leave(:autocommit, _conn), do: :ok
  defp leave(_position, conn), do: Xqlite.commit(conn)

  defp pair(path, journal) do
    a = open!(path, journal)
    :ok = Xqlite.execute_batch(a, "CREATE TABLE IF NOT EXISTS t(v); " <> @reset)
    {a, open!(path, journal)}
  end

  defp attached(conn, journal) do
    aux = tmp_db_path("busy_wait_aux")
    holder = open!(aux, journal)
    :ok = Xqlite.execute_batch(holder, "CREATE TABLE u(v)")
    {:ok, _} = Xqlite.execute(conn, "ATTACH ?1 AS aux", [aux])
    holder
  end

  defp open!(path, journal) do
    {:ok, conn} = Xqlite.open(path, journal_mode: journal, synchronous: :off)
    conn
  end

  defp rows(conn) do
    {:ok, %Xqlite.Result{rows: rows}} = Xqlite.query(conn, "SELECT v FROM t")
    rows |> List.flatten() |> Enum.sort()
  end

  defp later(ms, fun) do
    spawn(fn ->
      Process.sleep(ms)
      fun.()
    end)
  end

  defp finish(answer, stmt) do
    :ok = Xqlite.finalize(stmt)
    ok(answer)
  end

  defp busy_messages do
    receive do
      {:xqlite_busy, retries, elapsed_ms} -> [{retries, elapsed_ms} | busy_messages()]
    after
      0 -> []
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(answer), do: answer
end
