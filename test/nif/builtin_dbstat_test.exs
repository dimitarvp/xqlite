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

      test "dbstat virtual table is queryable", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name, path, pageno, pagetype, ncell, payload, unused, mx_payload FROM dbstat",
                   []
                 )

        assert length(rows) > 0
      end

      test "dbstat reports pages for table and index", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "SELECT DISTINCT name FROM dbstat ORDER BY name", [])

        names = Enum.map(rows, &hd/1)
        assert "dbst_data" in names
        assert "dbst_idx" in names
      end

      test "dbstat pageno is positive integer", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "SELECT pageno FROM dbstat", [])

        assert Enum.all?(rows, fn [pageno] -> is_integer(pageno) and pageno > 0 end)
      end

      test "dbstat pagetype is a known type", %{conn: conn} do
        known_types = ["internal", "leaf", "overflow"]

        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "SELECT DISTINCT pagetype FROM dbstat", [])

        types = Enum.map(rows, &hd/1)
        assert Enum.all?(types, fn t -> t in known_types end)
      end

      test "dbstat ncell is non-negative", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "SELECT ncell FROM dbstat", [])

        assert Enum.all?(rows, fn [ncell] -> is_integer(ncell) and ncell >= 0 end)
      end

      test "dbstat payload and unused are non-negative", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(conn, "SELECT payload, unused FROM dbstat", [])

        assert Enum.all?(rows, fn [payload, unused] ->
                 is_integer(payload) and payload >= 0 and
                   is_integer(unused) and unused >= 0
               end)
      end

      test "dbstat with schema filter", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name FROM dbstat WHERE name = 'dbst_data'",
                   []
                 )

        assert length(rows) > 0
        assert Enum.all?(rows, fn [name] -> name == "dbst_data" end)
      end

      test "dbstat aggregate: total pages per object", %{conn: conn} do
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name, COUNT(*) AS pages, SUM(payload) AS total_payload FROM dbstat GROUP BY name ORDER BY name",
                   []
                 )

        assert length(rows) >= 2

        Enum.each(rows, fn [_name, pages, payload] ->
          assert is_integer(pages) and pages > 0
          assert is_integer(payload) and payload >= 0
        end)
      end

      test "dbstat on empty table", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE dbst_empty (id INTEGER PRIMARY KEY);")

        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT name, ncell FROM dbstat WHERE name = 'dbst_empty'",
                   []
                 )

        assert length(rows) >= 1
      end
    end
  end
end
