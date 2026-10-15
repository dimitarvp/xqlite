defmodule Xqlite.ColumnNameLawTest do
  @moduledoc """
  The law: every function that reads result column names answers
  `{:column_name_not_utf8, %{column: index, name: bytes}}` for the first name SQLite hands
  back that is not UTF-8, before it binds or steps, and any other name byte for byte, with or
  without an authorizer on the connection. The schema readers answer it for a stored column name
  of the table, at the column's place in it.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase
  import Xqlite.TestUtil, only: [authorizer_draw: 1, install_draw: 2]

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000
  @sql "SELECT * FROM t"
  @setup "PRAGMA journal_mode = MEMORY; PRAGMA synchronous = OFF; CREATE TABLE t(x)"
  @stored "SELECT hex(name) FROM pragma_table_info('t')"
  # Latin-1, never valid, lone continuation, overlong, surrogate, past U+10FFFF, truncated.
  @not_utf8 Enum.map(~w(E9 FF 80 C080 E08080 EDA080 F4908080 E282), &Base.decode16!/1)
  @table_names "SELECT cid, hex(name) FROM pragma_table_xinfo('t')"
  @index_names "SELECT cid, iif(name ISNULL, NULL, hex(name)) FROM pragma_index_xinfo('ti')"
  @key_names """
  SELECT (SELECT cid FROM pragma_table_xinfo('t') WHERE name = k."from"), hex(k."from")
  FROM pragma_foreign_key_list('t') AS k
  """

  for_each_opener "a column name" do
    test "the anchor: a Latin-1 name answers the error before the write", %{conn: conn} do
      :ok = NIF.execute_batch(conn, @setup)
      :ok = rewrite_columns(conn, ["pr\xE9nom", "b"])
      result = Xqlite.query(conn, "INSERT INTO t(b) VALUES ('x') RETURNING *")
      assert {:error, {:column_name_not_utf8, %{column: 0, name: "pr\xE9nom"}}} = result
      assert {:ok, %{rows: [[0]]}} = Xqlite.query(conn, "SELECT count(*) FROM t")
    end

    test "under a busy observer a Latin-1 name answers as with none, and [:read] still denies",
         %{conn: conn} do
      :ok = NIF.execute_batch(conn, @setup)
      :ok = rewrite_columns(conn, ["pr\xE9nom", "b"])
      {:ok, _handle} = Xqlite.register_busy_observer(conn, self())
      result = Xqlite.query(conn, @sql)
      assert {:error, {:column_name_not_utf8, %{column: 0, name: "pr\xE9nom"}}} = result
      cte = "WITH s(a, b) AS (#{@sql}) SELECT * FROM s"
      assert {:ok, %{columns: ["a", "b"]}} = Xqlite.query(conn, cte)
      :ok = Xqlite.set_authorizer(conn, [:read])
      assert {:error, {:authorization_denied, 23, _}} = Xqlite.query(conn, @sql)
    end

    # A close frees what the readers left open and fails on a statement a rejected prepare leaked.
    property "every reader answers the first name that is not UTF-8, whatever authorizer the connection carries",
             context do
      {mod, fun, args} = Xqlite.TestUtil.find_opener_mfa!(context)

      check all(names <- names(), draw <- authorizer_draw([:read, :select]), max_runs: 2000) do
        assert {:ok, conn} = apply(mod, fun, args)
        :ok = NIF.execute_batch(conn, @setup)
        {:ok, early} = Xqlite.prepare(conn, @sql)
        :ok = rewrite_columns(conn, names)
        assert {:ok, %{rows: stored}} = Xqlite.query(conn, @stored)
        assert stored |> List.flatten() |> Enum.map(&Base.decode16!/1) == names
        assert :done = Xqlite.step(early)
        :ok = install_draw(conn, draw)
        assert readers(conn, early) == names |> expected() |> List.duplicate(4)
        assert :done = Xqlite.step(early)
        assert {:ok, %{rows: []}} = Xqlite.query(conn, "SELECT 1 FROM (#{@sql})")
        assert :ok = Xqlite.close(conn)
      end
    end

    test "the anchor: the schema readers answer a stored name by its place in the table",
         %{conn: conn} do
      :ok =
        NIF.execute_batch(conn, """
        CREATE TABLE p(id); CREATE TABLE t(a AS (1), b, c); CREATE INDEX ti ON t(c);
        CREATE TABLE v(a); CREATE TABLE y(a);
        """)

      :ok =
        rewrite_schema(conn, [
          {"t", ~s|CREATE TABLE t(a AS (1), "b\xFE" REFERENCES p(id), "c\xFF")|},
          {"ti", ~s|CREATE INDEX ti ON t("c\xFF")|},
          {"v", ~s|CREATE TABLE v(a REFERENCES q("k\xE9"))|},
          {"y", ~s|CREATE TABLE y(a REFERENCES "q\xE9"(k))|}
        ])

      b = {:error, {:column_name_not_utf8, %{column: 1, name: "b\xFE"}}}
      assert {NIF.schema_columns(conn, "t"), NIF.schema_foreign_keys(conn, "t")} == {b, b}
      c = {:error, {:column_name_not_utf8, %{column: 2, name: "c\xFF"}}}
      assert NIF.schema_index_columns(conn, "ti") == c
      assert {:error, {:utf8_error, 4, _}} = NIF.schema_foreign_keys(conn, "v")
      assert {:error, {:utf8_error, 2, _}} = NIF.schema_foreign_keys(conn, "y")
    end

    property "the schema readers answer the first stored name that is not UTF-8 at its place",
             context do
      {mod, fun, args} = Xqlite.TestUtil.find_opener_mfa!(context)

      check all(
              names <- names(),
              keyed <- list_of(boolean(), length: length(names)),
              sort_keys <- list_of(integer(), length: length(names)),
              count <- integer(1..length(names)),
              max_runs: 2000
            ) do
        assert {:ok, conn} = apply(mod, fun, args)
        positions = sort_keys |> Enum.with_index() |> Enum.sort() |> Enum.take(count)
        :ok = plant_keyed_table(conn, names, keyed, for({_key, at} <- positions, do: at))
        [columns, index] = Enum.map([@table_names, @index_names], &oracle(conn, &1))
        # With no key, the reader answers what the table's columns answer, or no key.
        keys = with {:ok, []} <- oracle(conn, @key_names), {:ok, _} <- columns, do: {:ok, []}
        assert names_read(NIF.schema_columns(conn, "t"), :name) == columns
        assert names_read(NIF.schema_index_columns(conn, "ti"), :name) == index
        assert names_read(NIF.schema_foreign_keys(conn, "t"), :from_column) == keys
        assert :ok = Xqlite.close(conn)
      end
    end
  end

  # Two connections to one file, which no opener gives; A waits on B's lock after its prepare.
  test "a rename between the name read and the first step answers both lists" do
    path = Xqlite.TestUtil.tmp_db_path("columns_changed")
    {:ok, a} = Xqlite.open(path, journal_mode: :delete)
    {:ok, b} = Xqlite.open(path, journal_mode: :delete)
    on_exit(fn -> Enum.each([a, b], &NIF.close/1) end)
    :ok = NIF.execute_batch(a, "CREATE TABLE t(a, b, c); INSERT INTO t VALUES (1, 2, 3);")
    stream = Xqlite.stream(a, @sql, [], on_error: :emit_error)
    {:ok, _observer} = NIF.register_busy_observer(a, self())
    :ok = NIF.execute_batch(b, "BEGIN EXCLUSIVE;")
    query = Task.async(fn -> Xqlite.query(a, "INSERT INTO t VALUES (7, 8, 9) RETURNING *") end)
    assert_receive {:xqlite_busy, _retries, _elapsed_ms}, 5_000
    :ok = NIF.execute_batch(b, "ALTER TABLE t RENAME COLUMN b TO z; COMMIT;")
    changed = {:columns_changed, %{expected: ["a", "b", "c"], live: ["a", "z", "c"]}}
    assert {:error, ^changed} = Task.await(query)
    assert {:ok, %{rows: [[7, 8, 9]]}} = Xqlite.query(b, "SELECT * FROM t WHERE a = 7")
    assert [{:error, ^changed}] = Enum.to_list(stream)
  end

  defp names do
    valid = string(:printable, max_length: 3)
    invalid = [valid, member_of(@not_utf8), valid] |> fixed_list() |> map(&Enum.join/1)

    [valid, invalid]
    |> one_of()
    |> uniq_list_of(min_length: 1, max_length: 4, uniq_fun: &String.downcase(&1, :ascii))
  end

  defp expected(names) do
    case Enum.find_index(names, &(not String.valid?(&1))) do
      nil -> {:ok, names}
      index -> {:error, {:column_name_not_utf8, %{column: index, name: Enum.at(names, index)}}}
    end
  end

  defp readers(conn, early) do
    [
      Xqlite.column_names(early),
      with({:ok, result} <- Xqlite.query(conn, @sql), do: {:ok, result.columns}),
      with({:ok, stmt} <- Xqlite.prepare(conn, @sql), do: Xqlite.column_names(stmt)),
      with({:ok, s} <- NIF.stream_open(conn, @sql, []), do: NIF.stream_get_columns(s))
    ]
  end

  defp rewrite_columns(conn, names) do
    columns = Enum.map_join(names, ", ", &quote_name/1)
    rewrite_schema(conn, [{"t", "CREATE TABLE t(#{columns})"}])
  end

  # SQL text must be UTF-8, so each CREATE text goes in as hex; RESET reloads it.
  defp rewrite_schema(conn, objects) do
    updates =
      Enum.map_join(objects, "; ", fn {name, sql} ->
        "UPDATE sqlite_schema SET sql = CAST(x'#{Base.encode16(sql)}' AS TEXT) WHERE name = '#{name}'"
      end)

    :ok = NIF.execute_batch(conn, "PRAGMA writable_schema = ON; #{updates}")
    NIF.execute_batch(conn, "PRAGMA writable_schema = RESET")
  end

  # A table `t` whose columns are `names`, those `keyed` declared `REFERENCES p(id)`, and an
  # index `ti` over the columns at `positions`, written with placeholders first.
  defp plant_keyed_table(conn, names, keyed, positions) do
    slots = Enum.map(0..(length(names) - 1), &"c#{&1}")
    pick = fn list -> Enum.map_join(positions, ", ", &Enum.at(list, &1)) end

    columns =
      Enum.zip_with(names, keyed, &"#{quote_name(&1)}#{if &2, do: " REFERENCES p(id)"}")

    :ok =
      NIF.execute_batch(conn, """
      PRAGMA journal_mode = MEMORY; PRAGMA synchronous = OFF; CREATE TABLE p(id);
      CREATE TABLE t(#{Enum.join(slots, ", ")}); CREATE INDEX ti ON t(#{pick.(slots)});
      """)

    rewrite_schema(conn, [
      {"t", "CREATE TABLE t(#{Enum.join(columns, ", ")})"},
      {"ti", "CREATE INDEX ti ON t(#{pick.(Enum.map(names, &quote_name/1))})"}
    ])
  end

  # SQLite as the oracle: the first name that is not UTF-8, at its place, or every name.
  defp oracle(conn, sql) do
    assert {:ok, %{rows: rows}} = NIF.query(conn, sql, [])
    named = for [place, hex] <- rows, do: {place, hex && Base.decode16!(hex)}

    bad =
      for {place, name} <- named, is_binary(name), not String.valid?(name), do: {place, name}

    case bad do
      [] -> {:ok, Enum.map(named, fn {_place, name} -> name end)}
      [{place, name} | _] -> {:error, {:column_name_not_utf8, %{column: place, name: name}}}
    end
  end

  defp names_read({:ok, structs}, key), do: {:ok, Enum.map(structs, &Map.fetch!(&1, key))}
  defp names_read(error, _key), do: error

  defp quote_name(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""
end
