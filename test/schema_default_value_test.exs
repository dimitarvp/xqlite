defmodule Xqlite.SchemaDefaultValueTest do
  @moduledoc """
  The combinatorial example matrix for `ColumnInfo.default_value`
  classification — every literal form SQLite's DEFAULT clause
  accepts, plus the expression fallback. The matching round-trip
  properties live in `Xqlite.SchemaDefaultValuePropertyTest`.
  """

  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]
  alias XqliteNIF, as: NIF

  # {column-ddl, expected default_value}. Column names are generated
  # (c0, c1, ...) so the matrix stays declaration-order aligned.
  @matrix [
    # --- absence / null / booleans ---
    {"INTEGER", :none},
    {"INTEGER DEFAULT NULL", {:literal, nil}},
    {"INTEGER DEFAULT null", {:literal, nil}},
    {"INTEGER DEFAULT TRUE", {:literal, true}},
    {"INTEGER DEFAULT FALSE", {:literal, false}},
    {"INTEGER DEFAULT true", {:literal, true}},

    # --- integers ---
    {"INTEGER DEFAULT 0", {:literal, 0}},
    {"INTEGER DEFAULT 42", {:literal, 42}},
    {"INTEGER DEFAULT -17", {:literal, -17}},
    {"INTEGER DEFAULT +5", {:literal, 5}},
    {"INTEGER DEFAULT 9223372036854775807", {:literal, 9_223_372_036_854_775_807}},
    {"INTEGER DEFAULT -9223372036854775808", {:literal, -9_223_372_036_854_775_808}},
    # integer-shaped but > i64: SQLite coerces to REAL at insert; we
    # refuse to silently change numeric type and surface verbatim
    {"INTEGER DEFAULT 9223372036854775808", {:expr, "9223372036854775808"}},
    {"INTEGER DEFAULT 0xFF", {:literal, 255}},
    {"INTEGER DEFAULT -0x10", {:literal, -16}},
    # hex is 64-bit two's complement, exactly like SQLite
    {"INTEGER DEFAULT 0xFFFFFFFFFFFFFFFF", {:literal, -1}},

    # --- floats ---
    {"REAL DEFAULT 3.14", {:literal, 3.14}},
    {"REAL DEFAULT -0.5", {:literal, -0.5}},
    {"REAL DEFAULT .5", {:literal, 0.5}},
    {"REAL DEFAULT 5.", {:literal, 5.0}},
    {"REAL DEFAULT 1e10", {:literal, 1.0e10}},
    {"REAL DEFAULT 1E-7", {:literal, 1.0e-7}},
    {"REAL DEFAULT 0.1e+2", {:literal, 10.0}},
    # infinity is not a literal we can represent faithfully
    {"REAL DEFAULT 9e999", {:expr, "9e999"}},

    # --- text literals ---
    {"TEXT DEFAULT ''", {:literal, ""}},
    {"TEXT DEFAULT 'hello'", {:literal, "hello"}},
    {"TEXT DEFAULT 'it''s'", {:literal, "it's"}},
    {"TEXT DEFAULT 'héllo 🚀'", {:literal, "héllo 🚀"}},
    # number-looking and keyword-looking strings stay strings
    {"TEXT DEFAULT '42'", {:literal, "42"}},
    {"TEXT DEFAULT 'NULL'", {:literal, "NULL"}},
    {"TEXT DEFAULT 'CURRENT_TIMESTAMP'", {:literal, "CURRENT_TIMESTAMP"}},
    # the date/time zoo stays strings — no type divination
    {"TEXT DEFAULT '2024-01-15'", {:literal, "2024-01-15"}},
    {"TEXT DEFAULT '10:30:00.123'", {:literal, "10:30:00.123"}},
    {"TEXT DEFAULT '2024-01-15 10:30:00'", {:literal, "2024-01-15 10:30:00"}},
    {"TEXT DEFAULT '2024-01-15T10:30:00Z'", {:literal, "2024-01-15T10:30:00Z"}},
    {"TEXT DEFAULT '2024-01-15T10:30:00+02:00'", {:literal, "2024-01-15T10:30:00+02:00"}},
    # JSON text stays a string
    {~s(TEXT DEFAULT '{"a": 1, "b": [true, null]}'),
     {:literal, ~s({"a": 1, "b": [true, null]})}},

    # --- blob literals ---
    {"BLOB DEFAULT x''", {:blob, <<>>}},
    {"BLOB DEFAULT x'00'", {:blob, <<0>>}},
    {"BLOB DEFAULT x'DEADBEEF'", {:blob, <<0xDE, 0xAD, 0xBE, 0xEF>>}},
    {"BLOB DEFAULT X'deadbeef'", {:blob, <<0xDE, 0xAD, 0xBE, 0xEF>>}},
    {"BLOB DEFAULT x'DEADbeef'", {:blob, <<0xDE, 0xAD, 0xBE, 0xEF>>}},
    # bytes that happen to be valid UTF-8 are still a blob — tag wins
    {"BLOB DEFAULT x'C3A9'", {:blob, <<0xC3, 0xA9>>}},
    # invalid UTF-8 bytes — the canonical blob case
    {"BLOB DEFAULT x'FFFE'", {:blob, <<0xFF, 0xFE>>}},

    # --- CURRENT_* keywords ---
    {"TEXT DEFAULT CURRENT_TIME", {:current, :time}},
    {"TEXT DEFAULT CURRENT_DATE", {:current, :date}},
    {"TEXT DEFAULT CURRENT_TIMESTAMP", {:current, :timestamp}},
    {"TEXT DEFAULT current_timestamp", {:current, :timestamp}},

    # --- expressions, verbatim (SQLite strips the outer parens) ---
    {"TEXT DEFAULT (datetime('now'))", {:expr, "datetime('now')"}},
    {"TEXT DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))",
     {:expr, "strftime('%Y-%m-%dT%H:%M:%fZ','now')"}},
    {"INTEGER DEFAULT (unixepoch())", {:expr, "unixepoch()"}},
    {"REAL DEFAULT (julianday('now'))", {:expr, "julianday('now')"}},
    {"TEXT DEFAULT (date('now','+1 day'))", {:expr, "date('now','+1 day')"}},
    {"REAL DEFAULT (random())", {:expr, "random()"}},
    {"BLOB DEFAULT (randomblob(16))", {:expr, "randomblob(16)"}},
    {"TEXT DEFAULT (lower(hex(randomblob(16))))", {:expr, "lower(hex(randomblob(16)))"}},
    {~s[TEXT DEFAULT (json('{"a":1}'))], {:expr, ~s[json('{"a":1}')]}},
    {"TEXT DEFAULT (json_array(1,2,3))", {:expr, "json_array(1,2,3)"}},
    # constant-fold bait: must stay an expression
    {"INTEGER DEFAULT (1+2)", {:expr, "1+2"}},
    {"INTEGER DEFAULT (abs(-42))", {:expr, "abs(-42)"}},
    {"TEXT DEFAULT ('a' || 'b')", {:expr, "'a' || 'b'"}},
    # nested escaped quotes inside an expression
    {"TEXT DEFAULT (printf('%s','it''s'))", {:expr, "printf('%s','it''s')"}},
    # double-quoted string: DQS misfeature, ambiguous — verbatim
    {~s(TEXT DEFAULT "dq_string"), {:expr, ~s("dq_string")}}
  ]

  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "the full default-value matrix classifies as designed", %{conn: conn} do
        columns_ddl =
          @matrix
          |> Enum.with_index()
          |> Enum.map_join(",\n  ", fn {{ddl, _expected}, i} -> "c#{i} #{ddl}" end)

        :ok = NIF.execute_batch(conn, "CREATE TABLE dv_matrix (\n  #{columns_ddl}\n)")

        {:ok, columns} = NIF.schema_columns(conn, "dv_matrix")
        by_name = Map.new(columns, fn col -> {col.name, col.default_value} end)

        for {{ddl, expected}, i} <- Enum.with_index(@matrix) do
          actual = Map.fetch!(by_name, "c#{i}")

          assert actual == expected,
                 "column c#{i} (#{ddl}): expected #{inspect(expected)}, got #{inspect(actual)}"
        end
      end

      test "ALTER-added defaults classify the same as CREATE-time ones", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE dv_alter (a INTEGER)")

        {:ok, _} =
          NIF.execute(conn, "ALTER TABLE dv_alter ADD COLUMN b TEXT DEFAULT 'added'", [])

        {:ok, _} = NIF.execute(conn, "ALTER TABLE dv_alter ADD COLUMN c INTEGER DEFAULT 7", [])

        {:ok, columns} = NIF.schema_columns(conn, "dv_alter")
        by_name = Map.new(columns, fn col -> {col.name, col.default_value} end)

        assert by_name["a"] == :none
        assert by_name["b"] == {:literal, "added"}
        assert by_name["c"] == {:literal, 7}
      end

      test "generated columns report :none without crashing", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE TABLE dv_gen (a INTEGER, b INTEGER GENERATED ALWAYS AS (a * 2) VIRTUAL)"
          )

        {:ok, columns} = NIF.schema_columns(conn, "dv_gen")
        by_name = Map.new(columns, fn col -> {col.name, col.default_value} end)

        assert by_name["b"] == :none
      end

      test "STRICT tables classify identically", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE TABLE dv_strict (a INTEGER DEFAULT 42, b TEXT DEFAULT 'x') STRICT"
          )

        {:ok, columns} = NIF.schema_columns(conn, "dv_strict")
        by_name = Map.new(columns, fn col -> {col.name, col.default_value} end)

        assert by_name["a"] == {:literal, 42}
        assert by_name["b"] == {:literal, "x"}
      end

      test "the same literal classifies identically across affinities", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE TABLE dv_affinity (a INTEGER DEFAULT 42, b TEXT DEFAULT 42, " <>
              "c BLOB DEFAULT 42, d REAL DEFAULT 42, e NUMERIC DEFAULT 42)"
          )

        {:ok, columns} = NIF.schema_columns(conn, "dv_affinity")

        for col <- columns do
          assert col.default_value == {:literal, 42},
                 "column #{col.name}: got #{inspect(col.default_value)}"
        end
      end

      test "a one-megabyte string literal default survives", %{conn: conn} do
        big = String.duplicate("a", 1_048_576)
        :ok = NIF.execute_batch(conn, "CREATE TABLE dv_big (a TEXT DEFAULT '#{big}')")

        {:ok, [col]} = NIF.schema_columns(conn, "dv_big")
        assert col.default_value == {:literal, big}
      end
    end
  end
end
