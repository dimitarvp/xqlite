defmodule Xqlite.PragmaDomainLawTest do
  @moduledoc """
  What the typed PRAGMA gate accepts, measured against SQLite itself.

  Two laws. The first: for a writable integer PRAGMA whose spec names a
  finite range, `Xqlite.Pragma.put/4` accepts a value exactly when raw SQL
  (`PRAGMA name = value;` followed by `PRAGMA name;` on a fresh connection)
  reads the value back unchanged, and refuses it exactly when SQLite quietly
  keeps something else. SQLite is the oracle: a gate that refuses a value
  SQLite honours costs the caller a setting, and a gate that accepts one
  SQLite ignores reports a change that never happened. The read side of the
  oracle is raw SQL, never `Xqlite.get_pragma/2`, because this library
  answers `wal_autocheckpoint` from its own state.

  The second: a PRAGMA whose spec maps its integers to words takes those
  words, as an atom or a string, in any case, and reads back the word.

  The third: a PRAGMA whose value is a truth — one that reads back a boolean,
  and one whose mapping gives both booleans a word — takes SQLite's whole
  boolean vocabulary (`on`/`yes`/`true` and `off`/`no`/`false`) and stores
  what SQLite itself stores for that word, raw SQL being the oracle again. A
  mapping of three modes, such as `auto_vacuum`'s, gives a boolean no meaning
  and keeps refusing the words.

  All three run on fresh in-memory connections. Two of the value bands SQLite
  floors are out of reach that way rather than by exclusion: `max_page_count`
  below the database's own page count, and `auto_vacuum` on a file database,
  which cannot change without a VACUUM. The PRAGMAs listed in
  `@law_exclusions` are out of the first law entirely, each with the reason
  SQLite gives for disagreeing with any gate.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Xqlite.Pragma, as: P
  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  @law_exclusions %{
    cache_spill:
      "below the cache's own page count SQLite answers the page count, not the value",
    hard_heap_limit:
      "it belongs to the operating-system process, applies only when it lowers the " <>
        "current limit, is never released, and a small value ends the process",
    journal_size_limit: "SQLite stores -1 for every negative",
    mmap_size:
      "SQLite clamps it to a compile-time maximum that differs per build and reads " <>
        "the compiled default for every negative",
    threads: "SQLite caps it at a compile-time worker maximum that differs per build",
    wal_autocheckpoint:
      "this library owns SQLite's WAL hook slot and answers its own threshold"
  }

  # The domain is read from the shipped spec, so a range that drifts from
  # SQLite's own is what this law reports.
  @law_pragmas P.schema()
               |> Enum.filter(fn {name, spec} ->
                 spec.writable and spec.return_type == :int and
                   is_struct(spec.valid_values, Range) and
                   not Map.has_key?(@law_exclusions, name)
               end)
               |> Enum.map(fn {name, spec} -> {name, spec.valid_values} end)
               |> Enum.sort()

  @mapped_pragmas P.schema()
                  |> Enum.filter(fn {_name, spec} -> is_map(spec.int_mapping) end)
                  |> Enum.map(fn {name, spec} -> {name, Map.values(spec.int_mapping)} end)
                  |> Enum.sort()

  # Every PRAGMA whose value is a truth: one whose reader answers a boolean,
  # and one whose mapping gives both booleans a word of their own.
  @boolean_word_pragmas P.schema()
                        |> Enum.filter(fn {_name, spec} ->
                          spec.writable and 0 in spec.read_arities and
                            (spec.return_type == :bool or
                               (is_map(spec.int_mapping) and
                                  true in Map.values(spec.int_mapping) and
                                  false in Map.values(spec.int_mapping)))
                        end)
                        |> Enum.map(fn {name, _spec} -> name end)
                        |> Enum.sort()

  @boolean_words ~w(on off yes no true false)

  test "the anchor: max_page_count's own default is accepted" do
    db = fresh()
    assert {:ok, 4_294_967_294} = P.get(db, :max_page_count)
    assert {:ok, _} = P.put(db, :max_page_count, 4_294_967_294)
  end

  test "the anchor: every writable PRAGMA writes back what it just read" do
    db = fresh()

    for name <- writable_names() do
      assert {:ok, value} = P.get(db, name)

      assert {^name, {:ok, _}} = {name, P.put(db, name, value)}
    end
  end

  test "the anchor: a word of the mapping is accepted in any spelling" do
    db = fresh()
    assert {:ok, _} = P.put(db, :auto_vacuum, :full)
    assert {:ok, :full} = P.get(db, :auto_vacuum)
    assert {:ok, _} = P.put(db, :secure_delete, "FAST")
    assert {:ok, :fast} = P.get(db, :secure_delete)
    assert {:ok, _} = P.put(db, :secure_delete, "fast")
    assert {:ok, :fast} = P.get(db, :secure_delete)
  end

  test "a word outside the mapping is still refused" do
    db = fresh()

    for value <- [:maybe, "maybe", 2] do
      assert {:error, {:invalid_pragma_value, %{pragma: :foreign_keys}}} =
               P.put(db, :foreign_keys, value)
    end

    # 2 is the integer SQLite would read as the boolean true here, storing 1
    # and losing the third mode, which only the word reaches.
    assert {:error, {:invalid_pragma_value, %{pragma: :secure_delete}}} =
             P.put(db, :secure_delete, 2)

    assert {:error, {:invalid_pragma_value, %{pragma: :auto_vacuum}}} =
             P.put(db, :auto_vacuum, :later)
  end

  # A mapping of three modes gives a boolean no meaning, so the words stay
  # refused there even though SQLite takes `= TRUE` and stores the default.
  test "a mapping without booleans keeps refusing the boolean words" do
    db = fresh()

    for value <- [:on, :off, "yes", "NO", true, false] do
      assert {:error, {:invalid_pragma_value, %{pragma: :auto_vacuum}}} =
               P.put(db, :auto_vacuum, value)

      assert {:error, {:invalid_pragma_value, %{pragma: :temp_store}}} =
               P.put(db, :temp_store, value)
    end
  end

  test "the anchor: a mapped PRAGMA holding booleans takes the boolean words" do
    db = fresh()

    assert {:ok, _} = P.put(db, :secure_delete, :on)
    assert {:ok, true} = P.get(db, :secure_delete)
    assert {:ok, _} = P.put(db, :secure_delete, "OFF")
    assert {:ok, false} = P.get(db, :secure_delete)
    assert {:ok, _} = P.put(db, :secure_delete, :fast)
    assert {:ok, :fast} = P.get(db, :secure_delete)
  end

  property "put accepts exactly the values SQLite keeps" do
    check all({name, value} <- pragma_and_value(), max_runs: 2000) do
      kept? = sqlite_keeps?(name, value)
      accepted? = put_accepts?(name, value)
      reset_soft_heap_limit()

      assert {name, value, accepted?} == {name, value, kept?}
    end
  end

  property "every word of a mapping round-trips, however it is spelled" do
    check all({name, word, spelling} <- mapped_spelling(), max_runs: 2000) do
      db = fresh()

      assert {^name, {:ok, _}} = {name, P.put(db, name, spelling)}
      assert {^name, {:ok, ^word}} = {name, P.get(db, name)}
    end
  end

  property "a boolean word stores what SQLite stores for that word" do
    check all({name, spelling, word} <- boolean_word_case(), max_runs: 2000) do
      db = fresh()
      stored = meaning(name, raw_write(name, word))

      assert {^name, {:ok, _}} = {name, P.put(db, name, spelling)}
      assert {name, {:ok, stored}} == {name, P.get(db, name)}
    end
  end

  # `mmap_size` is left out: on an in-memory database its reader answers
  # `:no_value`, which is not a value anything can write back.
  defp writable_names do
    P.schema()
    |> Enum.filter(fn {name, spec} ->
      spec.writable and name != :mmap_size and 0 in spec.read_arities and
        spec.return_type != :nothing
    end)
    |> Enum.map(fn {name, _spec} -> name end)
    |> Enum.sort()
  end

  defp pragma_and_value do
    bind(member_of(@law_pragmas), fn {name, range} ->
      map(value_of(name, range), fn value -> {name, value} end)
    end)
  end

  # A small soft heap limit would cap this operating-system process for every
  # test after it, so the generated inside-value stays above a band no test
  # here can reach; the edges, which are what a range gets wrong, still run.
  defp value_of(:soft_heap_limit, first..last//_) do
    one_of([member_of([first, last, first - 1, last + 1]), integer(67_108_864..last)])
  end

  defp value_of(_name, first..last//_) do
    one_of([member_of([first, last, first - 1, last + 1]), integer(first..last)])
  end

  defp mapped_spelling do
    bind(member_of(@mapped_pragmas), fn {name, words} ->
      bind(member_of(words), fn word ->
        map(member_of(spellings(word)), fn spelling -> {name, word, spelling} end)
      end)
    end)
  end

  defp spellings(word) do
    text = to_string(word)
    [word, text, String.upcase(text), String.downcase(text)]
  end

  defp boolean_word_case do
    bind(member_of(@boolean_word_pragmas), fn name ->
      bind(member_of(@boolean_words), fn word ->
        map(member_of(boolean_spellings(word)), fn spelling -> {name, spelling, word} end)
      end)
    end)
  end

  defp boolean_spellings(word) do
    upper = String.upcase(word)
    [word, upper, String.to_atom(word), String.to_atom(upper)]
  end

  # SQLite's own answer for the word, read on a connection that saw nothing
  # else. A PRAGMA with no row to give reads as `:no_value` on both sides.
  defp raw_write(name, word) do
    db = fresh()
    :ok = NIF.execute_batch(db, "PRAGMA #{name} = #{word};")

    case Xqlite.query(db, "PRAGMA #{name};", []) do
      {:ok, %{rows: [[read_back]]}} -> read_back
      {:ok, %{rows: []}} -> :no_value
    end
  end

  defp meaning(_name, :no_value), do: :no_value

  defp meaning(name, raw) do
    assert {:ok, spec} = Map.fetch(P.schema(), name)
    mapped_meaning(spec.int_mapping, raw)
  end

  defp mapped_meaning(nil, raw), do: raw == 1

  defp mapped_meaning(mapping, raw) do
    assert {:ok, word} = Map.fetch(mapping, raw)
    word
  end

  defp sqlite_keeps?(name, value) do
    db = fresh()
    :ok = NIF.execute_batch(db, "PRAGMA #{name} = #{value};")

    case Xqlite.query(db, "PRAGMA #{name};", []) do
      {:ok, %{rows: [[read_back]]}} -> read_back == value
      _no_row -> false
    end
  end

  defp put_accepts?(name, value) do
    case P.put(fresh(), name, value) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp reset_soft_heap_limit do
    :ok = NIF.execute_batch(fresh(), "PRAGMA soft_heap_limit = 0;")
  end

  defp fresh do
    assert {:ok, db} = NIF.open_in_memory(":memory:")
    db
  end
end
