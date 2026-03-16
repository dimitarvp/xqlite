defmodule Xqlite.NIF.BuiltinDbstatTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "DBSTAT using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE dbst_data (id INTEGER PRIMARY KEY, val TEXT);
          INSERT INTO dbst_data VALUES (1, 'hello');
          INSERT INTO dbst_data VALUES (2, 'world');
          CREATE INDEX dbst_idx ON dbst_data(val);
          """)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "dbstat reports correct distinct object names", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "SELECT DISTINCT name FROM dbstat ORDER BY name", [])

        names = Enum.map(rows, &hd/1)
        assert "dbst_data" in names
        assert "dbst_idx" in names
        assert "sqlite_schema" in names
      end

      test "all pages are leaf type for small dataset", %{conn: conn} do
        assert {:ok, %{rows: [["leaf"]]}} =
                 NIF.query(conn, "SELECT DISTINCT pagetype FROM dbstat", [])
      end

      test "dbst_data has exactly 2 cells with known payload", %{conn: conn} do
        assert {:ok, %{rows: [["dbst_data", 2, payload, _unused]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT name, ncell, payload, unused FROM dbstat WHERE name = 'dbst_data'",
                   []
                 )

        assert payload > 0
      end

      test "dbst_idx has exactly 2 cells", %{conn: conn} do
        assert {:ok, %{rows: [["dbst_idx", 2, _, _]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT name, ncell, payload, unused FROM dbstat WHERE name = 'dbst_idx'",
                   []
                 )
      end

      test "pageno values are positive integers", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "SELECT pageno FROM dbstat", [])

        Enum.each(rows, fn [pageno] ->
          assert is_integer(pageno)
          assert pageno > 0
        end)
      end

      test "aggregate pages per object", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name, COUNT(*) AS pages FROM dbstat GROUP BY name ORDER BY name",
                   []
                 )

        page_map = Map.new(rows, fn [name, count] -> {name, count} end)
        assert page_map["dbst_data"] == 1
        assert page_map["dbst_idx"] == 1
        assert page_map["sqlite_schema"] == 1
      end

      test "empty table has one page with zero cells", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE dbst_empty (id INTEGER PRIMARY KEY);")

        assert {:ok, %{rows: [["dbst_empty", 0, 0, _]], num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT name, ncell, payload, unused FROM dbstat WHERE name = 'dbst_empty'",
                   []
                 )
      end
    end
  end
end
