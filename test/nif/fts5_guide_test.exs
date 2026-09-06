defmodule Xqlite.NIF.Fts5GuideTest do
  @moduledoc """
  Executes `guides/full_text_search.md` instead of restating it.

  Every fenced block of the guide runs, in the order the guide prints
  it, against one connection: the `elixir` blocks through
  `Code.eval_string/2` with the bindings carried from one block to the
  next, the `sql` block through `XqliteNIF.query/3`. The guide's
  opening line sits in a fence of its own, which this test skips — the
  connection comes from the opener harness instead. Blocks that name
  `Repo` belong to the Ecto adapter and cannot run here; their count is
  asserted, so a second unrunnable block cannot slip in unnoticed.

  Beside that, three tests pin guide claims that live in prose rather
  than in a fence: the match language, the operational commands, the
  tokenizer options, and what SQLite does with `STRICT` and column
  constraints on an FTS5 table.
  """
  use ExUnit.Case, async: true

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  @guide "guides/full_text_search.md"
  @opener_line "{:ok, conn} = Xqlite.open_in_memory()"
  @sql_fence_param "schedulers"
  @adapter_fences 1

  for_each_opener "fts5_guide" do
    test "every fenced block of the guide runs, in order", %{conn: conn} do
      run_guide(conn, File.read!(@guide))
    end

    test "FTS5 is compiled in, as the guide's opening line claims", %{conn: conn} do
      assert {:ok, %{rows: [[opts]]}} =
               NIF.query(
                 conn,
                 "SELECT group_concat(compile_options) FROM pragma_compile_options()",
                 []
               )

      assert opts =~ "ENABLE_FTS5"
    end

    test "match language + operational commands", %{conn: conn} do
      :ok =
        NIF.execute_batch(conn, """
        CREATE TABLE arts (id INTEGER PRIMARY KEY, title TEXT, body TEXT);
        CREATE VIRTUAL TABLE arts_fts USING fts5(title, body, content = 'arts', content_rowid = 'id');
        CREATE TRIGGER arts_ai AFTER INSERT ON arts BEGIN
          INSERT INTO arts_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
        END;
        """)

      {:ok, _} =
        NIF.execute(conn, "INSERT INTO arts (title, body) VALUES (?1, ?2)", [
          "SQLite and the BEAM",
          "Cancellable queries keep schedulers happy"
        ])

      # The match language the guide advertises: phrase, prefix, column filter,
      # boolean, NEAR. Each must PARSE and run (the parameter is always bound —
      # the guide's security note — never interpolated).
      matches = fn q ->
        assert {:ok, %{rows: [[n]]}} =
                 NIF.query(conn, "SELECT count(*) FROM arts_fts WHERE arts_fts MATCH ?1", [q])

        n
      end

      assert matches.("sched*") == 1
      assert matches.("title:beam") == 1
      assert matches.("sqlite AND (beam OR erlang)") == 1
      assert matches.("NEAR(sqlite beam, 5)") == 1
      assert matches.("\"exact phrase that is absent\"") == 0

      # Operational notes: rebuild, integrity-check, optimize.
      assert {:ok, _} =
               NIF.execute(conn, "INSERT INTO arts_fts(arts_fts) VALUES ('rebuild')", [])

      assert {:ok, _} =
               NIF.execute(
                 conn,
                 "INSERT INTO arts_fts(arts_fts, rank) VALUES ('integrity-check', 1)",
                 []
               )

      assert {:ok, _} =
               NIF.execute(conn, "INSERT INTO arts_fts(arts_fts) VALUES ('optimize')", [])
    end

    test "tokenizer options from the operational notes", %{conn: conn} do
      # porter stemming + trigram substring index — both advertised.
      assert :ok =
               NIF.execute_batch(
                 conn,
                 "CREATE VIRTUAL TABLE t_porter USING fts5(x, tokenize = 'porter unicode61');"
               )

      assert :ok =
               NIF.execute_batch(
                 conn,
                 "CREATE VIRTUAL TABLE t_tri USING fts5(x, tokenize = 'trigram');"
               )
    end

    test "an FTS5 table takes neither STRICT nor a column constraint", %{conn: conn} do
      assert {:error, {:sql_input_error, %{code: 1}}} =
               NIF.execute_batch(conn, "CREATE VIRTUAL TABLE t_strict USING fts5(a) STRICT")

      for column <- [
            "a NOT NULL",
            "a PRIMARY KEY",
            "a CHECK (a <> '')",
            "a UNIQUE",
            "a INTEGER"
          ] do
        assert {:error, {:sqlite_failure, 1, 1, _detail}} =
                 NIF.execute_batch(conn, "CREATE VIRTUAL TABLE t_c USING fts5(#{column})")
      end
    end
  end

  defp run_guide(conn, guide) do
    blocks = fenced_blocks(guide)

    assert Enum.count(blocks, &opener_block?/1) == 1
    assert Enum.count(blocks, &adapter_block?/1) == @adapter_fences

    Enum.reduce(blocks, [conn: conn], fn block, bindings ->
      run_block(conn, block, bindings)
    end)
  end

  defp fenced_blocks(guide) do
    Regex.scan(~r/```(\w+)\n(.*?)```/s, guide, capture: :all_but_first)
  end

  defp run_block(_conn, ["elixir", body] = block, bindings) do
    case skip?(block) do
      true -> bindings
      false -> eval_block(body, bindings)
    end
  end

  defp run_block(conn, ["sql", body], bindings) do
    assert {:ok, _} = NIF.query(conn, String.trim(body), [@sql_fence_param])
    bindings
  end

  defp run_block(_conn, [lang, _body], _bindings),
    do: flunk("the guide has a #{lang} fence and this test has no runner for it")

  defp eval_block(body, bindings) do
    {_value, carried} = Code.eval_string(body, bindings)
    carried
  end

  defp skip?(block), do: opener_block?(block) or adapter_block?(block)

  defp opener_block?(["elixir", body]), do: String.trim(body) == @opener_line
  defp opener_block?(_block), do: false

  defp adapter_block?(["elixir", body]), do: String.contains?(body, "Repo")
  defp adapter_block?(_block), do: false
end
