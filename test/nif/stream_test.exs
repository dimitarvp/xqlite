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

        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "INSERT INTO stream_items (id, name, price) VALUES (1, 'Item 1', 10.99);",
                   []
                 )

        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "INSERT INTO stream_items (id, name, price) VALUES (2, 'Item 2', 5.50);",
                   []
                 )

        on_exit(fn ->
          NIF.close(conn)
        end)

        {:ok, conn: conn}
      end

      # --- stream_open/4 Tests (Revisited with stream_get_columns) ---
      test "stream_open/4 with valid SQL returns a handle and correct columns", %{conn: conn} do
        sql = "SELECT id, name, price FROM stream_items;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert is_reference(stream_handle)
        assert {:ok, ["id", "name", "price"]} == NIF.stream_get_columns(stream_handle)
      end

      test "stream_open/4 with positional parameters returns a handle and correct columns", %{
        conn: conn
      } do
        sql = "SELECT name, price FROM stream_items WHERE id = ?1;"
        params = [1]
        {:ok, stream_handle} = NIF.stream_open(conn, sql, params, [])
        assert is_reference(stream_handle)
        assert {:ok, ["name", "price"]} == NIF.stream_get_columns(stream_handle)
      end

      test "stream_open/4 with named parameters returns a handle and correct columns", %{
        conn: conn
      } do
        sql = "SELECT id FROM stream_items WHERE name = :item_name;"
        params = [item_name: "Item 2"]
        {:ok, stream_handle} = NIF.stream_open(conn, sql, params, [])
        assert is_reference(stream_handle)
        assert {:ok, ["id"]} == NIF.stream_get_columns(stream_handle)
      end

      test "stream_open/4 with invalid SQL (syntax error) returns an error", %{conn: conn} do
        sql = "SELEKT id FROM stream_items;"
        assert {:error, error_details} = NIF.stream_open(conn, sql, [], [])

        assert match?({:sqlite_failure, _p_code, _e_code, _msg_str}, error_details)

        case error_details do
          {:sqlite_failure, _, _, msg_str} when is_binary(msg_str) ->
            assert String.contains?(msg_str, "syntax error")
            assert String.contains?(msg_str, "SELEKT")

          _ ->
            flunk(
              "Expected {:sqlite_failure, _, _, msg_with_syntax_error}, got: #{inspect(error_details)}"
            )
        end
      end

      test "stream_open/4 with SQL for non-existent table returns an error", %{conn: conn} do
        sql = "SELECT id FROM non_existent_table_for_stream;"
        assert {:error, error_details} = NIF.stream_open(conn, sql, [], [])

        assert match?({:no_such_table, _msg}, error_details)

        case error_details do
          {:no_such_table, msg_str} when is_binary(msg_str) ->
            assert String.contains?(msg_str, "no such table")

          _ ->
            flunk("Expected {:no_such_table, _msg}, got: #{inspect(error_details)}")
        end
      end

      test "stream_open/4 with empty SQL string returns handle and empty columns", %{
        conn: conn
      } do
        sql = ""
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert is_reference(stream_handle)
        assert {:ok, []} == NIF.stream_get_columns(stream_handle)
      end

      test "stream_open/4 with comments-only SQL returns handle and empty columns", %{
        conn: conn
      } do
        sql = "-- This is just a comment;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert is_reference(stream_handle)
        assert {:ok, []} == NIF.stream_get_columns(stream_handle)
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
      end

      test "stream_open/4 with too many positional params returns an error", %{conn: conn} do
        sql = "SELECT id FROM stream_items WHERE id = ?1;"
        params = [1, "extra_param"]
        assert {:error, error_details} = NIF.stream_open(conn, sql, params, [])

        case error_details do
          {:sqlite_failure, _primary_code, 25, _msg} -> :ok
          _ -> flunk("Expected SQLITE_RANGE (25) error, got: #{inspect(error_details)}")
        end
      end

      # --- stream_get_columns/1 Tests ---
      test "stream_get_columns/1 returns correct columns for a select all query", %{conn: conn} do
        sql = "SELECT * FROM stream_items WHERE id = 1;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert {:ok, ["id", "name", "price"]} == NIF.stream_get_columns(stream_handle)
      end

      test "stream_get_columns/1 returns correct columns for a query with specific columns", %{
        conn: conn
      } do
        sql = "SELECT price, name FROM stream_items WHERE id = 1;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert {:ok, ["price", "name"]} == NIF.stream_get_columns(stream_handle)
      end

      test "stream_get_columns/1 returns empty list for stream from empty SQL", %{conn: conn} do
        sql = ""
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert {:ok, []} == NIF.stream_get_columns(stream_handle)
      end

      # --- stream_close/1 Tests ---
      test "stream_close/1 successfully closes an open stream", %{conn: conn} do
        sql = "SELECT id FROM stream_items;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_close/1 is idempotent", %{conn: conn} do
        sql = "SELECT id FROM stream_items;"
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert :ok == NIF.stream_close(stream_handle)
        # Call again
        assert :ok == NIF.stream_close(stream_handle)
      end

      test "stream_get_columns/1 still returns columns after stream_close/1", %{conn: conn} do
        sql = "SELECT name FROM stream_items;"
        expected_columns = ["name"]
        {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert {:ok, expected_columns} == NIF.stream_get_columns(stream_handle)

        assert :ok == NIF.stream_close(stream_handle)
        # Column information is part of the Rust struct and persists even after the
        # underlying SQLite statement is finalized.
        assert {:ok, expected_columns} == NIF.stream_get_columns(stream_handle)
      end

      test "stream_close/1 on an invalid handle type returns an error", %{conn: conn} do
        # Pass the connection resource itself instead of a stream handle
        assert {:error, {:invalid_stream_handle, _reason}} = NIF.stream_close(conn)
      end

      test "stream_close/1 on a dummy reference returns an error", %{conn: _conn} do
        dummy_ref = make_ref()
        assert {:error, {:invalid_stream_handle, _reason}} = NIF.stream_close(dummy_ref)
      end

      # NOTE: Testing GC and Drop behavior is complex and less deterministic in unit tests.
      # We rely on the Rust Drop trait implementation for fallback cleanup.
      # Explicit stream_close is the primary way resources should be managed by users
      # of the NIFs directly, or by Stream.resource when using the Elixir wrapper.
    end
  end
end
