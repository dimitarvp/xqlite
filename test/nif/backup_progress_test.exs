defmodule Xqlite.NIF.BackupProgressTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "backup_with_progress using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        backup_path =
          Path.join(
            System.tmp_dir!(),
            "xqlite_bkp_#{:erlang.unique_integer([:positive])}.db"
          )

        on_exit(fn ->
          NIF.close(conn)
          File.rm(backup_path)
        end)

        {:ok, conn: conn, backup_path: backup_path}
      end

      # -------------------------------------------------------------------
      # Progress reporting
      # -------------------------------------------------------------------

      test "sends progress messages to pid", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE bkp_prog (id INTEGER PRIMARY KEY, data TEXT);")

        for i <- 1..100 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO bkp_prog VALUES (?1, ?2)", [
              i,
              String.duplicate("x", 200)
            ])
        end

        {:ok, token} = NIF.create_cancel_token()
        assert :ok = NIF.backup_with_progress(conn, "main", path, self(), 5, [token])

        # Should have received at least one progress message
        assert_received {:xqlite_backup_progress, remaining, pagecount}
        assert is_integer(remaining)
        assert is_integer(pagecount)
        assert pagecount > 0
      end

      test "final progress message has remaining == 0", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE bkp_fin (id INTEGER PRIMARY KEY, data TEXT);")

        for i <- 1..50 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO bkp_fin VALUES (?1, ?2)", [
              i,
              String.duplicate("y", 100)
            ])
        end

        {:ok, token} = NIF.create_cancel_token()
        :ok = NIF.backup_with_progress(conn, "main", path, self(), 5, [token])

        # Drain all messages and check the last one
        messages = drain_progress_messages()
        assert length(messages) >= 1

        {last_remaining, last_pagecount} = List.last(messages)
        assert last_remaining == 0
        assert last_pagecount > 0
      end

      test "progress remaining decreases over time", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE bkp_dec (id INTEGER PRIMARY KEY, data TEXT);")

        for i <- 1..200 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO bkp_dec VALUES (?1, ?2)", [
              i,
              String.duplicate("z", 500)
            ])
        end

        {:ok, token} = NIF.create_cancel_token()
        :ok = NIF.backup_with_progress(conn, "main", path, self(), 2, [token])

        messages = drain_progress_messages()
        assert length(messages) >= 2

        remaining_values = Enum.map(messages, fn {r, _} -> r end)
        # Remaining should be non-increasing
        pairs = Enum.zip(remaining_values, tl(remaining_values))
        assert Enum.all?(pairs, fn {a, b} -> a >= b end)
      end

      test "pagecount is consistent across progress messages", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE bkp_pc (id INTEGER PRIMARY KEY, data TEXT);")

        for i <- 1..100 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO bkp_pc VALUES (?1, ?2)", [
              i,
              String.duplicate("w", 300)
            ])
        end

        {:ok, token} = NIF.create_cancel_token()
        :ok = NIF.backup_with_progress(conn, "main", path, self(), 3, [token])

        messages = drain_progress_messages()
        pagecounts = messages |> Enum.map(fn {_, pc} -> pc end) |> Enum.uniq()

        # Pagecount should be the same throughout (source not modified during backup)
        assert length(pagecounts) == 1
      end

      # -------------------------------------------------------------------
      # Data integrity
      # -------------------------------------------------------------------

      test "backup file contains correct data", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE bkp_data (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, 1} = NIF.execute(conn, "INSERT INTO bkp_data VALUES (1, 'alpha')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO bkp_data VALUES (2, 'beta')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO bkp_data VALUES (3, 'gamma')", [])

        {:ok, token} = NIF.create_cancel_token()
        :ok = NIF.backup_with_progress(conn, "main", path, self(), 10, [token])

        {:ok, verify_conn} = NIF.open_readonly(path)

        assert {:ok, %{rows: [[1, "alpha"], [2, "beta"], [3, "gamma"]], num_rows: 3}} =
                 NIF.query(verify_conn, "SELECT * FROM bkp_data ORDER BY id", [])

        NIF.close(verify_conn)
      end

      test "large backup preserves all rows", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE TABLE bkp_large (id INTEGER PRIMARY KEY, data TEXT);"
          )

        for i <- 1..1000 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO bkp_large VALUES (?1, ?2)", [i, "row_#{i}"])
        end

        {:ok, token} = NIF.create_cancel_token()
        :ok = NIF.backup_with_progress(conn, "main", path, self(), 10, [token])

        {:ok, verify_conn} = NIF.open_readonly(path)

        assert {:ok, %{rows: [[1000]]}} =
                 NIF.query(verify_conn, "SELECT COUNT(*) FROM bkp_large", [])

        assert {:ok, %{rows: [[1, "row_1"]]}} =
                 NIF.query(verify_conn, "SELECT * FROM bkp_large WHERE id = 1", [])

        assert {:ok, %{rows: [[1000, "row_1000"]]}} =
                 NIF.query(verify_conn, "SELECT * FROM bkp_large WHERE id = 1000", [])

        NIF.close(verify_conn)
      end

      # -------------------------------------------------------------------
      # Cancellation
      # -------------------------------------------------------------------

      test "cancellation returns :operation_cancelled", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE TABLE bkp_cancel (id INTEGER PRIMARY KEY, data TEXT);"
          )

        for i <- 1..500 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO bkp_cancel VALUES (?1, ?2)", [
              i,
              String.duplicate("c", 1000)
            ])
        end

        {:ok, token} = NIF.create_cancel_token()

        # Cancel immediately before starting
        :ok = NIF.cancel_operation(token)

        assert {:error, :operation_cancelled} =
                 NIF.backup_with_progress(conn, "main", path, self(), 1, [token])
      end

      test "cancellation mid-backup via async cancel", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE TABLE bkp_async (id INTEGER PRIMARY KEY, data TEXT);"
          )

        for i <- 1..1000 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO bkp_async VALUES (?1, ?2)", [
              i,
              String.duplicate("d", 2000)
            ])
        end

        {:ok, token} = NIF.create_cancel_token()

        task =
          Task.async(fn ->
            NIF.backup_with_progress(conn, "main", path, self(), 1, [token])
          end)

        # Give it a moment to start, then cancel
        Process.sleep(10)
        :ok = NIF.cancel_operation(token)

        result = Task.await(task, 5000)
        assert result == {:error, :operation_cancelled} or result == :ok
      end

      # -------------------------------------------------------------------
      # Pages per step variations
      # -------------------------------------------------------------------

      test "pages_per_step 1 produces many progress messages", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE bkp_pps1 (id INTEGER PRIMARY KEY, data TEXT);")

        for i <- 1..100 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO bkp_pps1 VALUES (?1, ?2)", [
              i,
              String.duplicate("e", 200)
            ])
        end

        {:ok, token} = NIF.create_cancel_token()
        :ok = NIF.backup_with_progress(conn, "main", path, self(), 1, [token])

        message_count = length(drain_progress_messages())
        assert message_count >= 3 and message_count <= 20
      end

      test "large pages_per_step completes in fewer messages", %{conn: conn, backup_path: path} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE TABLE bkp_pps100 (id INTEGER PRIMARY KEY, data TEXT);"
          )

        for i <- 1..50 do
          {:ok, 1} = NIF.execute(conn, "INSERT INTO bkp_pps100 VALUES (?1, ?2)", [i, "small"])
        end

        {:ok, token} = NIF.create_cancel_token()
        :ok = NIF.backup_with_progress(conn, "main", path, self(), 1000, [token])

        messages = drain_progress_messages()
        # Large step size on small DB → very few messages (likely 1)
        assert length(messages) >= 1
        assert length(messages) <= 3
      end

      # -------------------------------------------------------------------
      # Error cases
      # -------------------------------------------------------------------

      test "invalid dest_path returns error", %{conn: conn} do
        {:ok, token} = NIF.create_cancel_token()

        assert {:error, _} =
                 NIF.backup_with_progress(
                   conn,
                   "main",
                   "/no/such/dir/backup.db",
                   self(),
                   10,
                   [token]
                 )
      end

      test "invalid schema returns error", %{conn: conn, backup_path: path} do
        {:ok, token} = NIF.create_cancel_token()

        assert {:error, _} =
                 NIF.backup_with_progress(
                   conn,
                   "nonexistent_schema",
                   path,
                   self(),
                   10,
                   [token]
                 )
      end

      test "empty database backup succeeds", %{conn: conn, backup_path: path} do
        {:ok, token} = NIF.create_cancel_token()
        assert :ok = NIF.backup_with_progress(conn, "main", path, self(), 10, [token])

        assert File.exists?(path)
        assert File.stat!(path).size > 0

        message_count = length(drain_progress_messages())
        assert message_count >= 1 and message_count <= 3
      end
    end
  end

  # -------------------------------------------------------------------
  # Edge cases outside connection_openers loop
  # -------------------------------------------------------------------

  test "backup_with_progress on closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    NIF.close(conn)
    {:ok, token} = NIF.create_cancel_token()

    assert {:error, _} =
             NIF.backup_with_progress(
               conn,
               "main",
               "/tmp/xqlite_closed.db",
               self(),
               10,
               [token]
             )
  end

  test "dead subscriber pid does not crash the NIF mid-backup" do
    {:ok, conn} = NIF.open_in_memory(":memory:")

    on_exit(fn ->
      NIF.close(conn)
    end)

    :ok =
      NIF.execute_batch(
        conn,
        "CREATE TABLE bkp_dead (id INTEGER PRIMARY KEY, data TEXT);"
      )

    for i <- 1..200 do
      {:ok, 1} =
        NIF.execute(conn, "INSERT INTO bkp_dead VALUES (?1, ?2)", [
          i,
          String.duplicate("z", 400)
        ])
    end

    dest =
      Path.join(
        System.tmp_dir!(),
        "xqlite_bkp_dead_#{:erlang.unique_integer([:positive])}.db"
      )

    on_exit(fn -> File.rm(dest) end)

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    receive do: ({:DOWN, ^ref, :process, ^dead, _} -> :ok)

    {:ok, token} = NIF.create_cancel_token()

    # Tiny pages_per_step so we fire the send repeatedly against a dead pid.
    # Every send must be a no-op; the backup must complete.
    assert :ok = NIF.backup_with_progress(conn, "main", dest, dead, 1, [token])

    assert File.exists?(dest)
    assert File.stat!(dest).size > 0
  end

  test "GenServer-like process forwards backup_progress events" do
    {:ok, conn} = NIF.open_in_memory(":memory:")

    on_exit(fn ->
      NIF.close(conn)
    end)

    :ok =
      NIF.execute_batch(
        conn,
        "CREATE TABLE bkp_fwd (id INTEGER PRIMARY KEY, data TEXT);"
      )

    for i <- 1..50 do
      {:ok, 1} =
        NIF.execute(conn, "INSERT INTO bkp_fwd VALUES (?1, ?2)", [i, "row_#{i}"])
    end

    dest =
      Path.join(
        System.tmp_dir!(),
        "xqlite_bkp_fwd_#{:erlang.unique_integer([:positive])}.db"
      )

    on_exit(fn -> File.rm(dest) end)

    test_pid = self()

    forwarder =
      spawn(fn ->
        forwarder_loop(test_pid)
      end)

    {:ok, token} = NIF.create_cancel_token()
    :ok = NIF.backup_with_progress(conn, "main", dest, forwarder, 5, [token])

    # At least one forwarded event must arrive with the right shape.
    assert_receive {:forwarded_backup_progress,
                    {:xqlite_backup_progress, remaining, pagecount}},
                   2_000

    assert is_integer(remaining) and remaining >= 0
    assert is_integer(pagecount) and pagecount > 0
  end

  defp forwarder_loop(target) do
    receive do
      {:xqlite_backup_progress, _, _} = event ->
        send(target, {:forwarded_backup_progress, event})
        forwarder_loop(target)
    end
  end

  # -------------------------------------------------------------------
  # Helper
  # -------------------------------------------------------------------

  defp drain_progress_messages do
    drain_progress_messages([])
  end

  defp drain_progress_messages(acc) do
    receive do
      {:xqlite_backup_progress, remaining, pagecount} ->
        drain_progress_messages([{remaining, pagecount} | acc])
    after
      2000 ->
        Enum.reverse(acc)
    end
  end
end
