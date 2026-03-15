defmodule Xqlite.NIF.BuiltinSoundexTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "SOUNDEX using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # Basic soundex encoding
      # -------------------------------------------------------------------

      test "soundex() returns 4-character code", %{conn: conn} do
        assert {:ok, %{rows: [[code]]}} =
                 NIF.query(conn, "SELECT soundex('Robert')", [])

        assert String.length(code) == 4
        assert code == "R163"
      end

      test "soundex() of common names", %{conn: conn} do
        assert {:ok, %{rows: [["S530"]]}} = NIF.query(conn, "SELECT soundex('Smith')", [])
        assert {:ok, %{rows: [["J525"]]}} = NIF.query(conn, "SELECT soundex('Johnson')", [])
        assert {:ok, %{rows: [["W452"]]}} = NIF.query(conn, "SELECT soundex('Williams')", [])
      end

      # -------------------------------------------------------------------
      # Phonetic equivalence
      # -------------------------------------------------------------------

      test "phonetically similar names produce same code", %{conn: conn} do
        assert {:ok, %{rows: [[code1]]}} = NIF.query(conn, "SELECT soundex('Robert')", [])
        assert {:ok, %{rows: [[code2]]}} = NIF.query(conn, "SELECT soundex('Rupert')", [])
        assert code1 == code2
      end

      test "Smith and Smyth produce same code", %{conn: conn} do
        assert {:ok, %{rows: [[code1]]}} = NIF.query(conn, "SELECT soundex('Smith')", [])
        assert {:ok, %{rows: [[code2]]}} = NIF.query(conn, "SELECT soundex('Smyth')", [])
        assert code1 == code2
      end

      test "phonetically different names produce different codes", %{conn: conn} do
        assert {:ok, %{rows: [[code1]]}} = NIF.query(conn, "SELECT soundex('Robert')", [])
        assert {:ok, %{rows: [[code2]]}} = NIF.query(conn, "SELECT soundex('Smith')", [])
        assert code1 != code2
      end

      # -------------------------------------------------------------------
      # Edge cases
      # -------------------------------------------------------------------

      test "single character returns padded code", %{conn: conn} do
        assert {:ok, %{rows: [["A000"]]}} = NIF.query(conn, "SELECT soundex('A')", [])
      end

      test "empty string returns ?000", %{conn: conn} do
        assert {:ok, %{rows: [["?000"]]}} = NIF.query(conn, "SELECT soundex('')", [])
      end

      test "soundex of NULL returns ?000", %{conn: conn} do
        assert {:ok, %{rows: [["?000"]]}} = NIF.query(conn, "SELECT soundex(NULL)", [])
      end

      test "numeric string returns ?000", %{conn: conn} do
        assert {:ok, %{rows: [["?000"]]}} = NIF.query(conn, "SELECT soundex('12345')", [])
      end

      test "case insensitive", %{conn: conn} do
        assert {:ok, %{rows: [[code1]]}} = NIF.query(conn, "SELECT soundex('ROBERT')", [])
        assert {:ok, %{rows: [[code2]]}} = NIF.query(conn, "SELECT soundex('robert')", [])
        assert code1 == code2
      end

      test "leading non-alpha characters produce ?000", %{conn: conn} do
        assert {:ok, %{rows: [["?000"]]}} = NIF.query(conn, "SELECT soundex('!!!')", [])
      end

      # -------------------------------------------------------------------
      # Used in queries for fuzzy matching
      # -------------------------------------------------------------------

      test "soundex-based fuzzy name lookup", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE sx_names (id INTEGER PRIMARY KEY, name TEXT);
          INSERT INTO sx_names VALUES (1, 'Smith');
          INSERT INTO sx_names VALUES (2, 'Smyth');
          INSERT INTO sx_names VALUES (3, 'Schmidt');
          INSERT INTO sx_names VALUES (4, 'Johnson');
          INSERT INTO sx_names VALUES (5, 'Smithe');
          """)

        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name FROM sx_names WHERE soundex(name) = soundex('Smith') ORDER BY name",
                   []
                 )

        names = Enum.map(rows, &hd/1)
        assert "Smith" in names
        assert "Smyth" in names
        assert "Smithe" in names
        assert "Johnson" not in names
      end
    end
  end
end
