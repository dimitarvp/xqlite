defmodule Xqlite.StrictTableTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.TestUtil, only: [tmp_db_path: 1]

  alias XqliteNIF, as: NIF

  setup do
    {:ok, conn} = Xqlite.open_in_memory()
    on_exit(fn -> NIF.close(conn) end)
    {:ok, conn: conn}
  end

  # ---------------------------------------------------------------------------
  # check_strict_violations
  # ---------------------------------------------------------------------------

  describe "check_strict_violations/2" do
    test "clean table returns empty list", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE clean (id INTEGER PRIMARY KEY, age INTEGER, name TEXT)")
      NIF.execute(conn, "INSERT INTO clean VALUES (1, 30, 'alice')")
      NIF.execute(conn, "INSERT INTO clean VALUES (2, 25, 'bob')")

      assert {:ok, []} = Xqlite.check_strict_violations(conn, "clean")
    end

    test "detects TEXT in INTEGER column", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE dirty (id INTEGER PRIMARY KEY, age INTEGER)")
      NIF.execute(conn, "INSERT INTO dirty VALUES (1, 30)")
      NIF.execute(conn, "INSERT INTO dirty VALUES (2, 'not a number')")

      assert {:ok, [violation]} = Xqlite.check_strict_violations(conn, "dirty")
      assert violation.rowid == 2
      assert violation.column == "age"
      assert violation.actual_type == "text"
      assert violation.expected_type == "INTEGER"
    end

    test "detects REAL in INTEGER column", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE floaty (id INTEGER PRIMARY KEY, count INTEGER)")
      NIF.execute(conn, "INSERT INTO floaty VALUES (1, 10)")
      NIF.execute(conn, "INSERT INTO floaty VALUES (2, 3.14)")

      assert {:ok, [violation]} = Xqlite.check_strict_violations(conn, "floaty")
      assert violation.rowid == 2
      assert violation.column == "count"
      assert violation.actual_type == "real"
      assert violation.expected_type == "INTEGER"
    end

    test "detects TEXT in REAL column", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE scores (id INTEGER PRIMARY KEY, score REAL)")
      NIF.execute(conn, "INSERT INTO scores VALUES (1, 95.5)")
      NIF.execute(conn, "INSERT INTO scores VALUES (2, 'excellent')")

      assert {:ok, [violation]} = Xqlite.check_strict_violations(conn, "scores")
      assert violation.rowid == 2
      assert violation.column == "score"
      assert violation.actual_type == "text"
      assert violation.expected_type == "REAL"
    end

    test "REAL column allows integer values (no violation)", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE compat (id INTEGER PRIMARY KEY, val REAL)")
      NIF.execute(conn, "INSERT INTO compat VALUES (1, 42)")
      NIF.execute(conn, "INSERT INTO compat VALUES (2, 3.14)")

      assert {:ok, []} = Xqlite.check_strict_violations(conn, "compat")
    end

    test "TEXT column allows integer and real values (no violation)", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE texts (id INTEGER PRIMARY KEY, label TEXT)")
      NIF.execute(conn, "INSERT INTO texts VALUES (1, 'hello')")
      NIF.execute(conn, "INSERT INTO texts VALUES (2, 42)")
      NIF.execute(conn, "INSERT INTO texts VALUES (3, 3.14)")

      assert {:ok, []} = Xqlite.check_strict_violations(conn, "texts")
    end

    test "NULL values are always allowed", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE nullable (id INTEGER PRIMARY KEY, val INTEGER)")
      NIF.execute(conn, "INSERT INTO nullable VALUES (1, NULL)")

      assert {:ok, []} = Xqlite.check_strict_violations(conn, "nullable")
    end

    test "detects multiple violations across columns", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE multi (id INTEGER PRIMARY KEY, age INTEGER, score REAL)")
      NIF.execute(conn, "INSERT INTO multi VALUES (1, 30, 95.5)")
      NIF.execute(conn, "INSERT INTO multi VALUES (2, 'bad age', 80.0)")
      NIF.execute(conn, "INSERT INTO multi VALUES (3, 25, 'bad score')")
      NIF.execute(conn, "INSERT INTO multi VALUES (4, 'also bad', 'also bad')")

      {:ok, violations} = Xqlite.check_strict_violations(conn, "multi")
      assert length(violations) == 4

      age_violations = Enum.filter(violations, &(&1.column == "age"))
      score_violations = Enum.filter(violations, &(&1.column == "score"))

      assert length(age_violations) == 2
      assert length(score_violations) == 2

      rowids = Enum.map(violations, & &1.rowid) |> Enum.sort()
      assert rowids == [2, 3, 4, 4]
    end

    test "detects BLOB in INTEGER column via raw SQL", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE blobs (id INTEGER PRIMARY KEY, val INTEGER)")
      NIF.execute(conn, "INSERT INTO blobs VALUES (1, 42)")
      NIF.execute(conn, "INSERT INTO blobs VALUES (2, X'DEADBEEF')")

      {:ok, violations} = Xqlite.check_strict_violations(conn, "blobs")
      assert [violation] = violations
      assert violation.rowid == 2
      assert violation.actual_type == "blob"
      assert violation.expected_type == "INTEGER"
    end

    test "nonexistent table returns error", %{conn: conn} do
      assert {:error, _} = Xqlite.check_strict_violations(conn, "nonexistent")
    end

    test "empty table returns empty list", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE empty (id INTEGER PRIMARY KEY, val INTEGER)")
      assert {:ok, []} = Xqlite.check_strict_violations(conn, "empty")
    end

    test "a table whose every column is untyped reports one violation per column",
         %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE untyped (a, b, c)")
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO untyped VALUES (1, 'two', X'03')")

      assert {:ok, violations} = Xqlite.check_strict_violations(conn, "untyped")

      assert violations == [
               %{kind: :missing_declared_type, column: "a"},
               %{kind: :missing_declared_type, column: "b"},
               %{kind: :missing_declared_type, column: "c"}
             ]
    end

    test "a declared type STRICT does not know is a violation", %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE typo (id INTEGER, v VARCHAR(255))")

      assert {:ok, violations} = Xqlite.check_strict_violations(conn, "typo")

      assert violations == [
               %{kind: :unknown_declared_type, column: "v", declared: "VARCHAR(255)"}
             ]
    end

    test "an ANY column is checked by nothing", %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE anyish (id INTEGER, v ANY)")
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO anyish VALUES (1, 'text')")

      assert {:ok, []} = Xqlite.check_strict_violations(conn, "anyish")
    end

    test "declared-type and row violations are reported together", %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE mixed (n INTEGER, v DATETIME)")
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO mixed VALUES ('oops', 'x')")

      assert {:ok, violations} = Xqlite.check_strict_violations(conn, "mixed")

      assert Enum.any?(violations, &(&1[:kind] == :unknown_declared_type))
      assert Enum.any?(violations, &(&1[:actual_type] == "text"))
    end

    test "a blob stored in a TEXT column is reported", %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE texty (c TEXT)")
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO texty VALUES (?)", [<<0xFF, 0xFE>>])

      assert {:ok, [violation]} = Xqlite.check_strict_violations(conn, "texty")
      assert violation.rowid == 1
      assert violation.column == "c"
      assert violation.actual_type == "blob"
      assert violation.expected_type == "TEXT"
    end

    test "text stored in a BLOB column is reported", %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE blobby (c BLOB)")
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO blobby VALUES (?)", ["still text"])

      assert {:ok, [violation]} = Xqlite.check_strict_violations(conn, "blobby")
      assert violation.rowid == 1
      assert violation.column == "c"
      assert violation.actual_type == "text"
      assert violation.expected_type == "BLOB"
    end

    property "the reported rows are the rows whose stored class the declared type refuses" do
      check all(
              declared <- StreamData.member_of(~w[INTEGER REAL TEXT BLOB ANY]),
              values <- StreamData.list_of(strict_value(), max_length: 4),
              max_runs: 2000
            ) do
        assert {:ok, conn} = NIF.open_in_memory(":memory:")
        assert :ok = NIF.execute_batch(conn, "CREATE TABLE probe (c #{declared})")

        Enum.each(values, fn value ->
          assert {:ok, 1} = NIF.execute(conn, "INSERT INTO probe VALUES (?)", [value])
        end)

        assert {:ok, violations} = Xqlite.check_strict_violations(conn, "probe")
        assert reported_violations(violations) == oracle_violations(conn, declared)

        assert :ok = NIF.close(conn)
      end
    end

    property "the declared-type verdict is the verdict SQLite itself gives" do
      check all(declared <- declared_type(), max_runs: 2000) do
        assert {:ok, conn} = NIF.open_in_memory(":memory:")

        assert :ok = NIF.execute_batch(conn, "CREATE TABLE probe (c #{declared})")
        assert {:ok, violations} = Xqlite.check_strict_violations(conn, "probe")

        oracle = NIF.execute_batch(conn, "CREATE TABLE oracle (c #{declared}) STRICT")

        assert declared_verdict(violations) == strict_verdict(oracle)

        assert :ok = NIF.close(conn)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # enable_strict_table
  # ---------------------------------------------------------------------------

  describe "enable_strict_table/2" do
    test "converts clean table to STRICT", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)")
      NIF.execute(conn, "INSERT INTO users VALUES (1, 'alice', 30)")
      NIF.execute(conn, "INSERT INTO users VALUES (2, 'bob', 25)")

      assert :ok = Xqlite.enable_strict_table(conn, "users")

      # Verify data survived
      {:ok, result} = NIF.query(conn, "SELECT * FROM users ORDER BY id", [])
      assert result.rows == [[1, "alice", 30], [2, "bob", 25]]

      # Verify STRICT is enforced — TEXT into INTEGER should fail
      assert {:error,
              {:constraint_violation, :constraint_datatype,
               %{source_type: :text, target_type: :integer, table: "users", columns: ["age"]}}} =
               NIF.execute(conn, "INSERT INTO users VALUES (3, 'carol', 'not a number')")
    end

    test "rejects table with type violations", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE dirty (id INTEGER PRIMARY KEY, age INTEGER)")
      NIF.execute(conn, "INSERT INTO dirty VALUES (1, 30)")
      NIF.execute(conn, "INSERT INTO dirty VALUES (2, 'bad')")

      assert {:error, {:strict_violations, violations}} =
               Xqlite.enable_strict_table(conn, "dirty")

      assert [violation] = violations
      assert violation.column == "age"
      assert violation.actual_type == "text"

      # Original table is untouched
      {:ok, result} = NIF.query(conn, "SELECT * FROM dirty ORDER BY id", [])
      assert result.rows == [[1, 30], [2, "bad"]]
    end

    test "preserves data types after rebuild", %{conn: conn} do
      NIF.execute(
        conn,
        "CREATE TABLE typed (id INTEGER PRIMARY KEY, i INTEGER, r REAL, t TEXT)"
      )

      NIF.execute(conn, "INSERT INTO typed VALUES (1, 42, 3.14, 'hello')")

      assert :ok = Xqlite.enable_strict_table(conn, "typed")

      {:ok, result} = NIF.query(conn, "SELECT * FROM typed", [])
      assert [[1, 42, 3.14, "hello"]] = result.rows
    end

    test "nonexistent table returns error", %{conn: conn} do
      assert {:error, {:no_such_table, "ghost"}} = Xqlite.enable_strict_table(conn, "ghost")
    end

    test "already-STRICT table is left untouched", %{conn: conn} do
      NIF.execute(
        conn,
        "CREATE TABLE strict_already (id INTEGER PRIMARY KEY, val INTEGER) STRICT"
      )

      NIF.execute(conn, "INSERT INTO strict_already VALUES (1, 42)")

      assert {:ok, stored_sql} = Xqlite.get_create_sql(conn, "strict_already")
      assert {:ok, changes} = Xqlite.total_changes(conn)

      assert :ok = Xqlite.enable_strict_table(conn, "strict_already")

      assert {:ok, ^stored_sql} = Xqlite.get_create_sql(conn, "strict_already")
      assert {:ok, ^changes} = Xqlite.total_changes(conn)

      {:ok, result} = NIF.query(conn, "SELECT * FROM strict_already", [])
      assert result.rows == [[1, 42]]
    end

    test "multiple violations reported in rejection", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE messy (id INTEGER PRIMARY KEY, a INTEGER, b REAL)")
      # row 1: text in int (violation), text in real (violation)
      NIF.execute(conn, "INSERT INTO messy VALUES (1, 'text_in_int', 'text_in_real')")
      # row 2: clean
      NIF.execute(conn, "INSERT INTO messy VALUES (2, 42, 3.14)")
      # row 3: real in int (violation), text in real (violation)
      NIF.execute(conn, "INSERT INTO messy VALUES (3, 3.14, 'oops')")

      assert {:error, {:strict_violations, violations}} =
               Xqlite.enable_strict_table(conn, "messy")

      assert length(violations) == 4
      assert Enum.any?(violations, &(&1.column == "a"))
      assert Enum.any?(violations, &(&1.column == "b"))
    end

    test "preserves indexes after rebuild", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE indexed (id INTEGER PRIMARY KEY, email TEXT)")
      NIF.execute(conn, "CREATE UNIQUE INDEX idx_email ON indexed(email)")
      NIF.execute(conn, "INSERT INTO indexed VALUES (1, 'a@b.com')")

      assert :ok = Xqlite.enable_strict_table(conn, "indexed")

      # Index should still enforce uniqueness
      assert {:error, {:constraint_violation, :constraint_unique, _}} =
               NIF.execute(conn, "INSERT INTO indexed VALUES (2, 'a@b.com')")
    end

    test "table with untyped columns fails (STRICT requires column types)", %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE loose (id INTEGER PRIMARY KEY, data)")
      NIF.execute(conn, "INSERT INTO loose VALUES (1, 'text')")

      assert {:error, {:strict_violations, [%{kind: :missing_declared_type, column: "data"}]}} =
               Xqlite.enable_strict_table(conn, "loose")

      # Original table untouched
      {:ok, result} = NIF.query(conn, "SELECT * FROM loose", [])
      assert result.rows == [[1, "text"]]
    end

    test "a column type STRICT does not know stops the rebuild before it starts",
         %{conn: conn} do
      NIF.execute(conn, "CREATE TABLE dated (id INTEGER PRIMARY KEY, at DATETIME)")

      assert {:error,
              {:strict_violations,
               [%{kind: :unknown_declared_type, column: "at", declared: "DATETIME"}]}} =
               Xqlite.enable_strict_table(conn, "dated")

      refute strict?(conn, "dated")
      assert tables(conn) == ["dated"]
    end

    test "an FTS5 virtual table is refused by both helpers", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(conn, "CREATE VIRTUAL TABLE t_fts USING fts5(title, body)")

      assert {:error, {:not_a_plain_table, %{table: "t_fts", type: :virtual}}} =
               Xqlite.check_strict_violations(conn, "t_fts")

      assert {:error, {:not_a_plain_table, %{table: "t_fts", type: :virtual}}} =
               Xqlite.enable_strict_table(conn, "t_fts")
    end

    test "a shadow table of a virtual table is refused by both helpers", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(conn, "CREATE VIRTUAL TABLE s_fts USING fts5(title, body)")

      assert {:error, {:not_a_plain_table, %{table: "s_fts_data", type: :shadow}}} =
               Xqlite.check_strict_violations(conn, "s_fts_data")

      assert {:error, {:not_a_plain_table, %{table: "s_fts_data", type: :shadow}}} =
               Xqlite.enable_strict_table(conn, "s_fts_data")
    end

    test "a view is refused by both helpers", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(
                 conn,
                 "CREATE TABLE base (id INTEGER); CREATE VIEW v1 AS SELECT id FROM base;"
               )

      assert {:error, {:not_a_plain_table, %{table: "v1", type: :view}}} =
               Xqlite.check_strict_violations(conn, "v1")

      assert {:error, {:not_a_plain_table, %{table: "v1", type: :view}}} =
               Xqlite.enable_strict_table(conn, "v1")
    end
  end

  # ---------------------------------------------------------------------------
  # names SQLite accepts but that need quoting, and the four spellings a stored
  # CREATE TABLE statement can carry
  # ---------------------------------------------------------------------------

  describe "hostile names and stored spellings" do
    for {label, rendered} <- [
          {"double-quoted", ~s|"users"|},
          {"backtick-quoted", "`users`"},
          {"bracket-quoted", "[users]"}
        ] do
      test "a table stored #{label} converts", %{conn: conn} do
        assert :ok = NIF.execute_batch(conn, "CREATE TABLE #{unquote(rendered)} (id INTEGER);")
        assert {:ok, 1} = NIF.execute(conn, "INSERT INTO users VALUES (?)", [1])

        assert {:ok, []} = Xqlite.check_strict_violations(conn, "users")
        assert :ok = Xqlite.enable_strict_table(conn, "users")

        assert strict?(conn, "users")
        assert {:ok, %{rows: [[1]]}} = NIF.query(conn, "SELECT id FROM users", [])
      end
    end

    test "a bare name whose characters are regex syntax converts", %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE t$x (id INTEGER);")

      assert :ok = Xqlite.enable_strict_table(conn, "t$x")
      assert strict?(conn, "t$x")
    end

    test "a table whose name is empty converts", %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, ~s|CREATE TABLE "" (id INTEGER);|)
      assert {:ok, 1} = NIF.execute(conn, ~s|INSERT INTO "" VALUES (?)|, [1])

      assert {:ok, []} = Xqlite.check_strict_violations(conn, "")
      assert :ok = Xqlite.enable_strict_table(conn, "")

      assert strict?(conn, "")
      assert {:ok, %{rows: [[1]]}} = NIF.query(conn, ~s|SELECT id FROM ""|, [])
    end

    test "a table and a column holding quote characters convert", %{conn: conn} do
      table = ~s|we"ird|
      column = "it's"

      assert :ok =
               NIF.execute_batch(
                 conn,
                 "CREATE TABLE #{quoted(table)} (#{quoted(column)} INTEGER);"
               )

      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO #{quoted(table)} VALUES (?)", [1])
      assert {:ok, []} = Xqlite.check_strict_violations(conn, table)

      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO #{quoted(table)} VALUES (?)", ["oops"])
      assert {:ok, [violation]} = Xqlite.check_strict_violations(conn, table)
      assert violation.column == column
      assert violation.actual_type == "text"

      assert {:ok, 1} =
               NIF.execute(
                 conn,
                 "DELETE FROM #{quoted(table)} WHERE typeof(#{quoted(column)}) = 'text'"
               )

      assert :ok = Xqlite.enable_strict_table(conn, table)
      assert strict?(conn, table)
    end

    test "converting a table twice is idempotent", %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE plain (id INTEGER);")
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO plain VALUES (?)", [1])

      assert :ok = Xqlite.enable_strict_table(conn, "plain")
      assert :ok = Xqlite.enable_strict_table(conn, "plain")

      assert strict?(conn, "plain")
      assert tables(conn) == ["plain"]
      assert {:ok, %{rows: [[1]]}} = NIF.query(conn, "SELECT id FROM plain", [])
    end

    test "a WITHOUT ROWID table is refused by both helpers", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(
                 conn,
                 "CREATE TABLE wr (id INTEGER PRIMARY KEY) WITHOUT ROWID;"
               )

      assert {:error, {:without_rowid_unsupported, "wr"}} =
               Xqlite.check_strict_violations(conn, "wr")

      assert {:error, {:without_rowid_unsupported, "wr"}} =
               Xqlite.enable_strict_table(conn, "wr")

      refute strict?(conn, "wr")
      assert tables(conn) == ["wr"]
    end

    test "a name holding a NUL byte is refused by both helpers", %{conn: conn} do
      name = "bad" <> <<0>> <> "name"

      assert {:error, :null_byte_in_string} = Xqlite.check_strict_violations(conn, name)
      assert {:error, :null_byte_in_string} = Xqlite.enable_strict_table(conn, name)
    end

    test "a newline between the name and the column list survives the rebuild", %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE users\n(id INTEGER)")
      assert :ok = Xqlite.enable_strict_table(conn, "users")

      assert {:ok, ~s|CREATE TABLE "users"\n(id INTEGER) STRICT|} =
               Xqlite.get_create_sql(conn, "users")
    end

    test "a tab between the name and the column list survives the rebuild", %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE users\t(id INTEGER)")
      assert :ok = Xqlite.enable_strict_table(conn, "users")

      assert {:ok, ~s|CREATE TABLE "users"\t(id INTEGER) STRICT|} =
               Xqlite.get_create_sql(conn, "users")
    end

    property "any name SQLite accepts round-trips through both helpers" do
      check all(scenario <- scenario(), max_runs: 2000) do
        assert {:ok, conn} = NIF.open_in_memory(":memory:")
        run_scenario(conn, scenario)
        assert :ok = NIF.close(conn)
      end
    end

    property "whitespace between the name and the column list survives the rebuild" do
      check all(gap <- whitespace_gap(), max_runs: 2000) do
        assert {:ok, conn} = NIF.open_in_memory(":memory:")
        assert :ok = NIF.execute_batch(conn, "CREATE TABLE users" <> gap <> "(id INTEGER)")
        assert :ok = Xqlite.enable_strict_table(conn, "users")

        assert {:ok, ~s|CREATE TABLE "users"| <> gap <> "(id INTEGER) STRICT"} ==
                 Xqlite.get_create_sql(conn, "users")

        assert :ok = NIF.close(conn)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # an unqualified name resolves in temp before main, the way SQLite resolves it
  # ---------------------------------------------------------------------------

  describe "temporary tables" do
    test "a temporary table converts inside the temp schema", %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TEMP TABLE tmp_users (id INTEGER);")
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO tmp_users VALUES (?)", [1])

      assert {:ok, []} = Xqlite.check_strict_violations(conn, "tmp_users")
      assert :ok = Xqlite.enable_strict_table(conn, "tmp_users")

      assert strict?(conn, "temp", "tmp_users")
      assert {:ok, %{rows: [[1]]}} = NIF.query(conn, "SELECT id FROM tmp_users", [])
      assert tables(conn) == []
    end

    test "a temporary table shadowing a main one converts only the temporary one",
         %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE shadowed (id INTEGER);")
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO shadowed VALUES (?)", [1])

      assert :ok =
               NIF.execute_batch(conn, "CREATE TEMP TABLE shadowed (id INTEGER, extra TEXT);")

      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO shadowed VALUES (?, ?)", [2, "two"])

      assert {:ok, []} = Xqlite.check_strict_violations(conn, "shadowed")
      assert :ok = Xqlite.enable_strict_table(conn, "shadowed")

      assert strict?(conn, "temp", "shadowed")
      refute strict?(conn, "main", "shadowed")

      assert {:ok, %{rows: [[2, "two"]]}} =
               NIF.query(conn, ~s|SELECT * FROM "temp"."shadowed"|, [])

      assert {:ok, %{rows: [[1]]}} = NIF.query(conn, ~s|SELECT * FROM "main"."shadowed"|, [])

      assert {:ok, "CREATE TABLE shadowed (id INTEGER)"} =
               Xqlite.get_create_sql(conn, "shadowed")
    end

    test "a WITHOUT ROWID main table does not refuse its plain temporary namesake",
         %{conn: conn} do
      assert :ok =
               NIF.execute_batch(
                 conn,
                 "CREATE TABLE ns (id INTEGER PRIMARY KEY) WITHOUT ROWID;"
               )

      assert :ok = NIF.execute_batch(conn, "CREATE TEMP TABLE ns (id INTEGER);")

      assert {:ok, []} = Xqlite.check_strict_violations(conn, "ns")
      assert :ok = Xqlite.enable_strict_table(conn, "ns")

      assert strict?(conn, "temp", "ns")
      refute strict?(conn, "main", "ns")
    end

    test "a temporary WITHOUT ROWID table is refused over its plain main namesake",
         %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE nr (id INTEGER);")

      assert :ok =
               NIF.execute_batch(
                 conn,
                 "CREATE TEMP TABLE nr (id INTEGER PRIMARY KEY) WITHOUT ROWID;"
               )

      assert {:error, {:without_rowid_unsupported, "nr"}} =
               Xqlite.check_strict_violations(conn, "nr")

      assert {:error, {:without_rowid_unsupported, "nr"}} =
               Xqlite.enable_strict_table(conn, "nr")
    end

    test "a temporary table keeps its indexes across the rebuild", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(
                 conn,
                 "CREATE TEMP TABLE tidx (id INTEGER, email TEXT);" <>
                   "CREATE UNIQUE INDEX tidx_email ON tidx(email);"
               )

      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO tidx VALUES (?, ?)", [1, "a@b.com"])

      assert :ok = Xqlite.enable_strict_table(conn, "tidx")

      assert strict?(conn, "temp", "tidx")

      assert {:error, {:constraint_violation, :constraint_unique, _}} =
               NIF.execute(conn, "INSERT INTO tidx VALUES (?, ?)", [2, "a@b.com"])
    end

    property "whitespace survives the rebuild of a temporary table" do
      check all(gap <- whitespace_gap(), max_runs: 2000) do
        assert {:ok, conn} = NIF.open_in_memory(":memory:")

        assert :ok =
                 NIF.execute_batch(conn, "CREATE TEMP TABLE users" <> gap <> "(id INTEGER)")

        assert :ok = Xqlite.enable_strict_table(conn, "users")

        assert {:ok, ~s|CREATE TABLE "users"| <> gap <> "(id INTEGER) STRICT"} ==
                 temp_create_sql(conn, "users")

        assert :ok = NIF.close(conn)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # main precedes the attached databases, and those follow attach order
  # ---------------------------------------------------------------------------

  describe "attached databases" do
    test "a main table wins over its namesake in an attached database", %{conn: conn} do
      attach(conn)
      plant_table(conn, "main")
      plant_table(conn, "att1")

      assert {:ok, [violation]} = Xqlite.check_strict_violations(conn, "t")
      assert violation.rowid == planted_rowid("main")

      clean_table(conn, "main")
      clean_table(conn, "att1")

      assert :ok = Xqlite.enable_strict_table(conn, "t")

      assert strict?(conn, "main", "t")
      refute strict?(conn, "att1", "t")
    end

    test "a table only in an attached database converts inside that schema", %{conn: conn} do
      attach(conn)
      plant_table(conn, "att2")

      assert {:ok, [violation]} = Xqlite.check_strict_violations(conn, "t")
      assert violation.rowid == planted_rowid("att2")
      assert violation.column == "c"
      assert violation.actual_type == "text"

      clean_table(conn, "att2")

      assert :ok = Xqlite.enable_strict_table(conn, "t")

      assert strict?(conn, "att2", "t")
      assert {:ok, %{rows: [[7]]}} = NIF.query(conn, ~s|SELECT c FROM "att2"."t"|, [])
    end

    property "an unqualified name resolves in temp, then main, then attach order" do
      check all(schemas <- schema_subset(), max_runs: 2000) do
        assert {:ok, conn} = NIF.open_in_memory(":memory:")
        attach(conn)
        Enum.each(schemas, &plant_table(conn, &1))
        resolved = resolved_schema(schemas)

        assert {:ok, [violation]} = Xqlite.check_strict_violations(conn, "t")
        assert violation.rowid == planted_rowid(resolved)
        assert violation.column == "c"
        assert violation.actual_type == "text"
        assert violation.expected_type == "INTEGER"

        Enum.each(schemas, &clean_table(conn, &1))
        assert :ok = Xqlite.enable_strict_table(conn, "t")

        Enum.each(schemas, fn schema ->
          assert strict?(conn, schema, "t") == (schema == resolved)
        end)

        assert :ok = NIF.close(conn)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # the rebuild's own transaction closes before the helper returns
  # ---------------------------------------------------------------------------

  describe "the rebuild's transaction" do
    test "the rebuild leaves the connection out of any transaction", %{conn: conn} do
      assert :ok = NIF.execute_batch(conn, "CREATE TABLE settled (id INTEGER);")
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO settled VALUES (?)", [1])
      assert {:ok, false} = Xqlite.transaction_status(conn)

      assert :ok = Xqlite.enable_strict_table(conn, "settled")

      assert {:ok, false} = Xqlite.transaction_status(conn)
      assert strict?(conn, "settled")
    end

    test "a second connection to the same file sees the rebuilt table" do
      path = tmp_db_path("strict_rebuild")

      assert {:ok, writer} = NIF.open(path)
      on_exit(fn -> NIF.close(writer) end)

      assert :ok =
               NIF.execute_batch(
                 writer,
                 "CREATE TABLE shared (id INTEGER, email TEXT);" <>
                   "CREATE UNIQUE INDEX shared_email ON shared(email);"
               )

      assert {:ok, 1} = NIF.execute(writer, "INSERT INTO shared VALUES (?, ?)", [1, "a@b.com"])
      assert :ok = Xqlite.enable_strict_table(writer, "shared")

      assert {:ok, reader} = NIF.open(path)
      on_exit(fn -> NIF.close(reader) end)

      assert strict?(reader, "shared")
      assert {:ok, %{rows: [[1, "a@b.com"]]}} = NIF.query(reader, "SELECT * FROM shared", [])

      assert {:error, {:constraint_violation, :constraint_unique, _}} =
               NIF.execute(reader, "INSERT INTO shared VALUES (?, ?)", [2, "a@b.com"])
    end
  end

  # ---------------------------------------------------------------------------
  # the rebuild drops and recreates the table, so everything SQLite attaches to
  # a table — foreign-key actions on its children, its triggers, the views that
  # read it, its rowids — has to come back
  # ---------------------------------------------------------------------------

  describe "what the rebuild carries across" do
    for {label, clause} <- [
          {"ON DELETE CASCADE", "ON DELETE CASCADE"},
          {"ON DELETE SET NULL", "ON DELETE SET NULL"},
          {"ON DELETE SET DEFAULT", "ON DELETE SET DEFAULT"},
          {"ON DELETE RESTRICT", "ON DELETE RESTRICT"},
          {"no action clause", ""}
        ] do
      test "a child declaring #{label} keeps its rows when the parent converts",
           %{conn: conn} do
        plant_parent_and_child(conn, unquote(clause))

        assert :ok = Xqlite.enable_strict_table(conn, "p")

        assert strict?(conn, "p")

        assert {:ok, %{rows: [[1, 1], [2, 1]]}} =
                 NIF.query(conn, "SELECT id, p_id FROM ch", [])

        assert {:ok, %{rows: []}} = NIF.query(conn, "PRAGMA foreign_key_check", [])
        assert pragma_flag(conn, "foreign_keys") == 1
      end
    end

    test "a trigger on the table survives and still fires", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE t (c INTEGER);
               CREATE TABLE log (n INTEGER);
               CREATE TRIGGER t_ai AFTER INSERT ON t BEGIN INSERT INTO log VALUES (new.c); END;
               """)

      assert :ok = Xqlite.enable_strict_table(conn, "t")

      assert strict?(conn, "t")

      assert {:ok,
              %{
                rows: [
                  [
                    "CREATE TRIGGER t_ai AFTER INSERT ON t BEGIN INSERT INTO log VALUES (new.c); END"
                  ]
                ]
              }} =
               NIF.query(conn, "SELECT sql FROM main.sqlite_master WHERE type='trigger'", [])

      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (?)", [5])
      assert {:ok, %{rows: [[5]]}} = NIF.query(conn, "SELECT n FROM log", [])
    end

    test "a temporary trigger on a main table survives and still fires", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE mt (c INTEGER);
               CREATE TABLE mlog (n INTEGER);
               CREATE TEMP TRIGGER mt_ai AFTER INSERT ON main.mt
                 BEGIN INSERT INTO mlog VALUES (new.c); END;
               """)

      assert :ok = Xqlite.enable_strict_table(conn, "mt")

      assert strict?(conn, "mt")

      assert {:ok, %{rows: [["mt_ai", "mt"]]}} =
               NIF.query(conn, "SELECT name, tbl_name FROM temp.sqlite_master", [])

      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO mt VALUES (?)", [8])
      assert {:ok, %{rows: [[8]]}} = NIF.query(conn, "SELECT n FROM mlog", [])
    end

    test "a trigger on another table that writes the table still fires", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE t (c INTEGER);
               CREATE TABLE other (n INTEGER);
               CREATE TRIGGER other_ai AFTER INSERT ON other
                 BEGIN INSERT INTO t VALUES (new.n); END;
               """)

      assert :ok = Xqlite.enable_strict_table(conn, "t")

      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO other VALUES (?)", [4])
      assert {:ok, %{rows: [[4]]}} = NIF.query(conn, "SELECT c FROM t", [])
    end

    test "the views that read the table keep answering", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE t (c INTEGER);
               CREATE VIEW v AS SELECT c FROM t;
               CREATE VIEW v2 AS SELECT c FROM v;
               CREATE TEMP VIEW tv AS SELECT c FROM main.t;
               INSERT INTO t VALUES (1), (2);
               """)

      assert :ok = Xqlite.enable_strict_table(conn, "t")

      assert strict?(conn, "t")
      assert {:ok, %{rows: [[1], [2]]}} = NIF.query(conn, "SELECT c FROM v", [])
      assert {:ok, %{rows: [[1], [2]]}} = NIF.query(conn, "SELECT c FROM v2", [])
      assert {:ok, %{rows: [[1], [2]]}} = NIF.query(conn, "SELECT c FROM tv", [])
    end

    test "a table in an attached database keeps a usable index", %{conn: conn} do
      attach(conn)

      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE att1.t (c INTEGER);
               CREATE UNIQUE INDEX att1.t_c ON t(c);
               INSERT INTO att1.t VALUES (1), (2);
               """)

      assert :ok = Xqlite.enable_strict_table(conn, "t")

      assert strict?(conn, "att1", "t")

      assert {:error, {:constraint_violation, :constraint_unique, _}} =
               NIF.execute(conn, "INSERT INTO att1.t VALUES (?)", [1])

      assert {:ok, %{rows: plan_rows}} =
               NIF.query(conn, "EXPLAIN QUERY PLAN SELECT c FROM att1.t WHERE c = 1", [])

      assert Enum.any?(plan_rows, &plan_names_index?/1)
    end

    test "a gap in the rowids survives", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE t (c INTEGER);
               INSERT INTO t (rowid, c) VALUES (1, 1), (3, 3);
               """)

      assert :ok = Xqlite.enable_strict_table(conn, "t")

      assert {:ok, %{rows: [[1, 1], [3, 3]]}} =
               NIF.query(conn, "SELECT rowid, c FROM t ORDER BY rowid", [])
    end

    test "a table with generated columns converts", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE g (
                 a INTEGER,
                 b INTEGER GENERATED ALWAYS AS (a * 2) VIRTUAL,
                 e INTEGER GENERATED ALWAYS AS (a * 3) STORED
               );
               INSERT INTO g (a) VALUES (1), (2);
               """)

      assert :ok = Xqlite.enable_strict_table(conn, "g")

      assert strict?(conn, "g")

      assert {:ok, %{rows: [[1, 1, 2, 3], [2, 2, 4, 6]]}} =
               NIF.query(conn, "SELECT rowid, a, b, e FROM g ORDER BY rowid", [])
    end

    test "a self-referencing foreign key converts", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE s (id INTEGER PRIMARY KEY, parent INTEGER REFERENCES s(id));
               INSERT INTO s VALUES (1, NULL), (2, 1);
               """)

      assert :ok = Xqlite.enable_strict_table(conn, "s")

      assert strict?(conn, "s")
      assert {:ok, %{rows: []}} = NIF.query(conn, "PRAGMA foreign_key_check", [])
      assert row_count(conn, "s") == 2
    end

    test "every index shape comes back byte-identical", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE t (c INTEGER, d TEXT);
               CREATE UNIQUE INDEX "i ""x"".y" ON t(c);
               CREATE INDEX i_partial ON t(c) WHERE c > 1;
               CREATE INDEX i_expression ON t(length(d));
               CREATE INDEX [i desc] ON t(c DESC);
               INSERT INTO t VALUES (1, 'a'), (2, 'b');
               """)

      before = master_rows(conn, "main")

      assert :ok = Xqlite.enable_strict_table(conn, "t")

      assert master_rows(conn, "main") ==
               Enum.map(
                 before,
                 &strict_master_row(&1, "t", ~s|CREATE TABLE "t" (c INTEGER, d TEXT)|)
               )
    end
  end

  # ---------------------------------------------------------------------------
  # the refusals that keep the rebuild from destroying what it cannot rebuild
  # ---------------------------------------------------------------------------

  describe "the rebuild's refusals" do
    test "a call inside a caller's transaction is refused and leaves it open",
         %{conn: conn} do
      assert :ok =
               NIF.execute_batch(
                 conn,
                 "CREATE TABLE t (c INTEGER); CREATE TABLE keep (c INTEGER);"
               )

      assert {:ok, _} = NIF.execute(conn, "BEGIN IMMEDIATE", [])
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO keep VALUES (?)", [1])

      assert {:error, :transaction_in_progress} = Xqlite.enable_strict_table(conn, "t")

      assert {:ok, true} = Xqlite.transaction_status(conn)
      assert row_count(conn, "keep") == 1
      assert {:ok, _} = NIF.execute(conn, "COMMIT", [])
      assert row_count(conn, "keep") == 1
      refute strict?(conn, "t")
    end

    test "an existing rebuild table is refused by its bare name", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE t (c INTEGER);
               CREATE TABLE t_xqlite_strict_rebuild (c INTEGER);
               """)

      assert {:error, {:table_exists, "t_xqlite_strict_rebuild"}} =
               Xqlite.enable_strict_table(conn, "t")

      refute strict?(conn, "t")
      assert {:ok, false} = Xqlite.transaction_status(conn)
    end

    test "a table declaring rowid, _rowid_ and oid is refused", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(
                 conn,
                 ~s|CREATE TABLE t ("RowID" TEXT, "_RowID_" TEXT, "OID" TEXT);|
               )

      assert {:error, {:rowid_shadowed, "t"}} = Xqlite.enable_strict_table(conn, "t")

      refute strict?(conn, "t")
    end

    test "all three names declared with one of them the rowid alias converts",
         %{conn: conn} do
      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE t (rowid INTEGER PRIMARY KEY, _rowid_ TEXT, oid TEXT);
               INSERT INTO t VALUES (10, 'a', 'x'), (30, 'c', 'z');
               """)

      assert :ok = Xqlite.enable_strict_table(conn, "t")

      assert strict?(conn, "t")

      assert {:ok, %{rows: [[10, "a", "x"], [30, "c", "z"]]}} =
               NIF.query(conn, ~s|SELECT "rowid", "_rowid_", "oid" FROM t ORDER BY 1|, [])
    end

    test "all three names shadowed beside the rowid alias keeps the index and the values",
         %{conn: conn} do
      columns = ~s|"rowid" TEXT, "_rowid_" TEXT, "oid" TEXT, id INTEGER PRIMARY KEY|

      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE t (#{columns});
               CREATE INDEX t_i ON t("oid");
               INSERT INTO t VALUES ('a', 'b', 'c', 7), ('d', 'e', 'f', 9);
               """)

      before = master_rows(conn, "main")

      assert :ok = Xqlite.enable_strict_table(conn, "t")

      assert strict?(conn, "t")

      assert master_rows(conn, "main") ==
               Enum.map(
                 before,
                 &strict_master_row(&1, "t", ~s|CREATE TABLE "t" (| <> columns <> ")")
               )

      assert {:ok, %{rows: [["a", "b", "c", 7], ["d", "e", "f", 9]]}} =
               NIF.query(conn, ~s|SELECT "rowid", "_rowid_", "oid", id FROM t ORDER BY id|, [])
    end

    for {label, declaration} <- [
          {"a descending primary key", "id INTEGER PRIMARY KEY DESC"},
          {"a primary key declared INT", "id INT PRIMARY KEY"}
        ] do
      test "all three names shadowed beside #{label} is refused", %{conn: conn} do
        assert :ok =
                 NIF.execute_batch(conn, """
                 CREATE TABLE t ("rowid" TEXT, "_rowid_" TEXT, "oid" TEXT, #{unquote(declaration)});
                 INSERT INTO t VALUES ('a', 'b', 'c', 7);
                 """)

        before = master_rows(conn, "main")

        assert {:error, {:rowid_shadowed, "t"}} = Xqlite.enable_strict_table(conn, "t")

        refute strict?(conn, "t")
        assert master_rows(conn, "main") == before

        assert {:ok, %{rows: [["a", "b", "c", 7]]}} =
                 NIF.query(conn, ~s|SELECT "rowid", "_rowid_", "oid", id FROM t|, [])
      end
    end

    test "the pragmas the rebuild switches are restored after a failure", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(
                 conn,
                 "CREATE TABLE g (a INTEGER, b NUMERIC GENERATED ALWAYS AS (a * 2) VIRTUAL);"
               )

      assert {:error, _reason} = Xqlite.enable_strict_table(conn, "g")

      refute strict?(conn, "g")
      assert pragma_flag(conn, "foreign_keys") == 1
      assert pragma_flag(conn, "legacy_alter_table") == 0
      assert {:ok, false} = Xqlite.transaction_status(conn)
      assert tables(conn) == ["g"]
    end

    test "a stored index statement the rewrite cannot parse is refused", %{conn: conn} do
      assert :ok =
               NIF.execute_batch(conn, """
               CREATE TABLE t (c INTEGER);
               CREATE INDEX i ON t(c);
               INSERT INTO t VALUES (1), (2);
               """)

      unparsable = "CREATE /* note */ INDEX i ON t(c)"
      plant_index_sql(conn, unparsable)
      before = master_rows(conn, "main")

      assert {:error,
              {:schema_parsing_error, "sqlite_master", {:unexpected_value, ^unparsable}}} =
               Xqlite.enable_strict_table(conn, "t")

      refute strict?(conn, "t")
      assert master_rows(conn, "main") == before

      assert {:ok, %{rows: [[1, 1], [2, 2]]}} =
               NIF.query(conn, "SELECT rowid, c FROM t ORDER BY 1", [])

      assert {:ok, false} = Xqlite.transaction_status(conn)
      assert pragma_flag(conn, "foreign_keys") == 1
      assert pragma_flag(conn, "legacy_alter_table") == 0
    end
  end

  # ---------------------------------------------------------------------------
  # the two laws: what a successful rebuild preserves, and what a refused one
  # leaves alone
  # ---------------------------------------------------------------------------

  describe "the rebuild's laws" do
    property "a successful rebuild preserves the schema, the rows and the pragmas" do
      check all(layout <- layout(), max_runs: 2000) do
        assert {:ok, conn} = Xqlite.open_in_memory()
        run_layout(conn, layout)
        assert :ok = NIF.close(conn)
      end
    end

    property "a refused rebuild leaves the schema, the rows and the pragmas alone" do
      check all(refusal <- refusal(), max_runs: 2000) do
        assert {:ok, conn} = Xqlite.open_in_memory()
        run_refusal(conn, refusal)
        assert :ok = NIF.close(conn)
      end
    end
  end

  defp quoted(name), do: ~s|"| <> String.replace(name, ~s|"|, ~s|""|) <> ~s|"|

  defp temp_create_sql(conn, table) do
    sql = ~s|SELECT sql FROM "temp".sqlite_master WHERE type='table' AND name=?|

    assert {:ok, %{rows: [[create_sql]]}} = NIF.query(conn, sql, [table])
    {:ok, create_sql}
  end

  defp strict?(conn, table), do: strict?(conn, "main", table)

  defp strict?(conn, schema, table) do
    assert {:ok, objects} = Xqlite.schema_list_objects(conn, schema)

    Enum.any?(objects, fn
      %Xqlite.Schema.SchemaObjectInfo{name: ^table, strict: strict} -> strict
      _other -> false
    end)
  end

  defp tables(conn) do
    sql = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
    assert {:ok, %{rows: rows}} = NIF.query(conn, sql, [])

    Enum.map(rows, fn
      [name] -> name
      other -> other
    end)
  end

  defp row_count(conn, table) do
    assert {:ok, %{rows: [[n]]}} = NIF.query(conn, "SELECT count(*) FROM #{quoted(table)}", [])
    n
  end

  defp attach(conn) do
    assert {:ok, _} = NIF.execute(conn, "ATTACH ':memory:' AS att1", [])
    assert {:ok, _} = NIF.execute(conn, "ATTACH ':memory:' AS att2", [])
  end

  # SQLite writes its own `CREATE INDEX` opening over the one the statement
  # used, so a stored statement the rebuild cannot read back is only ever a
  # schema someone wrote into the catalogue by hand.
  defp plant_index_sql(conn, sql) do
    assert {:ok, _} = NIF.execute(conn, "PRAGMA writable_schema = ON", [])

    assert {:ok, 1} =
             NIF.execute(conn, "UPDATE sqlite_master SET sql = ? WHERE type='index'", [sql])

    assert {:ok, _} = NIF.execute(conn, "PRAGMA writable_schema = OFF", [])
  end

  # One clean row and one row SQLite would refuse under STRICT, at rowids only
  # this schema uses, so a reported violation names the schema it came from.
  defp plant_table(conn, schema) do
    assert {:ok, _} = NIF.execute(conn, "CREATE TABLE #{schema}.t (c INTEGER)", [])
    insert_at(conn, schema, planted_rowid(schema) - 1, 7)
    insert_at(conn, schema, planted_rowid(schema), "oops")
  end

  defp insert_at(conn, schema, rowid, value) do
    sql = "INSERT INTO #{schema}.t (rowid, c) VALUES (?, ?)"
    assert {:ok, 1} = NIF.execute(conn, sql, [rowid, value])
  end

  defp clean_table(conn, schema) do
    sql = "DELETE FROM #{schema}.t WHERE typeof(c) = 'text'"
    assert {:ok, 1} = NIF.execute(conn, sql, [])
  end

  defp planted_rowid(schema), do: 10 * (schema_order(schema) + 1)

  defp schema_order("temp"), do: 0
  defp schema_order("main"), do: 1
  defp schema_order("att1"), do: 2
  defp schema_order("att2"), do: 3

  defp resolved_schema(schemas), do: Enum.min_by(schemas, &schema_order/1)

  defp schema_subset do
    ~w[temp main att1 att2]
    |> subsets()
    |> Enum.reject(&(&1 == []))
    |> StreamData.member_of()
  end

  defp subsets([]), do: [[]]

  defp subsets([head | tail]) do
    rest = subsets(tail)
    rest ++ Enum.map(rest, &[head | &1])
  end

  # A binary parameter binds as text when it is valid UTF-8 and as a blob when
  # it is not, so the invalid ones are the only way to store a blob from here.
  defp strict_value do
    StreamData.one_of([
      StreamData.integer(),
      StreamData.scale(StreamData.float(), fn _size -> 3 end),
      StreamData.member_of(["", "12", "1.5", "abc", <<0>>, "a" <> <<0>> <> "b", "1e3", "  "]),
      StreamData.member_of([<<255>>, <<0xFF, 0xFE>>, <<0xC3, 0x28>>, <<0, 255>>]),
      StreamData.constant(nil)
    ])
  end

  defp reported_violations(violations) do
    violations
    |> Enum.map(&violation_tuple/1)
    |> Enum.sort()
  end

  defp violation_tuple(violation) do
    {violation.rowid, violation.column, violation.actual_type, violation.expected_type}
  end

  defp oracle_violations(conn, declared) do
    assert {:ok, %{rows: rows}} = NIF.query(conn, "SELECT rowid, typeof(c) FROM probe", [])

    rows
    |> Enum.flat_map(&outside_accepted(&1, declared))
    |> Enum.sort()
  end

  defp outside_accepted([rowid, actual], declared) do
    case actual in accepted_classes(declared) do
      true -> []
      false -> [{rowid, "c", actual, declared}]
    end
  end

  defp accepted_classes("INTEGER"), do: ["integer", "null"]
  defp accepted_classes("REAL"), do: ["real", "integer", "null"]
  defp accepted_classes("TEXT"), do: ["text", "integer", "real", "null"]
  defp accepted_classes("BLOB"), do: ["blob", "null"]
  defp accepted_classes("ANY"), do: ["integer", "real", "text", "blob", "null"]

  defp name_char do
    StreamData.member_of([
      ?a,
      ?b,
      ?t,
      ?X,
      ?Z,
      ?0,
      ?9,
      ?_,
      ?\s,
      ?",
      ?',
      ?`,
      ?[,
      ?],
      ?.,
      ?-,
      ?+,
      ?(,
      ?),
      ?*,
      ?\\,
      ?é,
      ?ß
    ])
  end

  # SQLite's tokenizer takes exactly these five bytes as whitespace between
  # the table name and the column list; a vertical tab is an unrecognized
  # token there, so no generated run can hold one.
  defp whitespace_gap do
    [" ", "\t", "\n", "\r", "\f"]
    |> StreamData.member_of()
    |> StreamData.list_of(min_length: 1, max_length: 3)
    |> StreamData.map(&Enum.join/1)
  end

  defp hostile_name do
    name_char()
    |> StreamData.list_of(min_length: 1, max_length: 20)
    |> StreamData.map(&List.to_string/1)
  end

  defp declared_type do
    StreamData.one_of([
      strict_declared_type(),
      StreamData.member_of([
        "VARCHAR(255)",
        "VARCHAR(1)",
        "CHARACTER(20)",
        "DATETIME",
        "DATE",
        "NUMERIC",
        "DECIMAL(10,5)",
        "DOUBLE",
        "FLOAT",
        "BOOLEAN",
        "CLOB",
        "SMALLINT",
        "BIGINT",
        "UNSIGNED BIG INT"
      ]),
      StreamData.constant("")
    ])
  end

  defp strict_declared_type do
    gen all(
          name <- StreamData.member_of(~w[INT INTEGER REAL TEXT BLOB ANY]),
          uppercase <- StreamData.list_of(StreamData.boolean(), length: String.length(name)),
          lead <- type_padding(),
          trail <- type_padding()
        ) do
      lead <> recased(name, uppercase) <> trail
    end
  end

  defp type_padding, do: StreamData.member_of(["", " ", "  ", "\t", "\n"])

  defp recased(name, uppercase) do
    name
    |> String.graphemes()
    |> Enum.zip(uppercase)
    |> Enum.map_join("", &recased_char/1)
  end

  defp recased_char({char, true}), do: String.upcase(char)
  defp recased_char({char, false}), do: String.downcase(char)

  defp declared_verdict(violations) do
    case Enum.any?(
           violations,
           &(&1[:kind] in [:unknown_declared_type, :missing_declared_type])
         ) do
      true -> :refused
      false -> :accepted
    end
  end

  defp strict_verdict(:ok), do: :accepted
  defp strict_verdict({:error, _reason}), do: :refused

  defp spellings(name) do
    [:double_quote, :backtick] ++ bracket_spelling(name) ++ bare_spelling(name)
  end

  defp bracket_spelling(name) do
    case String.contains?(name, "]") do
      true -> []
      false -> [:bracket]
    end
  end

  defp bare_spelling(name) do
    case Regex.match?(~r/^t[A-Za-z0-9_]*$/, name) do
      true -> [:bare]
      false -> []
    end
  end

  defp render(name, :double_quote), do: quoted(name)
  defp render(name, :backtick), do: "`" <> String.replace(name, "`", "``") <> "`"
  defp render(name, :bracket), do: "[" <> name <> "]"
  defp render(name, :bare), do: name

  defp scenario do
    gen all(
          table <- hostile_name(),
          column <- hostile_name(),
          spelling <- StreamData.member_of(spellings(table)),
          rows <- StreamData.list_of(StreamData.integer(), max_length: 3),
          dirty <- StreamData.boolean(),
          without_rowid <-
            StreamData.frequency([
              {7, StreamData.constant(false)},
              {1, StreamData.constant(true)}
            ])
        ) do
      %{
        table: table,
        column: column,
        spelling: spelling,
        rows: rows,
        dirty: dirty,
        without_rowid: without_rowid
      }
    end
  end

  defp create_table(conn, %{without_rowid: true} = scenario) do
    sql =
      "CREATE TABLE #{render(scenario.table, scenario.spelling)} " <>
        "(#{quoted(scenario.column)} INTEGER PRIMARY KEY) WITHOUT ROWID;"

    assert :ok = NIF.execute_batch(conn, sql)
  end

  defp create_table(conn, scenario) do
    sql =
      "CREATE TABLE #{render(scenario.table, scenario.spelling)} " <>
        "(#{quoted(scenario.column)} INTEGER);"

    assert :ok = NIF.execute_batch(conn, sql)
  end

  defp insert_rows(conn, scenario) do
    Enum.each(scenario.rows, fn value ->
      assert {:ok, 1} =
               NIF.execute(conn, "INSERT INTO #{quoted(scenario.table)} VALUES (?)", [value])
    end)
  end

  defp run_scenario(conn, %{without_rowid: true} = scenario) do
    create_table(conn, scenario)
    table = scenario.table

    assert {:error, {:without_rowid_unsupported, ^table}} =
             Xqlite.check_strict_violations(conn, table)

    assert {:error, {:without_rowid_unsupported, ^table}} =
             Xqlite.enable_strict_table(conn, table)

    refute strict?(conn, table)
  end

  defp run_scenario(conn, %{dirty: true} = scenario) do
    create_table(conn, scenario)
    insert_rows(conn, scenario)

    assert {:ok, 1} =
             NIF.execute(conn, "INSERT INTO #{quoted(scenario.table)} VALUES (?)", ["oops"])

    assert {:ok, [violation]} = Xqlite.check_strict_violations(conn, scenario.table)
    assert violation.column == scenario.column
    assert violation.actual_type == "text"

    assert {:error, {:strict_violations, [_]}} =
             Xqlite.enable_strict_table(conn, scenario.table)

    refute strict?(conn, scenario.table)
    assert row_count(conn, scenario.table) == length(scenario.rows) + 1
  end

  defp run_scenario(conn, scenario) do
    create_table(conn, scenario)
    insert_rows(conn, scenario)

    assert {:ok, []} = Xqlite.check_strict_violations(conn, scenario.table)
    assert :ok = Xqlite.enable_strict_table(conn, scenario.table)
    assert :ok = Xqlite.enable_strict_table(conn, scenario.table)

    assert strict?(conn, scenario.table)
    assert tables(conn) == [scenario.table]
    assert row_count(conn, scenario.table) == length(scenario.rows)
  end

  @law_schemas ["main", "temp", "att1", "att2"]

  defp plant_parent_and_child(conn, clause) do
    assert :ok =
             NIF.execute_batch(conn, """
             CREATE TABLE p (id INTEGER PRIMARY KEY);
             CREATE TABLE ch (id INTEGER PRIMARY KEY,
               p_id INTEGER DEFAULT 1 REFERENCES p(id) #{clause});
             INSERT INTO p VALUES (1);
             INSERT INTO ch VALUES (1, 1), (2, 1);
             """)
  end

  defp pragma_flag(conn, name) do
    assert {:ok, %{rows: [[value]]}} = NIF.query(conn, "PRAGMA " <> name, [])
    value
  end

  defp set_law_flag(conn, name, on?) do
    assert {:ok, _} = NIF.execute(conn, "PRAGMA " <> name <> " = " <> law_on_off(on?), [])
  end

  defp law_on_off(true), do: "ON"
  defp law_on_off(false), do: "OFF"

  defp law_flag(true), do: 1
  defp law_flag(false), do: 0

  defp master_rows(conn, schema) do
    sql =
      "SELECT type, name, tbl_name, sql FROM " <>
        quoted(schema) <> ".sqlite_master ORDER BY type, name"

    assert {:ok, %{rows: rows}} = NIF.query(conn, sql, [])
    rows
  end

  defp strict_master_row(["table", name, tbl_name, _sql], name, create_sql),
    do: ["table", name, tbl_name, create_sql <> " STRICT"]

  defp strict_master_row(row, _table, _create_sql), do: row

  defp plan_names_index?([_id, _parent, _notused, detail]), do: String.contains?(detail, "t_c")
  defp plan_names_index?(_row), do: false

  # ---------------------------------------------------------------------------
  # the preservation law's generated layout: a table with a rowid gap, and any
  # combination of the things SQLite attaches to a table around it
  # ---------------------------------------------------------------------------

  defp layout do
    gen all(
          schema <- StreamData.member_of(@law_schemas),
          table <- StreamData.member_of(["t", "t x", ~s|t"x|, "t]y"]),
          spelling <- StreamData.member_of(spellings(table)),
          columns <- law_columns(),
          alias? <- StreamData.boolean(),
          index <- StreamData.member_of([:none, :unique, :partial, :expression, :desc]),
          trigger? <- StreamData.boolean(),
          view? <- StreamData.boolean(),
          child <- law_child(alias?),
          foreign_keys <- StreamData.boolean(),
          legacy_alter_table <- StreamData.boolean()
        ) do
      %{
        schema: schema,
        table: table,
        spelling: spelling,
        columns: columns,
        alias?: alias?,
        index: index,
        trigger?: trigger?,
        view?: view?,
        child: child,
        foreign_keys: foreign_keys,
        legacy_alter_table: legacy_alter_table
      }
    end
  end

  defp law_columns do
    hostile_name()
    |> StreamData.list_of(min_length: 1, max_length: 2)
    |> StreamData.map(&law_distinct/1)
  end

  defp law_distinct(names), do: Enum.uniq_by(names, &String.downcase/1)

  # A child can only name a parent key, so a foreign key needs the alias column.
  defp law_child(true),
    do: StreamData.member_of([:none, :cascade, :set_null, :set_default, :restrict, :no_action])

  defp law_child(false), do: StreamData.constant(:none)

  defp run_layout(conn, layout) do
    attach(conn)
    set_law_flag(conn, "foreign_keys", layout.foreign_keys)
    set_law_flag(conn, "legacy_alter_table", layout.legacy_alter_table)

    layout
    |> layout_statements()
    |> run_statements(conn)

    before = snapshot(conn)
    fk_before = fk_check(conn, layout.schema)
    view_before = law_view_rows(conn, layout)

    assert :ok = Xqlite.enable_strict_table(conn, layout.table)

    assert strict?(conn, layout.schema, layout.table)
    assert snapshot(conn) == converted(before, layout)
    assert fk_check(conn, layout.schema) == fk_before
    assert law_view_rows(conn, layout) == view_before
    assert pragma_flag(conn, "foreign_keys") == law_flag(layout.foreign_keys)
    assert pragma_flag(conn, "legacy_alter_table") == law_flag(layout.legacy_alter_table)
    assert {:ok, false} = Xqlite.transaction_status(conn)
    assert_trigger_fires(conn, layout)
  end

  defp run_statements(statements, conn) do
    Enum.each(statements, fn
      {sql, params} -> assert {:ok, _} = NIF.execute(conn, sql, params)
      other -> flunk("unbuildable statement: " <> inspect(other))
    end)
  end

  defp layout_statements(layout) do
    [{law_create_statement(layout), []}] ++
      law_row_statements(layout) ++
      law_index_statements(layout) ++
      law_trigger_statements(layout) ++
      law_view_statements(layout) ++
      law_child_statements(layout)
  end

  defp law_create_statement(layout) do
    rendered = render(layout.table, layout.spelling)
    law_create_sql(layout, quoted(layout.schema) <> "." <> rendered)
  end

  defp law_create_sql(layout, rendered),
    do: "CREATE TABLE " <> rendered <> " (" <> law_column_defs(layout) <> ")"

  defp law_column_defs(layout) do
    layout.columns
    |> Enum.with_index()
    |> Enum.map_join(", ", &law_column_def(&1, layout))
  end

  defp law_column_def({name, 0}, %{alias?: true}), do: quoted(name) <> " INTEGER PRIMARY KEY"
  defp law_column_def({name, 0}, _layout), do: quoted(name) <> " INTEGER"
  defp law_column_def({name, _index}, _layout), do: quoted(name) <> " TEXT"

  defp law_object(layout, name), do: quoted(layout.schema) <> "." <> quoted(name)

  defp law_row_statements(layout) do
    names = ["rowid" | layout.columns]
    columns = Enum.map_join(names, ", ", &quoted/1)
    marks = Enum.map_join(names, ", ", fn _name -> "?" end)

    sql =
      "INSERT INTO " <>
        law_object(layout, layout.table) <> " (" <> columns <> ") VALUES (" <> marks <> ")"

    Enum.map(law_row_values(layout), fn values -> {sql, Enum.take(values, length(names))} end)
  end

  defp law_row_values(%{alias?: true}), do: [[1, 1, "a"], [3, 3, "b"]]
  defp law_row_values(_layout), do: [[1, 10, "a"], [3, 30, "b"]]

  defp law_index_statements(%{index: :none}), do: []

  defp law_index_statements(layout) do
    column = quoted(List.last(layout.columns))
    sql = law_index_sql(layout.index, law_object(layout, "ix"), quoted(layout.table), column)
    [{sql, []}]
  end

  defp law_index_sql(:unique, name, table, column),
    do: "CREATE UNIQUE INDEX " <> name <> " ON " <> table <> "(" <> column <> ")"

  defp law_index_sql(:partial, name, table, column),
    do:
      "CREATE INDEX " <>
        name <> " ON " <> table <> "(" <> column <> ") WHERE " <> column <> " IS NOT NULL"

  defp law_index_sql(:expression, name, table, column),
    do: "CREATE INDEX " <> name <> " ON " <> table <> "(length(" <> column <> "))"

  defp law_index_sql(:desc, name, table, column),
    do: "CREATE INDEX " <> name <> " ON " <> table <> "(" <> column <> " DESC)"

  defp law_trigger_statements(%{trigger?: false}), do: []

  defp law_trigger_statements(layout) do
    [
      {"CREATE TABLE " <> law_object(layout, "log") <> " (n INTEGER)", []},
      {"CREATE TRIGGER " <>
         law_object(layout, "tr") <>
         " AFTER INSERT ON " <>
         quoted(layout.table) <> " BEGIN INSERT INTO \"log\" VALUES (1); END", []}
    ]
  end

  defp law_view_statements(%{view?: false}), do: []

  defp law_view_statements(layout) do
    sql =
      "CREATE VIEW " <>
        law_object(layout, "v") <>
        " AS SELECT " <> quoted(List.first(layout.columns)) <> " FROM " <> quoted(layout.table)

    [{sql, []}]
  end

  defp law_child_statements(%{child: :none}), do: []

  defp law_child_statements(layout) do
    create =
      "CREATE TABLE " <>
        law_object(layout, "ch") <>
        " (id INTEGER PRIMARY KEY, p INTEGER DEFAULT 1 REFERENCES " <>
        quoted(layout.table) <>
        "(" <> quoted(List.first(layout.columns)) <> ") " <> law_fk_action(layout.child) <> ")"

    insert = "INSERT INTO " <> law_object(layout, "ch") <> " VALUES (?, ?)"

    [{create, []}, {insert, [1, 1]}, {insert, [2, 1]}]
  end

  defp law_fk_action(:cascade), do: "ON DELETE CASCADE"
  defp law_fk_action(:set_null), do: "ON DELETE SET NULL"
  defp law_fk_action(:set_default), do: "ON DELETE SET DEFAULT"
  defp law_fk_action(:restrict), do: "ON DELETE RESTRICT"
  defp law_fk_action(:no_action), do: ""

  defp assert_trigger_fires(_conn, %{trigger?: false}), do: :ok

  defp assert_trigger_fires(conn, layout) do
    logged = law_row_count(conn, layout.schema, "log")
    {sql, params} = law_extra_row(layout)

    assert {:ok, 1} = NIF.execute(conn, sql, params)
    assert law_row_count(conn, layout.schema, "log") == logged + 1
  end

  defp law_extra_row(layout) do
    columns = Enum.map_join(layout.columns, ", ", &quoted/1)
    marks = Enum.map_join(layout.columns, ", ", fn _name -> "?" end)

    sql =
      "INSERT INTO " <>
        law_object(layout, layout.table) <> " (" <> columns <> ") VALUES (" <> marks <> ")"

    {sql, Enum.take([99, "z"], length(layout.columns))}
  end

  defp law_row_count(conn, schema, table) do
    sql = "SELECT count(*) FROM " <> quoted(schema) <> "." <> quoted(table)
    assert {:ok, %{rows: [[n]]}} = NIF.query(conn, sql, [])
    n
  end

  defp law_view_rows(_conn, %{view?: false}), do: :no_view

  defp law_view_rows(conn, layout) do
    assert {:ok, %{rows: rows}} =
             NIF.query(conn, "SELECT * FROM " <> law_object(layout, "v"), [])

    rows
  end

  defp fk_check(conn, schema) do
    sql = "PRAGMA " <> quoted(schema) <> ".foreign_key_check"
    assert {:ok, %{rows: rows}} = NIF.query(conn, sql, [])
    rows
  end

  # SQLite is the oracle for both halves: its own catalogue, and every table's
  # rows read with the rowid in front so a renumbering cannot hide.
  defp snapshot(conn) do
    Map.new(@law_schemas, fn schema -> {schema, schema_snapshot(conn, schema)} end)
  end

  defp schema_snapshot(conn, schema) do
    master = master_rows(conn, schema)
    {master, law_table_rows(conn, schema, master)}
  end

  defp law_table_rows(conn, schema, master) do
    master
    |> Enum.flat_map(&master_table_name/1)
    |> Map.new(fn name -> {name, rows_with_rowid(conn, schema, name)} end)
  end

  defp master_table_name(["table", name | _rest]), do: [name]
  defp master_table_name(_row), do: []

  defp rows_with_rowid(conn, schema, table) do
    sql = "SELECT rowid, * FROM " <> quoted(schema) <> "." <> quoted(table) <> " ORDER BY 1"

    case NIF.query(conn, sql, []) do
      {:ok, %{rows: rows}} -> rows
      {:error, reason} -> reason
    end
  end

  defp converted(snapshot, layout) do
    Map.update!(snapshot, layout.schema, fn
      {master, rows} -> {law_strict_master(master, layout), rows}
      other -> other
    end)
  end

  defp law_strict_master(master, layout) do
    create_sql = law_create_sql(layout, quoted(layout.table))
    Enum.map(master, &strict_master_row(&1, layout.table, create_sql))
  end

  # ---------------------------------------------------------------------------
  # the refusal law's domain: one setup per refusal the helpers can produce
  # ---------------------------------------------------------------------------

  defp refusal do
    gen all(
          kind <-
            StreamData.member_of([
              :violations,
              :not_a_plain_table,
              :without_rowid,
              :rowid_shadowed,
              :table_exists
            ]),
          schema <- StreamData.member_of(@law_schemas),
          foreign_keys <- StreamData.boolean(),
          legacy_alter_table <- StreamData.boolean()
        ) do
      %{
        kind: kind,
        schema: schema,
        foreign_keys: foreign_keys,
        legacy_alter_table: legacy_alter_table
      }
    end
  end

  defp run_refusal(conn, refusal) do
    attach(conn)
    set_law_flag(conn, "foreign_keys", refusal.foreign_keys)
    set_law_flag(conn, "legacy_alter_table", refusal.legacy_alter_table)

    refusal
    |> refusal_statements()
    |> run_statements(conn)

    before = snapshot(conn)

    assert {:error, reason} = Xqlite.enable_strict_table(conn, "t")
    assert refused?(reason, refusal.kind)

    assert snapshot(conn) == before
    assert pragma_flag(conn, "foreign_keys") == law_flag(refusal.foreign_keys)
    assert pragma_flag(conn, "legacy_alter_table") == law_flag(refusal.legacy_alter_table)
    assert {:ok, false} = Xqlite.transaction_status(conn)
  end

  defp refused?({:strict_violations, [_ | _]}, :violations), do: true
  defp refused?({:not_a_plain_table, %{table: "t", type: :view}}, :not_a_plain_table), do: true
  defp refused?({:without_rowid_unsupported, "t"}, :without_rowid), do: true
  defp refused?({:rowid_shadowed, "t"}, :rowid_shadowed), do: true
  defp refused?({:table_exists, "t_xqlite_strict_rebuild"}, :table_exists), do: true
  defp refused?(_reason, _kind), do: false

  defp refusal_statements(%{kind: :violations} = refusal) do
    [
      {"CREATE TABLE " <> law_object(refusal, "t") <> " (c INTEGER)", []},
      {"INSERT INTO " <> law_object(refusal, "t") <> " VALUES (?)", ["oops"]}
    ]
  end

  defp refusal_statements(%{kind: :not_a_plain_table} = refusal) do
    [
      {"CREATE TABLE " <> law_object(refusal, "base") <> " (c INTEGER)", []},
      {"CREATE VIEW " <> law_object(refusal, "t") <> ~s| AS SELECT c FROM "base"|, []}
    ]
  end

  defp refusal_statements(%{kind: :without_rowid} = refusal) do
    sql =
      "CREATE TABLE " <> law_object(refusal, "t") <> " (id INTEGER PRIMARY KEY) WITHOUT ROWID"

    [{sql, []}]
  end

  defp refusal_statements(%{kind: :rowid_shadowed} = refusal) do
    sql =
      "CREATE TABLE " <>
        law_object(refusal, "t") <> ~s| ("rowid" TEXT, "_rowid_" TEXT, "oid" TEXT)|

    [{sql, []}]
  end

  defp refusal_statements(%{kind: :table_exists} = refusal) do
    [
      {"CREATE TABLE " <> law_object(refusal, "t") <> " (c INTEGER)", []},
      {"CREATE TABLE " <> law_object(refusal, "t_xqlite_strict_rebuild") <> " (c INTEGER)", []}
    ]
  end
end
