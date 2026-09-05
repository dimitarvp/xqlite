defmodule Xqlite.ArgumentValidationLawTest do
  @moduledoc """
  Wrappers that name a fixed set of accepted values reject everything
  else with a structured error, never with a raise.

  `begin/2`, `wal_checkpoint/3` and `txn_state/2` used to carry the
  accepted values in a function-head guard, so a typo — a string mode,
  an atom schema — came back as a `FunctionClauseError`. Each property
  below generates terms of every type outside the accepted set and
  pins the error shape; the plain tests beside them pin the accepted
  values, including the transaction state each `begin/2` mode leaves
  behind.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  @begin_modes [:deferred, :immediate, :exclusive]
  @checkpoint_modes [:passive, :full, :restart, :truncate]

  # Every term type a caller can put in an argument position, kept small
  # so 2000 runs stay in the sub-second range.
  defp any_term do
    StreamData.scale(
      StreamData.one_of([
        StreamData.atom(:alphanumeric),
        StreamData.boolean(),
        StreamData.constant(nil),
        StreamData.binary(),
        StreamData.string(:printable),
        StreamData.integer(),
        StreamData.list_of(StreamData.integer(), max_length: 3),
        StreamData.map_of(StreamData.atom(:alphanumeric), StreamData.integer(), max_length: 3),
        StreamData.tuple({StreamData.atom(:alphanumeric), StreamData.integer()})
      ]),
      fn size -> min(size, 8) end
    )
  end

  defp term_other_than(accepted) do
    StreamData.filter(any_term(), fn term -> term not in accepted end)
  end

  defp non_schema_term do
    StreamData.filter(any_term(), fn term -> not (is_binary(term) or is_nil(term)) end)
  end

  for_each_opener do
    property "begin/2 refuses every term that is not a transaction mode", %{conn: conn} do
      check all(mode <- term_other_than(@begin_modes), max_runs: 2000) do
        assert {:error, :invalid_transaction_mode} == Xqlite.begin(conn, mode)
        assert {:ok, true} == Xqlite.autocommit(conn)
      end
    end

    test "begin/2 accepts its three modes and leaves the measured state", %{conn: conn} do
      for {mode, expected_state} <- [deferred: :none, immediate: :write, exclusive: :write] do
        assert :ok == Xqlite.begin(conn, mode)
        assert {:ok, false} == Xqlite.autocommit(conn)
        assert {:ok, expected_state} == Xqlite.txn_state(conn)
        assert :ok == Xqlite.rollback(conn)
      end
    end

    property "wal_checkpoint/3 refuses every term that is not a mode", %{conn: conn} do
      check all(mode <- term_other_than(@checkpoint_modes), max_runs: 2000) do
        assert {:error, {:cannot_execute, reason}} =
                 Xqlite.wal_checkpoint(conn, mode, "main")

        assert is_binary(reason)
      end
    end

    property "wal_checkpoint/3 refuses a schema that is not a string", %{conn: conn} do
      check all(
              schema <- StreamData.filter(any_term(), &(not is_binary(&1))),
              max_runs: 2000
            ) do
        assert {:error, {:cannot_execute, reason}} =
                 Xqlite.wal_checkpoint(conn, :passive, schema)

        assert is_binary(reason)
      end
    end

    test "wal_checkpoint/3 accepts its four modes", %{conn: conn} do
      for mode <- @checkpoint_modes do
        assert {:ok, %{log_pages: _, checkpointed_pages: _, busy: _}} =
                 Xqlite.wal_checkpoint(conn, mode, "main")
      end
    end

    property "txn_state/2 refuses a schema that is neither a string nor nil", %{conn: conn} do
      check all(schema <- non_schema_term(), max_runs: 2000) do
        assert {:error, {:cannot_execute, reason}} = Xqlite.txn_state(conn, schema)
        assert is_binary(reason)
      end
    end

    test "txn_state/2 accepts a string schema and nil", %{conn: conn} do
      assert {:ok, :none} == Xqlite.txn_state(conn, "main")
      assert {:ok, :none} == Xqlite.txn_state(conn, nil)
      assert {:ok, :none} == Xqlite.txn_state(conn)
    end
  end
end
