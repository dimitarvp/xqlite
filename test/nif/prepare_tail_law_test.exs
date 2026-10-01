defmodule Xqlite.NIF.PrepareTailLawTest do
  @moduledoc """
  Every function that runs one statement accepts and rejects the same
  strings. Input holding no statement is rejected, and so is text after the
  first statement holding anything but whitespace, comments and semicolons;
  that text is never compiled, and a leading PRAGMA is judged before any
  compile, so a rejected string applies no PRAGMA. The first property
  compares the paths against each other, so a path that drifts is caught
  even where the shared rule itself is debatable; the laws after it read the
  PRAGMAs SQLite applies while compiling back around each call.

  The generated strings carry a lead as well as a tail — bare semicolons,
  comments and whitespace ahead of the first real statement. Those are what
  a query plan built by prefixing text to the caller's SQL breaks on, so
  they belong in the comparison.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  @statements ["SELECT 1", "SELECT 1, 2", "VALUES (1)", "SELECT 1 AS a, 2 AS b"]

  @tails [
    "",
    ";",
    ";;",
    "  ",
    ";   ",
    ";\n-- c\n",
    "; -- c",
    "; /* c */",
    ";;  -- c",
    "; SELECT 2",
    "; VALUES (2)"
  ]

  @leads [
    "",
    ";",
    "; ",
    ";;",
    " ; ; ",
    "/* c */; ",
    "-- c\n; ",
    "\n;\n"
  ]

  @no_statement [
    "",
    " ",
    "   \n\t ",
    ";",
    ";;",
    " ; ; ",
    "-- c",
    "-- c\n",
    "/* c */",
    "/* c */ ",
    "/* unterminated"
  ]

  # The PRAGMAs SQLite applies while compiling them that a connection reads
  # back, each with a value no opener starts with.
  @applied for pair <- ~w(automatic_index=0 cell_size_check=1 checkpoint_fullfsync=1
    count_changes=1 empty_result_callbacks=1 foreign_keys=0 full_column_names=1 fullfsync=1
    ignore_check_constraints=1 legacy_alter_table=1 query_only=1 read_uncommitted=1
    recursive_triggers=1 reverse_unordered_selects=1 short_column_names=0 trusted_schema=0
    writable_schema=1 busy_timeout=7 cache_size=7 default_cache_size=7 cache_spill=OFF
    synchronous=0 secure_delete=1 temp_store=2 journal_size_limit=7 locking_mode=exclusive
    analysis_limit=7 threads=2 wal_autocheckpoint=5 case_sensitive_like=1 page_size=8192
    auto_vacuum=1 encoding='UTF-16le'),
               do: pair |> String.split("=") |> List.to_tuple()

  @read_by_table for {name, _value} <- @applied,
                     name not in ~w(default_cache_size case_sensitive_like wal_autocheckpoint),
                     do: "pragma_" <> name
  @state_sql "SELECT *, 'a' LIKE 'A' FROM " <>
               Enum.join(["pragma_defer_foreign_keys" | @read_by_table], ", ")

  @hostile_statements [~s(SELECT 'a;b' AS "c;d"), "VALUES (';--')", "SELECT 1 /* ; */"] ++
                        ["SELECT 1 AS [x;y]"]
  @hostile_pairs for name <- ["cache_size", ~s("a;b"), "[a;b]", "`a;b`"],
                     value <- ["1", "'a;b'", "'it''s;'", "'--'", "'/*'"],
                     do: {name, value}
  @bom <<0xEF, 0xBB, 0xBF>>
  @inner_blanks [" ", "\t", "\n", "\r", "\f", " \v", " " <> @bom] ++
                  ["-- a;b'\n", ~s(/* a; -- "b */)]
  @blanks [";" | @inner_blanks]
  @cases [&String.upcase/1, &String.downcase/1, &String.capitalize/1]

  # The fourteen functions that run one statement, as {module, name, arguments after the SQL}.
  @functions [{NIF, :query, [[]]}, {NIF, :query_with_changes, [[]]}, {NIF, :execute, [[]]}] ++
               [{NIF, :stream_open, [[]]}, {NIF, :explain_analyze, [[]]}] ++
               [{NIF, :stmt_prepare, []}, {NIF, :query_cancellable, [[], []]}] ++
               [{NIF, :execute_cancellable, [[], []]}, {Xqlite, :query, []}] ++
               [{NIF, :query_with_changes_cancellable, [[], []]}, {Xqlite, :execute, []}] ++
               [{Xqlite, :prepare, []}, {Xqlite, :stream, []}, {Xqlite, :explain_analyze, []}]

  defp sql_shape do
    StreamData.one_of([
      one_statement_with_tail(),
      StreamData.member_of(@no_statement),
      nul_bearing()
    ])
  end

  defp one_statement_with_tail do
    gen all(
          lead <- StreamData.member_of(@leads),
          head <- StreamData.member_of(@statements),
          tail <- StreamData.member_of(@tails)
        ) do
      lead <> head <> tail
    end
  end

  defp nul_bearing do
    StreamData.bind(StreamData.member_of(@statements ++ @no_statement), fn base ->
      StreamData.map(StreamData.integer(0..byte_size(base)), fn at -> splice_nul(base, at) end)
    end)
  end

  defp splice_nul(base, at) do
    binary_part(base, 0, at) <> <<0>> <> binary_part(base, at, byte_size(base) - at)
  end

  defp classify(:ok), do: :ok
  defp classify({:ok, _}), do: :ok
  defp classify({:error, reason}), do: {:error, tag(reason)}

  defp tag(reason) when is_atom(reason), do: reason
  defp tag({name, _}), do: name
  defp tag({name, _, _}), do: name
  defp tag({name, _, _, _}), do: name

  defp prepare_class(conn, sql) do
    case NIF.stmt_prepare(conn, sql) do
      {:ok, stmt} ->
        assert :ok = NIF.stmt_finalize(stmt)
        :ok

      other ->
        classify(other)
    end
  end

  defp stream_class(conn, sql) do
    case NIF.stream_open(conn, sql, []) do
      {:ok, handle} ->
        assert :ok = NIF.stream_close(handle)
        :ok

      other ->
        classify(other)
    end
  end

  defp query_class(conn, sql), do: classify(NIF.query(conn, sql, []))

  defp explain_class(conn, sql), do: classify(NIF.explain_analyze(conn, sql, []))

  defp execute_class(conn, sql), do: classify(NIF.execute(conn, sql, []))

  defp all_classes(conn, sql) do
    [
      prepare: prepare_class(conn, sql),
      stream: stream_class(conn, sql),
      query: query_class(conn, sql),
      explain_analyze: explain_class(conn, sql),
      execute: execute_class(conn, sql)
    ]
  end

  defp blanks, do: @blanks |> member_of() |> list_of(max_length: 3) |> map(&Enum.join/1)

  defp value_forms(value) do
    quoted = for form <- ["'#{value}'", ~s("#{value}")], value =~ ~r/^\w+$/, do: form
    signed = for form <- ["+" <> value], value =~ ~r/^\d+$/, do: form
    Enum.flat_map([value | quoted ++ signed], &[["=", &1], ["(#{&1})"]])
  end

  defp pragma_statement(pairs) do
    gen all(
          {name, value} <- member_of(pairs),
          prefix <- member_of([[], ["EXPLAIN"], ["EXPLAIN", "QUERY", "PLAN"]]),
          schema <- member_of(["", "main."]),
          value_words <- member_of(value_forms(value)),
          words = prefix ++ ["PRAGMA", schema <> name | value_words],
          cases <- list_of(member_of(@cases), length: length(words)),
          gaps <- list_of(member_of(@inner_blanks), length: length(words) - 1)
        ) do
      [first | rest] = Enum.zip_with(cases, words, & &1.(&2))
      Enum.join([first | Enum.zip_with(gaps, rest, &<>/2)])
    end
  end

  defp statement(pairs), do: one_of([pragma_statement(pairs), member_of(@hostile_statements)])

  # At least one statement is a PRAGMA a read can see. defer_foreign_keys comes
  # second only: written by the first statement, it reads 0 even when applied.
  defp two_statements(applied) do
    later = [{"defer_foreign_keys", "1"} | applied]

    gen all(
          {first, second} <-
            one_of([
              tuple({pragma_statement(applied), statement(later ++ @hostile_pairs)}),
              tuple({statement(applied ++ @hostile_pairs), pragma_statement(later)})
            ]),
          [lead, gap, trail] <- list_of(blanks(), length: 3)
        ) do
      lead <> first <> ";" <> gap <> second <> trail
    end
  end

  defp one_statement do
    gen all(
          statement <- statement(@applied ++ @hostile_pairs),
          [lead, trail] <- list_of(blanks(), length: 2)
        ) do
      lead <> statement <> trail
    end
  end

  defp call({module, name, extra}, conn, sql), do: apply(module, name, [conn, sql | extra])

  defp release({_, :stmt_prepare, _}, {:ok, stmt}), do: NIF.stmt_finalize(stmt)
  defp release({_, :prepare, _}, {:ok, stmt}), do: NIF.stmt_finalize(stmt)
  defp release({NIF, :stream_open, _}, {:ok, stream}), do: NIF.stream_close(stream)
  defp release(_function, {:ok, _answer}), do: :ok
  defp release(_function, {:error, _reason} = error), do: error
  defp release({Xqlite, :stream, _}, stream), do: Stream.run(stream)

  defp every_path(class),
    do: Enum.map(~w(prepare stream query explain_analyze execute)a, &{&1, class})

  defp state(conn) do
    {:ok, %{rows: [row]}} = NIF.query(conn, @state_sql, [])
    {:ok, %{rows: [[autocheckpoint]]}} = NIF.query(conn, "PRAGMA wal_autocheckpoint", [])
    [autocheckpoint | row]
  end

  defp assert_rejected_unchanged(f, conn, sql) do
    before = state(conn)
    assert {:error, :multiple_statements} = call(f, conn, sql)
    assert state(conn) == before
  end

  for_each_opener do
    property "the five compile paths classify one SQL string identically", %{conn: conn} do
      check all(sql <- sql_shape(), max_runs: 2000) do
        classes = all_classes(conn, sql)
        assert classes == every_path(classes[:prepare])
      end
    end

    property "a string holding a second statement is rejected and changes nothing", context do
      {module, opener, args} = Xqlite.TestUtil.find_opener_mfa!(context)

      check all(sql <- two_statements(@applied), f <- member_of(@functions), max_runs: 2000) do
        {:ok, conn} = apply(module, opener, args)
        assert_rejected_unchanged(f, conn, sql)
        assert :ok = NIF.close(conn)
      end
    end

    property "one statement among blanks runs as execute_batch/2 runs it", context do
      {module, opener, args} = Xqlite.TestUtil.find_opener_mfa!(context)

      check all(sql <- one_statement(), f <- member_of(@functions), max_runs: 2000) do
        {:ok, conn} = apply(module, opener, args)
        {:ok, oracle} = apply(module, opener, args)
        assert :ok = release(f, call(f, conn, sql))
        assert :ok = NIF.execute_batch(oracle, sql)
        assert state(conn) == state(oracle)
        assert :ok = NIF.close(conn)
        assert :ok = NIF.close(oracle)
      end
    end

    property "a rejected string leaves a connection kept read-only by query_only read-only" do
      applied = List.keyreplace(@applied, "query_only", 0, {"query_only", "0"})

      check all(sql <- two_statements(applied), f <- member_of(@functions), max_runs: 2000) do
        uri = "file:t1ro#{System.unique_integer([:positive])}?mode=memory&cache=shared"
        {:ok, writer} = NIF.open_in_memory(uri)
        :ok = NIF.execute_batch(writer, "CREATE TABLE t (x)")
        {:ok, reader} = Xqlite.open_in_memory_readonly(uri)
        assert_rejected_unchanged(f, reader, sql)
        insert = NIF.execute(reader, "INSERT INTO t VALUES (1)", [])
        assert {:error, {:read_only_database, _, _}} = insert
        assert :ok = NIF.close(reader)
        assert :ok = NIF.close(writer)
      end
    end

    test "a PRAGMA in either statement of a rejected string stays unapplied", %{conn: conn} do
      {off, more} = {"PRAGMA foreign_keys = OFF", "; SELECT 1 AS a"}

      for f <- @functions,
          sql <- ["SELECT 1 AS a; " <> off, off <> more, @bom <> off <> more] do
        assert {:error, :multiple_statements} = call(f, conn, sql)
        assert {:ok, %{rows: [[1]]}} = NIF.query(conn, "PRAGMA foreign_keys", [])
      end
    end

    test "semicolons in the trailing comments of one statement pass", %{conn: conn} do
      on = "PRAGMA recursive_triggers = 1; -- on; for this test\n;"

      for f <- @functions, sql <- [on, "SELECT 1 AS a; /* a; b */ ;"] do
        assert :ok = release(f, call(f, conn, sql))
      end

      assert {:ok, %{rows: [[1]]}} = NIF.query(conn, "PRAGMA recursive_triggers", [])
    end

    test "a rejected defer_foreign_keys write leaves COMMIT checking the row", %{conn: conn} do
      ddl = "CREATE TABLE p (id PRIMARY KEY); CREATE TABLE c (x REFERENCES p);"
      :ok = NIF.execute_batch(conn, ddl <> "BEGIN; PRAGMA defer_foreign_keys = ON;")
      {:ok, 1} = NIF.execute(conn, "INSERT INTO c VALUES (9)", [])
      off = "SELECT 1; PRAGMA defer_foreign_keys = OFF"
      assert {:error, :multiple_statements} = NIF.query(conn, off, [])
      commit = NIF.execute(conn, "COMMIT", [])
      assert {:error, {:constraint_violation, :constraint_foreign_key, _}} = commit
    end

    test "a rejected temp_store write keeps the TEMP tables", %{conn: conn} do
      :ok = NIF.execute_batch(conn, "CREATE TEMP TABLE tt (x)")
      store = "SELECT 1; PRAGMA temp_store = 2"
      assert {:error, :multiple_statements} = NIF.query(conn, store, [])
      assert {:ok, _} = NIF.query(conn, "SELECT count(*) FROM temp.tt", [])
    end

    test "a word that only starts with PRAGMA is no PRAGMA", %{conn: conn} do
      assert {:error, {:sql_input_error, _}} = NIF.query(conn, "PRAGMAX = 1; SELECT 1", [])
    end

    test "a tail of semicolons, whitespace or comments is not a second statement",
         %{conn: conn} do
      for sql <-
            ["SELECT 1;;", "SELECT 1;   ", "SELECT 1; -- c", "SELECT 1; /* c */"] ++
              ["SELECT 1;/*/", "SELECT 1;/*/ SELECT 2", "SELECT 1;" <> @bom] do
        assert all_classes(conn, sql) == every_path(:ok)
      end
    end

    test "a tail holding any token is a second statement on every path", %{conn: conn} do
      for sql <-
            ["SELECT 1; SELECT 2", "SELECT 1; DROP TABLE IF EXISTS absent_table"] ++
              ["SELECT 1;\v", "SELECT 1;/*"] do
        assert all_classes(conn, sql) == every_path({:error, :multiple_statements})
      end
    end

    test "SQL holding no statement is refused on every path", %{conn: conn} do
      for sql <- ["", "   ", "-- c", "/* c */", ";;"] do
        assert all_classes(conn, sql) == every_path({:error, :no_statement})
      end
    end

    test "a NUL byte anywhere in the SQL is refused on every path", %{conn: conn} do
      for sql <- ["\0", "SELECT\0 1", "SELECT 1\0"] do
        assert all_classes(conn, sql) == every_path({:error, :null_byte_in_string})
      end
    end
  end
end
