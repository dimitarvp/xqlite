defmodule Xqlite.XqliteTelemetryBlock3Test do
  @moduledoc """
  Block 3 telemetry coverage: stream / backup / restore / wal_checkpoint /
  serialize / deserialize / load_extension / enable_load_extension /
  pragma get/set.

  Same harness as the Block 2 test file: per-test handler attach with a
  unique handler-id, capture events into the test mailbox, assert
  expected shape, detach.
  """

  use ExUnit.Case, async: true

  setup do
    {:ok, conn} = Xqlite.open_in_memory()
    on_exit(fn -> XqliteNIF.close(conn) end)
    {:ok, conn: conn}
  end

  describe "stream telemetry" do
    test "open / fetch / close fire as expected when consumed", %{conn: conn} do
      :ok =
        XqliteNIF.execute_batch(
          conn,
          "CREATE TABLE t(id INTEGER PRIMARY KEY); INSERT INTO t VALUES (1), (2), (3);"
        )

      handler_id = "test-stream-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite, :stream, :open, :start],
        [:xqlite, :stream, :open, :stop],
        [:xqlite, :stream, :fetch],
        [:xqlite, :stream, :close]
      ])

      stream = Xqlite.stream(conn, "SELECT id FROM t", [], batch_size: 2)
      results = Enum.to_list(stream)
      assert length(results) == 3

      # Open span
      assert_receive {:telemetry_event, [:xqlite, :stream, :open, :start], _, %{batch_size: 2}}

      assert_receive {:telemetry_event, [:xqlite, :stream, :open, :stop], _,
                      %{result_class: :ok}}

      # At least one fetch event
      assert_receive {:telemetry_event, [:xqlite, :stream, :fetch], measurements, metadata}
      assert is_integer(measurements.duration) and measurements.duration >= 0
      assert is_integer(measurements.rows_returned)
      assert is_reference(metadata.stream_handle)
      assert is_boolean(metadata.done?)

      # Close event
      assert_receive {:telemetry_event, [:xqlite, :stream, :close], close_measurements,
                      close_metadata}

      assert is_integer(close_measurements.total_rows)
      assert close_measurements.total_rows == 3
      assert close_metadata.reason in [:drained, :errored, :halted]

      :telemetry.detach(handler_id)
    end

    test "open :stop fires with :error on bad SQL", %{conn: conn} do
      handler_id = "test-stream-bad-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite, :stream, :open, :stop]
      ])

      {:error, _} = Xqlite.stream(conn, "SELECT * FROM nonexistent", [])

      assert_receive {:telemetry_event, [:xqlite, :stream, :open, :stop], _, metadata}
      assert metadata.result_class == :error

      :telemetry.detach(handler_id)
    end
  end

  describe "serialize telemetry" do
    test "fires :stop with byte_size on success", %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
      handler_id = "test-serialize-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :serialize, :stop]])

      {:ok, bin} = Xqlite.serialize(conn, "main")
      assert is_binary(bin)

      assert_receive {:telemetry_event, [:xqlite, :serialize, :stop], _measurements, metadata}
      assert metadata.result_class == :ok
      assert metadata.byte_size == byte_size(bin)
      assert metadata.schema == "main"

      :telemetry.detach(handler_id)
    end
  end

  describe "deserialize telemetry" do
    test "fires :stop with read_only? metadata", %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")
      {:ok, bin} = Xqlite.serialize(conn)

      {:ok, conn2} = Xqlite.open_in_memory()
      on_exit(fn -> XqliteNIF.close(conn2) end)

      handler_id = "test-deserialize-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :deserialize, :stop]])

      :ok = Xqlite.deserialize(conn2, bin, "main", false)

      assert_receive {:telemetry_event, [:xqlite, :deserialize, :stop], _, metadata}
      assert metadata.result_class == :ok
      assert metadata.read_only? == false
      assert metadata.byte_size == byte_size(bin)

      :telemetry.detach(handler_id)
    end
  end

  describe "backup / restore telemetry" do
    test "backup :stop fires with byte_size on success", %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

      path =
        Path.join(System.tmp_dir!(), "xqlite_bk_tel_#{:erlang.unique_integer([:positive])}.db")

      on_exit(fn -> File.rm(path) end)

      handler_id = "test-backup-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :backup, :stop]])

      :ok = Xqlite.backup(conn, path)

      assert_receive {:telemetry_event, [:xqlite, :backup, :stop], _, metadata}
      assert metadata.result_class == :ok
      assert is_integer(metadata.byte_size) and metadata.byte_size > 0
      assert metadata.dest_path == path

      :telemetry.detach(handler_id)
    end

    test "backup :stop with :error for invalid path", %{conn: conn} do
      handler_id = "test-backup-err-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :backup, :stop]])

      {:error, _} = Xqlite.backup(conn, "/no/such/dir/backup.db")

      assert_receive {:telemetry_event, [:xqlite, :backup, :stop], _, metadata}
      assert metadata.result_class == :error
      assert metadata.byte_size == nil

      :telemetry.detach(handler_id)
    end

    test "restore :stop fires with src_path", %{conn: conn} do
      :ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY);")

      path =
        Path.join(System.tmp_dir!(), "xqlite_rs_tel_#{:erlang.unique_integer([:positive])}.db")

      on_exit(fn -> File.rm(path) end)
      :ok = Xqlite.backup(conn, path)

      handler_id = "test-restore-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :restore, :stop]])

      {:ok, conn2} = Xqlite.open_in_memory()
      on_exit(fn -> XqliteNIF.close(conn2) end)

      :ok = Xqlite.restore(conn2, path)

      assert_receive {:telemetry_event, [:xqlite, :restore, :stop], _, metadata}
      assert metadata.result_class == :ok
      assert metadata.src_path == path

      :telemetry.detach(handler_id)
    end
  end

  describe "wal_checkpoint telemetry" do
    test "fires :stop with mode + page counts on success" do
      path =
        Path.join(
          System.tmp_dir!(),
          "xqlite_wal_tel_#{:erlang.unique_integer([:positive])}.db"
        )

      on_exit(fn ->
        for ext <- ["", "-wal", "-shm"], do: File.rm(path <> ext)
      end)

      {:ok, conn} = Xqlite.open(path)
      on_exit(fn -> XqliteNIF.close(conn) end)

      :ok =
        XqliteNIF.execute_batch(
          conn,
          "CREATE TABLE t(id INTEGER PRIMARY KEY); INSERT INTO t VALUES (1);"
        )

      handler_id = "test-wal-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :wal_checkpoint, :stop]])

      {:ok, _} = Xqlite.wal_checkpoint(conn, :passive, "main")

      assert_receive {:telemetry_event, [:xqlite, :wal_checkpoint, :stop], _, metadata}
      assert metadata.result_class == :ok
      assert metadata.mode == :passive
      assert metadata.schema == "main"
      assert is_integer(metadata.log_pages)
      assert is_integer(metadata.checkpointed_pages)
      assert is_boolean(metadata.busy?)

      :telemetry.detach(handler_id)
    end
  end

  describe "load_extension / enable_load_extension telemetry" do
    test "load_extension :stop fires with :error for nonexistent path", %{conn: conn} do
      handler_id = "test-loadext-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :extension, :load, :stop]])

      :ok = Xqlite.enable_load_extension(conn, true)
      {:error, _} = Xqlite.load_extension(conn, "/no/such/extension")

      assert_receive {:telemetry_event, [:xqlite, :extension, :load, :stop], _, metadata}
      assert metadata.result_class == :error
      assert metadata.path == "/no/such/extension"

      :ok = Xqlite.enable_load_extension(conn, false)
      :telemetry.detach(handler_id)
    end

    test "enable_load_extension fires :enable event", %{conn: conn} do
      handler_id = "test-enableext-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :extension, :enable]])

      :ok = Xqlite.enable_load_extension(conn, true)
      assert_receive {:telemetry_event, [:xqlite, :extension, :enable], _, %{enabled: true}}

      :ok = Xqlite.enable_load_extension(conn, false)
      assert_receive {:telemetry_event, [:xqlite, :extension, :enable], _, %{enabled: false}}

      :telemetry.detach(handler_id)
    end
  end

  describe "pragma get/set telemetry" do
    test "set fires :pragma, :set with name + value", %{conn: conn} do
      handler_id = "test-pragma-set-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :pragma, :set]])

      {:ok, _} = Xqlite.set_pragma(conn, "cache_size", 100)

      assert_receive {:telemetry_event, [:xqlite, :pragma, :set], _, metadata}
      assert metadata.name == "cache_size"
      assert metadata.value == 100

      :telemetry.detach(handler_id)
    end

    test "get fires :pragma, :get with name", %{conn: conn} do
      handler_id = "test-pragma-get-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :pragma, :get]])

      {:ok, _} = Xqlite.get_pragma(conn, "cache_size")

      assert_receive {:telemetry_event, [:xqlite, :pragma, :get], _, %{name: "cache_size"}}

      :telemetry.detach(handler_id)
    end

    test "atom names get converted to strings", %{conn: conn} do
      handler_id = "test-pragma-atom-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite, :pragma, :get]])

      {:ok, _} = Xqlite.get_pragma(conn, :cache_size)

      assert_receive {:telemetry_event, [:xqlite, :pragma, :get], _, %{name: "cache_size"}}

      :telemetry.detach(handler_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp attach_capture(handler_id, events) do
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )
  end
end
