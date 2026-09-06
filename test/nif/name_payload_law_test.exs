defmodule Xqlite.NIF.NamePayloadLawTest do
  @moduledoc """
  The four error tags SQLite gives us no code for — `:no_such_table`,
  `:no_such_index`, `:table_exists`, `:index_exists` — carry the object name
  SQLite printed, not the whole sentence it printed it in.

  SQLite renders that name in two different ways, and the payload keeps
  whichever one SQLite chose:

    * `no such table: X` and `no such index: X` print the resolved name with
      its quotes stripped, and keep a schema qualifier when the statement
      named one (`main.X`).
    * `table X already exists` prints the identifier token exactly as the
      statement wrote it, quotes included, and never carries a qualifier.
    * `index X already exists` prints the resolved name, unquoted, and never
      carries a qualifier either.

  The first law checks the two "no such" tags against SQLite's own text in
  the same run: `DROP VIEW` on a missing view produces a message built from
  the same format string with one word changed, and that word keeps it out
  of these four tags, so it still arrives with its full text under
  `:sqlite_failure`. The expected name is taken from that message, so the
  law compares the payload against SQLite rather than against a hard-coded
  shape.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  @name_chars [?a, ?B, ?9, ?_, ?\s, ?., ?", ?', ?-, ?%, ?é, ?樹]

  defp identifier do
    StreamData.member_of(@name_chars)
    |> StreamData.list_of(min_length: 1, max_length: 8)
    |> StreamData.map(&List.to_string/1)
  end

  defp quoted(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""

  # SQLite's own rendering of `name`, read out of a message this classifier
  # does not claim: `no such view: NAME` comes from the same C format string
  # as `no such table: NAME`.
  defp sqlite_rendering(conn, name) do
    assert {:error, {:sqlite_failure, _code, _extended, message}} =
             NIF.query(conn, "DROP VIEW " <> quoted(name), [])

    String.replace_prefix(message, "no such view: ", "")
  end

  for_each_opener "name payloads" do
    property "the two 'no such' tags carry the name SQLite printed", %{conn: conn} do
      check all(name <- identifier(), max_runs: 2000) do
        rendered = sqlite_rendering(conn, name)
        q = quoted(name)

        assert {:error, {:no_such_table, ^rendered}} =
                 NIF.query(conn, "SELECT * FROM " <> q, [])

        assert {:error, {:no_such_index, ^rendered}} =
                 NIF.query(conn, "DROP INDEX " <> q, [])

        qualified = "main." <> rendered

        assert {:error, {:no_such_table, ^qualified}} =
                 NIF.query(conn, "SELECT * FROM main." <> q, [])

        assert {:error, {:no_such_index, ^qualified}} =
                 NIF.query(conn, "DROP INDEX main." <> q, [])
      end
    end

    property "the two 'already exists' tags carry the name SQLite printed",
             %{conn: conn} do
      :ok = NIF.execute_batch(conn, "BEGIN;")

      check all(name <- identifier(), max_runs: 2000) do
        table = quoted(name <> "_t")
        index_name = name <> "_i"
        index = quoted(index_name)

        :ok = NIF.execute_batch(conn, "CREATE TABLE " <> table <> " (a);")
        :ok = NIF.execute_batch(conn, "CREATE INDEX " <> index <> " ON " <> table <> "(a);")

        assert {:error, {:table_exists, ^table}} =
                 NIF.query(conn, "CREATE TABLE " <> table <> " (a)", [])

        assert {:error, {:table_exists, ^table}} =
                 NIF.query(conn, "CREATE TABLE main." <> table <> " (a)", [])

        assert {:error, {:index_exists, ^index_name}} =
                 NIF.query(conn, "CREATE INDEX " <> index <> " ON " <> table <> "(a)", [])

        assert {:error, {:index_exists, ^index_name}} =
                 NIF.query(
                   conn,
                   "CREATE INDEX main." <> index <> " ON " <> table <> "(a)",
                   []
                 )

        :ok = NIF.execute_batch(conn, "DROP TABLE " <> table <> ";")
      end

      :ok = NIF.execute_batch(conn, "ROLLBACK;")
    end

    test "a missing table reports the bare name, a qualified one keeps its schema",
         %{conn: conn} do
      assert {:error, {:no_such_table, "ghost_tbl"}} =
               NIF.query(conn, "SELECT * FROM ghost_tbl", [])

      assert {:error, {:no_such_table, "main.ghost_tbl"}} =
               NIF.query(conn, "SELECT * FROM main.ghost_tbl", [])

      assert {:error, {:no_such_index, "ghost_idx"}} =
               NIF.query(conn, "DROP INDEX ghost_idx", [])
    end

    test "a duplicate table echoes the token, a duplicate index the resolved name",
         %{conn: conn} do
      :ok = NIF.execute_batch(conn, "CREATE TABLE \"twice tbl\" (a);")
      :ok = NIF.execute_batch(conn, ~s{CREATE INDEX "twice idx" ON "twice tbl"(a);})

      assert {:error, {:table_exists, "\"twice tbl\""}} =
               NIF.query(conn, "CREATE TABLE \"twice tbl\" (a)", [])

      assert {:error, {:index_exists, "twice idx"}} =
               NIF.query(conn, ~s{CREATE INDEX "twice idx" ON "twice tbl"(a)}, [])
    end
  end
end
