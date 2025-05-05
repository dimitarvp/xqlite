defmodule Xqlite.SchemaIntrospectionTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]
  alias XqliteNIF, as: NIF
  alias Xqlite.Schema

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

        assert {:ok, true} = NIF.execute_batch(conn, @schema_ddl)
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
              is_writable: false,
              strict: false
            },
            %Schema.SchemaObjectInfo{
              schema: "main",
              name: "items",
              object_type: :table,
              column_count: 3,
              is_writable: true,
              strict: false
            },
            %Schema.SchemaObjectInfo{
              schema: "main",
              name: "person_view",
              object_type: :view,
              column_count: 2,
              is_writable: false,
              strict: false
            },
            %Schema.SchemaObjectInfo{
              schema: "main",
              name: "user_items",
              object_type: :table,
              column_count: 3,
              is_writable: false,
              strict: false
            },
            %Schema.SchemaObjectInfo{
              schema: "main",
              name: "users",
              object_type: :table,
              column_count: 6,
              is_writable: false,
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

      test "schema_columns returns info for 'users' table", %{conn: conn} do
        # Expectation unchanged, was correct
        expected_columns = [
          %Schema.ColumnInfo{
            column_id: 0,
            name: "user_id",
            type_affinity: :integer,
            declared_type: "INTEGER",
            nullable: true,
            default_value: nil,
            primary_key_index: 1
          },
          %Schema.ColumnInfo{
            column_id: 1,
            name: "category_id",
            type_affinity: :integer,
            declared_type: "INTEGER",
            nullable: true,
            default_value: nil,
            primary_key_index: 0
          },
          %Schema.ColumnInfo{
            column_id: 2,
            name: "full_name",
            type_affinity: :text,
            declared_type: "TEXT",
            nullable: false,
            default_value: nil,
            primary_key_index: 0
          },
          %Schema.ColumnInfo{
            column_id: 3,
            name: "email",
            type_affinity: :text,
            declared_type: "TEXT",
            nullable: true,
            default_value: nil,
            primary_key_index: 0
          },
          %Schema.ColumnInfo{
            column_id: 4,
            name: "balance",
            type_affinity: :float,
            declared_type: "REAL",
            nullable: true,
            default_value: "0.0",
            primary_key_index: 0
          },
          %Schema.ColumnInfo{
            column_id: 5,
            name: "config",
            type_affinity: :binary,
            declared_type: "BLOB",
            nullable: true,
            default_value: nil,
            primary_key_index: 0
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
            default_value: nil,
            primary_key_index: 1
          },
          %Schema.ColumnInfo{
            column_id: 1,
            name: "description",
            type_affinity: :text,
            declared_type: "TEXT",
            nullable: true,
            default_value: nil,
            primary_key_index: 0
          },
          # Corrected nullable: true for value column (CHECK > 0 doesn't imply NOT NULL)
          %Schema.ColumnInfo{
            column_id: 2,
            name: "value",
            type_affinity: :float,
            declared_type: "REAL",
            nullable: true,
            default_value: nil,
            primary_key_index: 0
          }
        ]

        assert {:ok, expected_columns} == NIF.schema_columns(conn, "items")
      end

      test "schema_foreign_keys returns info for join table ('user_items')", %{conn: conn} do
        # Corrected expected order/IDs based on actual test results
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
          # Corrected table_column_id for expression is -2
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

      # --- Tests for "Not Found" cases ---
      test "schema_columns returns empty list for non-existent table", %{conn: conn} do
        assert {:ok, []} == NIF.schema_columns(conn, "non_existent_table")
      end

      test "schema_foreign_keys returns empty list for non-existent table", %{conn: conn} do
        assert {:ok, []} == NIF.schema_foreign_keys(conn, "non_existent_table")
      end

      test "schema_indexes returns empty list for non-existent table", %{conn: conn} do
        assert {:ok, []} == NIF.schema_indexes(conn, "non_existent_table")
      end

      test "schema_index_columns returns empty list for non-existent index", %{conn: conn} do
        assert {:ok, []} == NIF.schema_index_columns(conn, "non_existent_index")
      end

      test "get_create_sql returns nil for non-existent object", %{conn: conn} do
        assert {:ok, nil} == NIF.get_create_sql(conn, "non_existent_object")
      end
    end

    # end describe "using #{prefix}"
  end

  # end `for` loop

  # --- DB type-specific or other tests (outside the `for` loop) ---
  # None currently identified for schema introspection
end
