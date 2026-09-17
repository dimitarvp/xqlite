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
    {:analysis_limit, [0, 100], nil},
    {:user_version, [0, 5, 10, -100], nil},
    # Can only be set on a fresh DB
    {:page_size, [2048, 4096, 8192], nil},
    {:busy_timeout, [0, 1000, 5000], nil},
    # -1 means no limit
    {:journal_size_limit, [0, -1, 102_400], nil},
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
    {:secure_delete, [{0, false}, {1, true}, {2, :fast}]},

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
     ]},
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
    # Test with a positive, negative (if applicable), and zero value
    {:cache_size, [0, 8, -16], &verify_is_integer/4},
    {:soft_heap_limit, [0, 1024 * 1024], &verify_is_integer/4},
    {:hard_heap_limit, [0, 1024 * 1024], &verify_is_integer/4},
    {:threads, [0, 1, 8], &verify_is_integer/4},
    {:wal_autocheckpoint, [0, 1000], &verify_is_integer/4},
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

      for {name, values_to_test, verify_fun} <- @write_test_cases,
          verify_fun = Macro.escape(verify_fun) do
        verify_fun = verify_fun || (&default_verify_values/4)

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
      assert {:ok, cache_size} = P.get(db, :cache_size, [], db_name: "main")
      assert is_integer(cache_size)
    end

    test "put with db_name: main writes to main schema", %{db: db} do
      assert {:ok, _} = P.put(db, :cache_size, 5000, db_name: "main")
      assert {:ok, 5000} = P.get(db, :cache_size, [], db_name: "main")
    end

    test "get/put on an attached database", %{db: db} do
      NIF.execute_batch(db, "ATTACH ':memory:' AS aux;")

      assert {:ok, _} = P.put(db, :cache_size, 3000, db_name: "aux")
      assert {:ok, 3000} = P.get(db, :cache_size, [], db_name: "aux")

      # main schema should be unaffected
      {:ok, main_cache} = P.get(db, :cache_size)
      refute main_cache == 3000
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
    # with an empty list, while a broken quote is a syntax error instead.
    test "get quotes an argument holding a double quote", %{db: db} do
      assert {:ok, []} = P.get(db, :table_info, "a\"b", db_name: "main")
    end

    property "get accepts an argument whatever characters it holds", %{db: db} do
      check all(value <- pragma_string_value(), max_runs: 2000) do
        assert {:ok, []} = P.get(db, :table_info, value, db_name: "main")
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

    test "put returns {:error, {:invalid_pragma_name, name}} for unknown string pragma", %{
      db: db
    } do
      assert {:error, {:invalid_pragma_name, "never_atomized_pragma_xyz"}} =
               P.put(db, "never_atomized_pragma_xyz", 1)
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

    property "no name outside the schema reaches SQLite", %{db: db} do
      assert :ok = Xqlite.set_authorizer(db, [:pragma])

      check all(name <- unknown_pragma_name(), max_runs: 2000) do
        assert {:error, {:unknown_pragma, ^name}} = P.put(db, name, 1)
        assert {:error, {:unknown_pragma, ^name}} = P.get(db, name)
        assert {:error, {:unknown_pragma, ^name}} = P.get(db, name, "arg")
      end
    end
  end

  defp unknown_pragma_name do
    StreamData.string(:printable, max_length: 10)
    |> StreamData.map(&String.to_atom("xqlite_no_such_pragma_" <> &1))
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

  defp accepted_value(name) do
    case Map.fetch!(@accepted_spellings, name) do
      [] -> name |> integer_range() |> StreamData.integer()
      forms -> StreamData.member_of(forms)
    end
  end

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
      check all(
              name <- StreamData.member_of(@writable_names),
              value <- StreamData.member_of(@hostile_values),
              max_runs: 2000
            ) do
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
            [cache_size: -64_000],
            [cache_size: 2_000],
            [temp_store: :default],
            [temp_store: :file],
            [temp_store: :memory],
            [wal_autocheckpoint: 0],
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
               Xqlite.open_in_memory(cache_size: -10_000_000_000)

      assert {:error, {:invalid_pragma_value, %{pragma: :wal_autocheckpoint}}} =
               Xqlite.open_in_memory(wal_autocheckpoint: 3_000_000_000)
    end
  end
end
