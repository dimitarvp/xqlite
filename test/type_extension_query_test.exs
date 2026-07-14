defmodule Xqlite.TypeExtensionQueryTest do
  use ExUnit.Case, async: true

  alias Xqlite.TypeExtension
  alias XqliteNIF, as: NIF

  setup do
    {:ok, conn} = Xqlite.open_in_memory()
    on_exit(fn -> NIF.close(conn) end)

    :ok =
      NIF.execute_batch(
        conn,
        "CREATE TABLE events (id INTEGER PRIMARY KEY, day TEXT, meta TEXT);"
      )

    {:ok, conn: conn}
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
end
