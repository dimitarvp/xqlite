defmodule Xqlite.NIF.StreamTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]
  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "#{prefix} streaming" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        assert {:ok, 0} =
                 NIF.execute(
                   conn,
                   "CREATE TABLE stream_items (id INTEGER PRIMARY KEY, name TEXT, price REAL);",
                   []
                 )

        for i <- 1..12 do
          assert {:ok, 1} =
                   NIF.execute(
                     conn,
                     "INSERT INTO stream_items (id, name, price) VALUES (?1, ?2, ?3);",
                     [i, "Item #{i}", i + 0.50]
                   )
        end

        on_exit(fn ->
          NIF.close(conn)
        end)

        {:ok, conn: conn}
      end

      # --- stream_open/4 Tests ---
      test "stream_open/4 with valid SQL returns a handle and correct columns", %{conn: conn} do
        sql = "SELECT id, name, price FROM stream_items;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert is_reference(stream_handle)
        assert {:ok, ["id", "name", "price"]} == NIF.stream_get_columns(stream_handle)
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_open/4 with positional parameters returns a handle and correct columns", %{
        conn: conn
      } do
        sql = "SELECT name, price FROM stream_items WHERE id = ?1;"
        params = [1]
        {:ok, stream_handle} = NIF.stream_open(conn, sql, params, [])
        assert is_reference(stream_handle)
        assert {:ok, ["name", "price"]} == NIF.stream_get_columns(stream_handle)
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_open/4 with named parameters returns a handle and correct columns", %{
        conn: conn
      } do
        sql = "SELECT id FROM stream_items WHERE name = :item_name;"
        params = [item_name: "Item 2"]
        {:ok, stream_handle} = NIF.stream_open(conn, sql, params, [])
        assert is_reference(stream_handle)
        assert {:ok, ["id"]} == NIF.stream_get_columns(stream_handle)
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_open/4 with invalid SQL (syntax error) returns an error", %{conn: conn} do
        sql = "SELEKT id FROM stream_items;"
        assert {:error, error_details} = NIF.stream_open(conn, sql, [], [])

        assert match?({:sqlite_failure, _p_code, _e_code, _msg_str}, error_details)
        # Check message content after matching the structure
        {:sqlite_failure, _, _, msg_str} = error_details
        assert is_binary(msg_str)
        assert String.contains?(msg_str, "syntax error")
        assert String.contains?(msg_str, "SELEKT")
      end

      test "stream_open/4 with SQL for non-existent table returns an error", %{conn: conn} do
        sql = "SELECT id FROM non_existent_table_for_stream;"
        assert {:error, error_details} = NIF.stream_open(conn, sql, [], [])

        assert match?({:no_such_table, _msg}, error_details)
        {:no_such_table, msg_str} = error_details
        assert is_binary(msg_str)
        assert String.contains?(msg_str, "no such table")
      end

      test "stream_open/4 with empty SQL string returns handle, empty columns, and is done", %{
        conn: conn
      } do
        sql = ""
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert is_reference(stream_handle)
        assert {:ok, []} == NIF.stream_get_columns(stream_handle)
        assert :done == NIF.stream_fetch(stream_handle, 1)
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_open/4 with comments-only SQL returns handle, empty columns, and is done",
           %{conn: conn} do
        sql = "-- This is just a comment;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert is_reference(stream_handle)
        assert {:ok, []} == NIF.stream_get_columns(stream_handle)
        assert :done == NIF.stream_fetch(stream_handle, 1)
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_open/4 with invalid parameter name (named params) returns an error", %{
        conn: conn
      } do
        sql = "SELECT id FROM stream_items WHERE name = :name;"
        params = [name: "Item 1", unexpected_param_name: "foo"]

        assert {:error, {:invalid_parameter_name, ":unexpected_param_name"}} ==
                 NIF.stream_open(conn, sql, params, [])
      end

      test "stream_open/4 with too few positional params returns handle and correct columns",
           %{conn: conn} do
        sql = "SELECT id, name FROM stream_items WHERE id = ?1 AND name = ?2;"
        params = [1]
        {:ok, stream_handle} = NIF.stream_open(conn, sql, params, [])
        assert is_reference(stream_handle)
        assert {:ok, ["id", "name"]} == NIF.stream_get_columns(stream_handle)
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_open/4 with too many positional params returns an error", %{conn: conn} do
        sql = "SELECT id FROM stream_items WHERE id = ?1;"
        params = [1, "extra_param"]

        assert {:error, {:sqlite_failure, _, 25, _msg}} =
                 NIF.stream_open(conn, sql, params, [])
      end

      # --- stream_fetch/2 Tests ---
      test "stream_fetch/2 retrieves all rows in a single large batch", %{conn: conn} do
        sql = "SELECT id, name, price FROM stream_items ORDER BY id;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])

        expected_rows = for i <- 1..12, do: [i, "Item #{i}", i + 0.50]
        assert {:ok, %{rows: actual_rows}} = NIF.stream_fetch(stream_handle, 20)
        assert actual_rows == expected_rows

        assert :done == NIF.stream_fetch(stream_handle, 1)
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_fetch/2 retrieves all rows in multiple smaller batches", %{conn: conn} do
        sql = "SELECT id FROM stream_items ORDER BY id;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])

        assert {:ok, %{rows: [[1], [2], [3], [4], [5]]}} == NIF.stream_fetch(stream_handle, 5)
        assert {:ok, %{rows: [[6], [7], [8], [9], [10]]}} == NIF.stream_fetch(stream_handle, 5)
        assert {:ok, %{rows: [[11], [12]]}} == NIF.stream_fetch(stream_handle, 5)
        assert :done == NIF.stream_fetch(stream_handle, 1)
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_fetch/2 with invalid batch_size (0) returns an error", %{conn: conn} do
        sql = "SELECT id FROM stream_items LIMIT 2;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])

        assert {:error, {:invalid_batch_size, %{provided: "0", minimum: 1}}} ==
                 NIF.stream_fetch(stream_handle, 0)

        # Stream should still be usable with valid batch size
        assert {:ok, %{rows: [[1], [2]]}} == NIF.stream_fetch(stream_handle, 2)
        assert :done == NIF.stream_fetch(stream_handle, 1)
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_fetch/2 with invalid batch_size (negative) returns an error", %{conn: conn} do
        sql = "SELECT id FROM stream_items LIMIT 1;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])

        assert {:error, {:invalid_batch_size, %{provided: "-1", minimum: 1}}} ==
                 NIF.stream_fetch(stream_handle, -1)

        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_fetch/2 on an empty result set immediately returns :done", %{conn: conn} do
        sql = "SELECT id FROM stream_items WHERE id = 999;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert :done == NIF.stream_fetch(stream_handle, 5)
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_fetch/2 after :done signal consistently returns :done", %{conn: conn} do
        sql = "SELECT id FROM stream_items LIMIT 1;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert {:ok, %{rows: [[1]]}} == NIF.stream_fetch(stream_handle, 1)
        assert :done == NIF.stream_fetch(stream_handle, 1)
        assert :done == NIF.stream_fetch(stream_handle, 1)
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_fetch/2 after stream_close returns :done", %{conn: conn} do
        sql = "SELECT id FROM stream_items;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert :ok == NIF.stream_close(stream_handle)
        assert :done == NIF.stream_fetch(stream_handle, 1)
      end

      test "stream_fetch/2 with too few positional params results in :done (due to NULL comparison)",
           %{conn: conn} do
        sql = "SELECT id, name FROM stream_items WHERE id = ?1 AND name = ?2;"
        params = [1]
        {:ok, stream_handle} = NIF.stream_open(conn, sql, params, [])
        assert :done == NIF.stream_fetch(stream_handle, 1)
        assert :ok == NIF.stream_close(stream_handle)
      end

      # --- stream_close/1 Tests ---
      test "stream_close/1 successfully closes an open stream (re-verify)", %{conn: conn} do
        sql = "SELECT id FROM stream_items;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_close/1 is idempotent (re-verify)", %{conn: conn} do
        sql = "SELECT id FROM stream_items;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        :ok = NIF.stream_close(stream_handle)
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_get_columns/1 still returns columns after stream_close/1 (re-verify)", %{
        conn: conn
      } do
        sql = "SELECT name FROM stream_items;"
        expected_columns = ["name"]
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        # Pin here is fine if expected_columns is defined once
        assert {:ok, expected_columns} == NIF.stream_get_columns(stream_handle)

        assert :ok == NIF.stream_close(stream_handle)
        # Pin here is fine
        assert {:ok, expected_columns} == NIF.stream_get_columns(stream_handle)
      end

      test "stream_close/1 on an invalid handle type returns an error (re-verify)", %{
        conn: conn
      } do
        # This error will be {:error, {:invalid_stream_handle, "reason"}}
        assert {:error, {:invalid_stream_handle, _reason}} = NIF.stream_close(conn)
      end

      test "stream_close/1 on a dummy reference returns an error (re-verify)", %{conn: _conn} do
        dummy_ref = make_ref()
        assert {:error, {:invalid_stream_handle, _reason}} = NIF.stream_close(dummy_ref)
      end
    end
  end

  # --- Isolated Test Case (Updated for new batch_size contract) ---
  test "isolated: stream_fetch behavior with exhaustion and invalid batch_size" do
    assert {:ok, conn} = NIF.open_in_memory()
    assert {:ok, 0} = NIF.execute(conn, "CREATE TABLE iso_items (id INTEGER PRIMARY KEY);", [])
    assert {:ok, 1} = NIF.execute(conn, "INSERT INTO iso_items (id) VALUES (1);", [])
    assert {:ok, 1} = NIF.execute(conn, "INSERT INTO iso_items (id) VALUES (2);", [])

    sql = "SELECT id FROM iso_items ORDER BY id LIMIT 2;"
    {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])

    assert {:error, {:invalid_batch_size, %{provided: "0", minimum: 1}}} ==
             NIF.stream_fetch(stream_handle, 0),
           "Fetch (batch 0 should error)"

    assert {:error, {:invalid_batch_size, %{provided: "-1", minimum: 1}}} ==
             NIF.stream_fetch(stream_handle, -1),
           "Fetch (batch -1 should error)"

    assert {:ok, %{rows: [[1], [2]]}} == NIF.stream_fetch(stream_handle, 2),
           "Fetch (batch 2 - consume all)"

    assert :done == NIF.stream_fetch(stream_handle, 1), "Fetch (batch 1 - after done)"

    assert :ok == NIF.stream_close(stream_handle)
    assert :ok == NIF.close(conn)
  end
end
