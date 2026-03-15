defmodule Xqlite.NIF.BuiltinColumnMetadataTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "COLUMN_METADATA using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # table_xinfo — extended table info with hidden columns
      # -------------------------------------------------------------------

      test "table_xinfo returns hidden column flag", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE cm_xinfo (id INTEGER PRIMARY KEY, name TEXT, age INTEGER);
          """)

        assert {:ok, %{rows: rows, columns: cols, num_rows: 3}} =
                 NIF.query(conn, "PRAGMA table_xinfo(cm_xinfo)", [])

        assert cols == ["cid", "name", "type", "notnull", "dflt_value", "pk", "hidden"]

        [
          [0, "id", "INTEGER", 0, nil, 1, 0],
          [1, "name", "TEXT", 0, nil, 0, 0],
          [2, "age", "INTEGER", 0, nil, 0, 0]
        ] = rows
      end

      test "table_xinfo shows generated columns as hidden", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE cm_gen (
            a INTEGER,
            b INTEGER,
            c INTEGER GENERATED ALWAYS AS (a + b) STORED
          );
          """)

        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "PRAGMA table_xinfo(cm_gen)", [])

        # c is a stored generated column → hidden=3
        [_, _, [2, "c", "INTEGER", 0, nil, 0, hidden]] = rows
        assert hidden == 3
      end

      test "table_xinfo shows virtual generated columns", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE cm_virt (
            a INTEGER,
            b INTEGER,
            c INTEGER GENERATED ALWAYS AS (a * b) VIRTUAL
          );
          """)

        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "PRAGMA table_xinfo(cm_virt)", [])

        # c is a virtual generated column → hidden=2
        [_, _, [2, "c", "INTEGER", 0, nil, 0, hidden]] = rows
        assert hidden == 2
      end

      # -------------------------------------------------------------------
      # table_info vs table_xinfo
      # -------------------------------------------------------------------

      test "table_info omits generated columns, table_xinfo includes them", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE cm_compare (
            x INTEGER,
            y INTEGER,
            z INTEGER GENERATED ALWAYS AS (x + y) STORED
          );
          """)

        assert {:ok, %{rows: info_rows}} =
                 NIF.query(conn, "PRAGMA table_info(cm_compare)", [])

        assert {:ok, %{rows: xinfo_rows}} =
                 NIF.query(conn, "PRAGMA table_xinfo(cm_compare)", [])

        info_names = Enum.map(info_rows, fn [_, name | _] -> name end)
        xinfo_names = Enum.map(xinfo_rows, fn [_, name | _] -> name end)

        # table_info omits generated columns
        assert info_names == ["x", "y"]
        # table_xinfo includes them with the hidden flag
        assert xinfo_names == ["x", "y", "z"]
        # xinfo has one extra column (hidden)
        assert length(hd(xinfo_rows)) == length(hd(info_rows)) + 1
      end

      # -------------------------------------------------------------------
      # schema_columns NIF (uses sqlite3_table_column_metadata)
      # -------------------------------------------------------------------

      test "schema_columns reports correct types and constraints", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE cm_schema (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            email TEXT UNIQUE,
            score REAL DEFAULT 0.0
          );
          """)

        assert {:ok, columns} = NIF.schema_columns(conn, "cm_schema")
        assert length(columns) == 4

        id_col = Enum.find(columns, fn c -> c.name == "id" end)
        assert id_col.declared_type == "INTEGER"
        assert id_col.primary_key_index == 1
        assert id_col.nullable == true

        name_col = Enum.find(columns, fn c -> c.name == "name" end)
        assert name_col.declared_type == "TEXT"
        assert name_col.nullable == false
        assert name_col.primary_key_index == 0

        score_col = Enum.find(columns, fn c -> c.name == "score" end)
        assert score_col.declared_type == "REAL"
        assert score_col.default_value == "0.0"
      end

      test "schema_columns on table with no explicit types", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE cm_notype (a, b, c);")

        assert {:ok, columns} = NIF.schema_columns(conn, "cm_notype")

        Enum.each(columns, fn col ->
          assert col.declared_type == ""
        end)
      end

      test "schema_columns on WITHOUT ROWID table", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE cm_worowid (
            key TEXT PRIMARY KEY,
            value TEXT
          ) WITHOUT ROWID;
          """)

        assert {:ok, columns} = NIF.schema_columns(conn, "cm_worowid")
        assert length(columns) == 2

        key_col = Enum.find(columns, fn c -> c.name == "key" end)
        assert key_col.primary_key_index == 1
      end

      # -------------------------------------------------------------------
      # Column metadata on views
      # -------------------------------------------------------------------

      test "table_xinfo on view returns view columns with hidden=0", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE cm_base (id INTEGER PRIMARY KEY, val TEXT);
          CREATE VIEW cm_view AS SELECT id, val FROM cm_base;
          """)

        assert {:ok, %{rows: rows, num_rows: 2}} =
                 NIF.query(conn, "PRAGMA table_xinfo(cm_view)", [])

        names = Enum.map(rows, fn [_, name | _] -> name end)
        assert names == ["id", "val"]

        hiddens = Enum.map(rows, fn row -> List.last(row) end)
        assert hiddens == [0, 0]
      end

      # -------------------------------------------------------------------
      # Column metadata with complex types
      # -------------------------------------------------------------------

      test "columns with various SQLite type affinities", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE cm_types (
            a INTEGER,
            b TEXT,
            c REAL,
            d BLOB,
            e NUMERIC,
            f BOOLEAN,
            g VARCHAR(255),
            h DATETIME
          );
          """)

        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "PRAGMA table_xinfo(cm_types)", [])

        types = Enum.map(rows, fn [_, _, type | _] -> type end)

        assert types == [
                 "INTEGER",
                 "TEXT",
                 "REAL",
                 "BLOB",
                 "NUMERIC",
                 "BOOLEAN",
                 "VARCHAR(255)",
                 "DATETIME"
               ]
      end

      test "column default values are reported correctly", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE cm_defaults (
            a INTEGER DEFAULT 42,
            b TEXT DEFAULT 'hello',
            c REAL DEFAULT 3.14,
            d INTEGER DEFAULT NULL,
            e TEXT DEFAULT('')
          );
          """)

        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "PRAGMA table_xinfo(cm_defaults)", [])

        defaults = Enum.map(rows, fn [_, _, _, _, dflt | _] -> dflt end)
        assert defaults == ["42", "'hello'", "3.14", "NULL", "''"]
      end

      test "NOT NULL constraint reported for each column", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE cm_notnull (
            a INTEGER NOT NULL,
            b TEXT,
            c REAL NOT NULL,
            d BLOB
          );
          """)

        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "PRAGMA table_xinfo(cm_notnull)", [])

        notnulls = Enum.map(rows, fn [_, _, _, nn | _] -> nn end)
        assert notnulls == [1, 0, 1, 0]
      end

      # -------------------------------------------------------------------
      # Multiple primary key columns
      # -------------------------------------------------------------------

      test "composite primary key columns have ascending pk values", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE cm_cpk (
            a INTEGER,
            b TEXT,
            c INTEGER,
            PRIMARY KEY (a, c)
          );
          """)

        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "PRAGMA table_xinfo(cm_cpk)", [])

        pk_vals = Enum.map(rows, fn [_, name, _, _, _, pk | _] -> {name, pk} end)
        assert pk_vals == [{"a", 1}, {"b", 0}, {"c", 2}]
      end
    end
  end
end
