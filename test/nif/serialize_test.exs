defmodule Xqlite.NIF.SerializeTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "serialize/deserialize using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # Serialize basics
      # -------------------------------------------------------------------

      test "serialize empty database returns valid binary", %{conn: conn} do
        assert {:ok, binary} = NIF.serialize(conn, "main")
        assert is_binary(binary)
        assert byte_size(binary) > 0
        assert binary_part(binary, 0, 16) == "SQLite format 3\0"
      end

      test "serialize with explicit schema", %{conn: conn} do
        assert {:ok, binary} = NIF.serialize(conn, "main")
        assert is_binary(binary)
        assert byte_size(binary) > 0
      end

      test "serialize captures table data", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE s_test (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO s_test (id, val) VALUES (?1, ?2)", [1, "hello"])

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO s_test (id, val) VALUES (?1, ?2)", [2, "world"])

        {:ok, binary} = NIF.serialize(conn, "main")
        assert byte_size(binary) > 0

        # Deserialize into a fresh connection and verify data survived
        {:ok, conn2} = NIF.open_in_memory(":memory:")
        :ok = NIF.deserialize(conn2, "main", binary, false)

        assert {:ok, %{rows: [[1, "hello"], [2, "world"]], num_rows: 2}} =
                 NIF.query(conn2, "SELECT id, val FROM s_test ORDER BY id", [])

        NIF.close(conn2)
      end

      test "serialize captures schema (tables, indexes)", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE s_schema (id INTEGER PRIMARY KEY, name TEXT);
          CREATE INDEX idx_s_schema_name ON s_schema(name);
          """)

        {:ok, binary} = NIF.serialize(conn, "main")

        {:ok, conn2} = NIF.open_in_memory(":memory:")
        :ok = NIF.deserialize(conn2, "main", binary, false)

        {:ok, objects} = NIF.schema_list_objects(conn2, "main")
        table_names = Enum.map(objects, & &1.name)
        assert "s_schema" in table_names

        {:ok, indexes} = NIF.schema_indexes(conn2, "s_schema")
        index_names = Enum.map(indexes, & &1.name)
        assert "idx_s_schema_name" in index_names

        NIF.close(conn2)
      end

      test "serialize is a point-in-time snapshot", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE s_snap (id INTEGER PRIMARY KEY);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO s_snap (id) VALUES (?1)", [1])

        {:ok, snapshot} = NIF.serialize(conn, "main")

        # Insert more rows after snapshot
        {:ok, 1} = NIF.execute(conn, "INSERT INTO s_snap (id) VALUES (?1)", [2])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO s_snap (id) VALUES (?1)", [3])

        # Snapshot should only have the first row
        {:ok, conn2} = NIF.open_in_memory(":memory:")
        :ok = NIF.deserialize(conn2, "main", snapshot, false)

        assert {:ok, %{rows: [[1]], num_rows: 1}} =
                 NIF.query(conn2, "SELECT id FROM s_snap", [])

        NIF.close(conn2)
      end

      # -------------------------------------------------------------------
      # Deserialize basics
      # -------------------------------------------------------------------

      test "deserialize replaces existing database content", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE old_t (x INTEGER);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO old_t (x) VALUES (?1)", [999])

        # Create a different database in a second connection
        {:ok, conn2} = NIF.open_in_memory(":memory:")
        :ok = NIF.execute_batch(conn2, "CREATE TABLE new_t (y TEXT);")
        {:ok, 1} = NIF.execute(conn2, "INSERT INTO new_t (y) VALUES (?1)", ["fresh"])
        {:ok, binary} = NIF.serialize(conn2, "main")
        NIF.close(conn2)

        # Deserialize into the original connection
        :ok = NIF.deserialize(conn, "main", binary, false)

        # Old table should be gone
        assert {:error, {:no_such_table, _}} =
                 NIF.query(conn, "SELECT x FROM old_t", [])

        # New table should be present
        assert {:ok, %{rows: [["fresh"]], num_rows: 1}} =
                 NIF.query(conn, "SELECT y FROM new_t", [])
      end

      test "deserialize read-only mode blocks writes", %{conn: conn} do
        {:ok, conn2} = NIF.open_in_memory(":memory:")
        :ok = NIF.execute_batch(conn2, "CREATE TABLE ro_t (id INTEGER PRIMARY KEY);")
        {:ok, 1} = NIF.execute(conn2, "INSERT INTO ro_t (id) VALUES (?1)", [1])
        {:ok, binary} = NIF.serialize(conn2, "main")
        NIF.close(conn2)

        :ok = NIF.deserialize(conn, "main", binary, true)

        # Reads should work
        assert {:ok, %{rows: [[1]], num_rows: 1}} =
                 NIF.query(conn, "SELECT id FROM ro_t", [])

        # Writes should fail
        assert {:error, {:read_only_database, _}} =
                 NIF.execute(conn, "INSERT INTO ro_t (id) VALUES (?1)", [2])
      end

      test "deserialize writable mode allows writes", %{conn: conn} do
        {:ok, conn2} = NIF.open_in_memory(":memory:")
        :ok = NIF.execute_batch(conn2, "CREATE TABLE rw_t (id INTEGER PRIMARY KEY);")
        {:ok, binary} = NIF.serialize(conn2, "main")
        NIF.close(conn2)

        :ok = NIF.deserialize(conn, "main", binary, false)

        # Should be able to write
        assert {:ok, 1} = NIF.execute(conn, "INSERT INTO rw_t (id) VALUES (?1)", [1])

        assert {:ok, %{rows: [[1]], num_rows: 1}} =
                 NIF.query(conn, "SELECT id FROM rw_t", [])
      end

      # -------------------------------------------------------------------
      # Round-trip integrity
      # -------------------------------------------------------------------

      test "round-trip preserves multiple tables and data types", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE rt_ints (id INTEGER PRIMARY KEY, val INTEGER);
          CREATE TABLE rt_texts (id INTEGER PRIMARY KEY, val TEXT);
          CREATE TABLE rt_reals (id INTEGER PRIMARY KEY, val REAL);
          CREATE TABLE rt_blobs (id INTEGER PRIMARY KEY, val BLOB);
          """)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO rt_ints (id, val) VALUES (1, ?1)", [42])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO rt_texts (id, val) VALUES (1, ?1)", ["hi"])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO rt_reals (id, val) VALUES (1, ?1)", [3.14])

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO rt_blobs (id, val) VALUES (1, ?1)", [<<0, 1, 2>>])

        {:ok, binary} = NIF.serialize(conn, "main")

        {:ok, conn2} = NIF.open_in_memory(":memory:")
        :ok = NIF.deserialize(conn2, "main", binary, false)

        assert {:ok, %{rows: [[1, 42]]}} = NIF.query(conn2, "SELECT * FROM rt_ints", [])
        assert {:ok, %{rows: [[1, "hi"]]}} = NIF.query(conn2, "SELECT * FROM rt_texts", [])
        assert {:ok, %{rows: [[1, val]]}} = NIF.query(conn2, "SELECT * FROM rt_reals", [])
        assert_in_delta val, 3.14, 0.001

        assert {:ok, %{rows: [[1, <<0, 1, 2>>]]}} =
                 NIF.query(conn2, "SELECT * FROM rt_blobs", [])

        NIF.close(conn2)
      end

      test "round-trip preserves NULL values", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE rt_null (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, 1} = NIF.execute(conn, "INSERT INTO rt_null (id, val) VALUES (1, ?1)", [nil])

        {:ok, binary} = NIF.serialize(conn, "main")

        {:ok, conn2} = NIF.open_in_memory(":memory:")
        :ok = NIF.deserialize(conn2, "main", binary, false)

        assert {:ok, %{rows: [[1, nil]]}} = NIF.query(conn2, "SELECT * FROM rt_null", [])
        NIF.close(conn2)
      end

      test "round-trip preserves foreign keys", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE rt_parent (id INTEGER PRIMARY KEY);
          CREATE TABLE rt_child (id INTEGER PRIMARY KEY, pid INTEGER REFERENCES rt_parent(id));
          """)

        {:ok, binary} = NIF.serialize(conn, "main")

        {:ok, conn2} = NIF.open_in_memory(":memory:")
        :ok = NIF.deserialize(conn2, "main", binary, false)

        {:ok, fks} = NIF.schema_foreign_keys(conn2, "rt_child")
        assert length(fks) == 1
        assert hd(fks).target_table == "rt_parent"
        NIF.close(conn2)
      end

      test "round-trip preserves pragmas set before serialize", %{conn: conn} do
        {:ok, _} = NIF.set_pragma(conn, "user_version", 42)
        {:ok, binary} = NIF.serialize(conn, "main")

        {:ok, conn2} = NIF.open_in_memory(":memory:")
        :ok = NIF.deserialize(conn2, "main", binary, false)

        assert {:ok, 42} = NIF.get_pragma(conn2, "user_version")
        NIF.close(conn2)
      end

      # -------------------------------------------------------------------
      # Serialize after modifications
      # -------------------------------------------------------------------

      test "serialize after transaction commit captures committed data", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE s_tx (id INTEGER PRIMARY KEY);")
        :ok = NIF.begin(conn, :immediate)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO s_tx (id) VALUES (?1)", [1])
        :ok = NIF.commit(conn)

        {:ok, binary} = NIF.serialize(conn, "main")

        {:ok, conn2} = NIF.open_in_memory(":memory:")
        :ok = NIF.deserialize(conn2, "main", binary, false)
        assert {:ok, %{rows: [[1]]}} = NIF.query(conn2, "SELECT id FROM s_tx", [])
        NIF.close(conn2)
      end

      test "serialize after rollback excludes rolled-back data", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE s_rb (id INTEGER PRIMARY KEY);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO s_rb (id) VALUES (?1)", [1])

        :ok = NIF.begin(conn, :immediate)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO s_rb (id) VALUES (?1)", [2])
        :ok = NIF.rollback(conn)

        {:ok, binary} = NIF.serialize(conn, "main")

        {:ok, conn2} = NIF.open_in_memory(":memory:")
        :ok = NIF.deserialize(conn2, "main", binary, false)
        assert {:ok, %{rows: [[1]], num_rows: 1}} = NIF.query(conn2, "SELECT id FROM s_rb", [])
        NIF.close(conn2)
      end

      # -------------------------------------------------------------------
      # Deserialize then modify
      # -------------------------------------------------------------------

      test "writable deserialized database supports transactions", %{conn: conn} do
        {:ok, conn_src} = NIF.open_in_memory(":memory:")
        :ok = NIF.execute_batch(conn_src, "CREATE TABLE d_tx (id INTEGER PRIMARY KEY);")
        {:ok, binary} = NIF.serialize(conn_src, "main")
        NIF.close(conn_src)

        :ok = NIF.deserialize(conn, "main", binary, false)
        :ok = NIF.begin(conn, :immediate)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO d_tx (id) VALUES (?1)", [1])
        :ok = NIF.commit(conn)

        assert {:ok, %{rows: [[1]]}} = NIF.query(conn, "SELECT id FROM d_tx", [])
      end

      test "writable deserialized database can be re-serialized", %{conn: conn} do
        {:ok, conn_src} = NIF.open_in_memory(":memory:")
        :ok = NIF.execute_batch(conn_src, "CREATE TABLE d_rs (id INTEGER PRIMARY KEY);")
        {:ok, 1} = NIF.execute(conn_src, "INSERT INTO d_rs (id) VALUES (?1)", [1])
        {:ok, binary1} = NIF.serialize(conn_src, "main")
        NIF.close(conn_src)

        :ok = NIF.deserialize(conn, "main", binary1, false)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO d_rs (id) VALUES (?1)", [2])

        {:ok, binary2} = NIF.serialize(conn, "main")

        {:ok, conn3} = NIF.open_in_memory(":memory:")
        :ok = NIF.deserialize(conn3, "main", binary2, false)

        assert {:ok, %{rows: [[1], [2]], num_rows: 2}} =
                 NIF.query(conn3, "SELECT id FROM d_rs ORDER BY id", [])

        NIF.close(conn3)
      end

      # -------------------------------------------------------------------
      # Large data
      # -------------------------------------------------------------------

      test "round-trip with many rows", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE s_large (id INTEGER PRIMARY KEY, data TEXT);")

        for i <- 1..500 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO s_large (id, data) VALUES (?1, ?2)", [
              i,
              "row_#{i}_data"
            ])
        end

        {:ok, binary} = NIF.serialize(conn, "main")

        {:ok, conn2} = NIF.open_in_memory(":memory:")
        :ok = NIF.deserialize(conn2, "main", binary, false)

        assert {:ok, %{num_rows: 500}} = NIF.query(conn2, "SELECT id FROM s_large", [])

        assert {:ok, %{rows: [[500, "row_500_data"]]}} =
                 NIF.query(conn2, "SELECT id, data FROM s_large WHERE id = 500", [])

        NIF.close(conn2)
      end

      # -------------------------------------------------------------------
      # Stream integration
      # -------------------------------------------------------------------

      test "stream works on deserialized database", %{conn: conn} do
        {:ok, conn_src} = NIF.open_in_memory(":memory:")

        :ok =
          NIF.execute_batch(
            conn_src,
            "CREATE TABLE d_stream (id INTEGER PRIMARY KEY, val TEXT);"
          )

        {:ok, 1} = NIF.execute(conn_src, "INSERT INTO d_stream VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn_src, "INSERT INTO d_stream VALUES (2, 'b')", [])
        {:ok, binary} = NIF.serialize(conn_src, "main")
        NIF.close(conn_src)

        :ok = NIF.deserialize(conn, "main", binary, false)

        results =
          Xqlite.stream(conn, "SELECT id, val FROM d_stream ORDER BY id")
          |> Enum.to_list()

        assert results == [
                 %{"id" => 1, "val" => "a"},
                 %{"id" => 2, "val" => "b"}
               ]
      end
    end
  end

  # -------------------------------------------------------------------
  # Edge cases outside connection_openers loop (no connection needed
  # or tests requiring specific connection setup)
  # -------------------------------------------------------------------

  test "serialize on closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    NIF.close(conn)
    assert {:error, :connection_closed} = NIF.serialize(conn, "main")
  end

  test "deserialize on closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    NIF.close(conn)
    assert {:error, :connection_closed} = NIF.deserialize(conn, "main", <<>>, false)
  end

  test "deserialize with empty binary returns error" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    result = NIF.deserialize(conn, "main", <<>>, false)
    NIF.close(conn)
    assert {:error, _} = result
  end

  test "deserialize with garbage binary accepts but querying fails" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    # SQLite accepts garbage at deserialize time — validation is lazy
    :ok = NIF.deserialize(conn, "main", "not a valid sqlite database at all", false)
    assert {:error, _} = NIF.query(conn, "SELECT 1", [])
    NIF.close(conn)
  end

  test "transfer database between two independent connections" do
    {:ok, conn1} = NIF.open_in_memory(":memory:")
    :ok = NIF.execute_batch(conn1, "CREATE TABLE xfer (id INTEGER PRIMARY KEY, msg TEXT);")
    {:ok, 1} = NIF.execute(conn1, "INSERT INTO xfer VALUES (1, 'transferred')", [])
    {:ok, binary} = NIF.serialize(conn1, "main")
    NIF.close(conn1)

    {:ok, conn2} = NIF.open_in_memory(":memory:")
    :ok = NIF.deserialize(conn2, "main", binary, false)
    assert {:ok, %{rows: [[1, "transferred"]]}} = NIF.query(conn2, "SELECT * FROM xfer", [])
    NIF.close(conn2)
  end

  test "multiple sequential serializations produce independent snapshots" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    :ok = NIF.execute_batch(conn, "CREATE TABLE seq_s (id INTEGER PRIMARY KEY);")

    {:ok, 1} = NIF.execute(conn, "INSERT INTO seq_s (id) VALUES (?1)", [1])
    {:ok, snap1} = NIF.serialize(conn, "main")

    {:ok, 1} = NIF.execute(conn, "INSERT INTO seq_s (id) VALUES (?1)", [2])
    {:ok, snap2} = NIF.serialize(conn, "main")

    {:ok, 1} = NIF.execute(conn, "INSERT INTO seq_s (id) VALUES (?1)", [3])
    {:ok, snap3} = NIF.serialize(conn, "main")
    NIF.close(conn)

    # Each snapshot has a different number of rows
    {:ok, c1} = NIF.open_in_memory(":memory:")
    :ok = NIF.deserialize(c1, "main", snap1, false)
    assert {:ok, %{num_rows: 1}} = NIF.query(c1, "SELECT id FROM seq_s", [])
    NIF.close(c1)

    {:ok, c2} = NIF.open_in_memory(":memory:")
    :ok = NIF.deserialize(c2, "main", snap2, false)
    assert {:ok, %{num_rows: 2}} = NIF.query(c2, "SELECT id FROM seq_s", [])
    NIF.close(c2)

    {:ok, c3} = NIF.open_in_memory(":memory:")
    :ok = NIF.deserialize(c3, "main", snap3, false)
    assert {:ok, %{num_rows: 3}} = NIF.query(c3, "SELECT id FROM seq_s", [])
    NIF.close(c3)
  end
end
