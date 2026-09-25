defmodule Xqlite.SchemaIntrospectionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.Pragma, only: [quote_name: 1]
  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1, tmp_db_path: 1]

  alias Xqlite.Pragma
  alias Xqlite.Schema
  alias XqliteNIF, as: NIF

  @schema_ddl ~S"""
  CREATE TABLE categories ( cat_id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL, description TEXT );
  CREATE TABLE users ( user_id INTEGER PRIMARY KEY, category_id INTEGER REFERENCES categories(cat_id) ON DELETE SET NULL ON UPDATE CASCADE, full_name TEXT NOT NULL, email TEXT UNIQUE, balance REAL DEFAULT 0.0, config BLOB );
  CREATE INDEX idx_users_email_desc ON users(email DESC);
  CREATE INDEX idx_users_name_lower ON users(LOWER(full_name));
  CREATE TABLE items ( sku TEXT PRIMARY KEY, description TEXT, value REAL CHECK(value > 0) ) WITHOUT ROWID;
  CREATE TABLE user_items ( user_id INTEGER NOT NULL REFERENCES users(user_id) ON DELETE CASCADE, item_sku TEXT NOT NULL REFERENCES items(sku), quantity INTEGER DEFAULT 1, PRIMARY KEY (user_id, item_sku) );
  CREATE VIEW person_view AS SELECT user_id, full_name FROM users;
  CREATE TRIGGER item_value_trigger AFTER UPDATE ON items BEGIN UPDATE items SET description = 'Updated' WHERE item_id = NEW.item_id; END;
  INSERT INTO categories (cat_id, name) VALUES (10, 'Electronics'), (20, 'Books');
  INSERT INTO users (user_id, category_id, full_name, email, balance) VALUES (1, 10, 'Alice Alpha', 'alice@example.com', 100.50), (2, 20, 'Bob Beta', 'bob@example.com', 0.0);
  INSERT INTO items (sku, description, value) VALUES ('ITEM001', 'Laptop', 1200.00), ('ITEM002', 'Guide Book', 25.50);
  INSERT INTO user_items (user_id, item_sku, quantity) VALUES (1, 'ITEM002', 2);
  CREATE TEMP TABLE tt(x); CREATE INDEX temp.tix ON tt(x);
  ATTACH ':memory:' AS aux; CREATE TABLE aux.at(y); CREATE INDEX aux.aix ON at(y);
  """

  # --- Helper Functions ---
  defp sort_by_name(list), do: Enum.sort_by(list, & &1.name)
  defp sort_by_id_seq(list), do: Enum.sort_by(list, &{&1.id, &1.column_sequence})
  # Removed unused sort_by_seq

  # --- Shared test code ---
  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)

        assert {:ok, conn} = apply(mod, fun, args),
               "Failed opening for :#{context[:describetag]}"

        assert :ok = NIF.execute_batch(conn, @schema_ddl)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # --- Shared test cases ---

      test "schema_list_objects lists user tables and views", %{conn: conn} do
        # Expectation unchanged, was correct
        expected_objects =
          [
            %Schema.SchemaObjectInfo{
              schema: "main",
              name: "categories",
              object_type: :table,
              column_count: 3,
              is_without_rowid: false,
              strict: false
            },
            %Schema.SchemaObjectInfo{
              schema: "main",
              name: "items",
              object_type: :table,
              column_count: 3,
              is_without_rowid: true,
              strict: false
            },
            %Schema.SchemaObjectInfo{
              schema: "main",
              name: "person_view",
              object_type: :view,
              column_count: 2,
              is_without_rowid: false,
              strict: false
            },
            %Schema.SchemaObjectInfo{
              schema: "main",
              name: "user_items",
              object_type: :table,
              column_count: 3,
              is_without_rowid: false,
              strict: false
            },
            %Schema.SchemaObjectInfo{
              schema: "main",
              name: "users",
              object_type: :table,
              column_count: 6,
              is_without_rowid: false,
              strict: false
            }
          ]
          |> sort_by_name()

        assert {:ok, actual_objects_unsorted} = NIF.schema_list_objects(conn, "main")

        actual_objects_sorted =
          Enum.filter(actual_objects_unsorted, fn obj -> obj.name not in ["sqlite_schema"] end)
          |> sort_by_name()

        assert actual_objects_sorted == expected_objects
      end

      test "schema_list_objects names a virtual table and its shadow tables", %{conn: conn} do
        assert :ok =
                 NIF.execute_batch(
                   conn,
                   "CREATE VIRTUAL TABLE notes_fts USING fts5(title, body);"
                 )

        assert {:ok, objects} = NIF.schema_list_objects(conn, "main")
        types = Map.new(objects, fn object -> {object.name, object.object_type} end)

        assert types["notes_fts"] == :virtual
        assert types["notes_fts_data"] == :shadow
      end

      test "schema_columns returns info for 'users' table", %{conn: conn} do
        # Expectation unchanged, was correct
        expected_columns = [
          %Schema.ColumnInfo{
            column_id: 0,
            name: "user_id",
            type_affinity: :integer,
            declared_type: "INTEGER",
            nullable: true,
            default_value: :none,
            primary_key_index: 1,
            hidden_kind: :normal
          },
          %Schema.ColumnInfo{
            column_id: 1,
            name: "category_id",
            type_affinity: :integer,
            declared_type: "INTEGER",
            nullable: true,
            default_value: :none,
            primary_key_index: 0,
            hidden_kind: :normal
          },
          %Schema.ColumnInfo{
            column_id: 2,
            name: "full_name",
            type_affinity: :text,
            declared_type: "TEXT",
            nullable: false,
            default_value: :none,
            primary_key_index: 0,
            hidden_kind: :normal
          },
          %Schema.ColumnInfo{
            column_id: 3,
            name: "email",
            type_affinity: :text,
            declared_type: "TEXT",
            nullable: true,
            default_value: :none,
            primary_key_index: 0,
            hidden_kind: :normal
          },
          %Schema.ColumnInfo{
            column_id: 4,
            name: "balance",
            type_affinity: :float,
            declared_type: "REAL",
            nullable: true,
            default_value: {:literal, 0.0},
            primary_key_index: 0,
            hidden_kind: :normal
          },
          %Schema.ColumnInfo{
            column_id: 5,
            name: "config",
            type_affinity: :binary,
            declared_type: "BLOB",
            nullable: true,
            default_value: :none,
            primary_key_index: 0,
            hidden_kind: :normal
          }
        ]

        assert {:ok, expected_columns} == NIF.schema_columns(conn, "users")
      end

      test "schema_columns returns info for WITHOUT ROWID table ('items')", %{conn: conn} do
        expected_columns = [
          %Schema.ColumnInfo{
            column_id: 0,
            name: "sku",
            type_affinity: :text,
            declared_type: "TEXT",
            nullable: false,
            default_value: :none,
            primary_key_index: 1,
            hidden_kind: :normal
          },
          %Schema.ColumnInfo{
            column_id: 1,
            name: "description",
            type_affinity: :text,
            declared_type: "TEXT",
            nullable: true,
            default_value: :none,
            primary_key_index: 0,
            hidden_kind: :normal
          },
          # nullable: true for value column (CHECK > 0 doesn't imply NOT NULL)
          %Schema.ColumnInfo{
            column_id: 2,
            name: "value",
            type_affinity: :float,
            declared_type: "REAL",
            nullable: true,
            default_value: :none,
            primary_key_index: 0,
            hidden_kind: :normal
          }
        ]

        assert {:ok, expected_columns} == NIF.schema_columns(conn, "items")
      end

      test "schema_foreign_keys returns info for join table ('user_items')", %{conn: conn} do
        expected_fks = [
          # ID 0 actually references items
          %Schema.ForeignKeyInfo{
            id: 0,
            column_sequence: 0,
            target_table: "items",
            from_column: "item_sku",
            to_column: "sku",
            on_update: :no_action,
            on_delete: :no_action,
            match_clause: :none
          },
          # ID 1 actually references users
          %Schema.ForeignKeyInfo{
            id: 1,
            column_sequence: 0,
            target_table: "users",
            from_column: "user_id",
            to_column: "user_id",
            on_update: :no_action,
            on_delete: :cascade,
            match_clause: :none
          }
        ]

        # Already sorted by {id, seq} because we define it that way

        assert {:ok, actual_fks} = NIF.schema_foreign_keys(conn, "user_items")
        # Sort actual results and compare to the pre-sorted expected list
        assert sort_by_id_seq(actual_fks) == expected_fks
      end

      test "schema_indexes returns info including implicit and explicit", %{conn: conn} do
        # Check 'users' table indexes
        expected_users_indexes =
          [
            # UNIQUE(email)
            %Schema.IndexInfo{
              name: "sqlite_autoindex_users_1",
              unique: true,
              origin: :unique_constraint,
              partial: false
            },
            %Schema.IndexInfo{
              name: "idx_users_email_desc",
              unique: false,
              origin: :create_index,
              partial: false
            },
            %Schema.IndexInfo{
              name: "idx_users_name_lower",
              unique: false,
              origin: :create_index,
              partial: false
            }
          ]
          |> sort_by_name()

        assert {:ok, actual_users_idx} = NIF.schema_indexes(conn, "users")
        assert sort_by_name(actual_users_idx) == expected_users_indexes

        # Check 'items' table indexes (WITHOUT ROWID PK)
        expected_items_indexes = [
          %Schema.IndexInfo{
            name: "sqlite_autoindex_items_1",
            unique: true,
            origin: :primary_key_constraint,
            partial: false
          }
        ]

        assert {:ok, ^expected_items_indexes} = NIF.schema_indexes(conn, "items")

        # Check 'user_items' table indexes (Compound PK)
        expected_user_items_indexes = [
          %Schema.IndexInfo{
            name: "sqlite_autoindex_user_items_1",
            unique: true,
            origin: :primary_key_constraint,
            partial: false
          }
        ]

        assert {:ok, ^expected_user_items_indexes} = NIF.schema_indexes(conn, "user_items")
      end

      test "schema_index_columns returns info for various index types", %{conn: conn} do
        # Explicit DESC index on users(email)
        expected_desc = [
          %Schema.IndexColumnInfo{
            index_column_sequence: 0,
            table_column_id: 3,
            name: "email",
            sort_order: :desc,
            collation: "BINARY",
            is_key_column: true
          },
          %Schema.IndexColumnInfo{
            index_column_sequence: 1,
            table_column_id: -1,
            name: nil,
            sort_order: :asc,
            collation: "BINARY",
            is_key_column: false
          }
        ]

        assert {:ok, ^expected_desc} = NIF.schema_index_columns(conn, "idx_users_email_desc")

        # Compound PK index on user_items(user_id, item_sku)
        expected_compound = [
          %Schema.IndexColumnInfo{
            index_column_sequence: 0,
            table_column_id: 0,
            name: "user_id",
            sort_order: :asc,
            collation: "BINARY",
            is_key_column: true
          },
          %Schema.IndexColumnInfo{
            index_column_sequence: 1,
            table_column_id: 1,
            name: "item_sku",
            sort_order: :asc,
            collation: "BINARY",
            is_key_column: true
          },
          %Schema.IndexColumnInfo{
            index_column_sequence: 2,
            table_column_id: -1,
            name: nil,
            sort_order: :asc,
            collation: "BINARY",
            is_key_column: false
          }
        ]

        assert {:ok, ^expected_compound} =
                 NIF.schema_index_columns(conn, "sqlite_autoindex_user_items_1")

        # Index on expression users(LOWER(full_name))
        expected_expr = [
          # table_column_id for expression is -2
          %Schema.IndexColumnInfo{
            index_column_sequence: 0,
            table_column_id: -2,
            name: nil,
            sort_order: :asc,
            collation: "BINARY",
            is_key_column: true
          },
          %Schema.IndexColumnInfo{
            index_column_sequence: 1,
            table_column_id: -1,
            name: nil,
            sort_order: :asc,
            collation: "BINARY",
            is_key_column: false
          }
        ]

        assert {:ok, ^expected_expr} = NIF.schema_index_columns(conn, "idx_users_name_lower")
      end

      test "get_create_sql returns original SQL for various objects", %{conn: conn} do
        # Table
        assert {:ok, sql_users} = NIF.get_create_sql(conn, "users")
        assert is_binary(sql_users) and String.starts_with?(sql_users, "CREATE TABLE users")
        # Index
        assert {:ok, sql_idx} = NIF.get_create_sql(conn, "idx_users_email_desc")

        assert is_binary(sql_idx) and
                 String.contains?(sql_idx, "CREATE INDEX idx_users_email_desc")

        # View
        assert {:ok, sql_view} = NIF.get_create_sql(conn, "person_view")
        assert is_binary(sql_view) and String.starts_with?(sql_view, "CREATE VIEW")
        # Trigger
        assert {:ok, sql_trigger} = NIF.get_create_sql(conn, "item_value_trigger")
        assert is_binary(sql_trigger) and String.starts_with?(sql_trigger, "CREATE TRIGGER")
      end

      test "a missing name answers its tag, a table without keys no rows", %{conn: conn} do
        assert {:ok, []} = NIF.schema_foreign_keys(conn, "categories")
        assert {:error, {:no_such_table, "nope"}} = NIF.schema_foreign_keys(conn, "nope")
        assert {:error, {:no_such_table, "at"}} = Pragma.index_list(conn, "at", db_name: :main)
        assert {:ok, nil} = NIF.get_create_sql(conn, "sqlite_autoindex_users_1")
        assert {:error, {:no_such_object, "tt"}} = NIF.get_create_sql(conn, "tt")
      end

      property "a name answers rows when found and its tag when not", %{conn: conn} do
        indexes = ~w(idx_users_email_desc sqlite_autoindex_users_1 items tix aix)
        names = object_name(~w(users person_view sqlite_schema tt at) ++ indexes)

        check all(name <- names, max_runs: 2000) do
          table? = match?({:ok, _}, NIF.query(conn, "SELECT * FROM #{quote_name(name)}", []))
          index? = String.downcase(name, :ascii) in indexes
          found = %{no_such_table: table?, no_such_index: index?}

          for {tag, answer} <- object_answers(conn, name) do
            assert {name, match?({:ok, _}, answer)} == {name, found[tag]}
            assert found[tag] or answer == {:error, {tag, name}}
          end
        end
      end

      property "a schema name SQLite does not know is rejected by every function", %{
        conn: conn
      } do
        path = tmp_db_path("unknown_schema")

        check all(name <- object_name(~w(main temp aux)), max_runs: 2000) do
          rejected = {:error, {:no_such_schema, name}}
          sql = "PRAGMA #{quote_name(name)}.schema_version"
          attached? = match?({:ok, _}, NIF.query(conn, sql, []))
          rejections = conn |> schema_answers(name) |> Enum.map(&(&1 == rejected))
          assert rejections == List.duplicate(not attached?, 8)
          unattached = if attached?, do: [], else: unattached_answers(conn, name, path)
          assert Enum.uniq(unattached) in [[], [rejected]]
        end

        refute File.exists?(path)
      end

      test "an empty schema name is rejected by every function that takes one", %{conn: conn} do
        path = tmp_db_path("empty_schema")
        answers = schema_answers(conn, "") ++ unattached_answers(conn, "", path)
        assert Enum.uniq(answers) == [{:error, {:invalid_schema_name, ""}}]
        refute File.exists?(path)
      end

      test "the listing takes :all or any case of a name; nil is no name", %{conn: conn} do
        assert {:ok, all} = NIF.schema_list_objects(conn, :all)
        assert {:ok, main} = NIF.schema_list_objects(conn, "MAIN")
        assert main |> Enum.map(& &1.schema) |> Enum.uniq() == ["main"]
        assert length(all) > length(main) and Enum.any?(all, &(&1.name == "at"))
        assert_raise ArgumentError, fn -> NIF.txn_state(conn, nil) end
        assert_raise ArgumentError, fn -> NIF.wal_checkpoint(conn, :passive, nil) end

        assert_raise FunctionClauseError, fn ->
          apply(Xqlite, :schema_list_objects, [conn, nil])
        end
      end

      test "a schema name is judged with no SQL, temp before its first use included" do
        assert {:ok, c} = NIF.open_in_memory(":memory:")
        assert {:ok, :none} = NIF.txn_state(c, "temp")
        assert :ok = Xqlite.set_authorizer(c, [:pragma])
        assert {:ok, :none} = NIF.txn_state(c, "MAIN")
        assert {:error, {:no_such_schema, :no}} = Pragma.get(c, :cache_size, db_name: :no)
        assert {:error, {:no_such_schema, "no"}} = Pragma.put(c, :cache_size, 1, db_name: "no")
      end

      test "schema_columns handles various declared types and resolves correct affinity", %{
        conn: conn
      } do
        # This DDL tests SQLite's type affinity rules for columns with:
        # 1. No declared type ('c_no_type'): Should default to BLOB affinity.
        #    PRAGMA table_xinfo reports its 'type' as an empty string.
        # 2. A common keyword not having specific affinity rules ('c_boolean_keyword BOOLEAN'):
        #    Should default to NUMERIC affinity.
        # 3. Another common keyword without specific affinity ('c_datetime_keyword DATETIME'):
        #    Should default to NUMERIC affinity.
        # 4. A completely custom/unrecognized type name ('c_funky_type "VERY STRANGE NAME"'):
        #    Should also default to NUMERIC affinity.
        ddl = """
        CREATE TABLE type_affinity_examples (
          c_no_type,
          c_boolean_keyword BOOLEAN,
          c_datetime_keyword DATETIME,
          c_funky_type "VERY STRANGE NAME"
        );
        """

        # DDL execution can return non-zero for "rows affected"
        assert {:ok, _} = NIF.execute(conn, ddl, [])

        assert {:ok, columns_info} = NIF.schema_columns(conn, "type_affinity_examples")

        no_type_col = Enum.find(columns_info, &(&1.name == "c_no_type"))
        boolean_col = Enum.find(columns_info, &(&1.name == "c_boolean_keyword"))
        datetime_col = Enum.find(columns_info, &(&1.name == "c_datetime_keyword"))
        funky_col = Enum.find(columns_info, &(&1.name == "c_funky_type"))

        refute is_nil(no_type_col)
        assert no_type_col.declared_type == ""
        assert no_type_col.type_affinity == :binary

        refute is_nil(boolean_col)
        assert boolean_col.declared_type == "BOOLEAN"
        assert boolean_col.type_affinity == :numeric

        refute is_nil(datetime_col)
        assert datetime_col.declared_type == "DATETIME"
        assert datetime_col.type_affinity == :numeric

        refute is_nil(funky_col)
        assert funky_col.declared_type == "VERY STRANGE NAME"
        assert funky_col.type_affinity == :numeric
      end
    end

    # end describe "using #{prefix}"
  end

  # end `for` loop

  # --- DB type-specific or other tests (outside the `for` loop) ---

  describe "get_create_sql/2 isolated" do
    setup do
      {:ok, conn} = NIF.open_in_memory(":memory:")

      :ok =
        NIF.execute_batch(conn, "CREATE TABLE gcs_test (id INTEGER PRIMARY KEY, name TEXT);")

      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "returns the CREATE statement for an existing table", %{conn: conn} do
      assert {:ok, sql} = NIF.get_create_sql(conn, "gcs_test")
      assert is_binary(sql)
      assert String.starts_with?(sql, "CREATE TABLE gcs_test")
    end
  end

  defp object_name(names) do
    cased = Enum.flat_map(names, &[&1, String.upcase(&1), String.capitalize(&1)])
    other = StreamData.string(:printable, min_length: 1, max_length: 8)
    StreamData.one_of([StreamData.member_of(cased), other])
  end

  defp object_answers(conn, name) do
    [
      no_such_table: NIF.schema_columns(conn, name),
      no_such_table: NIF.schema_foreign_keys(conn, name),
      no_such_table: NIF.schema_indexes(conn, name),
      no_such_table: Pragma.table_info(conn, name),
      no_such_table: Pragma.table_xinfo(conn, name),
      no_such_table: Pragma.index_list(conn, name),
      no_such_table: Pragma.get(conn, :foreign_key_list, name),
      no_such_index: NIF.schema_index_columns(conn, name),
      no_such_index: Pragma.index_info(conn, name),
      no_such_index: Pragma.index_xinfo(conn, name)
    ]
  end

  defp schema_answers(conn, name) do
    [
      Xqlite.txn_state(conn, name),
      Xqlite.wal_checkpoint(conn, :passive, name),
      Xqlite.schema_list_objects(conn, name),
      NIF.txn_state(conn, name),
      NIF.wal_checkpoint(conn, :passive, name),
      NIF.serialize(conn, name),
      NIF.schema_list_objects(conn, name),
      Pragma.get(conn, :user_version, db_name: name)
    ]
  end

  defp unattached_answers(conn, name, path) do
    [
      NIF.deserialize(conn, name, <<>>, false),
      NIF.backup(conn, name, path),
      NIF.restore(conn, name, path),
      NIF.backup_with_progress(conn, name, path, self(), 1, []),
      NIF.blob_open(conn, name, "users", "config", 1, true)
    ]
  end
end
