defmodule Xqlite.NIF.ProgressHookTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "#{prefix}: register / unregister basics" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "register returns {:ok, integer_handle}", %{conn: conn} do
        assert {:ok, handle} = NIF.register_progress_hook(conn, self(), 100, nil)
        assert is_integer(handle) and handle > 0
        :ok = NIF.unregister_progress_hook(conn, handle)
      end

      test "every_n must be >= 1", %{conn: conn} do
        assert {:error, _} = NIF.register_progress_hook(conn, self(), 0, nil)
      end

      test "register multiple subscribers returns distinct handles", %{conn: conn} do
        {:ok, h1} = NIF.register_progress_hook(conn, self(), 100, nil)
        {:ok, h2} = NIF.register_progress_hook(conn, self(), 200, nil)
        {:ok, h3} = NIF.register_progress_hook(conn, self(), 50, nil)

        assert h1 != h2
        assert h2 != h3
        assert h1 != h3

        :ok = NIF.unregister_progress_hook(conn, h1)
        :ok = NIF.unregister_progress_hook(conn, h2)
        :ok = NIF.unregister_progress_hook(conn, h3)
      end

      test "unregister with unknown handle is a no-op (idempotent)", %{conn: conn} do
        assert :ok = NIF.unregister_progress_hook(conn, 999_999)
        {:ok, h} = NIF.register_progress_hook(conn, self(), 100, nil)
        :ok = NIF.unregister_progress_hook(conn, h)
        # Already unregistered — second call still :ok.
        assert :ok = NIF.unregister_progress_hook(conn, h)
      end
    end

    describe "#{prefix}: tick delivery" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "fires {:xqlite_progress, count, elapsed_ms} (no tag)", %{conn: conn} do
        {:ok, handle} = NIF.register_progress_hook(conn, self(), 1, nil)

        :ok = run_workload(conn)

        assert_receive {:xqlite_progress, count, elapsed_ms}, 2_000
        assert is_integer(count) and count >= 0
        assert is_integer(elapsed_ms) and elapsed_ms >= 0

        :ok = NIF.unregister_progress_hook(conn, handle)
      end

      test "fires {:xqlite_progress, tag, count, elapsed_ms} when tag set", %{conn: conn} do
        {:ok, handle} = NIF.register_progress_hook(conn, self(), 1, "worker_42")

        :ok = run_workload(conn)

        assert_receive {:xqlite_progress, :worker_42, count, _elapsed_ms}, 2_000
        assert is_integer(count) and count >= 0

        :ok = NIF.unregister_progress_hook(conn, handle)
      end

      test "decimation: every_n=10 emits ~10× fewer events than every_n=1",
           %{conn: conn} do
        {:ok, h1} = NIF.register_progress_hook(conn, self(), 1, "tight")
        {:ok, h10} = NIF.register_progress_hook(conn, self(), 10, "loose")

        :ok = run_workload(conn)
        Process.sleep(50)

        msgs = drain_progress_messages()

        tight_count = Enum.count(msgs, fn {tag, _, _} -> tag == :tight end)
        loose_count = Enum.count(msgs, fn {tag, _, _} -> tag == :loose end)

        assert tight_count > 0
        assert loose_count > 0
        # Every callback fire emits a tight tick. Loose subscribers
        # emit on n=0, 10, 20, 30, ... — roughly tight/10 events.
        # Be lenient: 5x ratio at minimum.
        assert tight_count >= loose_count * 5

        :ok = NIF.unregister_progress_hook(conn, h1)
        :ok = NIF.unregister_progress_hook(conn, h10)
      end

      test "count is monotonically non-decreasing within a subscriber",
           %{conn: conn} do
        {:ok, handle} = NIF.register_progress_hook(conn, self(), 1, "mono")

        :ok = run_workload(conn)
        Process.sleep(50)

        msgs = drain_progress_messages()
        counts = msgs |> Enum.map(fn {_, c, _} -> c end)

        assert length(counts) > 1

        Enum.zip(counts, tl(counts))
        |> Enum.each(fn {a, b} -> assert b >= a, "count went backwards: #{a} -> #{b}" end)

        :ok = NIF.unregister_progress_hook(conn, handle)
      end
    end

    describe "#{prefix}: multi-subscriber semantics" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "two subscribers each receive their own messages", %{conn: conn} do
        {:ok, h1} = NIF.register_progress_hook(conn, self(), 1, "alpha")
        {:ok, h2} = NIF.register_progress_hook(conn, self(), 1, "beta")

        :ok = run_workload(conn)
        Process.sleep(50)

        msgs = drain_progress_messages()
        alpha_count = Enum.count(msgs, fn {tag, _, _} -> tag == :alpha end)
        beta_count = Enum.count(msgs, fn {tag, _, _} -> tag == :beta end)

        assert alpha_count > 0
        assert beta_count > 0

        :ok = NIF.unregister_progress_hook(conn, h1)
        :ok = NIF.unregister_progress_hook(conn, h2)
      end

      test "unregistering one subscriber leaves the other working", %{conn: conn} do
        {:ok, h1} = NIF.register_progress_hook(conn, self(), 1, "kept")
        {:ok, h2} = NIF.register_progress_hook(conn, self(), 1, "removed")

        :ok = NIF.unregister_progress_hook(conn, h2)

        :ok = run_workload(conn)
        Process.sleep(50)

        msgs = drain_progress_messages()
        kept_count = Enum.count(msgs, fn {tag, _, _} -> tag == :kept end)
        removed_count = Enum.count(msgs, fn {tag, _, _} -> tag == :removed end)

        assert kept_count > 0
        assert removed_count == 0

        :ok = NIF.unregister_progress_hook(conn, h1)
      end

      test "different pids each receive only their own subscriber's events",
           %{conn: conn} do
        listener_a = spawn_collector()
        listener_b = spawn_collector()

        {:ok, h_a} = NIF.register_progress_hook(conn, listener_a, 1, "a")
        {:ok, h_b} = NIF.register_progress_hook(conn, listener_b, 1, "b")

        :ok = run_workload(conn)
        Process.sleep(50)

        msgs_a = get_collected(listener_a)
        msgs_b = get_collected(listener_b)

        assert length(msgs_a) > 0
        assert length(msgs_b) > 0
        # Each listener must only see its own tag.
        assert Enum.all?(msgs_a, fn {tag, _, _} -> tag == :a end)
        assert Enum.all?(msgs_b, fn {tag, _, _} -> tag == :b end)

        :ok = NIF.unregister_progress_hook(conn, h_a)
        :ok = NIF.unregister_progress_hook(conn, h_b)
      end
    end

    describe "#{prefix}: subscription-API contract" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "dead subscriber pid does not crash or block siblings", %{conn: conn} do
        dead = spawn(fn -> :ok end)
        ref = Process.monitor(dead)
        receive do: ({:DOWN, ^ref, :process, ^dead, _} -> :ok)

        live = spawn_collector()

        {:ok, h_dead} = NIF.register_progress_hook(conn, dead, 1, "dead_tag")
        {:ok, h_live} = NIF.register_progress_hook(conn, live, 1, "live_tag")

        :ok = run_workload(conn)
        Process.sleep(50)

        msgs = get_collected(live)
        assert length(msgs) > 0
        # Live sibling sees only its own tag.
        assert Enum.all?(msgs, fn {tag, _, _} -> tag == :live_tag end)

        :ok = NIF.unregister_progress_hook(conn, h_dead)
        :ok = NIF.unregister_progress_hook(conn, h_live)
      end

      test "GenServer-like process forwards progress events", %{conn: conn} do
        test_pid = self()

        forwarder =
          spawn(fn ->
            forwarder_loop(test_pid)
          end)

        {:ok, handle} = NIF.register_progress_hook(conn, forwarder, 1, "fwd")

        :ok = run_workload(conn)

        assert_receive {:forwarded_progress, {:xqlite_progress, :fwd, _, _}}, 2_000

        :ok = NIF.unregister_progress_hook(conn, handle)
      end

      test "concurrent register/unregister from multiple tasks does not crash",
           %{conn: conn} do
        tasks =
          Enum.map(1..10, fn _ ->
            Task.async(fn ->
              for _ <- 1..20 do
                {:ok, h} =
                  NIF.register_progress_hook(conn, self(), 100, nil)

                NIF.unregister_progress_hook(conn, h)
              end
            end)
          end)

        Task.await_many(tasks, 10_000)

        {:ok, h} = NIF.register_progress_hook(conn, self(), 1, "post_concurrent")
        :ok = run_workload(conn)
        assert_receive {:xqlite_progress, :post_concurrent, _, _}, 2_000
        :ok = NIF.unregister_progress_hook(conn, h)
      end

      test "survives 50 rapid register/unregister cycles", %{conn: conn} do
        for _ <- 1..50 do
          {:ok, h} = NIF.register_progress_hook(conn, self(), 1, "cycle")
          :ok = NIF.unregister_progress_hook(conn, h)
        end

        {:ok, h} = NIF.register_progress_hook(conn, self(), 1, "final")
        :ok = run_workload(conn)
        assert_receive {:xqlite_progress, :final, _, _}, 2_000
        :ok = NIF.unregister_progress_hook(conn, h)
      end
    end
  end

  describe "closed connection" do
    test "register on closed connection returns error" do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      :ok = NIF.close(conn)

      assert {:error, :connection_closed} =
               NIF.register_progress_hook(conn, self(), 100, nil)
    end

    test "unregister on closed connection returns error" do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      :ok = NIF.close(conn)
      assert {:error, :connection_closed} = NIF.unregister_progress_hook(conn, 1)
    end
  end

  describe "per-connection isolation" do
    test "subscriber on conn1 does not fire for conn2 queries" do
      {:ok, conn1} = NIF.open_in_memory(":memory:")
      {:ok, conn2} = NIF.open_in_memory(":memory:")

      on_exit(fn ->
        NIF.close(conn1)
        NIF.close(conn2)
      end)

      listener1 = spawn_collector()
      {:ok, _h1} = NIF.register_progress_hook(conn1, listener1, 1, "c1")

      :ok = run_workload(conn2)
      Process.sleep(50)

      assert get_collected(listener1) == []
    end
  end

  describe "cancel + tick coexistence" do
    setup do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(conn) end)
      :ok = NIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

      for i <- 1..2_000 do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (?1)", [i])
      end

      {:ok, conn: conn}
    end

    test "cancel signal interrupts query while tick subscriber is registered",
         %{conn: conn} do
      {:ok, tick_h} = NIF.register_progress_hook(conn, self(), 1, "co_tick")

      {:ok, token} = NIF.create_cancel_token()
      :ok = NIF.cancel_operation(token)

      assert {:error, :operation_cancelled} =
               NIF.query_cancellable(
                 conn,
                 "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT count(*) FROM n",
                 [],
                 [token]
               )

      :ok = NIF.unregister_progress_hook(conn, tick_h)
    end

    test "tick subscriber fires during a cancellable query (no cancel signal)",
         %{conn: conn} do
      {:ok, tick_h} = NIF.register_progress_hook(conn, self(), 1, "co_tick2")
      {:ok, token} = NIF.create_cancel_token()

      {:ok, _} =
        NIF.query_cancellable(
          conn,
          "SELECT count(*) FROM t",
          [],
          [token]
        )

      assert_receive {:xqlite_progress, :co_tick2, _, _}, 2_000

      :ok = NIF.unregister_progress_hook(conn, tick_h)
    end
  end

  describe "Xqlite.register_progress_hook/3 wrapper" do
    setup do
      {:ok, conn} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(conn) end)
      {:ok, conn: conn}
    end

    test "accepts atom tag and converts to string for the NIF", %{conn: conn} do
      {:ok, handle} =
        Xqlite.register_progress_hook(conn, self(), every_n: 1, tag: :worker_99)

      :ok = run_workload(conn)
      assert_receive {:xqlite_progress, :worker_99, _, _}, 2_000

      :ok = Xqlite.unregister_progress_hook(conn, handle)
    end

    test "default every_n=1000, no tag", %{conn: conn} do
      {:ok, handle} = Xqlite.register_progress_hook(conn, self())

      # With every_n=1000 and a small workload we may or may not see ticks;
      # smoke test only — confirm no crash and clean unregister.
      :ok = run_workload(conn)
      :ok = Xqlite.unregister_progress_hook(conn, handle)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp run_workload(conn) do
    :ok = NIF.execute_batch(conn, "CREATE TABLE IF NOT EXISTS pw(id INTEGER PRIMARY KEY)")

    for i <- 1..200 do
      {:ok, 1} = NIF.execute(conn, "INSERT OR IGNORE INTO pw VALUES (?1)", [i])
    end

    {:ok, _} = NIF.query(conn, "SELECT * FROM pw", [])
    :ok = NIF.execute_batch(conn, "DROP TABLE pw")
    :ok
  end

  defp drain_progress_messages do
    do_drain([])
  end

  defp do_drain(acc) do
    receive do
      {:xqlite_progress, tag, count, elapsed_ms} ->
        do_drain([{tag, count, elapsed_ms} | acc])

      {:xqlite_progress, count, elapsed_ms} ->
        do_drain([{nil, count, elapsed_ms} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp spawn_collector do
    spawn(fn -> collector_loop([]) end)
  end

  defp collector_loop(acc) do
    receive do
      {:get, from} ->
        send(from, {:collected, Enum.reverse(acc)})
        collector_loop(acc)

      {:xqlite_progress, tag, count, elapsed_ms} ->
        collector_loop([{tag, count, elapsed_ms} | acc])

      {:xqlite_progress, count, elapsed_ms} ->
        collector_loop([{nil, count, elapsed_ms} | acc])
    end
  end

  defp get_collected(pid) do
    send(pid, {:get, self()})

    receive do
      {:collected, msgs} -> msgs
    after
      500 -> []
    end
  end

  defp forwarder_loop(target) do
    receive do
      {:xqlite_progress, _, _, _} = event ->
        send(target, {:forwarded_progress, event})
        forwarder_loop(target)

      {:xqlite_progress, _, _} = event ->
        send(target, {:forwarded_progress, event})
        forwarder_loop(target)
    end
  end
end
