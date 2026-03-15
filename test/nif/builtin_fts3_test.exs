defmodule Xqlite.NIF.BuiltinFts3Test do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "FTS3 using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # Table creation (fts3 and fts4)
      # -------------------------------------------------------------------

      test "create FTS3 virtual table", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE f3_basic USING fts3(title, body);"
          )

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO f3_basic VALUES (?1, ?2)", ["hello", "world"])

        assert {:ok, %{rows: [["hello", "world"]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM f3_basic", [])
      end

      test "create FTS4 virtual table", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE f4_basic USING fts4(title, body);"
          )

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO f4_basic VALUES (?1, ?2)", ["hello", "world"])

        assert {:ok, %{rows: [["hello", "world"]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM f4_basic", [])
      end

      # -------------------------------------------------------------------
      # Basic MATCH queries
      # -------------------------------------------------------------------

      test "MATCH finds single term", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_match USING fts3(content);
          INSERT INTO f3_match VALUES ('the quick brown fox');
          INSERT INTO f3_match VALUES ('lazy dog sleeps');
          INSERT INTO f3_match VALUES ('quick rabbit runs');
          """)

        assert {:ok, %{rows: rows, num_rows: 2}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM f3_match WHERE f3_match MATCH 'quick' ORDER BY content",
                   []
                 )

        assert rows == [["quick rabbit runs"], ["the quick brown fox"]]
      end

      test "MATCH returns empty for absent term", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_absent USING fts3(content);
          INSERT INTO f3_absent VALUES ('hello world');
          """)

        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM f3_absent WHERE f3_absent MATCH 'xyz'",
                   []
                 )
      end

      # -------------------------------------------------------------------
      # Boolean operators (enabled via ENABLE_FTS3_PARENTHESIS)
      # -------------------------------------------------------------------

      test "AND operator", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_and USING fts3(content);
          INSERT INTO f3_and VALUES ('alpha beta gamma');
          INSERT INTO f3_and VALUES ('alpha delta');
          INSERT INTO f3_and VALUES ('beta epsilon');
          """)

        assert {:ok, %{rows: [["alpha beta gamma"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM f3_and WHERE f3_and MATCH 'alpha AND beta'",
                   []
                 )
      end

      test "OR operator", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_or USING fts3(content);
          INSERT INTO f3_or VALUES ('cat');
          INSERT INTO f3_or VALUES ('dog');
          INSERT INTO f3_or VALUES ('fish');
          """)

        assert {:ok, %{rows: rows, num_rows: 2}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM f3_or WHERE f3_or MATCH 'cat OR dog' ORDER BY content",
                   []
                 )

        assert rows == [["cat"], ["dog"]]
      end

      test "NOT operator", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_not USING fts3(content);
          INSERT INTO f3_not VALUES ('red apple');
          INSERT INTO f3_not VALUES ('green apple');
          INSERT INTO f3_not VALUES ('red cherry');
          """)

        assert {:ok, %{rows: [["green apple"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM f3_not WHERE f3_not MATCH 'apple NOT red'",
                   []
                 )
      end

      test "parenthesized boolean expression", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_paren USING fts3(content);
          INSERT INTO f3_paren VALUES ('alpha beta');
          INSERT INTO f3_paren VALUES ('alpha gamma');
          INSERT INTO f3_paren VALUES ('delta beta');
          INSERT INTO f3_paren VALUES ('delta gamma');
          """)

        assert {:ok, %{rows: rows, num_rows: 2}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM f3_paren WHERE f3_paren MATCH 'alpha AND (beta OR gamma)' ORDER BY content",
                   []
                 )

        assert rows == [["alpha beta"], ["alpha gamma"]]
      end

      # -------------------------------------------------------------------
      # Phrase matching
      # -------------------------------------------------------------------

      test "phrase match with double quotes", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_phrase USING fts3(content);
          INSERT INTO f3_phrase VALUES ('big brown bear');
          INSERT INTO f3_phrase VALUES ('brown big bear');
          """)

        assert {:ok, %{rows: [["big brown bear"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   ~s|SELECT content FROM f3_phrase WHERE f3_phrase MATCH '"big brown"'|,
                   []
                 )
      end

      # -------------------------------------------------------------------
      # Prefix queries
      # -------------------------------------------------------------------

      test "prefix query with asterisk", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_pfx USING fts3(content);
          INSERT INTO f3_pfx VALUES ('programming');
          INSERT INTO f3_pfx VALUES ('program');
          INSERT INTO f3_pfx VALUES ('progress');
          INSERT INTO f3_pfx VALUES ('other');
          """)

        assert {:ok, %{rows: rows, num_rows: 3}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM f3_pfx WHERE f3_pfx MATCH 'prog*' ORDER BY content",
                   []
                 )

        assert rows == [["program"], ["programming"], ["progress"]]
      end

      # -------------------------------------------------------------------
      # Column filters
      # -------------------------------------------------------------------

      test "column filter restricts match", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_col USING fts3(title, body);
          INSERT INTO f3_col VALUES ('rust', 'elixir code');
          INSERT INTO f3_col VALUES ('elixir', 'rust code');
          """)

        assert {:ok, %{rows: [["elixir", "rust code"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT * FROM f3_col WHERE f3_col MATCH 'title:elixir'",
                   []
                 )
      end

      # -------------------------------------------------------------------
      # snippet() and offsets()
      # -------------------------------------------------------------------

      test "snippet() wraps matched terms", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_snip USING fts3(content);
          INSERT INTO f3_snip VALUES ('the quick brown fox jumps');
          """)

        assert {:ok, %{rows: [[snippet]]}} =
                 NIF.query(
                   conn,
                   "SELECT snippet(f3_snip, '<b>', '</b>', '...', 0) FROM f3_snip WHERE f3_snip MATCH 'quick'",
                   []
                 )

        assert String.contains?(snippet, "<b>quick</b>")
      end

      test "offsets() returns token position info", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_off USING fts3(content);
          INSERT INTO f3_off VALUES ('the quick brown fox');
          """)

        assert {:ok, %{rows: [[offsets_str]]}} =
                 NIF.query(
                   conn,
                   "SELECT offsets(f3_off) FROM f3_off WHERE f3_off MATCH 'quick'",
                   []
                 )

        # offsets format: "col term_num byte_offset byte_length" space-separated
        parts = String.split(offsets_str, " ")
        assert length(parts) == 4

        [col, _term, byte_offset, byte_len] = Enum.map(parts, &String.to_integer/1)
        assert col == 0
        assert byte_offset == 4
        assert byte_len == 5
      end

      # -------------------------------------------------------------------
      # matchinfo()
      # -------------------------------------------------------------------

      test "matchinfo() returns binary blob", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_mi USING fts3(content);
          INSERT INTO f3_mi VALUES ('hello world');
          INSERT INTO f3_mi VALUES ('hello earth');
          """)

        assert {:ok, %{rows: rows, num_rows: 2}} =
                 NIF.query(
                   conn,
                   "SELECT matchinfo(f3_mi) FROM f3_mi WHERE f3_mi MATCH 'hello'",
                   []
                 )

        Enum.each(rows, fn [mi] ->
          assert is_binary(mi)
          # matchinfo returns 32-bit integers packed in binary
          assert rem(byte_size(mi), 4) == 0
        end)
      end

      # -------------------------------------------------------------------
      # Delete and update
      # -------------------------------------------------------------------

      test "delete from FTS3 table", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_del USING fts3(content);
          INSERT INTO f3_del VALUES ('keep me');
          INSERT INTO f3_del VALUES ('delete me');
          """)

        {:ok, 1} =
          NIF.execute(conn, "DELETE FROM f3_del WHERE content = 'delete me'", [])

        assert {:ok, %{rows: [["keep me"]], num_rows: 1}} =
                 NIF.query(conn, "SELECT content FROM f3_del", [])
      end

      test "update FTS3 row updates the index", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_upd USING fts3(content);
          INSERT INTO f3_upd(rowid, content) VALUES (1, 'old text');
          """)

        {:ok, 1} =
          NIF.execute(conn, "UPDATE f3_upd SET content = 'new text' WHERE rowid = 1", [])

        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM f3_upd WHERE f3_upd MATCH 'old'",
                   []
                 )

        assert {:ok, %{rows: [["new text"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM f3_upd WHERE f3_upd MATCH 'new'",
                   []
                 )
      end

      # -------------------------------------------------------------------
      # Edge cases
      # -------------------------------------------------------------------

      test "FTS3 with Unicode content", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_uni USING fts3(content);
          INSERT INTO f3_uni VALUES ('café résumé naïve');
          """)

        assert {:ok, %{rows: [["café résumé naïve"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM f3_uni WHERE f3_uni MATCH 'café'",
                   []
                 )
      end

      test "FTS3 with empty string", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_empty USING fts3(content);
          INSERT INTO f3_empty VALUES ('');
          """)

        assert {:ok, %{rows: [[""]], num_rows: 1}} =
                 NIF.query(conn, "SELECT content FROM f3_empty", [])
      end

      test "FTS3 NEAR operator", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_near USING fts3(content);
          INSERT INTO f3_near VALUES ('alpha bravo charlie delta');
          INSERT INTO f3_near VALUES ('alpha x x x x x x x x x delta');
          """)

        assert {:ok, %{rows: [["alpha bravo charlie delta"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM f3_near WHERE f3_near MATCH 'alpha NEAR/3 delta'",
                   []
                 )
      end

      test "FTS3 with parameterized MATCH", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f3_param USING fts3(content);
          INSERT INTO f3_param VALUES ('parameterized search');
          INSERT INTO f3_param VALUES ('other content');
          """)

        assert {:ok, %{rows: [["parameterized search"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM f3_param WHERE f3_param MATCH ?1",
                   ["parameterized"]
                 )
      end

      # -------------------------------------------------------------------
      # FTS4-specific features
      # -------------------------------------------------------------------

      test "FTS4 with languageid", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f4_lang USING fts4(content, languageid="lid");
          INSERT INTO f4_lang(content, lid) VALUES ('english text', 0);
          INSERT INTO f4_lang(content, lid) VALUES ('other language text', 1);
          """)

        assert {:ok, %{rows: [["english text"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT content FROM f4_lang WHERE f4_lang MATCH 'english'",
                   []
                 )
      end

      test "FTS4 with notindexed column", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f4_noidx USING fts4(title, metadata, notindexed=metadata);
          INSERT INTO f4_noidx VALUES ('searchable title', 'not searchable metadata');
          """)

        assert {:ok, %{rows: [["searchable title", "not searchable metadata"]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT * FROM f4_noidx WHERE f4_noidx MATCH 'searchable'",
                   []
                 )

        # Searching for metadata content should find nothing
        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(
                   conn,
                   "SELECT * FROM f4_noidx WHERE f4_noidx MATCH 'metadata'",
                   []
                 )
      end

      test "FTS4 integrity-check", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE f4_ic USING fts4(content);
          INSERT INTO f4_ic VALUES ('test data');
          INSERT INTO f4_ic VALUES ('more data');
          """)

        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(
                   conn,
                   "INSERT INTO f4_ic(f4_ic) VALUES('integrity-check')",
                   []
                 )
      end
    end
  end
end
