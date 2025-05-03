defmodule Xqlite.SchemaIntrospectionTest do
  use ExUnit.Case, async: true

  alias Xqlite.Schema
  alias XqliteNIF, as: NIF

  @schema_ddl ~S"""
  -- Categories Table (Simple PK)
  CREATE TABLE categories (
    cat_id INTEGER PRIMARY KEY,
    name TEXT UNIQUE NOT NULL,
    description TEXT
  );

  -- Users Table (FK, UNIQUE, different types, explicit index, DESC index)
  CREATE TABLE users (
    user_id INTEGER PRIMARY KEY, -- Aliases rowid
    category_id INTEGER REFERENCES categories(cat_id) ON DELETE SET NULL ON UPDATE CASCADE,
    full_name TEXT NOT NULL,
    email TEXT UNIQUE,
    balance REAL DEFAULT 0.0,
    config BLOB
  );
  CREATE INDEX idx_users_name ON users(full_name);
  CREATE INDEX idx_users_email_desc ON users(email DESC); -- Index with DESC

  -- Items Table (WITHOUT ROWID, TEXT PK)
  CREATE TABLE items (
    sku TEXT PRIMARY KEY,
    description TEXT,
    price NUMERIC NOT NULL -- Numeric Affinity
  ) WITHOUT ROWID;

  -- User Items Join Table (Compound PK, Multiple FKs)
  CREATE TABLE user_items (
    user_id INTEGER NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    item_sku TEXT NOT NULL REFERENCES items(sku) ON DELETE RESTRICT,
    quantity INTEGER DEFAULT 1,
    PRIMARY KEY (user_id, item_sku)
  );

  -- Simple View
  CREATE VIEW active_users_view AS
    SELECT user_id, full_name, email FROM users WHERE balance > 0;

  -- Trigger (Example object, not directly tested by schema NIFs other than listing/SQL)
  CREATE TRIGGER update_user_balance_trigger
    AFTER INSERT ON user_items
  BEGIN
    UPDATE users SET balance = balance - (SELECT price FROM items WHERE sku = NEW.item_sku) * NEW.quantity
    WHERE user_id = NEW.user_id;
  END;

  -- Insert some data to potentially test view content later if needed (not strictly schema)
  INSERT INTO categories (cat_id, name) VALUES (10, 'Electronics'), (20, 'Books');
  INSERT INTO users (user_id, category_id, full_name, email, balance) VALUES
    (1, 10, 'Alice Alpha', 'alice@example.com', 100.50),
    (2, 20, 'Bob Beta', 'bob@example.com', 0.0); -- Will be inactive view-wise
  INSERT INTO items (sku, description, price) VALUES
    ('ITEM001', 'Laptop', 1200.00),
    ('ITEM002', 'Guide Book', 25.50);
  INSERT INTO user_items (user_id, item_sku, quantity) VALUES (1, 'ITEM002', 2);
  """

  # Each test case gets an in-memory database with the DDL executed after opening.
  setup do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    on_exit(fn -> NIF.close(conn) end)
    {:ok, true} = XqliteNIF.execute_batch(conn, @schema_ddl)
    {:ok, conn: conn}
  end

  defp sort_by_name(list) do
    Enum.sort_by(list, & &1.name)
  end

  defp sort_by_id_seq(list) do
    Enum.sort_by(list, &{&1.id, &1.column_sequence})
  end

  test "schema_databases returns info for the main database", %{conn: conn} do
    expected_result = {:ok, [%Schema.DatabaseInfo{name: "main", file: ""}]}
    assert expected_result == XqliteNIF.schema_databases(conn)
  end

  test "schema_list_objects lists all objects without filter", %{conn: conn} do
    expected_user_objects =
      [
        %Schema.SchemaObjectInfo{
          schema: "main",
          name: "active_users_view",
          object_type: :view,
          column_count: 3,
          is_writable: false,
          strict: false
        },
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

    {:ok, actual_objects_unsorted} = XqliteNIF.schema_list_objects(conn, nil)

    actual_user_objects_sorted =
      Enum.filter(actual_objects_unsorted, fn obj ->
        obj.schema == "main" and
          obj.name in ["active_users_view", "categories", "items", "user_items", "users"]
      end)
      |> sort_by_name()

    assert {:ok, expected_user_objects} == {:ok, actual_user_objects_sorted}
  end

  test "schema_list_objects lists objects filtered by schema 'main'", %{conn: conn} do
    expected_objects =
      [
        %Schema.SchemaObjectInfo{
          schema: "main",
          name: "active_users_view",
          object_type: :view,
          column_count: 3,
          is_writable: false,
          strict: false
        },
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
          name: "sqlite_schema",
          object_type: :table,
          column_count: 5,
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

    assert {:ok, expected_objects} ==
             XqliteNIF.schema_list_objects(conn, "main")
             |> then(fn {:ok, list} -> {:ok, sort_by_name(list)} end)
  end

  test "schema_list_objects returns empty list for non-existent schema", %{conn: conn} do
    assert {:ok, []} == XqliteNIF.schema_list_objects(conn, "non_existent_schema")
  end

  test "schema_columns returns column info for 'users' table", %{conn: conn} do
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

    assert {:ok, expected_columns} == XqliteNIF.schema_columns(conn, "users")
  end

  test "schema_columns returns column info for 'items' (WITHOUT ROWID)", %{conn: conn} do
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
      %Schema.ColumnInfo{
        column_id: 2,
        name: "price",
        type_affinity: :numeric,
        declared_type: "NUMERIC",
        nullable: false,
        default_value: nil,
        primary_key_index: 0
      }
    ]

    assert {:ok, expected_columns} == XqliteNIF.schema_columns(conn, "items")
  end

  test "schema_columns returns column info for 'user_items' (Compound PK)", %{conn: conn} do
    expected_columns = [
      %Schema.ColumnInfo{
        column_id: 0,
        name: "user_id",
        type_affinity: :integer,
        declared_type: "INTEGER",
        nullable: false,
        default_value: nil,
        primary_key_index: 1
      },
      %Schema.ColumnInfo{
        column_id: 1,
        name: "item_sku",
        type_affinity: :text,
        declared_type: "TEXT",
        nullable: false,
        default_value: nil,
        primary_key_index: 2
      },
      %Schema.ColumnInfo{
        column_id: 2,
        name: "quantity",
        type_affinity: :integer,
        declared_type: "INTEGER",
        nullable: true,
        default_value: "1",
        primary_key_index: 0
      }
    ]

    assert {:ok, expected_columns} == XqliteNIF.schema_columns(conn, "user_items")
  end

  test "schema_columns returns empty list for non-existent table", %{conn: conn} do
    assert {:ok, []} == XqliteNIF.schema_columns(conn, "non_existent_table")
  end

  test "schema_foreign_keys returns FK info for 'users' table", %{conn: conn} do
    expected_fks = [
      %Schema.ForeignKeyInfo{
        id: 0,
        column_sequence: 0,
        target_table: "categories",
        from_column: "category_id",
        to_column: "cat_id",
        on_update: :cascade,
        on_delete: :set_null,
        match_clause: :none
      }
    ]

    assert {:ok, expected_fks} == XqliteNIF.schema_foreign_keys(conn, "users")
  end

  test "schema_foreign_keys returns multiple FK info for 'user_items' table", %{conn: conn} do
    expected_fks =
      [
        %Schema.ForeignKeyInfo{
          id: 0,
          column_sequence: 0,
          target_table: "items",
          from_column: "item_sku",
          to_column: "sku",
          on_update: :no_action,
          on_delete: :restrict,
          match_clause: :none
        },
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
      # Still sort to be safe, though now matches expected order
      |> sort_by_id_seq()

    assert {:ok, expected_fks} ==
             XqliteNIF.schema_foreign_keys(conn, "user_items")
             |> then(fn {:ok, list} -> {:ok, sort_by_id_seq(list)} end)
  end

  test "schema_foreign_keys returns empty list for table with no FKs", %{conn: conn} do
    assert {:ok, []} == XqliteNIF.schema_foreign_keys(conn, "categories")
    assert {:ok, []} == XqliteNIF.schema_foreign_keys(conn, "items")
  end

  test "schema_foreign_keys returns empty list for non-existent table", %{conn: conn} do
    assert {:ok, []} == XqliteNIF.schema_foreign_keys(conn, "non_existent_table")
  end

  test "schema_indexes returns index info for 'users' table", %{conn: conn} do
    expected_indexes =
      [
        # Implicit index for UNIQUE email constraint (gets name _1)
        %Schema.IndexInfo{
          name: "sqlite_autoindex_users_1",
          unique: true,
          origin: :unique_constraint,
          partial: false
        },
        # Explicit index on full_name
        %Schema.IndexInfo{
          name: "idx_users_name",
          unique: false,
          origin: :create_index,
          partial: false
        },
        # Explicit index on email DESC
        %Schema.IndexInfo{
          name: "idx_users_email_desc",
          unique: false,
          origin: :create_index,
          partial: false
        }
        # NOTE: No separate index listed for simple INTEGER PRIMARY KEY (user_id)
      ]
      |> sort_by_name()

    assert {:ok, expected_indexes} ==
             XqliteNIF.schema_indexes(conn, "users")
             |> then(fn {:ok, list} -> {:ok, sort_by_name(list)} end)
  end

  test "schema_indexes returns index info for 'items' (WITHOUT ROWID)", %{conn: conn} do
    expected_indexes =
      [
        %Schema.IndexInfo{
          name: "sqlite_autoindex_items_1",
          unique: true,
          origin: :primary_key_constraint,
          partial: false
        }
      ]
      |> sort_by_name()

    assert {:ok, expected_indexes} ==
             XqliteNIF.schema_indexes(conn, "items")
             |> then(fn {:ok, list} -> {:ok, sort_by_name(list)} end)
  end

  test "schema_indexes returns index info for 'user_items' (Compound PK)", %{conn: conn} do
    expected_indexes =
      [
        %Schema.IndexInfo{
          name: "sqlite_autoindex_user_items_1",
          unique: true,
          origin: :primary_key_constraint,
          partial: false
        }
      ]
      |> sort_by_name()

    assert {:ok, expected_indexes} ==
             XqliteNIF.schema_indexes(conn, "user_items")
             |> then(fn {:ok, list} -> {:ok, sort_by_name(list)} end)
  end

  test "schema_indexes returns empty list for non-existent table", %{conn: conn} do
    assert {:ok, []} == XqliteNIF.schema_indexes(conn, "non_existent_table")
  end

  test "schema_index_columns returns info for simple index 'idx_users_name'", %{conn: conn} do
    expected_cols = [
      %Schema.IndexColumnInfo{
        index_column_sequence: 0,
        # 'full_name' is column 2 (0-based) in 'users' table
        table_column_id: 2,
        name: "full_name",
        sort_order: :asc,
        collation: "BINARY",
        is_key_column: true
      },
      %Schema.IndexColumnInfo{
        index_column_sequence: 1,
        # Implicitly included rowid/PK has cid -1
        table_column_id: -1,
        name: nil,
        sort_order: :asc,
        collation: "BINARY",
        is_key_column: false
      }
    ]

    assert {:ok, expected_cols} == XqliteNIF.schema_index_columns(conn, "idx_users_name")
  end

  test "schema_index_columns returns info for DESC index 'idx_users_email_desc'", %{
    conn: conn
  } do
    expected_cols = [
      %Schema.IndexColumnInfo{
        index_column_sequence: 0,
        # 'email' is column 3 in 'users' table
        table_column_id: 3,
        name: "email",
        sort_order: :desc,
        collation: "BINARY",
        is_key_column: true
      },
      %Schema.IndexColumnInfo{
        index_column_sequence: 1,
        # Implicitly included rowid/PK has cid -1
        table_column_id: -1,
        name: nil,
        sort_order: :asc,
        collation: "BINARY",
        is_key_column: false
      }
    ]

    assert {:ok, expected_cols} ==
             XqliteNIF.schema_index_columns(conn, "idx_users_email_desc")
  end

  test "schema_index_columns returns info for compound PK index 'sqlite_autoindex_user_items_1'",
       %{conn: conn} do
    expected_cols =
      [
        %Schema.IndexColumnInfo{
          index_column_sequence: 0,
          # 'user_id' is column 0 in 'user_items'
          table_column_id: 0,
          name: "user_id",
          sort_order: :asc,
          collation: "BINARY",
          is_key_column: true
        },
        %Schema.IndexColumnInfo{
          index_column_sequence: 1,
          # 'item_sku' is column 1 in 'user_items'
          table_column_id: 1,
          name: "item_sku",
          sort_order: :asc,
          collation: "BINARY",
          is_key_column: true
        },
        %Schema.IndexColumnInfo{
          index_column_sequence: 2,
          # Implicitly included rowid
          table_column_id: -1,
          name: nil,
          sort_order: :asc,
          collation: "BINARY",
          is_key_column: false
        }
      ]

    assert {:ok, expected_cols} ==
             XqliteNIF.schema_index_columns(conn, "sqlite_autoindex_user_items_1")
  end

  test "schema_index_columns returns empty list for non-existent index", %{conn: conn} do
    assert {:ok, []} == XqliteNIF.schema_index_columns(conn, "non_existent_index")
  end

  test "get_create_sql returns SQL for table 'users'", %{conn: conn} do
    assert {:ok, sql} = XqliteNIF.get_create_sql(conn, "users")
    assert is_binary(sql) and String.starts_with?(sql, "CREATE TABLE users")
  end

  test "get_create_sql returns SQL for view 'active_users_view'", %{conn: conn} do
    assert {:ok, sql} = XqliteNIF.get_create_sql(conn, "active_users_view")
    assert is_binary(sql) and String.starts_with?(sql, "CREATE VIEW active_users_view")
  end

  test "get_create_sql returns SQL for index 'idx_users_name'", %{conn: conn} do
    assert {:ok, sql} = XqliteNIF.get_create_sql(conn, "idx_users_name")
    assert is_binary(sql) and String.starts_with?(sql, "CREATE INDEX idx_users_name")
  end

  test "get_create_sql returns SQL for trigger 'update_user_balance_trigger'", %{
    conn: conn
  } do
    assert {:ok, sql} = XqliteNIF.get_create_sql(conn, "update_user_balance_trigger")

    assert is_binary(sql) and
             String.starts_with?(sql, "CREATE TRIGGER update_user_balance_trigger")
  end

  test "get_create_sql returns nil for non-existent object", %{conn: conn} do
    assert {:ok, nil} == XqliteNIF.get_create_sql(conn, "non_existent_object")
  end
end
