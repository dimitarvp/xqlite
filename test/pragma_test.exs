defmodule XqlitePragmaTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.TestUtil

  alias Xqlite.Pragma, as: P
  alias XqliteNIF, as: NIF

  doctest Xqlite.Pragma

  @write_test_cases [
    # Simple set/get with representative values
    {:application_id, [0, 12345, 98765, -1000], nil},
    {:analysis_limit, [:unlimited, 100], nil},
    {:user_version, [0, 5, 10, -100], nil},
    # Can only be set on a fresh DB
    {:page_size, [2048, 4096, 8192], nil},
    {:busy_timeout, [0, 1000, 5000], nil},
    {:journal_size_limit, [0, :unlimited, 102_400], nil},
    {:max_page_count, [1, 1_000_000], nil},

    # All boolean PRAGMAs
    {:automatic_index, [true, false]},
    {:cell_size_check, [true, false]},
    {:checkpoint_fullfsync, [true, false]},
    {:defer_foreign_keys, [true, false]},
    {:foreign_keys, [true, false]},
    {:fullfsync, [true, false]},
    {:ignore_check_constraints, [true, false]},
    {:legacy_alter_table, [true, false]},
    {:query_only, [true, false]},
    {:read_uncommitted, [true, false]},
    {:recursive_triggers, [true, false]},
    {:reverse_unordered_selects, [true, false]},
    {:trusted_schema, [true, false]},

    # PRAGMAs with special value mappings (test all specified values)
    {:synchronous,
     [
       {"NORMAL", :normal},
       {1, :normal},
       {"OFF", :off},
       {0, :off},
       {"FULL", :full},
       {2, :full},
       {"EXTRA", :extra},
       {3, :extra}
     ]},
    {:temp_store,
     [
       {"DEFAULT", :default},
       {0, :default},
       {"FILE", :file},
       {1, :file},
       {"MEMORY", :memory},
       {2, :memory}
     ]},
    {:auto_vacuum, [{0, :none}, {1, :full}, {2, :incremental}], &verify_is_atom/4},
    # SQLite reads `secure_delete = 2` as the boolean "true", so the third
    # mode is reachable by its word only.
    {:secure_delete, [{0, false}, {1, true}, {"FAST", :fast}]},

    # PRAGMAs with platform-dependent results
    {:journal_mode,
     [
       # Most common default for file DBs
       {"DELETE", "delete"},
       {"TRUNCATE", "truncate"},
       {"PERSIST", "persist"},
       {"MEMORY", "memory"},
       # On in-memory, WAL falls back to memory
       {"WAL", ~w(wal memory)},
       {"OFF", "off"}
     ], &verify_journal_mode/4},
    {:locking_mode, [{"NORMAL", "normal"}, {"EXCLUSIVE", "exclusive"}]},
    {:encoding,
     [
       {"UTF-8", "UTF-8"},
       {"UTF-16le", "UTF-16le"},
       {"UTF-16be", "UTF-16be"},
       # Setting UTF-16 may result in le or be
       {"UTF-16", ~w(UTF-16le UTF-16be)}
     ]},

    # Advisory values
    {:cache_size,
     [{{:pages, 0}, {:pages, 0}}, {{:pages, 8}, {:pages, 8}}, {{:kib, 16}, {:kib, 16}}]},
    # Both heap limits belong to the operating-system process, not to the
    # connection, and a hard limit is never released once it is lowered: a
    # small one here would make every later test in this process fail with
    # "out of memory". Only values that lower nothing are written.
    {:soft_heap_limit, [9_223_372_036_854_775_807], &verify_is_integer/4},
    {:hard_heap_limit, [9_223_372_036_854_775_807], &verify_is_integer/4},
    {:threads, [0, 1, 8], &verify_is_integer/4},
    {:wal_autocheckpoint, [:off, 1000]},
    {:mmap_size, [0, 256 * 1024], &verify_mmap_size_value/4}
  ]

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "PRAGMA tests using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, db} = apply(mod, fun, args)
        {:ok, db: db, test_context_tag: unquote(type_tag)}
      end

      # All readable PRAGMAs with zero arguments (they only fetch values and don't modify
      # any DB behaviour).

      for name <- P.readable_with_zero_args() do
        test "read pragma: #{name}", %{db: db} do
          assert valid_get_result(P.get(db, unquote(name)))
        end
      end

      # Test for a readable PRAGMA that takes one argument.
      test "read pragma: foreign_key_check with table name", %{db: db} do
        # Setup: Create tables but keep foreign keys OFF initially.
        assert {:ok, _} = P.put(db, :foreign_keys, false)

        assert :ok =
                 NIF.execute_batch(db, """
                   CREATE TABLE parents(id INTEGER PRIMARY KEY);
                   CREATE TABLE children(id INTEGER, parent_id INTEGER REFERENCES parents(id));
                   INSERT INTO parents (id) VALUES (1);
                   INSERT INTO children (id, parent_id) VALUES (10, 1);
                 """)

        # With FKs off, check should still pass as there are no violations yet.
        assert {:ok, []} = P.get(db, :foreign_key_check, "children")

        # Now, insert an invalid row. This will succeed because FKs are off.
        assert {:ok, 1} =
                 NIF.execute(db, "INSERT INTO children (id, parent_id) VALUES (20, 99);", [])

        # Now, run the check. It should find the pre-existing violation.
        # The rowid of the new row is 2.
        assert {:ok, [["children", 2, "parents", 0]]} =
                 P.get(db, :foreign_key_check, "children")
      end

      # All of the readable PRAGMAs with one arg are actually instructions that change the DB.
      # We are not going to test those.

      # All writable PRAGMAs with one arg.

      # The escape belongs in the body: as a comprehension clause it is a
      # filter, and it dropped every row that names no verify function.
      for {name, values_to_test, verify_fun} <- Enum.map(@write_test_cases, &write_case/1) do
        verify_fun = Macro.escape(verify_fun || (&default_verify_values/4))

        # Generate a test for each value to be set for a given PRAGMA
        for {set_val, expected_val} <- normalize_test_values(values_to_test) do
          test_name_string = "write pragma: #{name} = #{inspect(set_val)}"

          test test_name_string, %{db: db, test_context_tag: test_context_tag} do
            # We have to do `unquote(name)` several times here because Elixir's 1.18 compiler
            # warns us that certain comparisons can never succeed.
            set_val = unquote(set_val)
            expected_val = unquote(expected_val)
            verify_fun = unquote(verify_fun)

            # We need a clean DB for some PRAGMAs like page_size
            db = if unquote(name) == :page_size, do: clean_db(), else: db

            # The core of the test: put, then get and verify
            assert {:ok, _} = P.put(db, unquote(name), set_val)

            case P.get(db, unquote(name)) do
              {:ok, fetched_val} ->
                assert verify_fun.(test_context_tag, set_val, fetched_val, expected_val),
                       "Set `#{inspect(set_val)}`, but fetched `#{inspect(fetched_val)}`, expected one of `#{inspect(expected_val)}`"

              # For write-only PRAGMAs
              :ok ->
                assert verify_fun.(test_context_tag, set_val, :ok, expected_val)

              error ->
                flunk(
                  "P.get returned an unexpected error after a successful put: `#{inspect(error)}`"
                )
            end
          end
        end
      end
    end
  end

  describe "schema-prefixed pragmas via :db_name option" do
    setup do
      {:ok, db} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(db) end)
      {:ok, db: db}
    end

    test "get with db_name: main reads from main schema", %{db: db} do
      assert {:ok, {:kib, 2000}} = P.get(db, :cache_size, [], db_name: "main")
    end

    test "put with db_name: main writes to main schema", %{db: db} do
      assert {:ok, _} = P.put(db, :cache_size, {:pages, 5000}, db_name: "main")
      assert {:ok, {:pages, 5000}} = P.get(db, :cache_size, [], db_name: "main")
    end

    test "get/put on an attached database", %{db: db} do
      NIF.execute_batch(db, "ATTACH ':memory:' AS aux;")

      assert {:ok, _} = P.put(db, :cache_size, {:pages, 3000}, db_name: "aux")
      assert {:ok, {:pages, 3000}} = P.get(db, :cache_size, [], db_name: "aux")

      # main schema should be unaffected
      {:ok, main_cache} = P.get(db, :cache_size)
      refute main_cache == {:pages, 3000}
    end

    test "the two reads this library answers itself reject a db_name", %{db: db} do
      for name <- [:busy_timeout, :wal_autocheckpoint] do
        assert {:error,
                {:invalid_pragma_argument,
                 %{pragma: ^name, value: {:db_name, "main"}, reason: :invalid_options}}} =
                 P.get(db, name, db_name: "main")
      end
    end

    test "get list-returning pragma with db_name", %{db: db} do
      NIF.execute_batch(
        db,
        "CREATE TABLE main.dbname_test (id INTEGER PRIMARY KEY, name TEXT);"
      )

      assert {:ok, rows} = P.get(db, :table_info, "dbname_test", db_name: "main")
      assert is_list(rows)
      refute Enum.empty?(rows)
    end

    # A PRAGMA takes no bound parameter, so its argument is quoted into the
    # statement text; a quote inside the argument has to be doubled or the
    # statement ends early. `table_info` of a name no table carries answers
    # with the tag, while a broken quote is a syntax error instead.
    test "get quotes an argument holding a double quote", %{db: db} do
      assert {:error, {:no_such_table, "a\"b"}} =
               P.get(db, :table_info, "a\"b", db_name: "main")
    end

    property "get accepts an argument whatever characters it holds", %{db: db} do
      check all(value <- pragma_string_value(), max_runs: 2000) do
        assert {:error, {:no_such_table, ^value}} =
                 P.get(db, :table_info, value, db_name: "main")
      end
    end
  end

  describe "unknown pragma" do
    setup do
      {:ok, db} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(db) end)
      {:ok, db: db}
    end

    test "get returns {:error, {:unknown_pragma, name}} for unknown pragma", %{db: db} do
      assert {:error, {:unknown_pragma, :totally_fake_pragma}} =
               P.get(db, :totally_fake_pragma)
    end

    test "put returns {:error, {:unknown_pragma, name}} for unknown string pragma", %{
      db: db
    } do
      assert {:error, {:unknown_pragma, "never_atomized_pragma_xyz"}} =
               P.put(db, "never_atomized_pragma_xyz", 1)
    end

    test "put returns {:error, {:invalid_pragma_name, term}} for a key that is not a name", %{
      db: db
    } do
      assert {:error, {:invalid_pragma_name, {:not, :a, :name}}} =
               P.put(db, {:not, :a, :name}, 1)

      assert {:error, {:invalid_pragma_name, 7}} = P.get(db, 7)
    end

    # `to_string(nil)` is `""`, so a raw door that converted first would hand
    # SQLite an empty name and report the caller's key as that empty string.
    # The two door families answer with different tags, but neither invents a
    # key, and neither builds a statement.
    test "the anchor: nil is no name on any door", %{db: db} do
      assert :ok = Xqlite.set_authorizer(db, [:pragma])

      assert {:error, {:invalid_pragma_name, nil}} = Xqlite.get_pragma(db, nil)
      assert {:error, {:invalid_pragma_name, nil}} = Xqlite.set_pragma(db, nil, 1)
      assert {:error, {:unknown_pragma, nil}} = P.get(db, nil)
      assert {:error, {:unknown_pragma, nil}} = P.put(db, nil, 1)

      assert {:error, {:authorization_denied, _code, _message}} = P.get(db, :busy_timeout)
    end

    # `true` and `false` stay names of PRAGMAs SQLite parses and ignores, by
    # the raw doors' own rule for a name outside the typed schema.
    test "the anchor: true and false are still names on the raw doors", %{db: db} do
      assert {:ok, :no_value} = Xqlite.get_pragma(db, true)
      assert {:ok, :no_value} = Xqlite.get_pragma(db, false)
    end

    # Denying the `:pragma` action turns any PRAGMA that really reaches SQLite
    # into an authorization error, so a structured refusal here proves no
    # statement was built at all.
    test "an unknown name is refused before any statement reaches SQLite", %{db: db} do
      assert :ok = Xqlite.set_authorizer(db, [:pragma])

      assert {:error, {:unknown_pragma, :no_such_pragma}} = P.put(db, :no_such_pragma, 1)
      assert {:error, {:unknown_pragma, :no_such_pragma}} = P.get(db, :no_such_pragma)

      assert {:error, {:unknown_pragma, :no_such_pragma}} =
               P.get(db, :no_such_pragma, "arg")

      assert {:error, {:authorization_denied, _code, _msg}} = P.get(db, :busy_timeout)
    end

    # SQLite folds a PRAGMA name by ASCII letters alone. The Kelvin sign
    # folds to "k" under Unicode rules, so a Unicode fold would let it in.
    test "a name only a Unicode fold turns into a known one is unknown", %{db: db} do
      kelvin = "foreign_" <> <<0x212A::utf8>> <> "eys"
      kelvin_atom = String.to_atom(kelvin)

      assert {:error, {:unknown_pragma, ^kelvin}} = P.get(db, kelvin)
      assert {:error, {:unknown_pragma, ^kelvin}} = P.put(db, kelvin, 1)
      assert {:error, {:unknown_pragma, ^kelvin_atom}} = P.get(db, kelvin_atom)
      assert {:error, {:unknown_pragma, ^kelvin_atom}} = P.put(db, kelvin_atom, 1)
    end

    property "no name outside the schema reaches SQLite", %{db: db} do
      assert :ok = Xqlite.set_authorizer(db, [:pragma])

      check all(name <- unknown_pragma_name(), max_runs: 2000) do
        assert {:error, {:unknown_pragma, ^name}} = P.put(db, name, 1)
        assert {:error, {:unknown_pragma, ^name}} = P.get(db, name)
        assert {:error, {:unknown_pragma, ^name}} = P.get(db, name, "arg")
      end
    end
  end

  # A PRAGMA argument is a scalar, so a list in that position is the options and
  # only when every element is a `{key, value}` pair. What a pragma reads with
  # decides the rest: the six that read only with an argument refuse a missing
  # one, and the ones with no one-argument form refuse an argument instead of
  # handing SQLite `PRAGMA name(value)`, which it reads as a write.
  describe "the argument position" do
    setup do
      assert {:ok, db} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(db) end)

      :ok =
        NIF.execute_batch(db, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);")

      {:ok, db: db}
    end

    test "the anchor: a list is not an argument, on either path", %{db: db} do
      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :table_info, value: ["people"], reason: :not_a_scalar}}} =
               P.get(db, :table_info, ["people"])

      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :table_info, value: ["people"], reason: :not_a_scalar}}} =
               P.get(db, :table_info, ["people"], db_name: "main")

      # The named accessor takes a name, so `apply/3` keeps the compiler's
      # type checker out of a call whose argument is wrong on purpose.
      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :table_info, value: ["people"], reason: :not_a_scalar}}} =
               apply(P, :table_info, [db, ["people"]])

      assert {:ok, [[0, "id" | _] | _]} = P.get(db, :table_info, "people")
    end

    test "the anchor: nil is not an argument, on either path", %{db: db} do
      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :table_info, value: nil, reason: :not_a_scalar}}} =
               P.get(db, :table_info, nil)

      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :table_info, value: nil, reason: :not_a_scalar}}} =
               P.get(db, :table_info, nil, db_name: "main")

      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :table_info, value: nil, reason: :not_a_scalar}}} =
               apply(P, :table_info, [db, nil])
    end

    test "the anchor: a pragma that reads only with an argument refuses a missing one",
         %{db: db} do
      assert {:error,
              {:invalid_pragma_argument, %{pragma: :table_info, value: nil, reason: :missing}}} =
               P.get(db, :table_info)

      assert {:error,
              {:invalid_pragma_argument, %{pragma: :table_info, value: nil, reason: :missing}}} =
               P.get(db, :table_info, db_name: "main")
    end

    test "the anchor: a getter with no one-argument form refuses the argument", %{db: db} do
      assert {:ok, _} = P.put(db, :user_version, 7)

      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :user_version, value: 42, reason: :takes_no_argument}}} =
               P.get(db, :user_version, 42)

      assert {:ok, 7} = P.get(db, :user_version)
    end

    property "the refused argument writes nothing", %{db: db} do
      assert {:ok, _} = P.put(db, :user_version, 7)

      check all(value <- pragma_scalar(), max_runs: 2000) do
        assert {:error, {:invalid_pragma_argument, %{pragma: :user_version, reason: reason}}} =
                 P.get(db, :user_version, value)

        assert :takes_no_argument = reason
        assert {:ok, 7} = P.get(db, :user_version)
      end
    end

    property "every name answers by its read arities, and nothing else is built", %{db: db} do
      assert :ok = Xqlite.set_authorizer(db, [:pragma])

      check all(
              name <- StreamData.member_of(P.all()),
              shape <- argument_shape(),
              opts <- StreamData.member_of([[], [db_name: "main"]]),
              max_runs: 2000
            ) do
        assert verdict(name, shape, opts) ==
                 classify_answer(answer_for(db, name, shape, opts))
      end
    end
  end

  # SQLite answers no row at all for some PRAGMAs: memory mapped I/O has no
  # size on a database that is not a file, and two more report nothing
  # anywhere. Every read door answers `:no_value` there, and no write door
  # takes the atom back.
  describe "a PRAGMA the connection has no row for" do
    setup do
      assert {:ok, db} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(db) end)
      {:ok, db: db}
    end

    test "memory mapped I/O has no size in memory", %{db: db} do
      assert {:ok, :no_value} = P.get(db, :mmap_size)
      assert {:ok, :no_value} = Xqlite.get_pragma(db, :mmap_size)
    end

    test "the same PRAGMA answers a number off a file database" do
      path = tmp_db_path("mmap_size")
      assert {:ok, file_db} = Xqlite.open(path)
      on_exit(fn -> :ok = Xqlite.close(file_db) end)

      assert {:ok, size} = P.get(file_db, :mmap_size)
      assert is_integer(size)
    end

    test "two more answer it on every database", %{db: db} do
      assert {:ok, :no_value} = P.get(db, :legacy_file_format)
      assert {:ok, :no_value} = P.get(db, :incremental_vacuum)
    end

    test "no write door takes the atom back", %{db: db} do
      assert {:error, {:invalid_pragma_value, %{pragma: :mmap_size, value: :no_value}}} =
               P.put(db, :mmap_size, :no_value)

      assert {:error, {:invalid_pragma_value, %{pragma: :mmap_size, value: :no_value}}} =
               Xqlite.set_pragma(db, "mmap_size", :no_value)
    end
  end

  # The options are the last argument of every read and write door — and the
  # third argument too, when it is a keyword list, because the two are merged
  # before a statement is built. `:db_name` is the only key they carry.
  describe "the options position" do
    setup do
      assert {:ok, db} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(db) end)

      :ok =
        NIF.execute_batch(db, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);")

      {:ok, db: db}
    end

    test "the anchor: a term that is no keyword list is no options", %{db: db} do
      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :user_version, value: :nope, reason: :invalid_options}}} =
               P.get(db, :user_version, [], :nope)

      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :user_version, value: :nope, reason: :invalid_options}}} =
               P.put(db, :user_version, 1, :nope)
    end

    test "the anchor: an unknown key and a db_name that is no name", %{db: db} do
      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :user_version, value: {:foo, 1}, reason: :invalid_options}}} =
               P.get(db, :user_version, foo: 1)

      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :user_version, value: {:db_name, 42}, reason: :invalid_options}}} =
               P.get(db, :user_version, db_name: 42)
    end

    test "the anchor: the options that read keep reading", %{db: db} do
      assert {:ok, _written} = P.put(db, :user_version, 3)

      assert {:ok, 3} = P.get(db, :user_version, [], [])
      assert {:ok, 3} = P.get(db, :user_version, db_name: "main")
      assert {:ok, 3} = P.get(db, :user_version, db_name: :main)
      assert {:ok, 3} = P.get(db, :user_version, db_name: nil)
      assert {:ok, [[0, "id" | _rest] | _more]} = P.table_info(db, "people", db_name: "main")
    end

    property "every door refuses options it cannot read, and builds nothing", %{db: db} do
      assert :ok = Xqlite.set_authorizer(db, [:pragma])

      check all(options <- bad_options(), max_runs: 2000) do
        value = refused_option(options)

        assert {:error,
                {:invalid_pragma_argument,
                 %{pragma: :user_version, value: ^value, reason: :invalid_options}}} =
                 P.get(db, :user_version, [], options)

        assert {:error,
                {:invalid_pragma_argument,
                 %{pragma: :user_version, value: ^value, reason: :invalid_options}}} =
                 P.put(db, :user_version, 1, options)

        assert {:error,
                {:invalid_pragma_argument,
                 %{pragma: :table_info, value: ^value, reason: :invalid_options}}} =
                 apply(P, :table_info, [db, "people", options])
      end

      # The denying authorizer turns any PRAGMA that really reaches SQLite
      # into an authorization error, so the refusals above built nothing.
      assert {:error, {:authorization_denied, _code, _message}} = P.get(db, :busy_timeout)
    end

    property "the third argument is options too, and is judged the same way", %{db: db} do
      check all(options <- bad_keyword_options(), max_runs: 2000) do
        value = refused_option(options)

        assert {:error,
                {:invalid_pragma_argument,
                 %{pragma: :user_version, value: ^value, reason: :invalid_options}}} =
                 P.get(db, :user_version, options)
      end
    end
  end

  # Every term a caller can put in the options position that is not a keyword
  # list of the one key these doors read.
  defp bad_options do
    StreamData.one_of([
      StreamData.atom(:alphanumeric),
      StreamData.integer(),
      StreamData.scale(StreamData.binary(), fn size -> min(size, 8) end),
      StreamData.tuple({StreamData.atom(:alphanumeric), StreamData.integer()}),
      StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.integer(), max_length: 2),
      StreamData.list_of(StreamData.integer(), min_length: 1, max_length: 3),
      StreamData.constant([:db_name]),
      improper_options(),
      bad_keyword_options()
    ])
  end

  # A keyword list that ends in something other than `[]` is no keyword list,
  # so the whole term is what the refusal carries.
  defp improper_options do
    StreamData.map(StreamData.atom(:alphanumeric), fn tail -> [{:db_name, "main"} | tail] end)
  end

  # A proper keyword list the doors still cannot read: a key they do not know,
  # or a `:db_name` that is no name.
  defp bad_keyword_options do
    StreamData.one_of([
      StreamData.map(StreamData.integer(), fn number -> [db_name: number] end),
      StreamData.map(capped_float(), fn number -> [db_name: number] end),
      StreamData.map(StreamData.member_of([:foo, :schema, :bar]), fn key -> [{key, 1}] end),
      StreamData.map(StreamData.integer(), fn number -> [db_name: "main", other: number] end)
    ])
  end

  # `float/0` costs time quadratic in the size parameter, which grows by one
  # per run, so an uncapped one spends the property's budget generating.
  defp capped_float do
    StreamData.scale(StreamData.float(), fn size -> min(size, 5) end)
  end

  # What the refusal names: the whole term when it is no keyword list, and the
  # first pair the doors cannot read when it is one.
  defp refused_option(options) do
    case Keyword.keyword?(options) do
      true -> Enum.find(options, &bad_option_pair?/1)
      false -> options
    end
  end

  defp bad_option_pair?({:db_name, value}), do: not (is_binary(value) or is_atom(value))
  defp bad_option_pair?(_pair), do: true

  # SQLite reads the argument of four of these PRAGMAs as a number and of the
  # rest as a name, so the statement has to carry each as what it is.
  describe "a number in the argument position" do
    setup do
      assert {:ok, db} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(db) end)

      :ok =
        NIF.execute_batch(db, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);")

      {:ok, db: db}
    end

    test "the anchor: a number reaches the PRAGMA that reads one", %{db: db} do
      assert {:ok, ["ok"]} = P.get(db, :integrity_check, 1)
    end

    test "the anchor: a name no table carries answers the tag", %{db: db} do
      assert {:error, {:no_such_table, :no_such}} = P.table_info(db, :no_such)
    end

    # The getter flattens single-column rows; the values are SQLite's own.
    property "a number-reading PRAGMA answers what the raw statement answers", %{db: db} do
      check all(
              name <-
                StreamData.member_of([
                  :integrity_check,
                  :quick_check,
                  :optimize,
                  :incremental_vacuum
                ]),
              number <- StreamData.integer(1..8),
              max_runs: 2000
            ) do
        assert {:ok, rows} = P.get(db, name, number)

        assert {:ok, %Xqlite.Result{rows: raw_rows}} =
                 Xqlite.query(db, "PRAGMA #{name}(#{number});", [])

        assert List.flatten(rows) == List.flatten(raw_rows)
      end
    end
  end

  # The six shapes the argument position can take.
  defp argument_shape do
    StreamData.one_of([
      StreamData.constant(:none),
      StreamData.constant({:nil_argument, nil}),
      StreamData.map(pragma_scalar(), fn value -> {:scalar, value} end),
      StreamData.map(StreamData.member_of([[], [db_name: "main"]]), fn kw -> {:options, kw} end),
      StreamData.map(non_keyword_list(), fn list -> {:list, list} end),
      StreamData.map(nested_list(), fn list -> {:list, list} end)
    ])
  end

  defp pragma_scalar do
    StreamData.one_of([
      pragma_string_value(),
      StreamData.filter(StreamData.atom(:alphanumeric), fn atom -> not is_nil(atom) end),
      StreamData.integer(-2_147_483_648..2_147_483_647),
      StreamData.member_of([true, false, :people, "people", 0, -1])
    ])
  end

  defp non_keyword_list do
    [StreamData.atom(:alphanumeric), StreamData.integer(), pragma_string_value()]
    |> StreamData.one_of()
    |> StreamData.list_of(min_length: 1, max_length: 3)
  end

  defp nested_list do
    pragma_string_value()
    |> StreamData.list_of(min_length: 1, max_length: 2)
    |> StreamData.list_of(min_length: 1, max_length: 2)
  end

  # The two reads this library answers from its own state take no `:db_name`.
  defp verdict(name, {:options, kw}, opts), do: verdict(name, :none, kw ++ opts)

  defp verdict(name, :none, [{:db_name, db_name} | _])
       when name in [:busy_timeout, :wal_autocheckpoint],
       do: {:refused, name, :invalid_options, {:db_name, db_name}}

  defp verdict(name, shape, _opts), do: argument_verdict(name, shape)

  defp argument_verdict(name, :none), do: no_argument_verdict(name)
  defp argument_verdict(name, {:list, list}), do: {:refused, name, :not_a_scalar, list}
  defp argument_verdict(name, {:nil_argument, nil}), do: {:refused, name, :not_a_scalar, nil}

  defp argument_verdict(name, {:scalar, value}) do
    case name in P.readable_with_one_arg() do
      true -> :went_ahead
      false -> {:refused, name, :takes_no_argument, value}
    end
  end

  defp no_argument_verdict(name) do
    case name in P.readable_with_zero_args() do
      true -> :went_ahead
      false -> {:refused, name, :missing, nil}
    end
  end

  defp answer_for(db, name, :none, []), do: P.get(db, name)
  defp answer_for(db, name, :none, opts), do: P.get(db, name, [], opts)
  defp answer_for(db, name, {_kind, value}, []), do: P.get(db, name, value)
  defp answer_for(db, name, {_kind, value}, opts), do: P.get(db, name, value, opts)

  # The denying authorizer turns every PRAGMA that really reaches SQLite into
  # an authorization error, so a refusal here proves no statement was built.
  # A read that goes ahead is not always a statement: `wal_autocheckpoint` is
  # answered from the connection's own emulated threshold.
  defp classify_answer(
         {:error, {:invalid_pragma_argument, %{pragma: pragma, value: value, reason: reason}}}
       ), do: {:refused, pragma, reason, value}

  defp classify_answer(_went_ahead), do: :went_ahead

  # SQLite matches a PRAGMA name without regard to case, and the typed schema
  # spells every name in lower-case atoms. A caller who writes the name any
  # other way must reach the same PRAGMA through every door.
  describe "spellings of a known name" do
    setup do
      {:ok, canonical: Map.new(P.all(), fn name -> {name, door_answers(name, name)} end)}
    end

    test "the anchor: an upper-case string reads what the lower-case atom reads" do
      assert door_answers("FOREIGN_KEYS", :foreign_keys) ==
               door_answers(:foreign_keys, :foreign_keys)
    end

    # A door resolves the caller's spelling to the name this module knows, so
    # what SQLite is given — and what an error payload then reports — is the
    # same string whatever the caller wrote.
    test "the anchor: a door hands SQLite the name the spec spells" do
      assert {:ok, db} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(db) end)

      handler_id = Xqlite.Telemetry.TestSupport.attach_capture([[:xqlite, :pragma, :get]])
      on_exit(fn -> Xqlite.Telemetry.TestSupport.detach(handler_id) end)

      assert {:ok, _value} = Xqlite.get_pragma(db, :FUNCTION_LIST)

      assert_receive {:telemetry_event, [:xqlite, :pragma, :get], _measurements,
                      %{name: "function_list"}}
    end

    property "every door answers what the canonical atom answers", %{canonical: canonical} do
      check all(
              name <- StreamData.member_of(P.all()),
              spelling <- spelling_of(name),
              max_runs: 2000
            ) do
        assert door_answers(spelling, name) == Map.get(canonical, name)
      end
    end
  end

  # A key that is no name is no spelling of one either: every door refuses it
  # with the key the caller wrote, and builds nothing.
  describe "a key that is neither an atom nor a string" do
    setup do
      assert {:ok, db} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(db) end)
      {:ok, db: db}
    end

    test "the anchor: a charlist is a list, and nothing is written", %{db: db} do
      assert {:ok, 0} = Xqlite.get_pragma(db, :user_version)

      assert {:error, {:invalid_pragma_name, ~c"user_version"}} =
               Xqlite.set_pragma(db, ~c"user_version", 77)

      assert {:ok, 0} = Xqlite.get_pragma(db, :user_version)
    end

    property "every door refuses it, with the key unchanged", %{db: db} do
      assert :ok = Xqlite.set_authorizer(db, [:pragma])

      check all(key <- non_name_key(), max_runs: 2000) do
        assert {:error, {:invalid_pragma_name, ^key}} = P.get(db, key)
        assert {:error, {:invalid_pragma_name, ^key}} = P.put(db, key, 1)
        assert {:error, {:invalid_pragma_name, ^key}} = Xqlite.get_pragma(db, key)
        assert {:error, {:invalid_pragma_name, ^key}} = Xqlite.set_pragma(db, key, 1)
      end

      # The denying authorizer turns any PRAGMA that really reaches SQLite
      # into an authorization error, so the refusals above built nothing.
      assert {:error, {:authorization_denied, _code, _message}} = P.get(db, :busy_timeout)
    end
  end

  # Every kind of term a PRAGMA name cannot be.
  defp non_name_key do
    StreamData.one_of([
      StreamData.tuple({StreamData.atom(:alphanumeric), StreamData.atom(:alphanumeric)}),
      StreamData.map(StreamData.atom(:alphanumeric), fn key -> %{key => 1} end),
      StreamData.constant(self()),
      StreamData.map(StreamData.constant(:ref), fn _ -> make_ref() end),
      StreamData.map(StreamData.member_of(P.all()), &Atom.to_charlist/1),
      StreamData.integer(),
      StreamData.scale(StreamData.float(), fn size -> min(size, 10) end),
      StreamData.list_of(StreamData.atom(:alphanumeric), max_length: 3)
    ])
  end

  defp unknown_pragma_name do
    StreamData.bind(StreamData.string(:printable, max_length: 10), fn suffix ->
      text = "xqlite_no_such_pragma_" <> suffix

      StreamData.member_of([
        String.to_atom(text),
        String.to_atom(String.upcase(text)),
        text,
        String.upcase(text)
      ])
    end)
  end

  # Every spelling of a known name, the way a caller might write it.
  defp spelling_of(name) do
    text = Atom.to_string(name)
    upper = String.upcase(text)
    mixed = alternating_case(text)

    StreamData.member_of([
      name,
      String.to_atom(upper),
      String.to_atom(mixed),
      text,
      upper,
      mixed
    ])
  end

  defp alternating_case(text) do
    text
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map_join("", &recased_char/1)
  end

  defp recased_char({char, index}) when rem(index, 2) == 0, do: String.upcase(char)
  defp recased_char({char, _index}), do: String.downcase(char)

  # Every door, on a connection of its own, with a value no PRAGMA accepts so
  # that nothing is written and the answers depend on the name alone.
  defp door_answers(key, name) do
    assert {:ok, db} = NIF.open_in_memory(":memory:")
    :ok = NIF.execute_batch(db, "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);")

    answers =
      [
        P.get(db, key),
        P.put(db, key, nil),
        Xqlite.get_pragma(db, key),
        Xqlite.set_pragma(db, key, nil)
      ] ++ with_arg_answer(db, key, name)

    assert :ok = NIF.close(db)
    answers
  end

  defp with_arg_answer(db, key, name) do
    case name in P.readable_with_one_arg() do
      true -> [P.get(db, key, "people")]
      false -> []
    end
  end

  defp pragma_string_value do
    [?a, ?9, ?', ?", ?`, ?\\, ?;, ?-, ?\s, ?\n, ?é]
    |> StreamData.member_of()
    |> StreamData.list_of(max_length: 12)
    |> StreamData.map(&List.to_string/1)
  end

  defp valid_get_result({:error, _, _}), do: false
  defp valid_get_result({:error, _}), do: false
  defp valid_get_result({:ok, _}), do: true
  defp valid_get_result(:ok), do: true

  defp valid_get_result(other) do
    IO.puts("pragma_get_result: unknown response: `#{inspect(other)}`")
  end

  defp clean_db do
    {:ok, db} = NIF.open_in_memory(":memory:")
    ExUnit.Callbacks.on_exit(fn -> NIF.close(db) end)
    db
  end

  # ---------------------------------------------------------------------------
  # Value checking: Xqlite.set_pragma/3 and Xqlite.Pragma.put/4 share one rule
  # ---------------------------------------------------------------------------

  @writable_names P.writable()

  @accepted_spellings Map.new(P.writable(), fn name ->
                        spec = Map.fetch!(P.schema(), name)

                        forms =
                          case spec do
                            %{return_type: :bool} ->
                              [true, false, 1, 0, :on, :off, "ON", "off", "yes", "No", "TRUE"]

                            %{valid_values: %Range{}} ->
                              []

                            %{valid_values: nil} ->
                              [{:kib, 2_000}, {:pages, 0}]

                            %{valid_values: values} ->
                              Enum.flat_map(values, fn
                                value when is_binary(value) ->
                                  [
                                    value,
                                    String.downcase(value),
                                    String.upcase(value),
                                    String.to_atom(String.downcase(value))
                                  ]

                                value ->
                                  [value]
                              end)
                          end

                        {name, forms}
                      end)

  @hostile_values [
    :maybe,
    :garbage,
    nil,
    {1, 2},
    "99",
    "not-a-word",
    1.5,
    -1.5,
    3_000_000_000,
    -3_000_000_000
  ]

  # A heap limit belongs to the operating-system process, and a hard one is
  # never released: a small generated value would cap every test that runs
  # after it. These stay above a gigabyte, where they cap nothing.
  defp accepted_value(name) when name in [:hard_heap_limit, :soft_heap_limit] do
    _first..last//_ = integer_range(name)
    StreamData.integer(1_073_741_824..last)
  end

  defp accepted_value(name) do
    case Map.fetch!(@accepted_spellings, name) do
      [] -> name |> integer_range() |> StreamData.integer()
      forms -> StreamData.member_of(forms)
    end
  end

  # A value is hostile to a PRAGMA only when its own spec has no room for it;
  # the two 64-bit domains hold integers the 32-bit ones refuse.
  defp hostile_pair do
    StreamData.bind(StreamData.member_of(@writable_names), fn name ->
      name
      |> hostile_values_for()
      |> StreamData.member_of()
      |> StreamData.map(fn value -> {name, value} end)
    end)
  end

  defp hostile_values_for(name) do
    %{valid_values: valid} = Map.fetch!(P.schema(), name)
    Enum.reject(@hostile_values, fn value -> inside?(valid, value) end)
  end

  defp inside?(%Range{} = range, value) when is_integer(value), do: value in range
  defp inside?(_valid_values, _value), do: false

  defp integer_range(name) do
    %{valid_values: range} = Map.fetch!(P.schema(), name)
    range
  end

  defp accepted_pair do
    StreamData.bind(StreamData.member_of(@writable_names), fn name ->
      StreamData.map(accepted_value(name), fn value -> {name, value} end)
    end)
  end

  describe "Xqlite.set_pragma/3 checks the value" do
    setup do
      {:ok, conn} = Xqlite.open_in_memory()
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "a word no boolean pragma takes is refused, and the setting stands", %{conn: conn} do
      assert {:ok, 1} = Xqlite.get_pragma(conn, "foreign_keys")

      assert {:error, {:invalid_pragma_value, %{pragma: :foreign_keys, value: :maybe}}} =
               Xqlite.set_pragma(conn, "foreign_keys", :maybe)

      assert {:ok, 1} = Xqlite.get_pragma(conn, "foreign_keys")
    end

    test "a word no integer pragma takes is refused, and the setting stands", %{conn: conn} do
      {:ok, _} = Xqlite.set_pragma(conn, "user_version", 99)

      assert {:error, {:invalid_pragma_value, %{pragma: :user_version, value: :garbage}}} =
               Xqlite.set_pragma(conn, "user_version", :garbage)

      assert {:ok, 99} = Xqlite.get_pragma(conn, "user_version")
    end

    test "a boolean on an integer pragma is refused by both setters", %{conn: conn} do
      {:ok, _} = Xqlite.set_pragma(conn, "user_version", 7)

      assert {:error, {:invalid_pragma_value, %{pragma: :user_version, value: true}}} =
               P.put(conn, :user_version, true)

      assert {:ok, 7} = Xqlite.get_pragma(conn, "user_version")
    end

    # The hard limit belongs to the operating-system process and SQLite applies
    # it only when it lowers the limit in force, so the only value that is safe
    # to write here is one that lowers nothing. `:unlimited`, the 0 SQLite
    # stores for no limit, does not release it: it answers the limit in force.
    test "hard_heap_limit takes a 64-bit value, and :unlimited does not release it",
         %{conn: conn} do
      assert {:ok, limit} = P.put(conn, :hard_heap_limit, 9_223_372_036_854_775_807)
      assert is_integer(limit)
      assert {:ok, ^limit} = P.put(conn, :hard_heap_limit, :unlimited)
      assert {:ok, ^limit} = P.get(conn, :hard_heap_limit)
    end

    test "a pragma the spec marks read-only is refused", %{conn: conn} do
      assert {:error, {:read_only_pragma, :page_count}} = P.put(conn, :page_count, 5)
      assert {:error, {:read_only_pragma, :integrity_check}} = P.put(conn, :integrity_check, 5)
    end

    test "every spelling of a word pragma reaches SQLite", %{conn: conn} do
      for spelling <- ["WAL", "wal", :wal] do
        assert {:ok, mode} = Xqlite.set_pragma(conn, "journal_mode", spelling)
        assert mode in ["wal", "memory"]
      end
    end

    test "an upper-case pragma name keeps working", %{conn: conn} do
      assert {:ok, _} = Xqlite.set_pragma(conn, "FOREIGN_KEYS", 1)
      assert {:ok, 1} = Xqlite.get_pragma(conn, "foreign_keys")
    end

    test "a name the spec does not model keeps the raw path", %{conn: conn} do
      assert {:ok, _} = Xqlite.set_pragma(conn, "case_sensitive_like", 1)

      assert {:ok, %Xqlite.Result{rows: [[0]]}} =
               Xqlite.query(conn, "SELECT 'A' LIKE 'a'", [])
    end

    property "a value outside the spec is refused by both setters, and nothing moves", %{
      conn: conn
    } do
      check all({name, value} <- hostile_pair(), max_runs: 2000) do
        before = Xqlite.get_pragma(conn, name)

        assert {:error, {:invalid_pragma_value, %{pragma: ^name, value: ^value}}} =
                 Xqlite.set_pragma(conn, name, value)

        assert {:error, {:invalid_pragma_value, %{pragma: ^name, value: ^value}}} =
                 P.put(conn, name, value)

        assert Xqlite.get_pragma(conn, name) == before
      end
    end

    property "a spelling the spec lists is accepted the same way by both setters" do
      check all({name, value} <- accepted_pair(), max_runs: 2000) do
        {:ok, raw_db} = NIF.open_in_memory(":memory:")
        {:ok, typed_db} = NIF.open_in_memory(":memory:")

        assert Xqlite.set_pragma(raw_db, name, value) == P.put(typed_db, name, value)
        assert Xqlite.get_pragma(raw_db, name) == Xqlite.get_pragma(typed_db, name)

        NIF.close(raw_db)
        NIF.close(typed_db)
      end
    end
  end

  describe "the open path checks its values through the same rule" do
    test "every documented option value opens" do
      for opts <- [
            [journal_mode: :wal],
            [journal_mode: :delete],
            [journal_mode: :truncate],
            [journal_mode: :memory],
            [journal_mode: :off],
            [busy_timeout: 0],
            [busy_timeout: 5_000],
            [busy_timeout: :infinity],
            [foreign_keys: true],
            [foreign_keys: false],
            [synchronous: :off],
            [synchronous: :normal],
            [synchronous: :full],
            [synchronous: :extra],
            [cache_size: {:kib, 64_000}],
            [cache_size: {:pages, 2_000}],
            [temp_store: :default],
            [temp_store: :file],
            [temp_store: :memory],
            [wal_autocheckpoint: :off],
            [wal_autocheckpoint: 1_000],
            [mmap_size: 0],
            [auto_vacuum: :none],
            [auto_vacuum: :full],
            [auto_vacuum: :incremental],
            []
          ] do
        assert {:ok, conn} = Xqlite.open_in_memory(opts)
        NIF.close(conn)
      end
    end

    test "an option past what SQLite stores is refused at open" do
      assert {:error, {:invalid_pragma_value, %{pragma: :busy_timeout}}} =
               Xqlite.open_in_memory(busy_timeout: 3_000_000_000)

      assert {:error, {:invalid_pragma_value, %{pragma: :cache_size}}} =
               Xqlite.open_in_memory(cache_size: {:kib, 10_000_000_000})

      assert {:error, {:invalid_pragma_value, %{pragma: :wal_autocheckpoint}}} =
               Xqlite.open_in_memory(wal_autocheckpoint: 3_000_000_000)
    end
  end

  # A binary that is not UTF-8 is no text, so every position that becomes part
  # of the statement refuses it before the statement is built. The name has its
  # own answer, the one it gives for any character outside `A-Z`, `a-z`, `0-9`
  # and `_`.
  describe "a text position holding bytes that are no UTF-8" do
    setup do
      assert {:ok, db} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(db) end)
      {:ok, db: db}
    end

    test "the argument of a reading pragma is refused", %{db: db} do
      bad = <<109, 97, 255>>

      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :table_info, value: ^bad, reason: :invalid_utf8}}} =
               P.get(db, :table_info, bad)
    end

    test "a db_name option is refused on both doors", %{db: db} do
      bad = <<109, 97, 255>>

      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :user_version, value: ^bad, reason: :invalid_utf8}}} =
               P.get(db, :user_version, db_name: bad)

      assert {:error,
              {:invalid_pragma_argument,
               %{pragma: :user_version, value: ^bad, reason: :invalid_utf8}}} =
               P.put(db, :user_version, 1, db_name: bad)
    end

    test "an argument holding a NUL keeps its own answer", %{db: db} do
      assert {:error, :null_byte_in_string} = P.get(db, :table_info, "us" <> <<0>> <> "ers")
    end

    test "a pragma name that is not UTF-8 is refused as a name", %{db: db} do
      bad = <<109, 97, 255>>

      assert {:error, {:invalid_pragma_name, ^bad}} = Xqlite.get_pragma(db, bad)
      assert {:error, {:invalid_pragma_name, ^bad}} = Xqlite.set_pragma(db, bad, 1)
      assert {:error, {:invalid_pragma_name, ^bad}} = NIF.get_pragma(db, bad)
      assert {:error, {:invalid_pragma_name, ^bad}} = NIF.set_pragma(db, bad, 1)
    end

    test "the two setters answer their own refusal for a value that is not UTF-8", %{db: db} do
      bad = <<255>>

      assert {:error, :invalid_utf8_in_string} = NIF.set_pragma(db, "user_version", bad)

      assert {:error, {:invalid_pragma_value, %{pragma: :user_version, value: ^bad}}} =
               Xqlite.set_pragma(db, :user_version, bad)
    end
  end

  # `mmap_size` is capped by the bundled build's own `MAX_MMAP_SIZE`: SQLite
  # stores the cap for anything above it and 0 for anything below zero, so the
  # domain ends where the build does.
  describe "the memory-map size domain" do
    setup do
      path = tmp_db_path("mmap_domain")
      assert {:ok, db} = Xqlite.open(path)
      on_exit(fn -> Xqlite.close(db) end)
      {:ok, db: db}
    end

    test "zero and the ceiling are written and read back", %{db: db} do
      ceiling = mmap_ceiling()

      assert {:ok, ^ceiling} = P.put(db, :mmap_size, ceiling)
      assert {:ok, ^ceiling} = P.get(db, :mmap_size)

      assert {:ok, 0} = P.put(db, :mmap_size, 0)
      assert {:ok, 0} = P.get(db, :mmap_size)
    end

    test "a negative size and one past the ceiling are refused", %{db: db} do
      over = mmap_ceiling() + 1

      assert {:error, {:invalid_pragma_value, %{pragma: :mmap_size, value: -1}}} =
               P.put(db, :mmap_size, -1)

      assert {:error, {:invalid_pragma_value, %{pragma: :mmap_size, value: ^over}}} =
               P.put(db, :mmap_size, over)

      assert {:error, {:invalid_pragma_value, %{pragma: :mmap_size, value: -1}}} =
               Xqlite.set_pragma(db, :mmap_size, -1)

      assert {:error, {:invalid_pragma_value, %{pragma: :mmap_size, value: ^over}}} =
               Xqlite.set_pragma(db, :mmap_size, over)
    end

    # The schema carries one number for eight shipped builds, so the build has
    # to be asked whether it is still its own.
    test "the ceiling in the schema is the one this build was compiled with", %{db: db} do
      assert {:ok, options} = P.get(db, :compile_options)
      assert max_mmap_size(options) == mmap_ceiling()
    end
  end

  defp mmap_ceiling do
    %{mmap_size: %{valid_values: %Range{last: last}}} = P.schema()
    last
  end

  defp max_mmap_size(options) do
    Enum.find_value(options, fn option -> max_mmap_value(option) end)
  end

  defp max_mmap_value("MAX_MMAP_SIZE=0x" <> hex), do: String.to_integer(hex, 16)
  defp max_mmap_value("MAX_MMAP_SIZE=" <> decimal), do: String.to_integer(decimal)
  defp max_mmap_value(_other), do: nil
end
