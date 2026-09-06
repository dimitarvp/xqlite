defmodule Xqlite.NIF.SecurityGuideTest do
  # The extension snippet of `guides/security.md`, run with its published
  # return shapes so the guide cannot rot silently.
  use ExUnit.Case, async: true

  import Xqlite.ConnCase
  import Xqlite.TestUtil, only: [test_extension_path: 0]

  for_each_opener "security_guide" do
    test "enable, load, disable — the guide's extension snippet", %{conn: conn} do
      assert :ok = Xqlite.enable_load_extension(conn, true)
      assert :ok = Xqlite.load_extension(conn, test_extension_path())
      assert :ok = Xqlite.enable_load_extension(conn, false)

      assert {:ok, %{rows: [["xqlite_ext_ok"]]}} =
               Xqlite.query(conn, "SELECT xqlite_test_ext()")
    end
  end
end
