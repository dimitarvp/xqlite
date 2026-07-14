defmodule Xqlite.TypeExtensionInstantDurationTest do
  use ExUnit.Case, async: true

  alias Xqlite.TypeExtension
  alias XqliteNIF, as: NIF

  setup do
    {:ok, conn} = Xqlite.open_in_memory()
    on_exit(fn -> NIF.close(conn) end)

    :ok = NIF.execute_batch(conn, "CREATE TABLE t (v ANY);")
    {:ok, conn: conn}
  end

  describe "Instant" do
    test "encodes a DateTime to int64 nanoseconds since the epoch", %{conn: conn} do
      dt = ~U[2026-07-14 12:00:00.000000Z]
      expected_ns = DateTime.to_unix(dt, :nanosecond)

      assert {:ok, _} =
               Xqlite.execute(conn, "INSERT INTO t (v) VALUES (?1)", [dt],
                 type_extensions: [TypeExtension.Instant]
               )

      assert {:ok, %Xqlite.Result{rows: [[^expected_ns]]}} =
               Xqlite.query(conn, "SELECT v FROM t", [])
    end

    test "chain order decides between Instant and DateTime for the same struct", %{conn: conn} do
      dt = ~U[2026-01-01 00:00:00Z]

      {:ok, _} =
        Xqlite.execute(conn, "INSERT INTO t (v) VALUES (?1)", [dt],
          type_extensions: [TypeExtension.Instant, TypeExtension.DateTime]
        )

      {:ok, _} =
        Xqlite.execute(conn, "INSERT INTO t (v) VALUES (?1)", [dt],
          type_extensions: [TypeExtension.DateTime, TypeExtension.Instant]
        )

      assert {:ok, %Xqlite.Result{rows: [[first], [second]]}} =
               Xqlite.query(conn, "SELECT v FROM t ORDER BY rowid", [])

      assert first == DateTime.to_unix(dt, :nanosecond)
      assert second == DateTime.to_iso8601(dt)
    end

    test "there is no integer decode — stored instants read back as integers", %{conn: conn} do
      {:ok, _} = NIF.execute(conn, "INSERT INTO t (v) VALUES (1234567890)", [])

      assert {:ok, %Xqlite.Result{rows: [[1_234_567_890]]}} =
               Xqlite.query(conn, "SELECT v FROM t", [],
                 type_extensions: [TypeExtension.Instant]
               )
    end
  end

  if Code.ensure_loaded?(Duration) do
    describe "Duration" do
      test "encodes exact-unit durations to int64 nanoseconds", %{conn: conn} do
        d = Duration.new!(hour: 1, second: 30)

        assert {:ok, _} =
                 Xqlite.execute(conn, "INSERT INTO t (v) VALUES (?1)", [d],
                   type_extensions: [TypeExtension.Duration]
                 )

        assert {:ok, %Xqlite.Result{rows: [[3_630_000_000_000]]}} =
                 Xqlite.query(conn, "SELECT v FROM t", [])
      end

      test "microseconds convert at 1000 ns each", %{conn: conn} do
        d = Duration.new!(microsecond: {250, 6})

        assert {:ok, _} =
                 Xqlite.execute(conn, "INSERT INTO t (v) VALUES (?1)", [d],
                   type_extensions: [TypeExtension.Duration]
                 )

        assert {:ok, %Xqlite.Result{rows: [[250_000]]}} =
                 Xqlite.query(conn, "SELECT v FROM t", [])
      end

      test "calendar-unit durations are skipped and fail binding structurally", %{conn: conn} do
        d = Duration.new!(month: 1)

        assert {:error, _structured} =
                 Xqlite.execute(conn, "INSERT INTO t (v) VALUES (?1)", [d],
                   type_extensions: [TypeExtension.Duration]
                 )
      end
    end
  end
end
