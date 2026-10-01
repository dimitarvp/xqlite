defmodule Xqlite.TypeExtensionQueryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Xqlite.TypeExtension
  alias Xqlite.TypeExtension.UUID, as: UUIDExt
  alias XqliteNIF, as: NIF

  @uuid_exts [type_extensions: [Xqlite.TypeExtension.UUID]]

  setup do
    {:ok, conn} = Xqlite.open_in_memory()
    on_exit(fn -> NIF.close(conn) end)

    :ok =
      NIF.execute_batch(
        conn,
        """
        CREATE TABLE events (id INTEGER PRIMARY KEY, day TEXT, meta TEXT);
        CREATE TABLE holders (id INTEGER PRIMARY KEY, u BLOB, tag TEXT);
        CREATE INDEX holders_u ON holders(u);
        """
      )

    {:ok, conn: conn}
  end

  defp uuid_text(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>) do
    Enum.map_join([a, b, c, d, e], "-", fn part -> Base.encode16(part, case: :lower) end)
  end

  describe "Xqlite.query/4 with :type_extensions" do
    test "encodes params and decodes result rows through the chain", %{conn: conn} do
      exts = [TypeExtension.Date]

      assert {:ok, _} =
               Xqlite.execute(conn, "INSERT INTO events (day) VALUES (?1)", [~D[2026-07-14]],
                 type_extensions: exts
               )

      assert {:ok, %Xqlite.Result{rows: [[~D[2026-07-14]]]}} =
               Xqlite.query(conn, "SELECT day FROM events", [], type_extensions: exts)
    end

    test "decodes pre-existing shaped text on read", %{conn: conn} do
      {:ok, _} = NIF.execute(conn, "INSERT INTO events (day) VALUES ('2025-01-02')", [])

      assert {:ok, %Xqlite.Result{rows: [[~D[2025-01-02]]]}} =
               Xqlite.query(conn, "SELECT day FROM events", [],
                 type_extensions: [TypeExtension.Date]
               )
    end

    test "without the option, values pass through untouched", %{conn: conn} do
      {:ok, _} = NIF.execute(conn, "INSERT INTO events (day) VALUES ('2025-01-02')", [])

      assert {:ok, %Xqlite.Result{rows: [["2025-01-02"]]}} =
               Xqlite.query(conn, "SELECT day FROM events", [])
    end

    test "JSON extension round-trips a map through query/4", %{conn: conn} do
      exts = [TypeExtension.JSON]

      assert {:ok, _} =
               Xqlite.execute(
                 conn,
                 "INSERT INTO events (meta) VALUES (?1)",
                 [%{"kind" => "signup", "count" => 3}],
                 type_extensions: exts
               )

      assert {:ok, %Xqlite.Result{rows: [[%{"kind" => "signup", "count" => 3}]]}} =
               Xqlite.query(conn, "SELECT meta FROM events", [], type_extensions: exts)
    end
  end

  describe "Xqlite.execute/4 with :type_extensions" do
    test "encodes params; storage stays the raw encoded value", %{conn: conn} do
      assert {:ok, %Xqlite.Result{changes: 1}} =
               Xqlite.execute(conn, "INSERT INTO events (day) VALUES (?1)", [~D[2024-12-31]],
                 type_extensions: [TypeExtension.Date]
               )

      # Read WITHOUT extensions: the stored value is the encoded ISO text.
      assert {:ok, %Xqlite.Result{rows: [["2024-12-31"]]}} =
               Xqlite.query(conn, "SELECT day FROM events", [])
    end
  end

  describe ":type_extensions on every parameter-taking function" do
    property "a value written through execute/4 is found through all four", %{conn: conn} do
      check all(bytes <- StreamData.binary(length: 16), max_runs: 2000) do
        uuid = uuid_text(bytes)

        # Each run starts from an empty table: shrinking re-runs this body
        # with new values, and a row left behind would make the next run fail
        # on the leftover instead of on what it generated.
        assert {:ok, _} = Xqlite.execute(conn, "DELETE FROM holders", [])

        assert {:ok, %Xqlite.Result{changes: 1}} =
                 Xqlite.execute(
                   conn,
                   "INSERT INTO holders (u, tag) VALUES (?1, 'a')",
                   [uuid],
                   @uuid_exts
                 )

        assert {:ok, %{rows: [[^uuid]], num_rows: 1}} =
                 Xqlite.query(conn, "SELECT u FROM holders WHERE u = ?1", [uuid], @uuid_exts)

        assert {:ok, %Xqlite.Result{changes: 1}} =
                 Xqlite.execute(
                   conn,
                   "UPDATE holders SET tag = 'b' WHERE u = ?1",
                   [uuid],
                   @uuid_exts
                 )

        assert {:ok, report} =
                 Xqlite.explain_analyze(
                   conn,
                   "SELECT u FROM holders WHERE u = ?1",
                   [uuid],
                   @uuid_exts
                 )

        assert report.rows_produced == 1

        {:ok, stmt} = Xqlite.prepare(conn, "SELECT u FROM holders WHERE u = ?1")
        :ok = Xqlite.bind(stmt, [uuid], @uuid_exts)
        assert {:row, [raw]} = Xqlite.step(stmt)
        assert {:ok, ^uuid} = UUIDExt.decode(raw)
        :ok = Xqlite.finalize(stmt)
      end
    end

    test "nil parameters keep working on the forms that accept them", %{conn: conn} do
      assert {:ok, _} = Xqlite.explain_analyze(conn, "SELECT 1", nil)
      assert {:ok, _} = Xqlite.explain_analyze(conn, "SELECT 1", nil, @uuid_exts)
    end

    test "a blob wrapper passes the chain untouched on all four", %{conn: conn} do
      wrapper = %Xqlite.Blob{bytes: <<0xFF, 0x00, 0xFE>>}

      assert {:ok, %Xqlite.Result{changes: 1}} =
               Xqlite.execute(
                 conn,
                 "INSERT INTO holders (id, u) VALUES (2, ?1)",
                 [wrapper],
                 @uuid_exts
               )

      assert {:ok, %{rows: [["blob"]]}} =
               Xqlite.query(conn, "SELECT typeof(u) FROM holders WHERE id = 2", [], @uuid_exts)

      assert {:ok, _} =
               Xqlite.explain_analyze(conn, "SELECT ?1", [wrapper], @uuid_exts)

      {:ok, stmt} = Xqlite.prepare(conn, "SELECT typeof(?1)")
      :ok = Xqlite.bind(stmt, [wrapper], @uuid_exts)
      assert {:row, ["blob"]} = Xqlite.step(stmt)
      :ok = Xqlite.finalize(stmt)
    end

    test "a rejected parameter answers the error tuple on all four", %{conn: conn} do
      exts = [type_extensions: [Xqlite.TypeExtension.Decimal]]
      params = [%Decimal{sign: 1, coef: :inf}]
      refusal = {:non_finite, :infinity}

      assert {:error, {:type_extension_refused, %{position: 1, reason: ^refusal}}} =
               Xqlite.query(conn, "SELECT ?1", params, exts)

      assert {:error, {:type_extension_refused, %{position: 1, reason: ^refusal}}} =
               Xqlite.execute(conn, "INSERT INTO holders (u) VALUES (?1)", params, exts)

      assert {:error, {:type_extension_refused, %{position: 1, reason: ^refusal}}} =
               Xqlite.explain_analyze(conn, "SELECT ?1", params, exts)

      {:ok, stmt} = Xqlite.prepare(conn, "SELECT ?1")

      assert {:error, {:type_extension_refused, %{position: 1, reason: ^refusal}}} =
               Xqlite.bind(stmt, params, exts)

      :ok = Xqlite.finalize(stmt)
    end
  end
end
