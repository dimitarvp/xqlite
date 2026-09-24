defmodule XqliteTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Xqlite.Telemetry.TestSupport, only: [attach_capture: 1, detach: 1]

  alias Xqlite.TestUtil
  alias XqliteNIF, as: NIF

  doctest Xqlite

  @record_count 20

  # A recursive CTE costs far more than one progress-callback interval on its
  # very first step, so a signalled token cancels the first fetch with no rows
  # delivered — unlike a plain scan, whose rows are cheap enough that a couple
  # can slip through before the check comes round.
  @cancel_subject "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<200) SELECT x FROM n"

  for {type_tag, prefix, _opener_mfa} <- TestUtil.connection_openers() do
    describe "Xqlite.stream/4 using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = TestUtil.find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        assert :ok =
                 NIF.execute_batch(
                   conn,
                   "CREATE TABLE stream_test_users (id INTEGER PRIMARY KEY, name TEXT, email TEXT);"
                 )

        for i <- 1..@record_count do
          assert {:ok, 1} =
                   NIF.execute(
                     conn,
                     "INSERT INTO stream_test_users (id, name, email) VALUES (?1, ?2, ?3);",
                     [i, "User #{i}", "user#{i}@example.com"]
                   )
        end

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "streams all results as a list of maps", %{conn: conn} do
        stream = Xqlite.stream(conn, "SELECT id, name FROM stream_test_users ORDER BY id;")

        assert Enumerable.impl_for(stream) != nil

        results = Enum.to_list(stream)

        assert length(results) == @record_count
        assert List.first(results) == %{"id" => 1, "name" => "User 1"}

        assert List.last(results) == %{
                 "id" => @record_count,
                 "name" => "User #{@record_count}"
               }
      end

      test "streams correctly with a small batch size", %{conn: conn} do
        # Batch size of 5 means it will take 4 batches to consume 20 records.
        stream =
          Xqlite.stream(conn, "SELECT id FROM stream_test_users ORDER BY id;", [],
            batch_size: 5
          )

        results = Enum.map(stream, & &1["id"])

        assert results == Enum.to_list(1..@record_count)
      end

      test "streams an empty result set correctly", %{conn: conn} do
        stream = Xqlite.stream(conn, "SELECT id FROM stream_test_users WHERE id < 0;")
        assert Enum.to_list(stream) == []
      end

      test "streams with positional parameters", %{conn: conn} do
        stream =
          Xqlite.stream(
            conn,
            "SELECT name FROM stream_test_users WHERE id > ?1 ORDER BY id;",
            [
              @record_count - 2
            ]
          )

        results = Enum.to_list(stream)

        assert results == [
                 %{"name" => "User #{@record_count - 1}"},
                 %{"name" => "User #{@record_count}"}
               ]
      end

      test "streams with named parameters", %{conn: conn} do
        stream =
          Xqlite.stream(conn, "SELECT name FROM stream_test_users WHERE email = :email;",
            email: "user3@example.com"
          )

        results = Enum.to_list(stream)
        assert results == [%{"name" => "User 3"}]
      end

      test "returns an error tuple for invalid SQL", %{conn: conn} do
        # This tests the `case start_fun` logic in Xqlite.stream/4
        sql = "SELEKT * FROM stream_test_users;"
        result = Xqlite.stream(conn, sql)

        assert {:error, {:sql_input_error, %{code: 1, sql: ^sql, offset: 0}}} = result
      end

      test "stream/4 refuses SQL that holds no statement", %{conn: conn} do
        assert {:error, {:cannot_execute, reason}} = Xqlite.stream(conn, "")
        assert is_binary(reason)
      end

      # --- on_error option: happy-path element shape follows the mode ---

      test "on_error: :raise (default) yields raw row maps on the happy path", %{conn: conn} do
        sql = "SELECT id FROM stream_test_users WHERE id <= 2 ORDER BY id;"
        stream = Xqlite.stream(conn, sql, [], on_error: :raise)

        assert Enum.to_list(stream) == [%{"id" => 1}, %{"id" => 2}]
      end

      test "on_error: :halt yields raw row maps on the happy path", %{conn: conn} do
        sql = "SELECT id FROM stream_test_users WHERE id <= 2 ORDER BY id;"
        stream = Xqlite.stream(conn, sql, [], on_error: :halt)

        assert Enum.to_list(stream) == [%{"id" => 1}, %{"id" => 2}]
      end

      test "on_error: :emit_error tags each row as {:ok, row} on the happy path", %{conn: conn} do
        sql = "SELECT id FROM stream_test_users WHERE id <= 2 ORDER BY id;"
        stream = Xqlite.stream(conn, sql, [], on_error: :emit_error)

        assert Enum.to_list(stream) == [{:ok, %{"id" => 1}}, {:ok, %{"id" => 2}}]
      end

      # --- on_error option: mid-fetch error behavior follows the mode ---

      test "on_error: :raise raises Xqlite.StreamError carrying the structured reason", %{
        conn: conn
      } do
        seed_utf8_error_table(conn)

        stream =
          Xqlite.stream(conn, "SELECT v FROM bad_utf8 ORDER BY id;", [],
            on_error: :raise,
            batch_size: 1
          )

        error = assert_raise(Xqlite.StreamError, fn -> Enum.to_list(stream) end)
        assert {:utf8_error, 0, detail} = error.reason
        assert is_binary(detail)
        assert is_binary(error.message)
      end

      test "on_error: :halt truncates at the error and does not raise (lossy)", %{conn: conn} do
        seed_utf8_error_table(conn)

        stream =
          Xqlite.stream(conn, "SELECT v FROM bad_utf8 ORDER BY id;", [],
            on_error: :halt,
            batch_size: 1
          )

        {rows, _log} = with_log(fn -> Enum.to_list(stream) end)
        assert rows == [%{"v" => "g1"}, %{"v" => "g2"}]
      end

      test "on_error: :emit_error yields {:ok, row} then a terminal {:error, reason}", %{
        conn: conn
      } do
        seed_utf8_error_table(conn)

        stream =
          Xqlite.stream(conn, "SELECT v FROM bad_utf8 ORDER BY id;", [],
            on_error: :emit_error,
            batch_size: 1
          )

        assert [{:ok, %{"v" => "g1"}}, {:ok, %{"v" => "g2"}}, {:error, reason}] =
                 Enum.to_list(stream)

        assert {:utf8_error, 0, _detail} = reason
      end

      # --- a stream runs once ---

      test "on_error: :raise raises :stream_consumed on a pass after a take", %{conn: conn} do
        handler_id = attach_capture([[:xqlite, :stream, :close]])
        on_exit(fn -> detach(handler_id) end)
        stream = Xqlite.stream(conn, "SELECT id FROM stream_test_users ORDER BY id;")

        assert [%{"id" => 1}] = Enum.take(stream, 1)
        error = assert_raise(Xqlite.StreamError, fn -> Enum.to_list(stream) end)
        assert error.reason == :stream_consumed

        assert_received {:telemetry_event, [:xqlite, :stream, :close], _, %{reason: :halted}}
        refute_received {:telemetry_event, [:xqlite, :stream, :close], _, _}
      end

      test "on_error: :emit_error yields only :stream_consumed after a failed pass", %{
        conn: conn
      } do
        seed_utf8_error_table(conn)

        stream =
          Xqlite.stream(conn, "SELECT v FROM bad_utf8 ORDER BY id;", [],
            on_error: :emit_error,
            batch_size: 1
          )

        assert [{:ok, _}, {:ok, _}, {:error, {:utf8_error, _, _}}] = Enum.to_list(stream)
        assert Enum.to_list(stream) == [{:error, :stream_consumed}]
      end

      test "on_error: :halt logs a second pass and yields nothing", %{conn: conn} do
        sql = "SELECT id FROM stream_test_users ORDER BY id;"
        stream = Xqlite.stream(conn, sql, [], on_error: :halt)

        assert length(Enum.to_list(stream)) == @record_count
        {rows, log} = with_log(fn -> Enum.to_list(stream) end)
        assert rows == []
        assert log != ""
      end

      test "a pass started while the first still runs raises :stream_consumed", %{conn: conn} do
        sql = "SELECT id FROM stream_test_users ORDER BY id;"
        stream = Xqlite.stream(conn, sql, [], batch_size: 2)
        pairs = Stream.zip(stream, Stream.drop(stream, 1))

        error = assert_raise(Xqlite.StreamError, fn -> Enum.to_list(pairs) end)
        assert error.reason == :stream_consumed
      end

      test "stream/4 rejects an unsupported :on_error mode at open", %{conn: conn} do
        assert {:error, {:invalid_on_error, :bogus}} =
                 Xqlite.stream(conn, "SELECT id FROM stream_test_users;", [], on_error: :bogus)
      end

      test "stream/4 rejects a statement whose column names repeat at open", %{conn: conn} do
        assert {:error, {:duplicate_column_name, "id"}} =
                 Xqlite.stream(conn, "SELECT id, id FROM stream_test_users;")

        assert {:error, {:duplicate_column_name, "?"}} =
                 Xqlite.stream(conn, "SELECT ?, ?, ?", [1, 2, 3])
      end

      test "stream/4 takes the same columns once they are aliased", %{conn: conn} do
        sql = "SELECT id AS a, id AS b FROM stream_test_users ORDER BY id;"

        assert [%{"a" => 1, "b" => 1} | _] =
                 conn
                 |> Xqlite.stream(sql)
                 |> Enum.to_list()
      end

      test "stream/4 rejects a batch size that is not a positive integer at open",
           %{conn: conn} do
        sql = "SELECT id FROM stream_test_users;"

        for provided <- [0, -1, 1.0, :ten, "10", nil] do
          assert {:error, {:invalid_batch_size, %{provided: ^provided, minimum: 1}}} =
                   Xqlite.stream(conn, sql, [], batch_size: provided)
        end
      end

      # The fetch door reads the batch size as a signed 64-bit integer, so a
      # bigger number never reaches it. Left to the fetch, it failed on the
      # first batch — and under `on_error: :halt` that was an empty stream
      # with no error at all.
      test "stream/4 rejects a batch size past the fetch door's range at open",
           %{conn: conn} do
        sql = "SELECT id FROM stream_test_users;"

        for provided <- [
              9_223_372_036_854_775_808,
              18_446_744_073_709_551_616,
              -18_446_744_073_709_551_616
            ] do
          assert {:error, {:invalid_batch_size, %{provided: ^provided, minimum: 1}}} =
                   Xqlite.stream(conn, sql, [], batch_size: provided)
        end
      end

      test "stream/4 takes the largest batch size the fetch door reads", %{conn: conn} do
        sql = "SELECT id FROM stream_test_users;"
        opts = [batch_size: 9_223_372_036_854_775_807]

        assert @record_count ==
                 conn
                 |> Xqlite.stream(sql, [], opts)
                 |> Enum.count()
      end

      property "a batch size outside the fetch door's range is refused at open",
               %{conn: conn} do
        sql = "SELECT id FROM stream_test_users;"

        check all(outside <- outside_batch_range(), max_runs: 2000) do
          assert {:error, {:invalid_batch_size, %{provided: ^outside, minimum: 1}}} =
                   Xqlite.stream(conn, sql, [], batch_size: outside)
        end
      end

      test "query/4 refuses a keyword list that leaves a parameter out", %{conn: conn} do
        sql = "UPDATE stream_test_users SET name = :name, email = :email WHERE id = 1"
        params = [name: "new_name"]

        assert {:error, {:missing_parameter, %{index: 2, name: ":email"}}} =
                 Xqlite.query(conn, sql, params)

        assert {:ok, %{rows: [["User 1", "user1@example.com"]]}} =
                 Xqlite.query(conn, "SELECT name, email FROM stream_test_users WHERE id = 1")
      end

      # --- cancel_tokens option: a cancel is one more error routed by the mode ---

      test "cancel_tokens: on_error: :raise raises with :operation_cancelled", %{conn: conn} do
        {:ok, token} = Xqlite.create_cancel_token()
        :ok = Xqlite.cancel_operation(token)

        stream =
          Xqlite.stream(conn, @cancel_subject, [], on_error: :raise, cancel_tokens: token)

        error = assert_raise(Xqlite.StreamError, fn -> Enum.to_list(stream) end)
        assert error.reason == :operation_cancelled
      end

      test "cancel_tokens: on_error: :halt truncates the stream at the cancel", %{conn: conn} do
        {:ok, token} = Xqlite.create_cancel_token()
        :ok = Xqlite.cancel_operation(token)

        stream =
          Xqlite.stream(conn, @cancel_subject, [], on_error: :halt, cancel_tokens: [token])

        {rows, _log} = with_log(fn -> Enum.to_list(stream) end)
        assert rows == []
      end

      test "cancel_tokens: on_error: :emit_error ends with a terminal error", %{conn: conn} do
        {:ok, token} = Xqlite.create_cancel_token()
        :ok = Xqlite.cancel_operation(token)

        stream =
          Xqlite.stream(conn, @cancel_subject, [],
            on_error: :emit_error,
            cancel_tokens: [token]
          )

        assert Enum.to_list(stream) == [{:error, :operation_cancelled}]
      end

      test "cancel_tokens: a live token leaves the stream alone", %{conn: conn} do
        {:ok, token} = Xqlite.create_cancel_token()

        stream =
          Xqlite.stream(conn, "SELECT id FROM stream_test_users ORDER BY id;", [],
            cancel_tokens: token
          )

        assert Enum.map(stream, & &1["id"]) == Enum.to_list(1..@record_count)
      end

      test "stream/4 rejects a cancel_tokens value that is not references", %{conn: conn} do
        sql = "SELECT id FROM stream_test_users;"

        assert {:error,
                {:invalid_cancel_tokens,
                 %{reason: :bad_element, position: 1, value_type: :atom}}} =
                 Xqlite.stream(conn, sql, [], cancel_tokens: :bogus)

        assert {:error,
                {:invalid_cancel_tokens,
                 %{reason: :bad_element, position: 1, value_type: :atom}}} =
                 Xqlite.stream(conn, sql, [], cancel_tokens: [:bogus])
      end
    end

    describe "Xqlite.stream/4 partial batches using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = TestUtil.find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "the rows read before a bad value are delivered at the default batch size", %{
        conn: conn
      } do
        sql = seed_step_error_table(conn, :utf8, 14, 0)
        stream = Xqlite.stream(conn, sql, [], on_error: :emit_error)

        {rows, tail} =
          stream
          |> Enum.to_list()
          |> Enum.split(14)

        assert Enum.map(rows, &row_id/1) == Enum.to_list(1..14)
        assert [{:error, {:utf8_error, _, _}}] = tail
      end

      property "every mode delivers the good rows and stops right after them", %{conn: conn} do
        check all(
                good <- StreamData.integer(0..20),
                after_bad <- StreamData.integer(0..5),
                batch_size <- StreamData.integer(1..25),
                kind <- StreamData.member_of([:utf8, :overflow]),
                mode <- StreamData.member_of([:emit_error, :halt, :raise]),
                max_runs: 2000
              ) do
          sql = seed_step_error_table(conn, kind, good, after_bad)
          opts = [on_error: mode, batch_size: batch_size]
          expected_ids = Enum.to_list(1..good//1)

          assert_stream_outcome(Xqlite.stream(conn, sql, [], opts), mode, expected_ids, kind)
        end
      end
    end
  end

  describe "disable_foreign_key_enforcement/1" do
    setup do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "allows FK violations after disabling enforcement", %{conn: conn} do
      assert {:ok, _} = Xqlite.enable_foreign_key_enforcement(conn)
      assert {:ok, _} = Xqlite.disable_foreign_key_enforcement(conn)

      :ok =
        NIF.execute_batch(
          conn,
          """
          CREATE TABLE fk_parent (id INTEGER PRIMARY KEY);
          CREATE TABLE fk_child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES fk_parent(id));
          """
        )

      assert {:ok, 1} =
               NIF.execute(conn, "INSERT INTO fk_child (id, parent_id) VALUES (1, 999)", [])
    end
  end

  describe "enable_foreign_key_enforcement/1" do
    setup do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "blocks FK violations when enabled", %{conn: conn} do
      assert {:ok, _} = Xqlite.enable_foreign_key_enforcement(conn)

      :ok =
        NIF.execute_batch(conn, """
        CREATE TABLE fk_parent (id INTEGER PRIMARY KEY);
        CREATE TABLE fk_child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES fk_parent(id));
        """)

      assert {:error, {:constraint_violation, :constraint_foreign_key, _}} =
               NIF.execute(conn, "INSERT INTO fk_child (id, parent_id) VALUES (1, 999)", [])
    end
  end

  describe "SQLite loose type coercion (non-strict mode)" do
    setup do
      {:ok, conn} = NIF.open_in_memory(":memory:")

      :ok =
        NIF.execute_batch(conn, """
        CREATE TABLE coerce (
          i INTEGER,
          r REAL,
          t TEXT,
          b BLOB,
          n NUMERIC
        );
        """)

      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "string '42' stored in INTEGER column is coerced to integer 42", %{conn: conn} do
      {:ok, 1} = NIF.execute(conn, "INSERT INTO coerce (i) VALUES (?1)", ["42"])

      assert {:ok, %{rows: [[42]]}} =
               NIF.query(conn, "SELECT i FROM coerce", [])
    end

    test "integer stored in TEXT column stays as integer (no coercion)", %{conn: conn} do
      {:ok, 1} = NIF.execute(conn, "INSERT INTO coerce (t) VALUES (?1)", [42])

      assert {:ok, %{rows: [["42"]]}} =
               NIF.query(conn, "SELECT t FROM coerce", [])
    end

    test "float stored in INTEGER column retains REAL type", %{conn: conn} do
      {:ok, 1} = NIF.execute(conn, "INSERT INTO coerce (i) VALUES (?1)", [3.14])

      assert {:ok, %{rows: [[3.14]]}} =
               NIF.query(conn, "SELECT i FROM coerce", [])
    end

    test "integer 42 stored in REAL column is coerced to 42.0", %{conn: conn} do
      {:ok, 1} = NIF.execute(conn, "INSERT INTO coerce (r) VALUES (?1)", [42])

      assert {:ok, %{rows: [[42.0]]}} =
               NIF.query(conn, "SELECT r FROM coerce", [])
    end

    test "string stored in BLOB column retains TEXT type", %{conn: conn} do
      {:ok, 1} = NIF.execute(conn, "INSERT INTO coerce (b) VALUES (?1)", ["hello"])

      assert {:ok, %{rows: [["hello"]]}} =
               NIF.query(conn, "SELECT b FROM coerce", [])
    end

    test "NUMERIC affinity coerces string '123' to integer 123", %{conn: conn} do
      :ok = NIF.execute_batch(conn, "INSERT INTO coerce (n) VALUES ('123');")

      assert {:ok, %{rows: [[123]]}} =
               NIF.query(conn, "SELECT n FROM coerce", [])
    end

    test "NUMERIC affinity coerces string '3.14' to real 3.14", %{conn: conn} do
      :ok = NIF.execute_batch(conn, "INSERT INTO coerce (n) VALUES ('3.14');")

      assert {:ok, %{rows: [[3.14]]}} =
               NIF.query(conn, "SELECT n FROM coerce", [])
    end

    test "NUMERIC affinity keeps non-numeric string as TEXT", %{conn: conn} do
      :ok = NIF.execute_batch(conn, "INSERT INTO coerce (n) VALUES ('hello');")

      assert {:ok, %{rows: [["hello"]]}} =
               NIF.query(conn, "SELECT n FROM coerce", [])
    end
  end

  # Batch sizes the fetch door cannot read: below one, and past either end of
  # the signed 64-bit range it decodes the caller's number into.
  defp outside_batch_range do
    StreamData.one_of([
      StreamData.map(StreamData.integer(0..1_000_000), fn step ->
        9_223_372_036_854_775_808 + step
      end),
      StreamData.map(StreamData.integer(0..1_000_000), fn step ->
        -9_223_372_036_854_775_809 - step
      end),
      StreamData.map(StreamData.integer(64..512), fn bits -> Bitwise.bsl(1, bits) end),
      StreamData.integer(-1_000_000..0)
    ])
  end

  # Seeds a table whose 3rd row (by id) holds an invalid-UTF-8 TEXT value, so a
  # stream reading it row-by-row errors mid-fetch after two good rows.
  defp seed_utf8_error_table(conn) do
    :ok =
      NIF.execute_batch(conn, "CREATE TABLE bad_utf8 (id INTEGER PRIMARY KEY, v TEXT);")

    {:ok, 1} = NIF.execute(conn, "INSERT INTO bad_utf8 (id, v) VALUES (1, 'g1');", [])
    {:ok, 1} = NIF.execute(conn, "INSERT INTO bad_utf8 (id, v) VALUES (2, 'g2');", [])

    {:ok, 1} =
      NIF.execute(conn, "INSERT INTO bad_utf8 (id, v) VALUES (3, CAST(X'FF41' AS TEXT));", [])

    {:ok, 1} = NIF.execute(conn, "INSERT INTO bad_utf8 (id, v) VALUES (4, 'g4');", [])
    :ok
  end

  # `good` readable rows, then one row the read fails on, then `after_bad` more.
  # Returns the SELECT whose scan hits the failure.
  defp seed_step_error_table(conn, kind, good, after_bad) do
    total = good + 1 + after_bad
    values = Enum.map_join(1..total, ", ", fn id -> "(#{id}, #{cell(kind, id, good + 1)})" end)

    :ok =
      NIF.execute_batch(conn, """
      DROP TABLE IF EXISTS step_error;
      CREATE TABLE step_error (id INTEGER PRIMARY KEY, n);
      INSERT INTO step_error (id, n) VALUES #{values};
      """)

    select_sql(kind)
  end

  defp cell(:utf8, id, bad_id) when id == bad_id, do: "CAST(X'FF41' AS TEXT)"
  defp cell(:utf8, id, _bad_id), do: "'g#{id}'"
  defp cell(:overflow, id, bad_id) when id == bad_id, do: "-9223372036854775808"
  defp cell(:overflow, _id, _bad_id), do: "1"

  defp select_sql(:utf8), do: "SELECT id, n AS v FROM step_error ORDER BY id;"
  defp select_sql(:overflow), do: "SELECT id, abs(n) AS v FROM step_error ORDER BY id;"

  defp row_id({:ok, row}), do: row["id"]
  defp row_id(row) when is_map(row), do: row["id"]
  defp row_id(other), do: other

  defp assert_step_error(reason, :utf8) do
    assert {:utf8_error, _, _} = reason
  end

  defp assert_step_error(reason, :overflow) do
    assert {:sqlite_failure, _, _, _} = reason
  end

  defp assert_stream_outcome(stream, :emit_error, expected_ids, kind) do
    {rows, tail} =
      stream
      |> Enum.to_list()
      |> Enum.split(length(expected_ids))

    assert Enum.map(rows, &row_id/1) == expected_ids
    assert [{:error, reason}] = tail
    assert_step_error(reason, kind)
  end

  defp assert_stream_outcome(stream, :halt, expected_ids, _kind) do
    {rows, _log} = with_log(fn -> Enum.to_list(stream) end)
    assert Enum.map(rows, &row_id/1) == expected_ids
  end

  defp assert_stream_outcome(stream, :raise, expected_ids, kind) do
    Process.put(:seen_ids, [])

    error =
      assert_raise(Xqlite.StreamError, fn ->
        Enum.each(stream, fn row ->
          Process.put(:seen_ids, [row_id(row) | Process.get(:seen_ids)])
        end)
      end)

    assert Enum.reverse(Process.get(:seen_ids)) == expected_ids
    assert_step_error(error.reason, kind)
  end
end
