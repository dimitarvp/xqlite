defmodule Xqlite.NIF.WalCheckpointTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa_ignored_here} <- connection_openers() do
    describe "using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "returns the documented map shape", %{conn: conn} do
        # Our test openers produce non-WAL connections (SQLite forbids WAL on
        # in-memory and on anonymous empty-path temp DBs). wal_checkpoint on
        # non-WAL still returns SQLITE_OK with log/ckpt = -1 per docs —
        # good enough to exercise the shape and the FFI wiring.
        assert {:ok, %{log_pages: log, checkpointed_pages: ckpt, busy: busy}} =
                 NIF.wal_checkpoint(conn)

        assert is_integer(log)
        assert is_integer(ckpt)
        assert is_boolean(busy)
      end

      test "accepts all four modes", %{conn: conn} do
        for mode <- [:passive, :full, :restart, :truncate] do
          assert {:ok, %{log_pages: _, checkpointed_pages: _, busy: _}} =
                   NIF.wal_checkpoint(conn, mode)
        end
      end

      test "rejects an unknown mode atom with a structured error", %{conn: conn} do
        assert {:error, {:cannot_execute, msg}} = NIF.wal_checkpoint(conn, :bogus)
        assert is_binary(msg)
        assert msg =~ ":passive"
      end

      test "accepts an attached-schema name", %{conn: conn} do
        # Checkpointing the "main" schema by name is valid.
        assert {:ok, _} = NIF.wal_checkpoint(conn, :passive, "main")
      end

      test "unknown schema surfaces as an error", %{conn: conn} do
        assert {:error, _} = NIF.wal_checkpoint(conn, :passive, "does_not_exist")
      end
    end
  end
end
