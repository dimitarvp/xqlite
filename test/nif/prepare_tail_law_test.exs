defmodule Xqlite.NIF.PrepareTailLawTest do
  @moduledoc """
  Every entry point that compiles SQL — `stmt_prepare/2`, `stream_open/4`,
  `query/3` and `explain_analyze/3` — accepts and refuses the same strings.

  The rule they share is rusqlite's: input holding no statement at all is
  refused, and text after the first statement is refused only when it
  compiles to a statement of its own, so trailing whitespace, comments and
  extra semicolons are fine. The property compares the four paths against
  each other rather than against a hard-coded table, so a path that drifts
  is caught even where the shared rule itself is debatable.

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
    case NIF.stream_open(conn, sql, [], []) do
      {:ok, handle} ->
        assert :ok = NIF.stream_close(handle)
        :ok

      other ->
        classify(other)
    end
  end

  defp query_class(conn, sql), do: classify(NIF.query(conn, sql, []))

  defp explain_class(conn, sql), do: classify(NIF.explain_analyze(conn, sql, []))

  defp all_classes(conn, sql) do
    [
      prepare: prepare_class(conn, sql),
      stream: stream_class(conn, sql),
      query: query_class(conn, sql),
      explain_analyze: explain_class(conn, sql)
    ]
  end

  for_each_opener do
    property "the four prepare paths classify one SQL string identically", %{conn: conn} do
      check all(sql <- sql_shape(), max_runs: 2000) do
        [prepare: prepared, stream: streamed, query: queried, explain_analyze: explained] =
          all_classes(conn, sql)

        assert prepared == streamed
        assert prepared == queried
        assert prepared == explained
      end
    end

    test "a tail of semicolons, whitespace or comments is not a second statement",
         %{conn: conn} do
      for sql <- ["SELECT 1;;", "SELECT 1;   ", "SELECT 1; -- c", "SELECT 1; /* c */"] do
        assert [prepare: :ok, stream: :ok, query: :ok, explain_analyze: :ok] =
                 all_classes(conn, sql)
      end
    end

    test "a real second statement is refused on every path", %{conn: conn} do
      expected = {:error, :multiple_statements}

      for sql <- ["SELECT 1; SELECT 2", "SELECT 1; DROP TABLE IF EXISTS absent_table"] do
        assert [
                 prepare: ^expected,
                 stream: ^expected,
                 query: ^expected,
                 explain_analyze: ^expected
               ] = all_classes(conn, sql)
      end
    end

    test "SQL holding no statement is refused on every path", %{conn: conn} do
      expected = {:error, :cannot_execute}

      for sql <- ["", "   ", "-- c", "/* c */", ";;"] do
        assert [
                 prepare: ^expected,
                 stream: ^expected,
                 query: ^expected,
                 explain_analyze: ^expected
               ] = all_classes(conn, sql)
      end
    end

    test "a NUL byte anywhere in the SQL is refused on every path", %{conn: conn} do
      expected = {:error, :null_byte_in_string}

      for sql <- ["\0", "SELECT\0 1", "SELECT 1\0"] do
        assert [
                 prepare: ^expected,
                 stream: ^expected,
                 query: ^expected,
                 explain_analyze: ^expected
               ] = all_classes(conn, sql)
      end
    end
  end
end
