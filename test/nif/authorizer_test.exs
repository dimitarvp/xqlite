defmodule Xqlite.NIF.AuthorizerTest do
  use ExUnit.Case, async: true

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  for_each_opener "authorizer" do
    setup %{conn: conn} do
      :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT);")
      {:ok, 1} = NIF.execute(conn, "INSERT INTO t(id, name) VALUES (1, 'a')", [])
      :ok
    end

    test "denying :delete blocks DELETE but leaves SELECT working", %{conn: conn} do
      :ok = Xqlite.set_authorizer(conn, [:delete])

      assert {:error, {:authorization_denied, msg}} =
               NIF.execute(conn, "DELETE FROM t WHERE id = 1", [])

      assert is_binary(msg)

      assert {:ok, %{rows: [[1, "a"]], num_rows: 1}} =
               NIF.query(conn, "SELECT id, name FROM t", [])
    end

    test "denying :create_table blocks CREATE TABLE; removal restores it", %{conn: conn} do
      :ok = Xqlite.set_authorizer(conn, [:create_table])

      assert {:error, {:authorization_denied, _}} =
               NIF.execute(conn, "CREATE TABLE t2(x INTEGER)", [])

      :ok = Xqlite.remove_authorizer(conn)

      # Succeeds now; the affected-row count is `sqlite3_changes()`, which is
      # sticky across DDL (see CLAUDE.md), so we only assert on success here.
      assert {:ok, _} = NIF.execute(conn, "CREATE TABLE t2(x INTEGER)", [])

      assert {:ok, %{rows: [["t2"]]}} =
               NIF.query(conn, "SELECT name FROM sqlite_schema WHERE name = 't2'", [])
    end

    test "denying :pragma makes get_pragma and set_pragma fail", %{conn: conn} do
      :ok = Xqlite.set_authorizer(conn, [:pragma])

      assert {:error, {:authorization_denied, _}} = NIF.get_pragma(conn, "user_version")

      assert {:error, {:authorization_denied, _}} =
               NIF.set_pragma(conn, "user_version", 7)
    end

    test "re-installing replaces the previous deny-list", %{conn: conn} do
      :ok = Xqlite.set_authorizer(conn, [:delete])
      :ok = Xqlite.set_authorizer(conn, [:insert])

      # DELETE is allowed again under the replacement list...
      assert {:ok, 1} = NIF.execute(conn, "DELETE FROM t WHERE id = 1", [])

      # ...while INSERT is now the denied action.
      assert {:error, {:authorization_denied, _}} =
               NIF.execute(conn, "INSERT INTO t(id, name) VALUES (2, 'b')", [])
    end

    test "unrecognized atom is a structured error and installs nothing", %{conn: conn} do
      assert {:error, {:invalid_authorizer_action, :bogus}} =
               Xqlite.set_authorizer(conn, [:delete, :bogus])

      # Validation is atomic: with nothing installed, DELETE still works.
      assert {:ok, 1} = NIF.execute(conn, "DELETE FROM t WHERE id = 1", [])
    end

    test "an authorizer is scoped to its own connection", %{conn: conn} do
      {:ok, other} = NIF.open_in_memory(":memory:")
      :ok = NIF.execute_batch(other, "CREATE TABLE u(id INTEGER PRIMARY KEY);")
      {:ok, 1} = NIF.execute(other, "INSERT INTO u(id) VALUES (1)", [])

      :ok = Xqlite.set_authorizer(conn, [:delete])

      # Denied on `conn`...
      assert {:error, {:authorization_denied, _}} =
               NIF.execute(conn, "DELETE FROM t WHERE id = 1", [])

      # ...but the independent `other` connection is untouched.
      assert {:ok, 1} = NIF.execute(other, "DELETE FROM u WHERE id = 1", [])

      :ok = NIF.close(other)
    end

    test "remove_authorizer is idempotent when none is installed", %{conn: conn} do
      assert :ok = Xqlite.remove_authorizer(conn)
      assert :ok = Xqlite.remove_authorizer(conn)
    end
  end

  # -------------------------------------------------------------------
  # Edge cases unrelated to connection mode
  # -------------------------------------------------------------------

  test "set/remove on a closed connection returns the closed-connection error" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    :ok = NIF.close(conn)

    assert {:error, :connection_closed} = Xqlite.set_authorizer(conn, [:delete])
    assert {:error, :connection_closed} = Xqlite.remove_authorizer(conn)
  end
end
