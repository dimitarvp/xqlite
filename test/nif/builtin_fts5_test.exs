defmodule Xqlite.NIF.BuiltinFts5Test do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "FTS5 using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # Table creation and basic insert/match
      # -------------------------------------------------------------------

      test "create FTS5 virtual table", %{conn: conn} do
        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "CREATE VIRTUAL TABLE fts_basic USING fts5(title, body)",
                   []
                 )
      end

      test "insert and match single term", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_sm USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_sm VALUES (?1)", ["the quick brown fox"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_sm VALUES (?1)", ["lazy dog sleeps"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_sm VALUES (?1)", ["quick rabbit runs"])

        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "SELECT content FROM fts_sm WHERE fts_sm MATCH 'quick'", [])

        values = Enum.map(rows, &hd/1)
        assert "the quick brown fox" in values
        assert "quick rabbit runs" in values
        assert "lazy dog sleeps" not in values
      end

      test "match returns no results for absent term", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_nr USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_nr VALUES (?1)", ["hello world"])

        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(conn, "SELECT content FROM fts_nr WHERE fts_nr MATCH 'xyz'", [])
      end

      # -------------------------------------------------------------------
      # Phrase matching and boolean operators
      # -------------------------------------------------------------------

      test "phrase match with double quotes", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_ph USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_ph VALUES (?1)", ["big brown bear"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_ph VALUES (?1)", ["brown big bear"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_ph VALUES (?1)", ["big bear brown"])

        assert {:ok, %{rows: [[_]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   ~s|SELECT content FROM fts_ph WHERE fts_ph MATCH '"big brown"'|,
                   []
                 )
      end

      test "AND operator matches both terms", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_and USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_and VALUES (?1)", ["alpha beta gamma"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_and VALUES (?1)", ["alpha delta"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_and VALUES (?1)", ["beta epsilon"])

        assert {:ok, %{rows: [["alpha beta gamma"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM fts_and WHERE fts_and MATCH 'alpha AND beta'",
                   []
                 )
      end

      test "OR operator matches either term", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_or USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_or VALUES (?1)", ["cat"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_or VALUES (?1)", ["dog"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_or VALUES (?1)", ["fish"])

        assert {:ok, %{rows: rows, num_rows: 2}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM fts_or WHERE fts_or MATCH 'cat OR dog' ORDER BY content",
                   []
                 )

        assert rows == [["cat"], ["dog"]]
      end

      test "NOT operator excludes term", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_not USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_not VALUES (?1)", ["red apple"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_not VALUES (?1)", ["green apple"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_not VALUES (?1)", ["red cherry"])

        assert {:ok, %{rows: [["green apple"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM fts_not WHERE fts_not MATCH 'apple NOT red'",
                   []
                 )
      end

      # -------------------------------------------------------------------
      # Prefix queries
      # -------------------------------------------------------------------

      test "prefix query with asterisk", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_pfx USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_pfx VALUES (?1)", ["programming"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_pfx VALUES (?1)", ["program"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_pfx VALUES (?1)", ["progress"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_pfx VALUES (?1)", ["other"])

        assert {:ok, %{rows: rows, num_rows: 3}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM fts_pfx WHERE fts_pfx MATCH 'prog*' ORDER BY content",
                   []
                 )

        values = Enum.map(rows, &hd/1)
        assert values == ["program", "programming", "progress"]
      end

      # -------------------------------------------------------------------
      # Column filters
      # -------------------------------------------------------------------

      test "column filter restricts match to specific column", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE fts_col USING fts5(title, body);"
          )

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO fts_col VALUES (?1, ?2)", ["rust", "elixir code"])

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO fts_col VALUES (?1, ?2)", ["elixir", "rust code"])

        assert {:ok, %{rows: [["elixir", _]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT * FROM fts_col WHERE fts_col MATCH 'title:elixir'",
                   []
                 )
      end

      # -------------------------------------------------------------------
      # Ranking with bm25()
      # -------------------------------------------------------------------

      test "bm25() returns ranking scores", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_bm USING fts5(content);")

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO fts_bm VALUES (?1)", ["sqlite sqlite sqlite"])

        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_bm VALUES (?1)", ["sqlite once"])

        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT content, bm25(fts_bm) FROM fts_bm WHERE fts_bm MATCH 'sqlite' ORDER BY bm25(fts_bm)",
                   []
                 )

        assert length(rows) == 2
        # bm25 returns negative values; more relevant = more negative
        [[_, score1], [_, score2]] = rows
        assert is_float(score1)
        assert is_float(score2)
        assert score1 <= score2
      end

      # -------------------------------------------------------------------
      # rank configuration
      # -------------------------------------------------------------------

      test "ORDER BY rank works as shorthand for bm25", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_rk USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_rk VALUES (?1)", ["one two three"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_rk VALUES (?1)", ["one one one one"])

        assert {:ok, %{rows: [[first_content, _] | _]}} =
                 NIF.query(
                   conn,
                   "SELECT content, rank FROM fts_rk WHERE fts_rk MATCH 'one' ORDER BY rank",
                   []
                 )

        assert first_content == "one one one one"
      end

      # -------------------------------------------------------------------
      # highlight() and snippet()
      # -------------------------------------------------------------------

      test "highlight() wraps matched terms", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_hl USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_hl VALUES (?1)", ["the quick brown fox"])

        assert {:ok, %{rows: [[highlighted]]}} =
                 NIF.query(
                   conn,
                   "SELECT highlight(fts_hl, 0, '<b>', '</b>') FROM fts_hl WHERE fts_hl MATCH 'quick'",
                   []
                 )

        assert highlighted == "the <b>quick</b> brown fox"
      end

      test "highlight() with multiple matched terms", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_hl2 USING fts5(content);")

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO fts_hl2 VALUES (?1)", ["quick brown quick fox"])

        assert {:ok, %{rows: [[highlighted]]}} =
                 NIF.query(
                   conn,
                   "SELECT highlight(fts_hl2, 0, '[', ']') FROM fts_hl2 WHERE fts_hl2 MATCH 'quick'",
                   []
                 )

        assert highlighted == "[quick] brown [quick] fox"
      end

      test "snippet() returns context around match", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_sn USING fts5(content);")

        long_text =
          "word1 word2 word3 word4 word5 target word6 word7 word8 word9 word10"

        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_sn VALUES (?1)", [long_text])

        assert {:ok, %{rows: [[snippet]]}} =
                 NIF.query(
                   conn,
                   "SELECT snippet(fts_sn, 0, '<m>', '</m>', '...', 5) FROM fts_sn WHERE fts_sn MATCH 'target'",
                   []
                 )

        assert String.contains?(snippet, "<m>target</m>")
      end

      # -------------------------------------------------------------------
      # FTS5 content tables (external content)
      # -------------------------------------------------------------------

      test "content table with external content source", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE docs (id INTEGER PRIMARY KEY, text TEXT);
          INSERT INTO docs VALUES (1, 'elixir programming language');
          INSERT INTO docs VALUES (2, 'rust systems programming');
          INSERT INTO docs VALUES (3, 'sqlite database engine');
          CREATE VIRTUAL TABLE docs_fts USING fts5(text, content=docs, content_rowid=id);
          INSERT INTO docs_fts(docs_fts) VALUES('rebuild');
          """)

        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT text FROM docs_fts WHERE docs_fts MATCH 'programming'",
                   []
                 )

        values = Enum.map(rows, &hd/1)
        assert "elixir programming language" in values
        assert "rust systems programming" in values
        assert length(values) == 2
      end

      # -------------------------------------------------------------------
      # Delete and update
      # -------------------------------------------------------------------

      test "delete from FTS table", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_del USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_del VALUES (?1)", ["keep me"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_del VALUES (?1)", ["delete me"])

        {:ok, 1} =
          NIF.execute(conn, "DELETE FROM fts_del WHERE content = 'delete me'", [])

        assert {:ok, %{rows: [["keep me"]], num_rows: 1}} =
                 NIF.query(conn, "SELECT content FROM fts_del", [])
      end

      test "update FTS table row", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_upd USING fts5(content);")

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO fts_upd(rowid, content) VALUES (1, ?1)", ["old text"])

        {:ok, 1} =
          NIF.execute(conn, "UPDATE fts_upd SET content = ?1 WHERE rowid = 1", ["new text"])

        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM fts_upd WHERE fts_upd MATCH 'old'",
                   []
                 )

        assert {:ok, %{rows: [["new text"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM fts_upd WHERE fts_upd MATCH 'new'",
                   []
                 )
      end

      # -------------------------------------------------------------------
      # Edge cases — Unicode, empty strings, special chars
      # -------------------------------------------------------------------

      test "FTS5 handles Unicode text", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_uni USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_uni VALUES (?1)", ["café résumé naïve"])

        assert {:ok, %{rows: [[_]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM fts_uni WHERE fts_uni MATCH 'café'",
                   []
                 )
      end

      test "FTS5 handles CJK characters", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_cjk USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_cjk VALUES (?1)", ["日本語テスト"])

        assert {:ok, %{rows: [[_]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM fts_cjk WHERE fts_cjk MATCH '日本語テスト'",
                   []
                 )
      end

      test "FTS5 with empty string content", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_emp USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_emp VALUES (?1)", [""])

        assert {:ok, %{num_rows: 1}} =
                 NIF.query(conn, "SELECT content FROM fts_emp", [])
      end

      test "FTS5 with very long content", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_long USING fts5(content);")
        long_text = String.duplicate("word ", 10_000) <> "needle"
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_long VALUES (?1)", [long_text])

        assert {:ok, %{rows: [[_]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM fts_long WHERE fts_long MATCH 'needle'",
                   []
                 )
      end

      test "FTS5 NEAR query", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_near USING fts5(content);")

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO fts_near VALUES (?1)", ["alpha bravo charlie delta"])

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO fts_near VALUES (?1)", [
            "alpha x x x x x x x x x delta"
          ])

        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM fts_near WHERE fts_near MATCH 'NEAR(alpha delta, 3)'",
                   []
                 )

        values = Enum.map(rows, &hd/1)
        assert "alpha bravo charlie delta" in values
        assert length(values) == 1
      end

      # -------------------------------------------------------------------
      # FTS5 with multiple columns and weights
      # -------------------------------------------------------------------

      test "multi-column FTS with weighted bm25", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE fts_mc USING fts5(title, body);"
          )

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO fts_mc VALUES (?1, ?2)", [
            "sqlite guide",
            "this is about databases"
          ])

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO fts_mc VALUES (?1, ?2)", [
            "cooking recipes",
            "how to use sqlite in recipes"
          ])

        # Weight title 10x more than body
        assert {:ok, %{rows: [[first_title, _] | _]}} =
                 NIF.query(
                   conn,
                   "SELECT title, body FROM fts_mc WHERE fts_mc MATCH 'sqlite' ORDER BY bm25(fts_mc, 10.0, 1.0)",
                   []
                 )

        assert first_title == "sqlite guide"
      end

      # -------------------------------------------------------------------
      # FTS5 integrity check
      # -------------------------------------------------------------------

      test "integrity-check command succeeds on valid table", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_ic USING fts5(content);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_ic VALUES (?1)", ["test data"])

        assert {:ok, _} =
                 NIF.query(
                   conn,
                   "INSERT INTO fts_ic(fts_ic, rank) VALUES('integrity-check', 1)",
                   []
                 )
      end

      # -------------------------------------------------------------------
      # FTS5 with parameterized queries
      # -------------------------------------------------------------------

      test "MATCH with parameterized search term", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE VIRTUAL TABLE fts_param USING fts5(content);")

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO fts_param VALUES (?1)", ["parameterized search"])

        {:ok, 1} = NIF.execute(conn, "INSERT INTO fts_param VALUES (?1)", ["other content"])

        assert {:ok, %{rows: [["parameterized search"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM fts_param WHERE fts_param MATCH ?1",
                   ["parameterized"]
                 )
      end
    end
  end
end
