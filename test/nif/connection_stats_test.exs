defmodule Xqlite.NIF.ConnectionStatsTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  @expected_keys [
    :lookaside_used,
    :cache_used,
    :schema_used,
    :stmt_used,
    :lookaside_hit,
    :lookaside_miss_size,
    :lookaside_miss_full,
    :cache_hit,
    :cache_miss,
    :cache_write,
    :deferred_fks,
    :cache_used_shared,
    :cache_spill,
    :tempbuf_spill
  ]

  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "returns all documented keys on a fresh connection", %{conn: conn} do
        assert {:ok, stats} = NIF.connection_stats(conn)

        for key <- @expected_keys do
          assert Map.has_key?(stats, key), "missing key #{inspect(key)}"
          assert is_integer(Map.fetch!(stats, key)), "#{inspect(key)} should be integer"
        end
      end

      test "all counters are non-negative on a fresh connection", %{conn: conn} do
        assert {:ok, stats} = NIF.connection_stats(conn)

        for {key, value} <- stats do
          assert value >= 0, "#{inspect(key)} = #{value}, expected non-negative"
        end
      end

      test "cache_hit increases after repeated SELECTs", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER); INSERT INTO t VALUES (1), (2)")

        # Prime the cache.
        {:ok, _} = NIF.query(conn, "SELECT * FROM t", [])
        assert {:ok, before} = NIF.connection_stats(conn)

        for _ <- 1..5 do
          {:ok, _} = NIF.query(conn, "SELECT * FROM t", [])
        end

        assert {:ok, later} = NIF.connection_stats(conn)
        assert later.cache_hit >= before.cache_hit
      end
    end
  end
end
