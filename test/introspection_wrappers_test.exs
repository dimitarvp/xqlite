defmodule Xqlite.IntrospectionWrappersTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias Xqlite.Schema
  alias XqliteNIF, as: NIF

  @ddl """
  CREATE TABLE wrap_items (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    parent_id INTEGER REFERENCES wrap_items(id)
  );
  CREATE INDEX wrap_items_name_idx ON wrap_items(name);
  """

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        assert :ok = NIF.execute_batch(conn, @ddl)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "transaction-state readers", %{conn: conn} do
        assert {:ok, false} = Xqlite.transaction_status(conn)
        assert {:ok, true} = Xqlite.autocommit(conn)
        assert {:ok, :none} = Xqlite.txn_state(conn)

        assert :ok = Xqlite.begin(conn, :immediate)
        assert {:ok, true} = Xqlite.transaction_status(conn)
        assert {:ok, false} = Xqlite.autocommit(conn)
        assert {:ok, :write} = Xqlite.txn_state(conn, "main")
        assert :ok = Xqlite.rollback(conn)
      end

      test "DML counters", %{conn: conn} do
        assert {:ok, 1} =
                 NIF.execute(conn, "INSERT INTO wrap_items (id, name) VALUES (7, 'a')", [])

        assert {:ok, 7} = Xqlite.last_insert_rowid(conn)
        assert {:ok, 1} = Xqlite.changes(conn)

        assert {:ok, 1} =
                 NIF.execute(conn, "INSERT INTO wrap_items (id, name) VALUES (8, 'b')", [])

        assert {:ok, total} = Xqlite.total_changes(conn)
        assert total >= 2
      end

      test "connection stats and build info", %{conn: conn} do
        assert {:ok, %{cache_used: cache_used}} = Xqlite.connection_stats(conn)
        assert is_integer(cache_used)

        assert {:ok, options} = Xqlite.compile_options(conn)
        assert options != []
        assert Enum.all?(options, &is_binary/1)

        assert {:ok, version} = Xqlite.sqlite_version()
        assert is_binary(version)
      end

      test "schema introspection", %{conn: conn} do
        assert {:ok, [%Schema.DatabaseInfo{name: "main"} | _]} = Xqlite.schema_databases(conn)

        assert {:ok, objects} = Xqlite.schema_list_objects(conn, "main")
        assert Enum.any?(objects, &(&1.name == "wrap_items" and &1.object_type == :table))

        assert {:ok, columns} = Xqlite.schema_columns(conn, "wrap_items")
        assert Enum.map(columns, & &1.name) == ["id", "name", "parent_id"]

        assert {:ok, [fk]} = Xqlite.schema_foreign_keys(conn, "wrap_items")

        assert %Schema.ForeignKeyInfo{target_table: "wrap_items", from_column: "parent_id"} =
                 fk

        assert {:ok, indexes} = Xqlite.schema_indexes(conn, "wrap_items")
        assert Enum.any?(indexes, &(&1.name == "wrap_items_name_idx"))

        assert {:ok, index_columns} = Xqlite.schema_index_columns(conn, "wrap_items_name_idx")
        assert Enum.any?(index_columns, &(&1.name == "name"))

        assert {:ok, create_sql} = Xqlite.get_create_sql(conn, "wrap_items")
        assert String.starts_with?(create_sql, "CREATE TABLE")
        assert {:ok, nil} = Xqlite.get_create_sql(conn, "no_such_object")
      end

      test "closed-connection errors pass through", %{conn: conn} do
        assert :ok = NIF.close(conn)
        assert {:error, :connection_closed} = Xqlite.changes(conn)
        assert {:error, :connection_closed} = Xqlite.schema_columns(conn, "wrap_items")
      end
    end
  end
end
