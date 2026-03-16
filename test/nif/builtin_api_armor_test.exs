defmodule Xqlite.NIF.BuiltinApiArmorTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  test "ENABLE_API_ARMOR is present in compile options" do
    {:ok, conn} = NIF.open_in_memory()

    assert {:ok, options} = NIF.compile_options(conn)
    assert "ENABLE_API_ARMOR" in options

    NIF.close(conn)
  end

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "API_ARMOR raw FFI safety using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "stream_close mid-iteration finalizes cleanly", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE aa_mid (id INTEGER);")

        for i <- 1..100 do
          {:ok, 1} = NIF.execute(conn, "INSERT INTO aa_mid VALUES (?1)", [i])
        end

        {:ok, stream} = NIF.stream_open(conn, "SELECT * FROM aa_mid", [], [])

        assert {:ok, %{rows: rows}} = NIF.stream_fetch(stream, 5)
        assert length(rows) == 5

        assert :ok = NIF.stream_close(stream)
        assert :done = NIF.stream_fetch(stream, 10)
        assert :ok = NIF.stream_close(stream)
      end

      test "rapid stream open/close cycles", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE aa_cycle (id INTEGER);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO aa_cycle VALUES (1)", [])

        for _ <- 1..50 do
          {:ok, stream} = NIF.stream_open(conn, "SELECT * FROM aa_cycle", [], [])
          assert {:ok, %{rows: [[1]]}} = NIF.stream_fetch(stream, 10)
          assert :done = NIF.stream_fetch(stream, 10)
          assert :ok = NIF.stream_close(stream)
        end
      end
    end
  end
end
