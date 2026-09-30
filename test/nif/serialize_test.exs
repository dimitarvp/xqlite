defmodule Xqlite.NIF.SerializeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  for_each_opener "serialize/deserialize" do
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

      {:ok, 1} = NIF.execute(conn, "INSERT INTO s_snap (id) VALUES (?1)", [2])
      {:ok, 1} = NIF.execute(conn, "INSERT INTO s_snap (id) VALUES (?1)", [3])

      {:ok, conn2} = NIF.open_in_memory(":memory:")
      :ok = NIF.deserialize(conn2, "main", snapshot, false)

      assert {:ok, %{rows: [[1]], num_rows: 1}} =
               NIF.query(conn2, "SELECT id FROM s_snap", [])

      NIF.close(conn2)
    end

    test "deserialize replaces existing database content", %{conn: conn} do
      :ok = NIF.execute_batch(conn, "CREATE TABLE old_t (x INTEGER);")
      {:ok, 1} = NIF.execute(conn, "INSERT INTO old_t (x) VALUES (?1)", [999])

      {:ok, conn2} = NIF.open_in_memory(":memory:")
      :ok = NIF.execute_batch(conn2, "CREATE TABLE new_t (y TEXT);")
      {:ok, 1} = NIF.execute(conn2, "INSERT INTO new_t (y) VALUES (?1)", ["fresh"])
      {:ok, binary} = NIF.serialize(conn2, "main")
      NIF.close(conn2)

      :ok = NIF.deserialize(conn, "main", binary, false)

      assert {:error, {:no_such_table, _}} =
               NIF.query(conn, "SELECT x FROM old_t", [])

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

      assert {:ok, %{rows: [[1]], num_rows: 1}} =
               NIF.query(conn, "SELECT id FROM ro_t", [])

      assert {:error, {:read_only_database, _, _}} =
               NIF.execute(conn, "INSERT INTO ro_t (id) VALUES (?1)", [2])
    end

    test "deserialize writable mode allows writes", %{conn: conn} do
      {:ok, conn2} = NIF.open_in_memory(":memory:")
      :ok = NIF.execute_batch(conn2, "CREATE TABLE rw_t (id INTEGER PRIMARY KEY);")
      {:ok, binary} = NIF.serialize(conn2, "main")
      NIF.close(conn2)

      :ok = NIF.deserialize(conn, "main", binary, false)

      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO rw_t (id) VALUES (?1)", [1])

      assert {:ok, %{rows: [[1]], num_rows: 1}} =
               NIF.query(conn, "SELECT id FROM rw_t", [])
    end

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

    property "no binary without SQLite's header, and no read-only image loaded writable, replaces the contents",
             %{conn: conn} do
      :ok = NIF.execute_batch(conn, "CREATE TABLE kept (x); INSERT INTO kept VALUES (1);")
      <<head::binary-size(18), _, tail::binary>> = image_of("CREATE TABLE t (v);")

      for bytes <- ["not a database, just text", :binary.copy(<<0>>, 4096), <<>>] do
        assert {:error, {:invalid_image, %{reason: :not_a_database}}} =
                 Xqlite.deserialize(conn, bytes)
      end

      check all(bytes <- binary(), not match?("SQLite format 3\0" <> _, bytes), max_runs: 2000) do
        assert {:error, {:invalid_image, %{reason: :not_a_database, code: 26}}} =
                 NIF.deserialize(conn, "main", bytes, false)
      end

      check all(version <- integer(3..255), max_runs: 2000) do
        assert {:error, {:invalid_image, %{reason: :read_only_image, code: 8}}} =
                 NIF.deserialize(conn, "main", <<head::binary, version, tail::binary>>, false)
      end

      assert {:ok, %{rows: [[1]]}} = NIF.query(conn, "SELECT x FROM kept", [])
      assert :ok = Xqlite.deserialize(conn, <<head::binary, 3, tail::binary>>, "main", true)
      assert {:ok, %{rows: []}} = NIF.query(conn, "SELECT v FROM t", [])
    end

    test "a WAL database's image loads, from serialize/2 or from the closed database's file",
         %{conn: conn} do
      path = Xqlite.TestUtil.tmp_db_path("wal_image")
      {:ok, src} = Xqlite.open(path)
      :ok = NIF.execute_batch(src, "CREATE TABLE t (v); INSERT INTO t VALUES (1), (2);")
      {:ok, <<_::binary-size(18), 2, 2, _::binary>> = image} = Xqlite.serialize(src)
      :ok = NIF.close(src)
      refute File.exists?(path <> "-wal")

      for bytes <- [image, File.read!(path)] do
        assert :ok = Xqlite.deserialize(conn, bytes)
        assert {:ok, %{rows: [[2]]}} = NIF.query(conn, "SELECT count(*) FROM t", [])
      end
    end

    test "an image SQLite cannot read is rejected before it replaces a schema", %{conn: conn} do
      {:ok, src} = NIF.open_in_memory(":memory:")
      :ok = NIF.execute_batch(src, "CREATE TABLE t AS SELECT zeroblob(20000) AS v;")
      {:ok, image} = NIF.serialize(src, "main")
      :ok = NIF.close(src)
      :ok = NIF.execute_batch(conn, "CREATE TABLE kept (x); ATTACH ':memory:' AS aux;")

      assert {:error, {:invalid_image, %{reason: :malformed}}} =
               Xqlite.deserialize(conn, binary_part(image, 0, div(byte_size(image), 2)), "aux")

      assert {:ok, %{rows: [[0]]}} = NIF.query(conn, "SELECT count(*) FROM main.kept", [])
      assert {:ok, 0} = NIF.execute(conn, "DETACH aux", [])
    end

    test "an image in a text encoding the target cannot take is rejected, and serialize/2 answers, with :pragma denied",
         %{conn: conn} do
      {:ok, src} = NIF.open_in_memory(":memory:")
      :ok = NIF.execute_batch(src, "PRAGMA encoding = 'UTF-16le'; CREATE TABLE u (v);")
      {:ok, utf16} = NIF.serialize(src, "main")
      file = Xqlite.TestUtil.tmp_db_path("utf16_attached")
      :ok = NIF.execute_batch(src, "ATTACH '#{file}' AS f; CREATE TABLE f.t (v);")
      :ok = NIF.execute_batch(conn, "CREATE TABLE kept (x); ATTACH ':memory:' AS aux;")
      {:ok, utf8} = NIF.serialize(conn, "main")
      {:ok, fresh} = NIF.open_in_memory(":memory:")
      :ok = Xqlite.set_authorizer(conn, [:pragma])

      mismatch = {:error, {:invalid_image, %{reason: :encoding_mismatch, code: 1}}}
      assert Xqlite.deserialize(conn, utf16, "aux") == mismatch
      assert Xqlite.deserialize(conn, utf16) == mismatch
      assert Xqlite.deserialize(fresh, utf16) == mismatch
      assert Xqlite.deserialize(src, utf8) == mismatch
      assert {:ok, ^utf8} = Xqlite.serialize(conn)
      assert :ok = Xqlite.deserialize(conn, utf8)

      assert {:error, {:authorization_denied, 23, _}} =
               NIF.query(conn, "PRAGMA page_count", [])

      assert {:ok, %{rows: [[0]]}} = NIF.query(conn, "SELECT count(*) FROM main.kept", [])
      assert {:ok, 0} = NIF.execute(conn, "DETACH aux", [])
      assert {:ok, %{rows: [["UTF-16le"]]}} = NIF.query(src, "PRAGMA encoding", [])
      Enum.each([src, fresh], &NIF.close/1)
    end

    test "a rollback-journal image loads byte for byte", %{conn: conn} do
      path = Xqlite.TestUtil.tmp_db_path("delete_image")
      {:ok, src} = Xqlite.open(path, journal_mode: :delete)
      :ok = NIF.execute_batch(src, "CREATE TABLE t AS SELECT 1 AS v;")
      {:ok, image} = Xqlite.serialize(src)
      assert :ok = Xqlite.deserialize(conn, image)
      assert {:ok, ^image} = Xqlite.serialize(conn)
      NIF.close(src)
    end

    test "a write prepared before a load runs against the loaded schema, under the caller's deny list",
         %{conn: conn} do
      :ok = NIF.execute_batch(conn, "CREATE TABLE t (a INTEGER PRIMARY KEY, b TEXT);")
      {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (1, 'one')", [])
      {:ok, image} = NIF.serialize(conn, "main")
      :ok = Xqlite.set_authorizer(conn, [:delete])
      {:ok, insert} = NIF.stmt_prepare(conn, "INSERT INTO t VALUES (?1, ?2)")
      :ok = NIF.stmt_bind(insert, [2, "two"])

      assert :ok = Xqlite.deserialize(conn, image)
      assert :done = NIF.stmt_step(insert)
      assert {:ok, %{rows: [[1, "one"], [2, "two"]]}} = NIF.query(conn, "SELECT * FROM t", [])
      assert {:error, {:authorization_denied, 23, _}} = NIF.execute(conn, "DELETE FROM t", [])
      :ok = NIF.stmt_finalize(insert)
    end

    test "a query prepared before a load reads the loaded table, not the page it read before",
         %{conn: conn} do
      image =
        image_of("""
        CREATE TABLE t (a, b); CREATE TABLE pad (p, q);
        INSERT INTO t VALUES ('image-t', 1); INSERT INTO pad VALUES ('image-pad', 2);
        """)

      :ok = NIF.execute_batch(conn, "CREATE TABLE pad (p, q); CREATE TABLE t (a, b);")
      {:ok, select} = NIF.stmt_prepare(conn, "SELECT a, b FROM t")

      assert :ok = Xqlite.deserialize(conn, image)
      assert {:ok, %{rows: [["image-t", 1]]}} = NIF.stmt_multi_step(select, 10)
      :ok = NIF.stmt_finalize(select)
    end

    test "serialize/2 of a schema another connection holds locked answers busy", %{conn: conn} do
      path = Xqlite.TestUtil.tmp_db_path("locked")
      {:ok, holder} = Xqlite.open(path, journal_mode: :delete)
      :ok = NIF.execute_batch(holder, "CREATE TABLE t (a);")
      {:ok, 0} = NIF.execute(conn, "ATTACH '#{path}' AS held", [])
      {:ok, _} = NIF.set_pragma(conn, "busy_timeout", 0)

      :ok =
        NIF.execute_batch(holder, "PRAGMA locking_mode = EXCLUSIVE; INSERT INTO t VALUES (1);")

      assert {:error, {:database_busy_or_locked, 5, _}} = Xqlite.serialize(conn, "held")
      :ok = NIF.close(holder)
    end

    test "an empty schema SQLite cannot write a first page to answers :no_pages, and so does the unused temp schema, writing nothing",
         %{conn: conn} do
      path = Xqlite.TestUtil.tmp_db_path("zero_bytes")
      File.write!(path, "")
      {:ok, fresh} = NIF.open(path)
      assert {:error, :no_pages} = Xqlite.serialize(fresh, "temp")
      assert File.stat!(path).size == 0
      {:ok, zero} = Xqlite.open_readonly(path)
      {:ok, 0} = NIF.execute(conn, "ATTACH ':memory:' AS empty", [])
      :ok = Xqlite.set_authorizer(conn, [:transaction])

      for {c, schema} <- [{conn, "empty"}, {zero, "main"}] do
        {:error, {:no_such_table, "nosuch"}} = NIF.query(c, "SELECT * FROM nosuch", [])
        assert {:error, :no_pages} = Xqlite.serialize(c, schema)
      end

      Enum.each([zero, fresh], &NIF.close/1)
    end

    test "a failure inside SQLite's own copy answers its classified error", %{conn: conn} do
      {:ok, 23} = Xqlite.put_limit(conn, :sql_length, 23)
      assert {:ok, %{rows: [[_pages]]}} = NIF.query(conn, "PRAGMA main.page_count", [])
      assert {:error, {:too_big, 18, _}} = Xqlite.serialize(conn)
    end

    test "a TEMP trigger on a loaded table fires after every load", %{conn: conn} do
      :ok = temp_audit_trigger(conn)
      image = image_of("CREATE TABLE t (a);")

      for i <- 1..20 do
        :ok = Xqlite.deserialize(conn, image)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (?1)", [i])
      end

      assert {:ok, %{rows: [[20]]}} = NIF.query(conn, "SELECT count(*) FROM temp.audit", [])
    end

    test "DROP TRIGGER on a TEMP trigger over a loaded table answers :ok", %{conn: conn} do
      :ok = temp_audit_trigger(conn)
      :ok = Xqlite.deserialize(conn, image_of("CREATE TABLE t (a);"))
      assert {:ok, 0} = NIF.execute(conn, "DROP TRIGGER temp.trg", [])
      {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (1)", [])
      assert {:ok, %{rows: []}} = NIF.query(conn, "SELECT x FROM temp.audit", [])
    end

    test "a TEMP trigger over a table the image lacks waits for a load that has it",
         %{conn: conn} do
      :ok = temp_audit_trigger(conn)
      assert :ok = Xqlite.deserialize(conn, image_of("CREATE TABLE u (a);"))
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO u VALUES (1)", [])
      assert :ok = Xqlite.deserialize(conn, image_of("CREATE TABLE t (a);"))
      {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (2)", [])
      assert {:ok, %{rows: [[2]]}} = NIF.query(conn, "SELECT x FROM temp.audit", [])
    end

    test "a load or a restore while a statement runs on another schema answers busy, and the statement finishes with its types",
         %{conn: conn} do
      path = Xqlite.TestUtil.tmp_db_path("restore_src")
      {:ok, src} = Xqlite.open(path, journal_mode: :delete)
      :ok = NIF.execute_batch(src, "CREATE TABLE t (a); INSERT INTO t VALUES (1);")
      :ok = NIF.close(src)

      :ok =
        NIF.execute_batch(conn, """
        ATTACH ':memory:' AS aux;
        CREATE TABLE aux.st (a INTEGER, v INTEGER AS (a * 2) VIRTUAL) STRICT;
        WITH RECURSIVE s(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM s WHERE i < 200)
        INSERT INTO aux.st (a) SELECT i FROM s;
        """)

      {:ok, select} = NIF.stmt_prepare(conn, "SELECT a, v FROM aux.st")
      assert {:row, [1, 2]} = NIF.stmt_step(select)

      assert {:error, {:database_busy_or_locked, 5, _}} =
               Xqlite.deserialize(conn, image_of("CREATE TABLE t (a);"))

      assert {:error, {:database_busy_or_locked, 5, _}} = Xqlite.restore(conn, path)
      assert {:ok, %{rows: rows}} = NIF.stmt_multi_step(select, 1000)
      assert rows == Enum.map(2..200, &[&1, &1 * 2])
      :ok = NIF.stmt_finalize(select)
      assert {:error, {:no_such_table, _}} = NIF.query(conn, "SELECT a FROM main.t", [])
      assert :ok = Xqlite.restore(conn, path)
      assert {:ok, %{rows: [[1]]}} = NIF.query(conn, "SELECT a FROM main.t", [])
    end

    test "temp in any ASCII case is rejected by name before the image is judged", %{conn: conn} do
      {:ok, image} = NIF.serialize(conn, "main")
      names = for t <- ~w(t T), e <- ~w(e E), m <- ~w(m M), p <- ~w(p P), do: t <> e <> m <> p

      for name <- names, bytes <- [image, "no image"] do
        assert {:error, {:invalid_schema_name, ^name}} = Xqlite.deserialize(conn, bytes, name)
      end

      assert :ok = NIF.deserialize(conn, "main", image, false)
    end
  end

  defp temp_audit_trigger(conn) do
    NIF.execute_batch(conn, """
    CREATE TABLE t (a); CREATE TEMP TABLE audit (x);
    CREATE TEMP TRIGGER trg AFTER INSERT ON main.t BEGIN INSERT INTO audit VALUES (new.a); END;
    """)
  end

  defp image_of(sql) do
    {:ok, src} = NIF.open_in_memory(":memory:")
    :ok = NIF.execute_batch(src, sql)
    {:ok, image} = NIF.serialize(src, "main")
    :ok = NIF.close(src)
    image
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
