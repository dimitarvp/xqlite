defmodule Xqlite.NIF.Fts5GuideTest do
  # Executes the code path from `guides/full_text_search.md` so the guide
  # cannot rot silently: the same CREATE VIRTUAL TABLE / trigger / MATCH /
  # bm25 / highlight / snippet / operational-command SQL the guide publishes.
  # If FTS5 stops being compiled in, or any snippet's SQL stops working, this
  # test fails. Kept faithful to the guide (identical SQL and NIF calls);
  # parameterised over every connection opener for good measure.
  use ExUnit.Case, async: true

  import Xqlite.ConnCase
  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for_each_opener "fts5_guide" do
    test "a searchable table in two statements + external-content triggers", %{conn: conn} do
      # FTS5 must be compiled in (the guide's opening claim).
      assert {:ok, %{rows: [[opts]]}} =
               NIF.query(
                 conn,
                 "SELECT group_concat(compile_options) FROM pragma_compile_options()",
                 []
               )

      assert opts =~ "ENABLE_FTS5"

      # A searchable table in two statements.
      :ok =
        NIF.execute_batch(conn, """
        CREATE TABLE articles (id INTEGER PRIMARY KEY, title TEXT, body TEXT);
        CREATE VIRTUAL TABLE articles_fts USING fts5(
          title, body,
          content = 'articles',
          content_rowid = 'id'
        );
        """)

      # External-content sync triggers (insert / delete / update).
      :ok =
        NIF.execute_batch(conn, """
        CREATE TRIGGER articles_ai AFTER INSERT ON articles BEGIN
          INSERT INTO articles_fts(rowid, title, body)
          VALUES (new.id, new.title, new.body);
        END;
        CREATE TRIGGER articles_ad AFTER DELETE ON articles BEGIN
          INSERT INTO articles_fts(articles_fts, rowid, title, body)
          VALUES ('delete', old.id, old.title, old.body);
        END;
        CREATE TRIGGER articles_au AFTER UPDATE ON articles BEGIN
          INSERT INTO articles_fts(articles_fts, rowid, title, body)
          VALUES ('delete', old.id, old.title, old.body);
          INSERT INTO articles_fts(rowid, title, body)
          VALUES (new.id, new.title, new.body);
        END;
        """)

      # Querying: the guide's exact INSERT + MATCH-with-bm25-rank join.
      {:ok, _} =
        NIF.execute(
          conn,
          "INSERT INTO articles (title, body) VALUES (?1, ?2)",
          ["SQLite and the BEAM", "Cancellable queries keep schedulers happy"]
        )

      assert {:ok, %{rows: [[1, "SQLite and the BEAM", rank]]}} =
               NIF.query(
                 conn,
                 """
                 SELECT a.id, a.title, bm25(articles_fts) AS rank
                 FROM articles_fts
                 JOIN articles a ON a.id = articles_fts.rowid
                 WHERE articles_fts MATCH ?1
                 ORDER BY rank
                 """,
                 ["schedulers"]
               )

      # bm25 is "lower is better"; a single match ranks negative (best-first).
      assert is_float(rank)

      # Snippets and highlighting are built in.
      assert {:ok, %{rows: [[title_hl, excerpt]]}} =
               NIF.query(
                 conn,
                 """
                 SELECT highlight(articles_fts, 0, '<b>', '</b>') AS title_hl,
                        snippet(articles_fts, 1, '<b>', '</b>', '…', 12) AS excerpt
                 FROM articles_fts
                 WHERE articles_fts MATCH ?1
                 """,
                 ["schedulers"]
               )

      assert title_hl == "SQLite and the BEAM"
      assert excerpt =~ "<b>schedulers</b>"
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
  end
end
