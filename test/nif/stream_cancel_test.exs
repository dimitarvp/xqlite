defmodule Xqlite.NIF.StreamCancelTest do
  @moduledoc """
  Cancelling a stream through `XqliteNIF.stream_fetch_cancellable/3`.

  A stream hands its cancellation tokens to every fetch it makes. Signalling
  any one of them ends the fetch it lands in with
  `{:error, :operation_cancelled}` and finalizes the underlying statement, so
  the fetch after it is `:done` and closing the stream still answers `:ok`.
  Rows read before the cancel in the same batch are discarded, exactly as any
  mid-batch error discards them.

  The law's subject is a recursive CTE because cancellability follows the
  *shape* of a statement, not its size. SQLite consults the progress callback
  every 8 VM instructions, so a statement whose whole run is cheaper than that
  — `SELECT 1`, a one-row `VALUES`, a PRAGMA read, a scan that finds no row —
  finishes before the first check and cannot be cancelled. A recursive CTE is
  past that line at every depth, including 0, so the assertion can stay
  strict: the very next fetch after the signal is the cancelled one. A plain
  table scan is past the line too, but its rows are so cheap that two or three
  steps fit inside one check interval; that is a latency, not a different
  rule, and one example below pins it.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  # Two thousand runs of the law against each connection mode is far more work
  # than ExUnit's one-minute-per-test default leaves room for on a slow machine.
  @moduletag timeout: 180_000

  @runs 2_000
  @max_size 32
  @max_depth 48
  @max_batch_size 64
  @max_prefetches 3

  @scan_rows 200

  for_each_opener "stream cancellation" do
    property "a signalled token ends the next fetch and closes the stream", %{conn: conn} do
      check all(scenario <- generated_scenario(), max_runs: @runs) do
        run_scenario(conn, scenario)
      end
    end

    test "an empty token list returns the same rows and :done as stream_fetch/2", %{conn: conn} do
      sql = cte_sql(5)

      assert {:ok, plain} = NIF.stream_open(conn, sql, [], [])
      assert {:ok, twin} = NIF.stream_open(conn, sql, [], [])

      assert NIF.stream_fetch(plain, 4) == NIF.stream_fetch_cancellable(twin, 4, [])
      assert NIF.stream_fetch(plain, 4) == NIF.stream_fetch_cancellable(twin, 4, [])
      assert :done == NIF.stream_fetch(plain, 4)
      assert :done == NIF.stream_fetch_cancellable(twin, 4, [])

      assert :ok = NIF.stream_close(plain)
      assert :ok = NIF.stream_close(twin)
    end

    test "an empty token list rejects a bad batch size like stream_fetch/2", %{conn: conn} do
      sql = cte_sql(5)

      assert {:ok, plain} = NIF.stream_open(conn, sql, [], [])
      assert {:ok, twin} = NIF.stream_open(conn, sql, [], [])

      for bad <- [0, -1, :nope, "3"] do
        assert NIF.stream_fetch(plain, bad) == NIF.stream_fetch_cancellable(twin, bad, [])
      end

      assert {:error, {:invalid_batch_size, %{provided: {:integer, 0}, minimum: 1}}} =
               NIF.stream_fetch_cancellable(twin, 0, [])

      assert :ok = NIF.stream_close(plain)
      assert :ok = NIF.stream_close(twin)
    end

    test "a bad batch size is refused even with a signalled token", %{conn: conn} do
      assert {:ok, stream} = NIF.stream_open(conn, cte_sql(5), [], [])
      assert {:ok, token} = NIF.create_cancel_token()
      assert :ok = NIF.cancel_operation(token)

      assert {:error, {:invalid_batch_size, %{provided: {:integer, 0}, minimum: 1}}} =
               NIF.stream_fetch_cancellable(stream, 0, [token])

      # Refusing the batch size left the stream untouched, so it still runs.
      assert {:error, :operation_cancelled} = NIF.stream_fetch_cancellable(stream, 1, [token])
      assert :ok = NIF.stream_close(stream)
    end

    test "an empty token list reports a mid-batch error like stream_fetch/2", %{conn: conn} do
      seed_bad_utf8_table(conn)
      sql = "SELECT v FROM stream_cancel_bad_utf8"

      assert {:ok, plain} = NIF.stream_open(conn, sql, [], [])
      assert {:ok, twin} = NIF.stream_open(conn, sql, [], [])

      plain_result = NIF.stream_fetch(plain, 10)

      assert {:error, {:utf8_error, 0, _}} = plain_result
      assert plain_result == NIF.stream_fetch_cancellable(twin, 10, [])
      assert :done == NIF.stream_fetch(plain, 10)
      assert :done == NIF.stream_fetch_cancellable(twin, 10, [])

      assert :ok = NIF.stream_close(plain)
      assert :ok = NIF.stream_close(twin)
    end

    test "a token signalled before the first fetch cancels that fetch", %{conn: conn} do
      assert {:ok, stream} = NIF.stream_open(conn, cte_sql(200), [], [])
      assert {:ok, token} = NIF.create_cancel_token()
      assert :ok = NIF.cancel_operation(token)

      assert {:error, :operation_cancelled} = NIF.stream_fetch_cancellable(stream, 10, [token])
      assert :ok = NIF.stream_close(stream)
    end

    test "any one signalled token in the list cancels the fetch", %{conn: conn} do
      for count <- [2, 3], position <- 0..(count - 1) do
        assert {:ok, stream} = NIF.stream_open(conn, cte_sql(200), [], [])
        tokens = create_tokens(count)
        signal(tokens, position)

        assert {:error, :operation_cancelled} =
                 NIF.stream_fetch_cancellable(stream, 10, tokens)

        assert :ok = NIF.stream_close(stream)
      end
    end

    test "live tokens that are never signalled do not disturb a stream", %{conn: conn} do
      assert {:ok, stream} = NIF.stream_open(conn, cte_sql(3), [], [])
      tokens = create_tokens(3)

      assert {:ok, %{rows: [[0], [1], [2], [3]]}} =
               NIF.stream_fetch_cancellable(stream, 10, tokens)

      assert :done = NIF.stream_fetch_cancellable(stream, 10, tokens)
      assert :ok = NIF.stream_close(stream)
    end

    test "after a cancel the connection is clean and the token stays spent", %{conn: conn} do
      assert {:ok, stream} = NIF.stream_open(conn, cte_sql(200), [], [])
      assert {:ok, token} = NIF.create_cancel_token()
      assert :ok = NIF.cancel_operation(token)

      assert {:error, :operation_cancelled} = NIF.stream_fetch_cancellable(stream, 10, [token])
      assert :done = NIF.stream_fetch_cancellable(stream, 10, [token])
      assert :ok = NIF.stream_close(stream)

      assert {:ok, %{rows: [[1]]}} = NIF.query(conn, "SELECT 1", [])

      assert {:ok, fresh} = NIF.stream_open(conn, cte_sql(2), [], [])
      assert {:ok, %{rows: [[0], [1], [2]]}} = NIF.stream_fetch_cancellable(fresh, 10, [])
      assert :done = NIF.stream_fetch_cancellable(fresh, 10, [])
      assert :ok = NIF.stream_close(fresh)

      assert {:ok, spent} = NIF.stream_open(conn, cte_sql(200), [], [])
      assert {:error, :operation_cancelled} = NIF.stream_fetch_cancellable(spent, 10, [token])
      assert :ok = NIF.stream_close(spent)
    end

    test "a closed stream answers :done whatever the tokens say", %{conn: conn} do
      assert {:ok, stream} = NIF.stream_open(conn, cte_sql(200), [], [])
      assert :ok = NIF.stream_close(stream)

      assert {:ok, token} = NIF.create_cancel_token()
      assert :ok = NIF.cancel_operation(token)

      assert :done = NIF.stream_fetch_cancellable(stream, 10, [token])
      assert :done = NIF.stream_fetch_cancellable(stream, 10, [])
    end

    test "a fetch after the connection closed keeps reporting :connection_closed", %{
      conn: conn
    } do
      assert {:ok, stream} = NIF.stream_open(conn, cte_sql(200), [], [])
      assert {:ok, token} = NIF.create_cancel_token()
      assert :ok = NIF.cancel_operation(token)
      assert :ok = NIF.close(conn)

      # The connection check runs before any token is registered, so the
      # signalled token never gets a say. Closing the connection finalized
      # this stream, so stream_close/1 afterwards is a no-op `:ok` — and a
      # fetch still reports the closed connection rather than `:done`,
      # because that check comes first.
      assert {:error, :connection_closed} = NIF.stream_fetch_cancellable(stream, 10, [token])
      assert {:error, :connection_closed} = NIF.stream_fetch_cancellable(stream, 10, [token])
      assert {:error, :connection_closed} = NIF.stream_fetch_cancellable(stream, 10, [])

      assert :ok = NIF.stream_close(stream)
      assert {:error, :connection_closed} = NIF.stream_fetch_cancellable(stream, 10, [token])
    end

    test "a cancelled fetch frees the statement it was stepping", %{conn: conn} do
      assert {:ok, token} = NIF.create_cancel_token()
      assert :ok = NIF.cancel_operation(token)

      # stmt_used is BYTES held by prepared statements on this connection, not
      # a count, so it only reads as a leak check while nothing else on the
      # connection is outstanding.
      assert {:ok, %{stmt_used: before_open}} = NIF.connection_stats(conn)

      assert {:ok, stream} = NIF.stream_open(conn, cte_sql(200), [], [])
      assert {:ok, %{stmt_used: while_open}} = NIF.connection_stats(conn)
      assert while_open > before_open

      assert {:error, :operation_cancelled} = NIF.stream_fetch_cancellable(stream, 10, [token])
      assert {:ok, %{stmt_used: ^before_open}} = NIF.connection_stats(conn)

      assert :ok = NIF.stream_close(stream)
      assert {:ok, %{stmt_used: ^before_open}} = NIF.connection_stats(conn)
    end

    test "a table scan reports the cancel within three single-row fetches", %{conn: conn} do
      seed_scan_table(conn)

      assert {:ok, stream} =
               NIF.stream_open(conn, "SELECT id FROM stream_cancel_scan ORDER BY id", [], [])

      assert {:ok, token} = NIF.create_cancel_token()
      assert {:ok, %{rows: [[1]]}} = NIF.stream_fetch_cancellable(stream, 1, [token])
      assert :ok = NIF.cancel_operation(token)

      # A scanned row is about three VM instructions, and the progress
      # callback fires every eight, so up to two more single-row fetches can
      # be served before the check comes round. Nothing here is timing based:
      # the instruction count is deterministic.
      results = for _ <- 1..3, do: NIF.stream_fetch_cancellable(stream, 1, [token])
      assert {:error, :operation_cancelled} in results

      assert :ok = NIF.stream_close(stream)
    end
  end

  # Deliberately a single hardcoded in-memory connection instead of the
  # connection_openers/0 loop: cancellation from another process is
  # timing-sensitive and connection-mode-agnostic, so looping openers would
  # only multiply the flake surface.
  test "isolated: a token signalled from another process cancels a running fetch" do
    {:ok, conn} = Xqlite.open_in_memory()
    on_exit(fn -> NIF.close(conn) end)

    # The recursion bound is a never-reached ceiling: the cancel arrives about
    # 30 ms in and no runner counts to a billion first. If cancellation ever
    # breaks, this fails loudly via the ExUnit timeout rather than quietly
    # completing.
    sql =
      "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<1000000000) " <>
        "SELECT count(*) FROM n"

    {:ok, stream} = NIF.stream_open(conn, sql, [], [])
    {:ok, token} = NIF.create_cancel_token()

    spawn(fn ->
      Process.sleep(30)
      :ok = NIF.cancel_operation(token)
    end)

    assert {:error, :operation_cancelled} = NIF.stream_fetch_cancellable(stream, 1, [token])
    assert :done = NIF.stream_fetch_cancellable(stream, 1, [token])
    assert :ok = NIF.stream_close(stream)
  end

  # ---------------------------------------------------------------------
  # The law
  # ---------------------------------------------------------------------

  defp run_scenario(conn, scenario) do
    sql = cte_sql(scenario.depth)
    tokens = create_tokens(scenario.token_count)
    assert {:ok, stream} = NIF.stream_open(conn, sql, [], [])

    case scenario.cancel_point do
      :never -> assert_drains_like_a_query(conn, stream, sql, tokens, scenario)
      :before_first_fetch -> assert_cancelled_next(stream, tokens, scenario)
      {:after_fetches, k} -> assert_cancelled_after(stream, tokens, scenario, k)
    end

    assert :ok = NIF.stream_close(stream)
  end

  defp assert_drains_like_a_query(conn, stream, sql, tokens, scenario) do
    rows = drain(stream, scenario.batch_size, tokens, [])
    assert {:ok, %{rows: expected}} = NIF.query(conn, sql, [])
    assert rows == expected
  end

  defp assert_cancelled_after(stream, tokens, scenario, k) do
    fetch_times(stream, scenario.batch_size, tokens, safe_prefetches(scenario, k))
    assert_cancelled_next(stream, tokens, scenario)
  end

  defp assert_cancelled_next(stream, tokens, scenario) do
    signal(tokens, scenario.signal_index)

    assert {:error, :operation_cancelled} =
             NIF.stream_fetch_cancellable(stream, scenario.batch_size, tokens)

    assert :done = NIF.stream_fetch_cancellable(stream, scenario.batch_size, tokens)
  end

  # A fetch that reads its last row also finalizes the statement, and says so
  # only on the fetch after it, so the count of pre-fetches is capped at what
  # provably leaves at least one row unread: k batches consume k * batch_size
  # of the depth + 1 rows.
  defp safe_prefetches(scenario, k) do
    min(k, div(scenario.depth, scenario.batch_size))
  end

  defp drain(stream, batch_size, tokens, acc) do
    case NIF.stream_fetch_cancellable(stream, batch_size, tokens) do
      {:ok, %{rows: rows}} -> drain(stream, batch_size, tokens, acc ++ rows)
      :done -> acc
      other -> flunk("unexpected fetch result while draining: #{inspect(other)}")
    end
  end

  defp fetch_times(_stream, _batch_size, _tokens, 0), do: :ok

  defp fetch_times(stream, batch_size, tokens, count) do
    case NIF.stream_fetch_cancellable(stream, batch_size, tokens) do
      {:ok, %{rows: _rows}} -> fetch_times(stream, batch_size, tokens, count - 1)
      other -> flunk("unexpected fetch result before the signal: #{inspect(other)}")
    end
  end

  defp generated_scenario do
    StreamData.scale(scenario_data(), fn size -> min(size, @max_size) end)
  end

  defp scenario_data do
    gen all(
          depth <- StreamData.integer(0..@max_depth),
          batch_size <- StreamData.integer(1..@max_batch_size),
          token_count <- StreamData.integer(1..3),
          signal_slot <- StreamData.integer(0..2),
          cancel_point <- cancel_point_data()
        ) do
      %{
        depth: depth,
        batch_size: batch_size,
        token_count: token_count,
        signal_index: rem(signal_slot, token_count),
        cancel_point: cancel_point
      }
    end
  end

  defp cancel_point_data do
    StreamData.one_of([
      StreamData.constant(:before_first_fetch),
      StreamData.map(StreamData.integer(1..@max_prefetches), &{:after_fetches, &1}),
      StreamData.constant(:never)
    ])
  end

  # ---------------------------------------------------------------------
  # Subjects and helpers
  # ---------------------------------------------------------------------

  # Yields depth + 1 rows, 0 through depth, and costs more than one progress
  # interval on its very first step at every depth.
  defp cte_sql(depth) do
    "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<#{depth}) " <>
      "SELECT x FROM n"
  end

  defp create_tokens(count) do
    for _ <- 1..count do
      assert {:ok, token} = NIF.create_cancel_token()
      token
    end
  end

  defp signal(tokens, index) do
    token = Enum.at(tokens, index)
    assert :ok = NIF.cancel_operation(token)
  end

  defp seed_scan_table(conn) do
    assert :ok =
             NIF.execute_batch(
               conn,
               "CREATE TABLE stream_cancel_scan (id INTEGER PRIMARY KEY);"
             )

    values = Enum.map_join(1..@scan_rows, ",", fn i -> "(#{i})" end)
    sql = "INSERT INTO stream_cancel_scan VALUES #{values}"

    assert {:ok, @scan_rows} = NIF.execute(conn, sql, [])
  end

  defp seed_bad_utf8_table(conn) do
    assert :ok =
             NIF.execute_batch(
               conn,
               "CREATE TABLE stream_cancel_bad_utf8 (v TEXT);" <>
                 "INSERT INTO stream_cancel_bad_utf8 VALUES (CAST(X'FFFE8041' AS TEXT));"
             )
  end
end
