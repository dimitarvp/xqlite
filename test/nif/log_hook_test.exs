defmodule Xqlite.NIF.LogHookTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  # Always clean up the global log hook after each test.
  setup do
    on_exit(fn ->
      NIF.remove_log_hook()
    end)

    :ok
  end

  # --- Tests that need no connection (pure API) ---

  describe "set_log_hook/1" do
    test "returns {:ok, :ok}" do
      assert {:ok, :ok} = NIF.set_log_hook(self())
    end

    test "can be called multiple times to replace the listener" do
      assert {:ok, :ok} = NIF.set_log_hook(self())
      assert {:ok, :ok} = NIF.set_log_hook(self())
    end
  end

  describe "remove_log_hook/0" do
    test "returns {:ok, :ok} after a hook was set" do
      {:ok, :ok} = NIF.set_log_hook(self())
      assert {:ok, :ok} = NIF.remove_log_hook()
    end

    test "returns {:ok, :ok} even without prior set" do
      assert {:ok, :ok} = NIF.remove_log_hook()
    end

    test "is idempotent" do
      {:ok, :ok} = NIF.set_log_hook(self())
      assert {:ok, :ok} = NIF.remove_log_hook()
      assert {:ok, :ok} = NIF.remove_log_hook()
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
        {:ok, :ok} = NIF.set_log_hook(self())

        trigger_autoindex_warning(conn)

        assert_receive {:xqlite_log, code, message}, 2_000
        assert is_integer(code)
        assert is_binary(message)
      end

      test "message contains autoindex context", %{conn: conn} do
        {:ok, :ok} = NIF.set_log_hook(self())

        trigger_autoindex_warning(conn)

        assert_receive {:xqlite_log, _code, message}, 2_000
        assert message =~ "automatic index"
      end

      test "stops delivery after remove_log_hook/0", %{conn: conn} do
        {:ok, :ok} = NIF.set_log_hook(self())
        {:ok, :ok} = NIF.remove_log_hook()

        trigger_autoindex_warning(conn)

        refute_receive {:xqlite_log, _, _}, 500
      end

      test "replacing listener sends events only to new pid", %{conn: conn} do
        old_listener = spawn_log_collector()
        new_listener = spawn_log_collector()

        {:ok, :ok} = NIF.set_log_hook(old_listener)
        {:ok, :ok} = NIF.set_log_hook(new_listener)

        trigger_autoindex_warning(conn)

        new_messages = get_collected_messages(new_listener)
        assert length(new_messages) > 0

        old_messages = get_collected_messages(old_listener)
        assert old_messages == []
      end

      test "dead listener pid does not crash the system", %{conn: conn} do
        dead_pid = spawn(fn -> :ok end)
        ref = Process.monitor(dead_pid)
        receive do: ({:DOWN, ^ref, :process, ^dead_pid, _} -> :ok)

        {:ok, :ok} = NIF.set_log_hook(dead_pid)

        trigger_autoindex_warning(conn)
      end

      test "error code is SQLITE_WARNING_AUTOINDEX (284)", %{conn: conn} do
        {:ok, :ok} = NIF.set_log_hook(self())

        trigger_autoindex_warning(conn)

        # SQLITE_WARNING (28) | (1 << 8) = 284
        assert_receive {:xqlite_log, 284, _message}, 2_000
      end

      test "re-register after remove works", %{conn: conn} do
        {:ok, :ok} = NIF.set_log_hook(self())
        {:ok, :ok} = NIF.remove_log_hook()

        {:ok, :ok} = NIF.set_log_hook(self())

        trigger_autoindex_warning(conn)
        assert_receive {:xqlite_log, _, _}, 2_000
      end

      test "multiple log events from repeated autoindex queries", %{conn: conn} do
        {:ok, :ok} = NIF.set_log_hook(self())

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE multi_a (a TEXT, b TEXT);
          CREATE TABLE multi_b (x TEXT, y TEXT);
          """)

        for i <- 1..30 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO multi_a VALUES (?1, ?2)", ["v#{i}", "d#{i}"])

          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO multi_b VALUES (?1, ?2)", ["v#{i}", "e#{i}"])
        end

        for _ <- 1..3 do
          {:ok, _} =
            NIF.query(
              conn,
              "SELECT * FROM multi_a, multi_b WHERE multi_a.a = multi_b.x",
              []
            )
        end

        messages = collect_messages(3, 2_000)
        assert length(messages) >= 3
      end

      test "GenServer-like process forwards log events", %{conn: conn} do
        test_pid = self()

        server =
          spawn(fn ->
            receive do
              :register -> :ok
            end

            log_forwarder_loop(test_pid)
          end)

        {:ok, :ok} = NIF.set_log_hook(server)
        send(server, :register)

        trigger_autoindex_warning(conn)

        assert_receive {:forwarded_log, {:xqlite_log, code, message}}, 2_000
        assert is_integer(code)
        assert is_binary(message)
      end
    end

    describe "#{prefix}: error code variety" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "autoindex warning has code 284 and message with table context", %{conn: conn} do
        {:ok, :ok} = NIF.set_log_hook(self())

        trigger_autoindex_warning(conn)

        assert_receive {:xqlite_log, 284, message}, 2_000
        assert message =~ "automatic index"
      end

      test "multiple autoindex warnings have the same code", %{conn: conn} do
        {:ok, :ok} = NIF.set_log_hook(self())

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE ea (x TEXT, y TEXT);
          CREATE TABLE eb (x TEXT, y TEXT);
          """)

        for i <- 1..30 do
          {:ok, 1} = NIF.execute(conn, "INSERT INTO ea VALUES (?1, ?2)", ["v#{i}", "d#{i}"])
          {:ok, 1} = NIF.execute(conn, "INSERT INTO eb VALUES (?1, ?2)", ["v#{i}", "e#{i}"])
        end

        {:ok, _} = NIF.query(conn, "SELECT * FROM ea, eb WHERE ea.x = eb.x", [])

        assert_receive {:xqlite_log, 284, msg1}, 2_000

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE ec (a TEXT, b TEXT);
          CREATE TABLE ed (a TEXT, b TEXT);
          """)

        for i <- 1..30 do
          {:ok, 1} = NIF.execute(conn, "INSERT INTO ec VALUES (?1, ?2)", ["v#{i}", "d#{i}"])
          {:ok, 1} = NIF.execute(conn, "INSERT INTO ed VALUES (?1, ?2)", ["v#{i}", "e#{i}"])
        end

        {:ok, _} = NIF.query(conn, "SELECT * FROM ec, ed WHERE ec.a = ed.a", [])

        assert_receive {:xqlite_log, 284, msg2}, 2_000

        refute msg1 == msg2
      end

      test "code is always an integer and message is always a binary", %{conn: conn} do
        {:ok, :ok} = NIF.set_log_hook(self())

        trigger_autoindex_warning(conn)

        messages = collect_all_log_messages(2_000)
        assert length(messages) > 0

        Enum.each(messages, fn {:xqlite_log, code, message} ->
          assert is_integer(code), "expected code to be integer, got: #{inspect(code)}"
          assert is_binary(message), "expected message to be binary, got: #{inspect(message)}"
          assert byte_size(message) > 0, "expected non-empty message"
        end)
      end

      test "error code has base code extractable via bitwise AND", %{conn: conn} do
        {:ok, :ok} = NIF.set_log_hook(self())

        trigger_autoindex_warning(conn)

        assert_receive {:xqlite_log, code, _}, 2_000

        # Extended code 284 = SQLITE_WARNING (28) | (1 << 8)
        base_code = Bitwise.band(code, 0xFF)
        assert base_code == 28
      end
    end

    describe "#{prefix}: rapid set/remove cycling" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "survives 50 rapid set/remove cycles", %{conn: conn} do
        for _ <- 1..50 do
          {:ok, :ok} = NIF.set_log_hook(self())
          {:ok, :ok} = NIF.remove_log_hook()
        end

        {:ok, :ok} = NIF.set_log_hook(self())

        trigger_autoindex_warning(conn)

        assert_receive {:xqlite_log, 284, _}, 2_000
      end

      test "rapid listener replacement delivers to final listener only", %{conn: conn} do
        pids =
          for _ <- 1..50 do
            pid = spawn(fn -> Process.sleep(5_000) end)
            {:ok, :ok} = NIF.set_log_hook(pid)
            pid
          end

        final_listener = spawn_log_collector()
        {:ok, :ok} = NIF.set_log_hook(final_listener)

        trigger_autoindex_warning(conn)

        messages = get_collected_messages(final_listener)
        assert length(messages) > 0

        Enum.each(pids, fn pid ->
          Process.exit(pid, :kill)
        end)
      end

      test "set/remove interleaved with log-triggering queries", %{conn: conn} do
        for i <- 1..10 do
          {:ok, :ok} = NIF.set_log_hook(self())

          :ok =
            NIF.execute_batch(conn, """
            CREATE TABLE IF NOT EXISTS cycle_a_#{i} (a TEXT, b TEXT);
            CREATE TABLE IF NOT EXISTS cycle_b_#{i} (x TEXT, y TEXT);
            """)

          for j <- 1..30 do
            {:ok, 1} =
              NIF.execute(
                conn,
                "INSERT INTO cycle_a_#{i} VALUES (?1, ?2)",
                ["v#{j}", "d#{j}"]
              )

            {:ok, 1} =
              NIF.execute(
                conn,
                "INSERT INTO cycle_b_#{i} VALUES (?1, ?2)",
                ["v#{j}", "e#{j}"]
              )
          end

          {:ok, _} =
            NIF.query(
              conn,
              "SELECT * FROM cycle_a_#{i}, cycle_b_#{i} WHERE cycle_a_#{i}.a = cycle_b_#{i}.x",
              []
            )

          {:ok, :ok} = NIF.remove_log_hook()
        end

        messages = collect_all_log_messages(2_000)
        assert length(messages) >= 10
      end
    end
  end

  # --- Tests outside the for loop ---
  # Multi-connection tests and cross-connection lifecycle tests.

  describe "hook survives connection close" do
    test "opening a new connection after close still delivers events" do
      {:ok, :ok} = NIF.set_log_hook(self())

      {:ok, conn1} = NIF.open_in_memory(":memory:")
      trigger_autoindex_warning(conn1)
      assert_receive {:xqlite_log, _, _}, 2_000

      NIF.close(conn1)

      {:ok, conn2} = NIF.open_in_memory(":memory:")
      on_exit(fn -> NIF.close(conn2) end)

      trigger_autoindex_warning(conn2)
      assert_receive {:xqlite_log, _, _}, 2_000
    end
  end

  describe "multiple databases" do
    test "3 databases deliver events to a single listener" do
      {:ok, :ok} = NIF.set_log_hook(self())

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
    end

    test "3 sequential listeners each receive events from their own database" do
      conns =
        for _ <- 1..3 do
          {:ok, conn} = NIF.open_in_memory(":memory:")
          conn
        end

      on_exit(fn -> Enum.each(conns, &NIF.close/1) end)

      Enum.zip(1..3, conns)
      |> Enum.each(fn {_i, conn} ->
        listener = spawn_log_collector()
        {:ok, :ok} = NIF.set_log_hook(listener)

        trigger_autoindex_warning(conn)

        messages = get_collected_messages(listener)
        assert length(messages) > 0

        Enum.each(messages, fn {:xqlite_log, code, msg} ->
          assert is_integer(code)
          assert is_binary(msg)
        end)
      end)
    end

    test "concurrent triggers from multiple tasks" do
      {:ok, :ok} = NIF.set_log_hook(self())

      conns =
        for _ <- 1..3 do
          {:ok, conn} = NIF.open_in_memory(":memory:")
          conn
        end

      on_exit(fn -> Enum.each(conns, &NIF.close/1) end)

      tasks =
        Enum.map(conns, fn conn ->
          Task.async(fn -> trigger_autoindex_warning(conn) end)
        end)

      Task.await_many(tasks, 10_000)

      messages = collect_messages(3, 2_000)
      assert length(messages) >= 3
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

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

  defp collect_all_log_messages(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_all(deadline, [])
  end

  defp do_collect_all(deadline, acc) do
    now = System.monotonic_time(:millisecond)
    wait = max(deadline - now, 0)

    receive do
      {:xqlite_log, _code, _msg} = event ->
        do_collect_all(deadline, [event | acc])
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
