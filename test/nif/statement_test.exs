defmodule Xqlite.NIF.StatementTest do
  use ExUnit.Case, async: true

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  for_each_opener "statement" do
    setup %{conn: conn} do
      :ok =
        NIF.execute_batch(conn, "CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT);")

      :ok
    end

    # -------------------------------------------------------------------
    # Happy lifecycle
    # -------------------------------------------------------------------

    test "prepared INSERT loop then step SELECT to :done", %{conn: conn} do
      {:ok, insert} = Xqlite.prepare(conn, "INSERT INTO items (id, label) VALUES (?1, ?2)")

      results =
        for id <- 1..3 do
          :ok = Xqlite.bind(insert, [id, "v#{id}"])
          assert :done = Xqlite.step(insert)
          Xqlite.reset(insert)
        end

      assert results == [:ok, :ok, :ok]
      assert :ok = Xqlite.finalize(insert)

      {:ok, select} = Xqlite.prepare(conn, "SELECT id, label FROM items ORDER BY id")

      assert {:row, [1, "v1"]} = Xqlite.step(select)
      assert {:row, [2, "v2"]} = Xqlite.step(select)
      assert {:row, [3, "v3"]} = Xqlite.step(select)
      assert :done = Xqlite.step(select)
      assert :ok = Xqlite.finalize(select)
    end

    # -------------------------------------------------------------------
    # multi_step batching
    # -------------------------------------------------------------------

    test "multi_step batches rows and re-runs after :done", %{conn: conn} do
      seed(conn, 5)
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT id FROM items ORDER BY id")

      assert {:ok, %{rows: [[1], [2]], done: false}} = Xqlite.multi_step(stmt, 2)
      assert {:ok, %{rows: [[3], [4]], done: false}} = Xqlite.multi_step(stmt, 2)
      assert {:ok, %{rows: [[5]], done: true}} = Xqlite.multi_step(stmt, 2)

      # SQLite auto-resets a v2-prepared statement when it is stepped past
      # SQLITE_DONE, so a further batch replays the query from the top rather
      # than reporting an empty, done batch. Pinning the REAL behavior here.
      assert {:ok, %{rows: [[1], [2]], done: false}} = Xqlite.multi_step(stmt, 2)

      assert :ok = Xqlite.finalize(stmt)
    end

    test "multi_step rejects a batch size below one", %{conn: conn} do
      seed(conn, 3)
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT id FROM items ORDER BY id")

      assert {:error, {:invalid_batch_size, %{provided: 0, minimum: 1}}} =
               Xqlite.multi_step(stmt, 0)

      assert {:error, {:invalid_batch_size, %{provided: -3, minimum: 1}}} =
               Xqlite.multi_step(stmt, -3)

      assert :ok = Xqlite.finalize(stmt)
    end

    # -------------------------------------------------------------------
    # Partial consumption and early finalize
    # -------------------------------------------------------------------

    test "partial consumption then early finalize leaves the connection usable",
         %{conn: conn} do
      seed(conn, 5)
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT id FROM items ORDER BY id")

      assert {:row, [1]} = Xqlite.step(stmt)
      assert {:row, [2]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)

      assert {:ok, %{rows: [[5]], num_rows: 1}} =
               NIF.query(conn, "SELECT COUNT(*) FROM items", [])
    end

    # -------------------------------------------------------------------
    # reset / clear_bindings
    # -------------------------------------------------------------------

    test "reset preserves bindings; clear_bindings drops them to NULL", %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
      :ok = Xqlite.bind(stmt, [1])

      assert {:row, [1]} = Xqlite.step(stmt)
      assert :ok = Xqlite.reset(stmt)
      assert {:row, [1]} = Xqlite.step(stmt)

      assert :ok = Xqlite.reset(stmt)
      assert :ok = Xqlite.clear_bindings(stmt)
      assert {:row, [nil]} = Xqlite.step(stmt)

      assert :ok = Xqlite.finalize(stmt)
    end

    test "rebinding a stepped statement is rejected until reset", %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
      :ok = Xqlite.bind(stmt, [1])
      assert {:row, [1]} = Xqlite.step(stmt)

      assert {:error, {:sqlite_failure, code, _extended, _message}} = Xqlite.bind(stmt, [2])
      assert is_integer(code)

      assert :ok = Xqlite.reset(stmt)
      assert :ok = Xqlite.bind(stmt, [2])
      assert {:row, [2]} = Xqlite.step(stmt)

      assert :ok = Xqlite.finalize(stmt)
    end

    # -------------------------------------------------------------------
    # Named parameters
    # -------------------------------------------------------------------

    test "named parameters bind by keyword; unknown name is structured", %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT :a + :b")
      :ok = Xqlite.bind(stmt, a: 2, b: 3)
      assert {:row, [5]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)

      {:ok, other} = Xqlite.prepare(conn, "SELECT :a + :b")
      assert {:error, {:invalid_parameter_name, name}} = Xqlite.bind(other, z: 1)
      assert is_binary(name)
      assert :ok = Xqlite.finalize(other)
    end

    # -------------------------------------------------------------------
    # Positional count mismatch
    # -------------------------------------------------------------------

    test "positional bind with the wrong count is a structured error", %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1, ?2")

      assert {:error, {:invalid_parameter_count, %{provided: 1, expected: 2}}} =
               Xqlite.bind(stmt, [1])

      assert {:error, {:invalid_parameter_count, %{provided: 3, expected: 2}}} =
               Xqlite.bind(stmt, [1, 2, 3])

      assert :ok = Xqlite.finalize(stmt)
    end

    # -------------------------------------------------------------------
    # prepare rejections
    # -------------------------------------------------------------------

    test "prepare rejects empty, comment-only, and multi-statement SQL", %{conn: conn} do
      assert {:error, {:cannot_execute, whitespace_reason}} =
               Xqlite.prepare(conn, "   \n\t  ")

      assert is_binary(whitespace_reason)

      assert {:error, {:cannot_execute, comment_reason}} =
               Xqlite.prepare(conn, "-- just a comment")

      assert is_binary(comment_reason)

      assert {:error, :multiple_statements} = Xqlite.prepare(conn, "SELECT 1; SELECT 2")
    end

    # -------------------------------------------------------------------
    # Use-after-finalize
    # -------------------------------------------------------------------

    test "operations after finalize report :statement_finalized; names stay cached",
         %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1 AS only_col")
      assert :ok = Xqlite.finalize(stmt)

      assert {:error, :statement_finalized} = Xqlite.bind(stmt, [1])
      assert {:error, :statement_finalized} = Xqlite.step(stmt)
      assert {:error, :statement_finalized} = Xqlite.reset(stmt)
      assert {:error, :statement_finalized} = Xqlite.multi_step(stmt, 2)
      assert {:error, :statement_finalized} = Xqlite.clear_bindings(stmt)

      assert {:ok, ["only_col"]} = Xqlite.column_names(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    # -------------------------------------------------------------------
    # step before bind
    # -------------------------------------------------------------------

    test "stepping before any bind runs with NULL parameters", %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
      assert {:row, [nil]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    # -------------------------------------------------------------------
    # GC finalization of an abandoned statement
    # -------------------------------------------------------------------

    test "a statement abandoned by a dead process never wedges the connection",
         %{conn: conn} do
      seed(conn, 3)

      {pid, ref} =
        spawn_monitor(fn ->
          {:ok, _stmt} = Xqlite.prepare(conn, "SELECT id FROM items")
          :ok
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000

      :erlang.garbage_collect()
      Process.sleep(50)

      assert {:ok, %{rows: [[3]], num_rows: 1}} =
               NIF.query(conn, "SELECT COUNT(*) FROM items", [])
    end

    # -------------------------------------------------------------------
    # Concurrent stepping (safety, not determinism)
    # -------------------------------------------------------------------

    test "concurrent stepping of one statement is crash-free and drops no rows",
         %{conn: conn} do
      seed(conn, 40)
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT id FROM items ORDER BY id")

      collect = fn ->
        Stream.repeatedly(fn -> Xqlite.step(stmt) end)
        |> Enum.reduce_while([], fn
          {:row, [id]}, acc -> {:cont, [id | acc]}
          :done, acc -> {:halt, acc}
          other, acc -> {:halt, [{:unexpected, other} | acc]}
        end)
      end

      task1 = Task.async(collect)
      task2 = Task.async(collect)
      ids1 = Task.await(task1, 5_000)
      ids2 = Task.await(task2, 5_000)

      combined = ids1 ++ ids2

      refute Enum.any?(combined, &match?({:unexpected, _}, &1))
      assert combined |> Enum.uniq() |> Enum.sort() == Enum.to_list(1..40)

      assert :ok = Xqlite.finalize(stmt)
    end
  end

  # -------------------------------------------------------------------
  # Edge case unrelated to connection mode
  # -------------------------------------------------------------------

  test "statement ops after connection close: closed error, cached names, finalize :ok" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    {:ok, stmt} = Xqlite.prepare(conn, "SELECT 1 AS one")
    :ok = NIF.close(conn)

    assert {:error, :connection_closed} = Xqlite.step(stmt)
    assert {:error, :connection_closed} = Xqlite.bind(stmt, [1])
    assert {:ok, ["one"]} = Xqlite.column_names(stmt)
    assert :ok = Xqlite.finalize(stmt)
  end

  defp seed(conn, n) do
    values = Enum.map_join(1..n, ", ", fn i -> "(#{i}, 'v#{i}')" end)
    :ok = NIF.execute_batch(conn, "INSERT INTO items (id, label) VALUES #{values};")
  end
end
