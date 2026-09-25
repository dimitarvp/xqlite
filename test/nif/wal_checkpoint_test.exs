defmodule Xqlite.NIF.WalCheckpointTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1, tmp_db_path: 1]

  alias XqliteNIF, as: NIF

  # SQLite keeps an in-memory and an anonymous temporary database out of WAL mode.
  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "a named database outside WAL mode answers the error", %{conn: conn} do
        assert {:error, :not_in_wal_mode} = NIF.wal_checkpoint(conn, :passive, "main")
        assert {:error, :not_in_wal_mode} = Xqlite.wal_checkpoint(conn)
      end

      test "the every-database call still checkpoints an attached WAL file", %{conn: conn} do
        aux = tmp_db_path("checkpoint_aux")
        :ok = NIF.execute_batch(conn, "ATTACH '#{aux}' AS aux; PRAGMA aux.journal_mode = WAL")
        :ok = NIF.execute_batch(conn, "CREATE TABLE aux.t(x); INSERT INTO aux.t VALUES (1)")
        assert File.stat!(aux <> "-wal").size > 0

        assert {:ok, _} = NIF.wal_checkpoint(conn, :truncate, nil)
        assert File.stat!(aux <> "-wal").size == 0
      end

      test "rejects an unknown mode atom with a structured error", %{conn: conn} do
        assert {:error, {:invalid_checkpoint_mode, :bogus}} = NIF.wal_checkpoint(conn, :bogus)
      end

      test "unknown schema surfaces as an error", %{conn: conn} do
        assert {:error, _} = NIF.wal_checkpoint(conn, :passive, "does_not_exist")
      end
    end
  end

  describe "on a WAL file" do
    setup do
      path = tmp_db_path("checkpoint")
      {:ok, conn} = Xqlite.open(path)
      on_exit(fn -> NIF.close(conn) end)
      :ok = Xqlite.execute_batch(conn, "CREATE TABLE t(x); INSERT INTO t VALUES (1)")
      {:ok, conn: conn, path: path}
    end

    test "every mode answers the page counts from both modules", %{conn: conn} do
      for mode <- [:passive, :full, :restart, :truncate] do
        assert {:ok, %{log_pages: log, busy: false}} = NIF.wal_checkpoint(conn, mode, "main")

        assert {:ok, %{checkpointed_pages: done}} = Xqlite.wal_checkpoint(conn, mode)
        assert log >= 0 and done >= 0
      end
    end

    # A FULL checkpoint holds the checkpoint lock while it waits on the reader,
    # through the busy handler: the observer's first message says it is waiting.
    test "a checkpoint lock held elsewhere is the busy error", %{conn: conn, path: path} do
      [reader, holder, probe] = for _ <- 1..3, {:ok, other} <- [Xqlite.open(path)], do: other
      on_exit(fn -> Enum.each([reader, holder, probe], &NIF.close/1) end)
      :ok = Xqlite.begin(reader)
      {:ok, _} = Xqlite.query(reader, "SELECT count(*) FROM t")
      {:ok, _} = Xqlite.execute(conn, "INSERT INTO t VALUES (2)")
      {:ok, _} = Xqlite.register_busy_observer(holder, self())
      full = Task.async(fn -> Xqlite.wal_checkpoint(holder, :full) end)

      assert_receive {:xqlite_busy, _, _}, 5_000
      assert {:error, {:database_busy_or_locked, 5, _}} = Xqlite.wal_checkpoint(probe)
      :ok = Xqlite.rollback(reader)
      assert {:ok, _} = Task.await(full, 10_000)
    end
  end
end
