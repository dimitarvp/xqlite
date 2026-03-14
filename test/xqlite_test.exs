defmodule XqliteTest do
  use ExUnit.Case, async: true
  doctest Xqlite

  alias Xqlite.TestUtil
  alias XqliteNIF, as: NIF

  @record_count 20

  # Use the multi-DB test pattern
  for {type_tag, prefix, _opener_mfa} <- TestUtil.connection_openers() do
    describe "Xqlite.stream/4 using #{prefix}" do
      @describetag type_tag

      # Setup for each connection type
      setup context do
        {mod, fun, args} = TestUtil.find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        # Create and populate a test table
        assert :ok =
                 NIF.execute_batch(
                   conn,
                   "CREATE TABLE stream_test_users (id INTEGER PRIMARY KEY, name TEXT, email TEXT);"
                 )

        for i <- 1..@record_count do
          assert {:ok, 1} =
                   NIF.execute(
                     conn,
                     "INSERT INTO stream_test_users (id, name, email) VALUES (?1, ?2, ?3);",
                     [i, "User #{i}", "user#{i}@example.com"]
                   )
        end

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "streams all results as a list of maps", %{conn: conn} do
        stream = Xqlite.stream(conn, "SELECT id, name FROM stream_test_users ORDER BY id;")

        # Verify it's a stream
        assert Enumerable.impl_for(stream) != nil

        results = Enum.to_list(stream)

        assert length(results) == @record_count
        assert List.first(results) == %{"id" => 1, "name" => "User 1"}

        assert List.last(results) == %{
                 "id" => @record_count,
                 "name" => "User #{@record_count}"
               }
      end

      test "streams correctly with a small batch size", %{conn: conn} do
        # Batch size of 5 means it will take 4 batches to consume 20 records.
        stream =
          Xqlite.stream(conn, "SELECT id FROM stream_test_users ORDER BY id;", [],
            batch_size: 5
          )

        results = Enum.map(stream, & &1["id"])

        assert results == Enum.to_list(1..@record_count)
      end

      test "streams an empty result set correctly", %{conn: conn} do
        stream = Xqlite.stream(conn, "SELECT id FROM stream_test_users WHERE id < 0;")
        assert Enum.to_list(stream) == []
      end

      test "streams with positional parameters", %{conn: conn} do
        stream =
          Xqlite.stream(
            conn,
            "SELECT name FROM stream_test_users WHERE id > ?1 ORDER BY id;",
            [
              @record_count - 2
            ]
          )

        results = Enum.to_list(stream)

        assert results == [
                 %{"name" => "User #{@record_count - 1}"},
                 %{"name" => "User #{@record_count}"}
               ]
      end

      test "streams with named parameters", %{conn: conn} do
        stream =
          Xqlite.stream(conn, "SELECT name FROM stream_test_users WHERE email = :email;",
            email: "user3@example.com"
          )

        results = Enum.to_list(stream)
        assert results == [%{"name" => "User 3"}]
      end

      test "returns an error tuple for invalid SQL", %{conn: conn} do
        # This tests the `case start_fun` logic in Xqlite.stream/4
        result = Xqlite.stream(conn, "SELEKT * FROM stream_test_users;")

        assert match?({:error, {:sqlite_failure, _, _, _}}, result)
      end

      test "stream created with empty SQL results in an empty stream", %{conn: conn} do
        stream = Xqlite.stream(conn, "")
        assert Enum.to_list(stream) == []
      end
    end
  end

  describe "disable_strict_mode/1" do
    setup do
      {:ok, conn} = NIF.open_in_memory()
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "allows type coercion after disabling strict mode", %{conn: conn} do
      assert {:ok, _} = Xqlite.enable_strict_mode(conn)
      assert {:ok, _} = Xqlite.disable_strict_mode(conn)

      :ok =
        NIF.execute_batch(conn, "CREATE TABLE ds_test (id INTEGER PRIMARY KEY, val INTEGER);")

      # In non-strict mode, inserting a string into an INTEGER column succeeds
      # (SQLite stores it as-is due to type affinity being flexible)
      assert {:ok, 1} =
               NIF.execute(conn, "INSERT INTO ds_test (id, val) VALUES (1, 'hello')", [])

      assert {:ok, %{rows: [[1, "hello"]], num_rows: 1}} =
               NIF.query(conn, "SELECT * FROM ds_test", [])
    end
  end

  describe "disable_foreign_key_enforcement/1" do
    setup do
      {:ok, conn} = NIF.open_in_memory()
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "allows FK violations after disabling enforcement", %{conn: conn} do
      assert {:ok, _} = Xqlite.enable_foreign_key_enforcement(conn)
      assert {:ok, _} = Xqlite.disable_foreign_key_enforcement(conn)

      :ok =
        NIF.execute_batch(
          conn,
          """
          CREATE TABLE fk_parent (id INTEGER PRIMARY KEY);
          CREATE TABLE fk_child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES fk_parent(id));
          """
        )

      # With FK enforcement disabled, inserting a child with no matching parent succeeds
      assert {:ok, 1} =
               NIF.execute(conn, "INSERT INTO fk_child (id, parent_id) VALUES (1, 999)", [])
    end
  end

  describe "int2bool/1" do
    test "converts 0 to false" do
      assert Xqlite.int2bool(0) == false
    end

    test "converts 1 to true" do
      assert Xqlite.int2bool(1) == true
    end
  end
end
