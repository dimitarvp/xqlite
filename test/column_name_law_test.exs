defmodule Xqlite.ColumnNameLawTest do
  @moduledoc """
  The law: every function that reads result column names answers
  `{:column_name_not_utf8, %{column: index, name: bytes}}` for the first name SQLite hands
  back that is not UTF-8, before it binds or steps, and any other name byte for byte.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000
  @sql "SELECT * FROM t"
  @setup "PRAGMA journal_mode = MEMORY; PRAGMA synchronous = OFF; CREATE TABLE t(x)"
  @stored "SELECT hex(name) FROM pragma_table_info('t')"
  # Latin-1, never valid, lone continuation, overlong, surrogate, past U+10FFFF, truncated.
  @not_utf8 Enum.map(~w(E9 FF 80 C080 E08080 EDA080 F4908080 E282), &Base.decode16!/1)

  for_each_opener "a column name" do
    test "the anchor: a Latin-1 name answers the error before the write", %{conn: conn} do
      :ok = NIF.execute_batch(conn, @setup)
      :ok = rewrite_columns(conn, ["pr\xE9nom", "b"])
      result = Xqlite.query(conn, "INSERT INTO t(b) VALUES ('x') RETURNING *")
      assert {:error, {:column_name_not_utf8, %{column: 0, name: "pr\xE9nom"}}} = result
      assert {:ok, %{rows: [[0]]}} = Xqlite.query(conn, "SELECT count(*) FROM t")
    end

    # A close frees what the readers left open and fails on a statement a rejected prepare leaked.
    property "every reader answers the first name that is not UTF-8", context do
      {mod, fun, args} = Xqlite.TestUtil.find_opener_mfa!(context)

      check all(names <- names(), max_runs: 2000) do
        assert {:ok, conn} = apply(mod, fun, args)
        :ok = NIF.execute_batch(conn, @setup)
        {:ok, early} = Xqlite.prepare(conn, @sql)
        :ok = rewrite_columns(conn, names)
        assert {:ok, %{rows: stored}} = Xqlite.query(conn, @stored)
        assert stored |> List.flatten() |> Enum.map(&Base.decode16!/1) == names
        assert :done = Xqlite.step(early)
        assert readers(conn, early) == names |> expected() |> List.duplicate(4)
        assert :done = Xqlite.step(early)
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
    query = Task.async(fn -> Xqlite.query(a, @sql) end)
    assert_receive {:xqlite_busy, _retries, _elapsed_ms}, 5_000
    :ok = NIF.execute_batch(b, "ALTER TABLE t RENAME COLUMN b TO z; COMMIT;")
    changed = {:columns_changed, %{expected: ["a", "b", "c"], live: ["a", "z", "c"]}}
    assert {:error, ^changed} = Task.await(query)
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

  # SQL text must be UTF-8, so the CREATE text goes in as hex; RESET reloads it.
  defp rewrite_columns(conn, names) do
    create = Base.encode16("CREATE TABLE t(#{Enum.map_join(names, ", ", &quote_name/1)})")
    update = "UPDATE sqlite_schema SET sql = CAST(x'#{create}' AS TEXT) WHERE name = 't'"
    :ok = NIF.execute_batch(conn, "PRAGMA writable_schema = ON; #{update}")
    NIF.execute_batch(conn, "PRAGMA writable_schema = RESET")
  end

  defp quote_name(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""
end
