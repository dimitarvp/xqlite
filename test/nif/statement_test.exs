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

    test "step reads non-finite floats as sentinel atoms", %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT 1e308 * 10.0, -1e308 * 10.0")
      assert {:row, [:positive_infinity, :negative_infinity]} = Xqlite.step(stmt)
      assert :done = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

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

    test "rebinding a statement mid-run is rejected until reset", %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
      :ok = Xqlite.bind(stmt, [1])
      assert {:row, [1]} = Xqlite.step(stmt)

      assert {:error, :statement_mid_run} = Xqlite.bind(stmt, [2])

      assert :ok = Xqlite.reset(stmt)
      assert :ok = Xqlite.bind(stmt, [2])
      assert {:row, [2]} = Xqlite.step(stmt)

      assert :ok = Xqlite.finalize(stmt)
    end

    test "a bind refused mid-run takes no value and retires nothing", %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
      :ok = Xqlite.bind(stmt, [1])

      assert {:row, [1]} = Xqlite.step(stmt)
      assert {:error, :statement_mid_run} = Xqlite.bind(stmt, [2])
      assert {:error, :statement_mid_run} = Xqlite.bind(stmt, [2, 3])
      assert :ok = Xqlite.reset(stmt)
      assert {:row, [1]} = Xqlite.step(stmt)

      assert :done = Xqlite.step(stmt)
      assert :ok = Xqlite.bind(stmt, [3])
      assert {:ok, %{rows: [[3]], done: false}} = Xqlite.multi_step(stmt, 1)

      assert :ok = Xqlite.finalize(stmt)
    end

    test "a keyword bind refused mid-run takes no value either", %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT :a, :b")
      :ok = Xqlite.bind(stmt, a: 1, b: 2)

      assert {:ok, %{rows: [[1, 2]], done: false}} = Xqlite.multi_step(stmt, 1)
      assert {:error, :statement_mid_run} = Xqlite.bind(stmt, a: 3, b: 4)
      assert :ok = Xqlite.reset(stmt)
      assert {:row, [1, 2]} = Xqlite.step(stmt)

      assert :ok = Xqlite.finalize(stmt)
    end

    test "a clear mid-run is refused and the rest of the run keeps its value",
         %{conn: conn} do
      seed(conn, 3)
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT id, ?1 FROM items ORDER BY id")
      :ok = Xqlite.bind(stmt, ["P"])

      assert {:row, [1, "P"]} = Xqlite.step(stmt)
      assert {:error, :statement_mid_run} = Xqlite.clear_bindings(stmt)
      assert {:row, [2, "P"]} = Xqlite.step(stmt)

      assert :ok = Xqlite.reset(stmt)
      assert :ok = Xqlite.clear_bindings(stmt)
      assert {:row, [1, nil]} = Xqlite.step(stmt)

      assert :ok = Xqlite.finalize(stmt)
    end

    test "a clear mid-run on a statement that takes no parameters changes nothing",
         %{conn: conn} do
      seed(conn, 3)
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT id FROM items ORDER BY id")

      assert {:row, [1]} = Xqlite.step(stmt)
      assert :ok = Xqlite.clear_bindings(stmt)
      assert :ok = Xqlite.bind(stmt, [])
      assert {:row, [2]} = Xqlite.step(stmt)

      assert :ok = Xqlite.finalize(stmt)
    end

    test "after :done a bind takes new values and a clear takes NULLs", %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
      :ok = Xqlite.bind(stmt, [1])

      assert {:row, [1]} = Xqlite.step(stmt)
      assert :done = Xqlite.step(stmt)

      assert :ok = Xqlite.bind(stmt, [2])
      assert {:row, [2]} = Xqlite.step(stmt)
      assert :done = Xqlite.step(stmt)
      assert :ok = Xqlite.clear_bindings(stmt)
      assert {:row, [nil]} = Xqlite.step(stmt)

      assert :ok = Xqlite.finalize(stmt)
    end

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

    test "a keyword list that leaves a parameter out binds nothing", %{conn: conn} do
      :ok =
        NIF.execute_batch(conn, """
        CREATE TABLE pairs (id INTEGER PRIMARY KEY, a TEXT, b TEXT);
        INSERT INTO pairs (id, a, b) VALUES (1, 'keep_a', 'keep_b');
        """)

      sql = "UPDATE pairs SET a = :a, b = :b WHERE id = 1"
      {:ok, stmt} = NIF.stmt_prepare(conn, sql)
      params = [a: "x"]

      assert {:error, {:missing_parameter, %{index: 2, name: ":b"}}} =
               NIF.stmt_bind(stmt, params)

      assert :ok = NIF.stmt_finalize(stmt)

      assert {:ok, %{rows: [["keep_a", "keep_b"]]}} =
               NIF.query(conn, "SELECT a, b FROM pairs WHERE id = 1", [])
    end

    test "two partial keyword binds do not add up", %{conn: conn} do
      {:ok, stmt} = NIF.stmt_prepare(conn, "SELECT :a + :b")
      first = [a: 1]

      assert {:error, {:missing_parameter, %{index: 2, name: ":b"}}} =
               NIF.stmt_bind(stmt, first)

      whole = [a: 1, b: 2]
      assert :ok = NIF.stmt_bind(stmt, whole)
      assert {:row, [3]} = NIF.stmt_step(stmt)
      assert :ok = NIF.stmt_finalize(stmt)
    end

    test "positional bind with the wrong count is a structured error", %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1, ?2")

      assert {:error, {:invalid_parameter_count, %{provided: 1, expected: 2}}} =
               Xqlite.bind(stmt, [1])

      assert {:error, {:invalid_parameter_count, %{provided: 3, expected: 2}}} =
               Xqlite.bind(stmt, [1, 2, 3])

      assert :ok = Xqlite.finalize(stmt)
    end

    # An empty list used to bind nothing at all and answer `:ok`, so the
    # statement ran with NULL in every parameter. The stored rows are the
    # oracle: they are untouched, because the bind was refused.
    test "an empty or nil parameter list on a parameterised statement is refused",
         %{conn: conn} do
      seed(conn, 2)
      {:ok, stmt} = Xqlite.prepare(conn, "UPDATE items SET label = ?1")

      assert {:error, {:invalid_parameter_count, %{provided: 0, expected: 1}}} =
               Xqlite.bind(stmt, [])

      assert {:error, {:invalid_parameter_count, %{provided: 0, expected: 1}}} =
               NIF.stmt_bind(stmt, nil)

      assert :ok = Xqlite.finalize(stmt)

      assert {:ok, %{rows: [["v1"], ["v2"]]}} =
               Xqlite.query(conn, "SELECT label FROM items ORDER BY id", [])
    end

    test "prepare rejects empty, comment-only, and multi-statement SQL", %{conn: conn} do
      assert {:error, :no_statement} = Xqlite.prepare(conn, "   \n\t  ")
      assert {:error, :no_statement} = Xqlite.prepare(conn, "-- just a comment")
      assert {:error, :multiple_statements} = Xqlite.prepare(conn, "SELECT 1; SELECT 2")
    end

    test "prepare reports a syntax error with the offending SQL and byte offset", %{conn: conn} do
      assert {:error, {:sql_input_error, %{code: 1, sql: "SELCT 1", offset: 0}}} =
               Xqlite.prepare(conn, "SELCT 1")
    end

    test "prepare and query/3 classify rejected SQL identically", %{conn: conn} do
      for sql <- [
            "SELCT 1",
            "SELECT * FROM no_such_table_xyz",
            "SELECT nope FROM sqlite_master"
          ] do
        assert {:error, query_reason} = NIF.query(conn, sql, [])
        assert {:error, ^query_reason} = Xqlite.prepare(conn, sql)
      end
    end

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

    test "stepping before any bind is refused", %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
      assert {:error, {:parameters_unbound, %{expected: 1}}} = Xqlite.step(stmt)
      assert {:error, {:parameters_unbound, %{expected: 1}}} = Xqlite.multi_step(stmt, 2)

      assert {:error, {:parameters_unbound, %{expected: 1}}} =
               Xqlite.multi_step_cancellable(stmt, 2, [])

      assert :ok = Xqlite.finalize(stmt)
    end

    test "a refused bind leaves nothing to run", %{conn: conn} do
      seed(conn, 2)
      {:ok, stmt} = Xqlite.prepare(conn, "UPDATE items SET label = ?1")

      assert {:error, {:unsupported_data_type, :tuple}} = Xqlite.bind(stmt, [{:no}])
      assert {:error, {:parameters_unbound, %{expected: 1}}} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)

      assert {:ok, %{rows: [["v1"], ["v2"]]}} =
               Xqlite.query(conn, "SELECT label FROM items ORDER BY id", [])
    end

    test "a value over the connection's length limit binds nothing", %{conn: conn} do
      assert {:ok, _in_force} = Xqlite.put_limit(conn, :length, 64)
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1, ?2")

      assert :ok = Xqlite.bind(stmt, [1, "first"])

      assert {:error, {:value_too_large, %{byte_size: 65, limit: 64}}} =
               Xqlite.bind(stmt, [2, String.duplicate("x", 65)])

      assert {:row, [1, "first"]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "a keyword list over the length limit binds nothing either", %{conn: conn} do
      assert {:ok, _in_force} = Xqlite.put_limit(conn, :length, 64)
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT :a, :b")

      assert :ok = Xqlite.bind(stmt, a: 1, b: "first")

      assert {:error, {:value_too_large, %{byte_size: 65, limit: 64}}} =
               Xqlite.bind(stmt, a: 2, b: String.duplicate("x", 65))

      assert {:row, [1, "first"]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "a value of exactly the length limit binds", %{conn: conn} do
      assert {:ok, _in_force} = Xqlite.put_limit(conn, :length, 64)
      at_the_limit = String.duplicate("x", 64)
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1, ?2")

      assert :ok = Xqlite.bind(stmt, [1, at_the_limit])
      assert {:row, [1, ^at_the_limit]} = Xqlite.step(stmt)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "a row longer than the limit is SQLite's own refusal at the step", %{conn: conn} do
      assert {:ok, _in_force} = Xqlite.put_limit(conn, :length, 30)
      {:ok, stmt} = Xqlite.prepare(conn, "INSERT INTO items (label) VALUES (?1)")

      assert :ok = Xqlite.bind(stmt, [String.duplicate("x", 20)])
      assert :done = Xqlite.step(stmt)
      assert :ok = Xqlite.reset(stmt)

      assert :ok = Xqlite.bind(stmt, [String.duplicate("x", 28)])
      assert {:error, {:too_big, 18, message}} = Xqlite.step(stmt)
      assert is_binary(message)
      assert :ok = Xqlite.finalize(stmt)
    end

    test "a lowered length limit does not hide a statement", %{conn: conn} do
      assert {:ok, _in_force} = Xqlite.put_limit(conn, :length, 30)
      # Longer than the limit, so the expansion SQLite can hand back for it is
      # capped away — which must not read as "this text holds no statement".
      sql = "DELETE FROM items WHERE label = 'no such label'"
      assert byte_size(sql) > 30

      assert {:ok, %{num_rows: 0}} = Xqlite.query(conn, sql, [])
      assert {:error, :no_statement} = Xqlite.query(conn, "-- just a comment", [])
    end

    test "a lowered length limit does not hide a read-only statement", %{conn: conn} do
      assert {:ok, _in_force} = Xqlite.put_limit(conn, :length, 30)
      name = String.duplicate("s", 40)
      comment = " -- " <> String.duplicate("c", 60)

      assert {:ok, _savepoint} = Xqlite.execute(conn, "SAVEPOINT #{name}", [])
      assert {:ok, _rollback_to} = Xqlite.execute(conn, "ROLLBACK TO #{name}", [])
      assert {:ok, _release} = Xqlite.execute(conn, "RELEASE #{name}", [])
      assert {:ok, _begin} = Xqlite.execute(conn, "BEGIN" <> comment, [])
      assert {:ok, _rollback} = Xqlite.execute(conn, "ROLLBACK", [])
      assert {:ok, _pragma} = Xqlite.execute(conn, "PRAGMA foreign_keys=ON" <> comment, [])
    end

    test "a comment-only text holds no statement at any limit or door", %{conn: conn} do
      long_comment = "-- " <> String.duplicate("c", 60)

      assert {:error, :no_statement} = Xqlite.query(conn, long_comment, [])
      assert {:error, :no_statement} = Xqlite.execute(conn, long_comment, [])
      assert {:error, :no_statement} = Xqlite.prepare(conn, long_comment)

      assert {:ok, _in_force} = Xqlite.put_limit(conn, :length, 30)

      assert {:error, :no_statement} = Xqlite.query(conn, long_comment, [])
      assert {:error, :no_statement} = Xqlite.execute(conn, long_comment, [])
      assert {:error, :no_statement} = Xqlite.prepare(conn, long_comment)
    end

    test "the batch doors judge the batch size before anything else", %{conn: conn} do
      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")
      {:ok, token} = Xqlite.create_cancel_token()

      assert {:error, {:invalid_batch_size, %{provided: 0, minimum: 1}}} =
               Xqlite.multi_step(stmt, 0)

      assert {:error, {:invalid_batch_size, %{provided: 0, minimum: 1}}} =
               Xqlite.multi_step_cancellable(stmt, 0, [token])

      assert {:error, {:parameters_unbound, %{expected: 1}}} = Xqlite.multi_step(stmt, 1)

      assert {:error, {:parameters_unbound, %{expected: 1}}} =
               Xqlite.multi_step_cancellable(stmt, 1, [token])

      assert :ok = Xqlite.finalize(stmt)

      assert {:error, {:invalid_batch_size, %{provided: 0, minimum: 1}}} =
               Xqlite.multi_step(stmt, 0)

      assert {:error, :statement_finalized} = Xqlite.multi_step(stmt, 1)
    end

    test "a closed connection is reported before an unbound statement", %{conn: conn} do
      {:ok, other} = Xqlite.open_in_memory()
      {:ok, stmt} = Xqlite.prepare(other, "SELECT ?1")

      assert :ok = Xqlite.close(other)
      assert {:error, :connection_closed} = Xqlite.step(stmt)
      assert {:error, :connection_closed} = Xqlite.multi_step(stmt, 2)
      assert :ok = Xqlite.finalize(stmt)

      assert {:ok, %{rows: [[1]]}} = Xqlite.query(conn, "SELECT 1", [])
    end

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

  test "statement ops after connection close: closed error, cached names, finalize :ok" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    {:ok, stmt} = Xqlite.prepare(conn, "SELECT 1 AS one")
    :ok = NIF.close(conn)

    assert {:error, :connection_closed} = Xqlite.step(stmt)
    assert {:error, :connection_closed} = Xqlite.bind(stmt, [1])
    assert {:ok, ["one"]} = Xqlite.column_names(stmt)
    assert :ok = Xqlite.finalize(stmt)
  end

  test "a step refused as busy keeps its run: a bind waits and the retry writes once" do
    path = Xqlite.TestUtil.tmp_db_path("busy_step")
    {:ok, holder} = Xqlite.open(path)
    {:ok, conn} = Xqlite.open(path, busy_timeout: 0)
    on_exit(fn -> Enum.each([conn, holder], &NIF.close/1) end)

    :ok = NIF.execute_batch(holder, "CREATE TABLE t (v TEXT);")
    {:ok, stmt} = Xqlite.prepare(conn, "INSERT INTO t (v) VALUES (?1)")
    :ok = Xqlite.bind(stmt, ["x"])
    :ok = NIF.execute_batch(holder, "BEGIN IMMEDIATE;")

    assert {:error, {:database_busy_or_locked, _code, _message}} = Xqlite.step(stmt)
    assert {:error, :statement_mid_run} = Xqlite.bind(stmt, ["y"])
    assert {:error, :statement_mid_run} = Xqlite.clear_bindings(stmt)

    :ok = NIF.execute_batch(holder, "COMMIT;")
    assert :done = Xqlite.step(stmt)
    assert :ok = Xqlite.finalize(stmt)
    assert {:ok, %{rows: [["x"]]}} = Xqlite.query(holder, "SELECT v FROM t", [])
  end

  test "text params with interior NUL bytes bind and round-trip" do
    {:ok, conn} = Xqlite.open_in_memory()
    on_exit(fn -> NIF.close(conn) end)
    :ok = NIF.execute_batch(conn, "CREATE TABLE nuls (v ANY);")

    payload = <<1, 0, 2, 0, 3>>
    {:ok, stmt} = Xqlite.prepare(conn, "INSERT INTO nuls (v) VALUES (?1)")
    :ok = Xqlite.bind(stmt, [payload])
    :done = Xqlite.step(stmt)
    :ok = Xqlite.finalize(stmt)

    assert {:ok, %Xqlite.Result{rows: [[^payload]]}} =
             Xqlite.query(conn, "SELECT v FROM nuls", [])
  end

  test "SELECT * through a live statement re-expands after ALTER TABLE" do
    {:ok, conn} = Xqlite.open_in_memory()
    on_exit(fn -> NIF.close(conn) end)

    :ok =
      NIF.execute_batch(conn, "CREATE TABLE widen (a INTEGER); INSERT INTO widen VALUES (1);")

    {:ok, stmt} = Xqlite.prepare(conn, "SELECT * FROM widen")
    assert {:row, [1]} = Xqlite.step(stmt)
    :ok = Xqlite.reset(stmt)

    {:ok, _} = NIF.execute(conn, "ALTER TABLE widen ADD COLUMN b TEXT", [])

    # sqlite3_step's v2 auto-reprepare re-expands the star; both the row
    # width and the live column names must reflect the new schema.
    assert {:row, [1, nil]} = Xqlite.step(stmt)
    assert {:ok, ["a", "b"]} = Xqlite.column_names(stmt)
    :ok = Xqlite.finalize(stmt)
  end

  defp seed(conn, n) do
    values = Enum.map_join(1..n, ", ", fn i -> "(#{i}, 'v#{i}')" end)
    :ok = NIF.execute_batch(conn, "INSERT INTO items (id, label) VALUES #{values};")
  end
end
