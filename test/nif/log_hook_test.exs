defmodule Xqlite.NIF.LogHookTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  # The log hook is global (process-wide). Each test that registers a
  # subscriber stashes its handle in the test process dict via
  # `with_log_handle/2` and unregisters on test exit. Multi-subscriber
  # semantics means tests in this file don't interfere as long as
  # collectors are spawned per-test.

  describe "register_log_hook/1" do
    test "returns {:ok, integer_handle}" do
      with_log_handle(fn ->
        assert {:ok, h} = NIF.register_log_hook(self())
        assert is_integer(h) and h > 0
        h
      end)
    end

    test "two subscribers each get distinct handles" do
      {:ok, h1} = NIF.register_log_hook(self())
      {:ok, h2} = NIF.register_log_hook(self())
      assert h1 != h2
      :ok = NIF.unregister_log_hook(h1)
      :ok = NIF.unregister_log_hook(h2)
    end
  end

  describe "unregister_log_hook/1" do
    test "returns :ok after a hook was registered" do
      {:ok, h} = NIF.register_log_hook(self())
      assert :ok = NIF.unregister_log_hook(h)
    end

    test "is idempotent — unknown handle still :ok" do
      assert :ok = NIF.unregister_log_hook(999_999)
      {:ok, h} = NIF.register_log_hook(self())
      assert :ok = NIF.unregister_log_hook(h)
      assert :ok = NIF.unregister_log_hook(h)
    end
  end

  # --- Tests that use a single connection, run against all opener types ---

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "#{prefix}: log event delivery" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "delivers {:xqlite_log, code, message} to registered pid", %{conn: conn} do
        with_log_handle(fn ->
          {:ok, h} = NIF.register_log_hook(self())

          trigger_autoindex_warning(conn)

          assert_receive {:xqlite_log, code, message}, 2_000
          assert is_integer(code)
          assert is_binary(message)
          h
        end)
      end

      test "message contains autoindex context", %{conn: conn} do
        with_log_handle(fn ->
          {:ok, h} = NIF.register_log_hook(self())
          trigger_autoindex_warning(conn)
          assert_receive {:xqlite_log, _code, message}, 2_000
          assert message =~ "automatic index"
          h
        end)
      end

      test "stops delivery after unregister_log_hook/1", %{conn: conn} do
        {:ok, h} = NIF.register_log_hook(self())
        :ok = NIF.unregister_log_hook(h)

        trigger_autoindex_warning(conn)

        refute_receive {:xqlite_log, _, _}, 500
      end

      test "two subscribers each receive every event", %{conn: conn} do
        listener_a = spawn_log_collector()
        listener_b = spawn_log_collector()

        {:ok, h_a} = NIF.register_log_hook(listener_a)
        {:ok, h_b} = NIF.register_log_hook(listener_b)

        trigger_autoindex_warning(conn)

        msgs_a = get_collected_messages(listener_a)
        msgs_b = get_collected_messages(listener_b)
        assert length(msgs_a) > 0
        assert length(msgs_b) > 0

        :ok = NIF.unregister_log_hook(h_a)
        :ok = NIF.unregister_log_hook(h_b)
      end

      test "unregistering one subscriber leaves the other working", %{conn: conn} do
        listener_kept = spawn_log_collector()
        listener_removed = spawn_log_collector()

        {:ok, h_kept} = NIF.register_log_hook(listener_kept)
        {:ok, h_removed} = NIF.register_log_hook(listener_removed)

        :ok = NIF.unregister_log_hook(h_removed)

        trigger_autoindex_warning(conn)

        kept = get_collected_messages(listener_kept)
        removed = get_collected_messages(listener_removed)
        assert length(kept) > 0
        assert removed == []

        :ok = NIF.unregister_log_hook(h_kept)
      end

      test "dead listener pid does not crash or block siblings", %{conn: conn} do
        dead_pid = spawn(fn -> :ok end)
        ref = Process.monitor(dead_pid)
        receive do: ({:DOWN, ^ref, :process, ^dead_pid, _} -> :ok)

        live = spawn_log_collector()

        {:ok, h_dead} = NIF.register_log_hook(dead_pid)
        {:ok, h_live} = NIF.register_log_hook(live)

        trigger_autoindex_warning(conn)

        assert length(get_collected_messages(live)) > 0

        :ok = NIF.unregister_log_hook(h_dead)
        :ok = NIF.unregister_log_hook(h_live)
      end

      test "error code is SQLITE_WARNING_AUTOINDEX (284)", %{conn: conn} do
        with_log_handle(fn ->
          {:ok, h} = NIF.register_log_hook(self())
          trigger_autoindex_warning(conn)
          assert_receive {:xqlite_log, 284, _message}, 2_000
          h
        end)
      end

      test "re-register after unregister works", %{conn: conn} do
        {:ok, h1} = NIF.register_log_hook(self())
        :ok = NIF.unregister_log_hook(h1)

        with_log_handle(fn ->
          {:ok, h2} = NIF.register_log_hook(self())
          trigger_autoindex_warning(conn)
          assert_receive {:xqlite_log, _, _}, 2_000
          h2
        end)
      end

      test "GenServer-like process forwards log events", %{conn: conn} do
        test_pid = self()

        server =
          spawn(fn ->
            log_forwarder_loop(test_pid)
          end)

        {:ok, h} = NIF.register_log_hook(server)

        trigger_autoindex_warning(conn)

        assert_receive {:forwarded_log, {:xqlite_log, code, message}}, 2_000
        assert is_integer(code)
        assert is_binary(message)

        :ok = NIF.unregister_log_hook(h)
      end
    end

    describe "#{prefix}: rapid register/unregister cycling" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "survives 50 rapid register/unregister cycles", %{conn: conn} do
        for _ <- 1..50 do
          {:ok, h} = NIF.register_log_hook(self())
          :ok = NIF.unregister_log_hook(h)
        end

        with_log_handle(fn ->
          {:ok, h} = NIF.register_log_hook(self())
          trigger_autoindex_warning(conn)
          assert_receive {:xqlite_log, 284, _}, 2_000
          h
        end)
      end
    end
  end

  describe "multiple databases" do
    test "events from N databases all reach a single subscriber" do
      with_log_handle(fn ->
        {:ok, h} = NIF.register_log_hook(self())

        conns =
          for _ <- 1..3 do
            {:ok, conn} = NIF.open_in_memory(":memory:")
            conn
          end

        on_exit(fn -> Enum.each(conns, &NIF.close/1) end)

        Enum.each(conns, &trigger_autoindex_warning/1)

        messages = collect_messages(3, 2_000)
        assert length(messages) >= 3

        Enum.each(messages, fn {:xqlite_log, code, message} ->
          assert is_integer(code)
          assert is_binary(message)
        end)

        h
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Test bodies that register a hook return its handle from the inner
  # function; this wrapper unregisters on test exit. Avoids leaking
  # subscribers across async tests.
  defp with_log_handle(fun) do
    handle = fun.()
    :ok = NIF.unregister_log_hook(handle)
  end

  defp trigger_autoindex_warning(conn) do
    :ok =
      NIF.execute_batch(conn, """
      CREATE TABLE IF NOT EXISTS log_a (a TEXT, b TEXT);
      CREATE TABLE IF NOT EXISTS log_b (x TEXT, y TEXT);
      """)

    for i <- 1..30 do
      {:ok, 1} = NIF.execute(conn, "INSERT INTO log_a VALUES (?1, ?2)", ["v#{i}", "d#{i}"])
      {:ok, 1} = NIF.execute(conn, "INSERT INTO log_b VALUES (?1, ?2)", ["v#{i}", "e#{i}"])
    end

    {:ok, _} = NIF.query(conn, "SELECT * FROM log_a, log_b WHERE log_a.a = log_b.x", [])
  end

  defp spawn_log_collector do
    spawn(fn -> log_collector_loop([]) end)
  end

  defp log_collector_loop(acc) do
    receive do
      {:xqlite_log, _code, _msg} = event ->
        log_collector_loop([event | acc])

      {:get_messages, from} ->
        send(from, {:collected, Enum.reverse(acc)})
        log_collector_loop(acc)
    end
  end

  defp get_collected_messages(collector_pid) do
    send(collector_pid, {:get_messages, self()})

    receive do
      {:collected, messages} -> messages
    after
      1_000 -> []
    end
  end

  defp collect_messages(count, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(count, deadline, [])
  end

  defp do_collect(0, _deadline, acc), do: Enum.reverse(acc)

  defp do_collect(remaining, deadline, acc) do
    now = System.monotonic_time(:millisecond)
    wait = max(deadline - now, 0)

    receive do
      {:xqlite_log, _code, _msg} = event ->
        do_collect(remaining - 1, deadline, [event | acc])
    after
      wait -> Enum.reverse(acc)
    end
  end

  defp log_forwarder_loop(target) do
    receive do
      {:xqlite_log, _, _} = event ->
        send(target, {:forwarded_log, event})
        log_forwarder_loop(target)
    end
  end
end
