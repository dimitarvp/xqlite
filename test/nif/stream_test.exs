defmodule Xqlite.NIF.StreamTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]
  alias XqliteNIF, as: NIF

  # --- Shared test code (generated via `for` loop for different DB types) ---
  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "#{prefix} streaming" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        assert {:ok, 0} =
                 NIF.execute(
                   conn,
                   "CREATE TABLE stream_items (id INTEGER PRIMARY KEY, name TEXT);",
                   []
                 )

        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "INSERT INTO stream_items (id, name) VALUES (1, 'Item 1');",
                   []
                 )

        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "INSERT INTO stream_items (id, name) VALUES (2, 'Item 2');",
                   []
                 )

        on_exit(fn ->
          NIF.close(conn)
        end)

        {:ok, conn: conn}
      end

      # --- stream_open/4 Tests ---
      test "stream_open/4 with valid SQL returns a stream handle resource", %{conn: conn} do
        sql = "SELECT id, name FROM stream_items;"
        assert {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert is_reference(stream_handle)
      end

      test "stream_open/4 with valid SQL and positional parameters returns a handle", %{
        conn: conn
      } do
        sql = "SELECT id, name FROM stream_items WHERE id = ?1;"
        params = [1]
        assert {:ok, stream_handle} = NIF.stream_open(conn, sql, params, [])
        assert is_reference(stream_handle)
      end

      test "stream_open/4 with valid SQL and named parameters returns a handle", %{conn: conn} do
        sql = "SELECT id, name FROM stream_items WHERE id = :item_id;"
        params = [item_id: 1]
        assert {:ok, stream_handle} = NIF.stream_open(conn, sql, params, [])
        assert is_reference(stream_handle)
      end

      test "stream_open/4 with invalid SQL (syntax error) returns an error", %{conn: conn} do
        # Intentional syntax error
        sql = "SELEKT id FROM stream_items;"
        assert {:error, error_details} = NIF.stream_open(conn, sql, [], [])

        # We expect :sqlite_failure with specific codes if known,
        # or at least a message containing "syntax error".
        # The primary code for "syntax error" from prepare is typically SQLITE_ERROR (1).
        # Let's assert the pattern and then the message content.
        assert match?({:sqlite_failure, _code, _ext_code, _msg}, error_details)

        case error_details do
          # We can be specific about the primary code if it's consistently SQLITE_ERROR (1)
          # For now, let's focus on the message which is very indicative.
          {:sqlite_failure, _p_code, _e_code, msg_str} when is_binary(msg_str) ->
            assert String.contains?(msg_str, "syntax error")
            # Check for the offending token
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

      test "stream_open/4 with empty SQL string returns a stream handle (for an empty stream)",
           %{conn: conn} do
        sql = ""
        assert {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert is_reference(stream_handle)
      end

      test "stream_open/4 with comments-only SQL returns a stream handle (for an empty stream)",
           %{conn: conn} do
        sql = "-- This is just a comment;"
        assert {:ok, stream_handle} = NIF.stream_open(conn, sql, [], [])
        assert is_reference(stream_handle)
      end

      test "stream_open/4 with invalid parameter name (named params) returns an error", %{
        conn: conn
      } do
        sql = "SELECT id FROM stream_items WHERE name = :name;"
        params = [name: "Item 1", unexpected_param_name: "foo"]

        assert {:error, {:invalid_parameter_name, ":unexpected_param_name"}} =
                 NIF.stream_open(conn, sql, params, [])
      end

      test "stream_open/4 with invalid parameter count (too few positional) is okay at open",
           %{conn: conn} do
        sql = "SELECT id FROM stream_items WHERE id = ?1 AND name = ?2;"
        params = [1]

        # As discussed, this should now be okay at open time, error will be at fetch if ?2 is used.
        # If SQLite was strict about sqlite3_bind_parameter_count vs actual params bound,
        # and if our FFI binding only binds params.len(), this is fine.
        # The error would manifest if sqlite3_step requires the unbound parameter.
        assert {:ok, stream_handle} = NIF.stream_open(conn, sql, params, [])
        assert is_reference(stream_handle)
      end

      test "stream_open/4 with invalid parameter count (too many positional) returns an error",
           %{conn: conn} do
        sql = "SELECT id FROM stream_items WHERE id = ?1;"
        # "extra_param" would be ?2, which is out of range for the SQL
        params = [1, "extra_param"]

        # Expect SQLITE_RANGE (25) from trying to bind the second parameter ("extra_param")
        # to a non-existent second placeholder in the SQL.
        # Our XqliteError::from(rusqlite_err) should map this.
        # The rusqlite error often looks like:
        # SqliteFailure(Error { code: Range, extended_code: 25 }, Some("column index out of range"))
        # Or from ffi: Error { code: Range, extended_code: 25 } with a message like "parameter index out of range"
        # Let's assert for the specific XqliteError if we have one, or a SqliteFailure with code 25.
        assert {:error, error_details} = NIF.stream_open(conn, sql, params, [])

        case error_details do
          # SQLITE_RANGE extended code is 25
          {:sqlite_failure, _primary_code, 25, _msg} -> :ok
          _ -> flunk("Expected SQLITE_RANGE (25) error, got: #{inspect(error_details)}")
        end
      end
    end
  end
end
