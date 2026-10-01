defmodule Xqlite.NIF.LoadExtensionTest do
  use ExUnit.Case, async: true

  import Xqlite.ConnCase
  import Xqlite.TestUtil, only: [test_extension_path: 0]

  alias XqliteNIF, as: NIF

  for_each_opener "load_extension" do
    # -------------------------------------------------------------------
    # enable_load_extension
    # -------------------------------------------------------------------

    test "enable then disable succeeds", %{conn: conn} do
      assert :ok = NIF.enable_load_extension(conn, true)
      assert :ok = NIF.enable_load_extension(conn, false)
    end

    test "disable without prior enable succeeds", %{conn: conn} do
      assert :ok = NIF.enable_load_extension(conn, false)
    end

    test "Xqlite's two switches gate loading, and entry_point reaches SQLite", %{conn: conn} do
      assert :ok = Xqlite.enable_load_extension(conn)

      assert {:error, _} =
               Xqlite.load_extension(conn, test_extension_path(), entry_point: "no_such_init")

      assert :ok = Xqlite.disable_load_extension(conn)

      assert {:error, :extension_loading_disabled} =
               Xqlite.load_extension(conn, test_extension_path())
    end

    test "enable is idempotent", %{conn: conn} do
      assert :ok = NIF.enable_load_extension(conn, true)
      assert :ok = NIF.enable_load_extension(conn, true)
      NIF.enable_load_extension(conn, false)
    end

    # -------------------------------------------------------------------
    # load_extension — happy path
    # -------------------------------------------------------------------

    test "load test extension and call its function", %{conn: conn} do
      :ok = NIF.enable_load_extension(conn, true)
      assert :ok = NIF.load_extension(conn, test_extension_path(), nil)
      :ok = NIF.enable_load_extension(conn, false)

      assert {:ok, %{rows: [["xqlite_ext_ok"]]}} =
               NIF.query(conn, "SELECT xqlite_test_ext()", [])
    end

    test "load extension with explicit entry point", %{conn: conn} do
      :ok = NIF.enable_load_extension(conn, true)

      assert :ok =
               NIF.load_extension(
                 conn,
                 test_extension_path(),
                 "sqlite3_xqlitetestext_init"
               )

      :ok = NIF.enable_load_extension(conn, false)

      assert {:ok, %{rows: [["xqlite_ext_ok"]]}} =
               NIF.query(conn, "SELECT xqlite_test_ext()", [])
    end

    test "load extension with nil entry point auto-detects", %{conn: conn} do
      :ok = NIF.enable_load_extension(conn, true)
      assert :ok = NIF.load_extension(conn, test_extension_path(), nil)
      :ok = NIF.enable_load_extension(conn, false)

      assert {:ok, %{rows: [["xqlite_ext_ok"]]}} =
               NIF.query(conn, "SELECT xqlite_test_ext()", [])
    end

    test "extension function persists across queries", %{conn: conn} do
      :ok = NIF.enable_load_extension(conn, true)
      :ok = NIF.load_extension(conn, test_extension_path(), nil)
      :ok = NIF.enable_load_extension(conn, false)

      assert {:ok, %{rows: [["xqlite_ext_ok"]]}} =
               NIF.query(conn, "SELECT xqlite_test_ext()", [])

      assert {:ok, %{rows: [["xqlite_ext_ok"]]}} =
               NIF.query(conn, "SELECT xqlite_test_ext()", [])
    end

    test "disable after load does not unload the extension", %{conn: conn} do
      :ok = NIF.enable_load_extension(conn, true)
      :ok = NIF.load_extension(conn, test_extension_path(), nil)
      :ok = NIF.enable_load_extension(conn, false)

      # Extension function should still work after disabling load permission
      assert {:ok, %{rows: [["xqlite_ext_ok"]]}} =
               NIF.query(conn, "SELECT xqlite_test_ext()", [])
    end

    test "extension function works in expressions", %{conn: conn} do
      :ok = NIF.enable_load_extension(conn, true)
      :ok = NIF.load_extension(conn, test_extension_path(), nil)
      :ok = NIF.enable_load_extension(conn, false)

      assert {:ok, %{rows: [[13]]}} =
               NIF.query(conn, "SELECT LENGTH(xqlite_test_ext())", [])
    end

    # -------------------------------------------------------------------
    # load_extension — error cases
    # -------------------------------------------------------------------

    test "load without enabling returns :extension_loading_disabled", %{conn: conn} do
      assert {:error, :extension_loading_disabled} =
               NIF.load_extension(conn, test_extension_path(), nil)
    end

    test "load nonexistent path returns error", %{conn: conn} do
      :ok = NIF.enable_load_extension(conn, true)
      assert {:error, _} = NIF.load_extension(conn, "/no/such/extension", nil)
      :ok = NIF.enable_load_extension(conn, false)
    end

    test "load with wrong entry point returns error", %{conn: conn} do
      :ok = NIF.enable_load_extension(conn, true)

      assert {:error, _} =
               NIF.load_extension(
                 conn,
                 test_extension_path(),
                 "nonexistent_entry_point"
               )

      :ok = NIF.enable_load_extension(conn, false)
    end

    test "calling unloaded extension function returns error", %{conn: conn} do
      assert {:error, _} =
               NIF.query(conn, "SELECT xqlite_test_ext()", [])
    end

    test "a load racing the switch is judged under the connection lock", %{conn: conn} do
      path = test_extension_path()
      loads = Task.async(fn -> for _ <- 1..500, do: NIF.load_extension(conn, path, nil) end)

      {:ok, answers} =
        Enum.find_value(Stream.cycle([true, false]), fn on ->
          :ok = NIF.enable_load_extension(conn, on)
          Task.yield(loads, 0)
        end)

      assert Enum.reject(answers, &(&1 in [:ok, {:error, :extension_loading_disabled}])) == []
    end
  end

  # -------------------------------------------------------------------
  # Edge cases outside the connection_openers loop
  # -------------------------------------------------------------------

  test "enable_load_extension on closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    NIF.close(conn)
    assert {:error, _} = NIF.enable_load_extension(conn, true)
  end

  test "load_extension on closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    NIF.close(conn)
    assert {:error, :connection_closed} = NIF.load_extension(conn, test_extension_path(), nil)
  end

  test "extension loaded on one connection is not visible on another" do
    {:ok, conn1} = NIF.open_in_memory(":memory:")
    {:ok, conn2} = NIF.open_in_memory(":memory:")

    :ok = NIF.enable_load_extension(conn1, true)
    :ok = NIF.load_extension(conn1, test_extension_path(), nil)
    :ok = NIF.enable_load_extension(conn1, false)

    # conn1 has the extension
    assert {:ok, %{rows: [["xqlite_ext_ok"]]}} =
             NIF.query(conn1, "SELECT xqlite_test_ext()", [])

    # conn2 does not
    assert {:error, _} = NIF.query(conn2, "SELECT xqlite_test_ext()", [])

    NIF.close(conn1)
    NIF.close(conn2)
  end

  test "loading same extension twice is idempotent" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    :ok = NIF.enable_load_extension(conn, true)
    :ok = NIF.load_extension(conn, test_extension_path(), nil)
    :ok = NIF.load_extension(conn, test_extension_path(), nil)
    :ok = NIF.enable_load_extension(conn, false)

    assert {:ok, %{rows: [["xqlite_ext_ok"]]}} =
             NIF.query(conn, "SELECT xqlite_test_ext()", [])

    NIF.close(conn)
  end
end
