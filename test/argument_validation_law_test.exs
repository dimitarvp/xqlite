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

  alias XqliteNIF, as: NIF

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

  defp non_timeout_term do
    StreamData.filter(any_term(), fn term -> not (is_integer(term) and term >= 0) end)
  end

  # The raw stream door takes the connection, the SQL and the parameters, and
  # nothing else: an argument no code reads cannot be judged, so it is not
  # there to be passed.
  test "the raw stream door takes three arguments and no more" do
    assert {:module, XqliteNIF} = Code.ensure_loaded(XqliteNIF)
    assert function_exported?(XqliteNIF, :stream_open, 3)
    refute function_exported?(XqliteNIF, :stream_open, 4)
  end

  for_each_opener do
    property "begin/2 refuses every term that is not a transaction mode", %{conn: conn} do
      check all(mode <- term_other_than(@begin_modes), max_runs: 2000) do
        assert {:error, :invalid_transaction_mode} == Xqlite.begin(conn, mode)
        assert {:ok, true} == Xqlite.autocommit(conn)
      end
    end

    # Every door prepares the SQL before it reads the parameters, so a call
    # that is wrong in both ways reports the SQL. One example per door keeps
    # that order visible: a change to it shows up here, not in a user's code.
    test "a bad SQL and a bad parameter together answer the SQL error", %{conn: conn} do
      sql = "this is not sql"
      params = [<<1::1>>]

      answers = [
        {:nif_query, NIF.query(conn, sql, params)},
        {:nif_execute, NIF.execute(conn, sql, params)},
        {:nif_query_with_changes, NIF.query_with_changes(conn, sql, params)},
        {:nif_explain_analyze, NIF.explain_analyze(conn, sql, params)},
        {:nif_stream_open, NIF.stream_open(conn, sql, params)},
        {:query, Xqlite.query(conn, sql, params)},
        {:stream, Xqlite.stream(conn, sql, params)}
      ]

      for {door, answer} <- answers do
        assert {^door, {:error, {:sql_input_error, %{code: 1}}}} = {door, answer}
      end

      assert :ok = Xqlite.close(conn)
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

    test "busy_timeout/2 refuses a negative integer and a string", %{conn: conn} do
      assert {:error, {:cannot_execute, negative}} = Xqlite.busy_timeout(conn, -1)
      assert is_binary(negative)

      assert {:error, {:cannot_execute, text}} = Xqlite.busy_timeout(conn, "5")
      assert is_binary(text)
    end

    property "busy_timeout/2 refuses every term that is not a non-negative integer",
             %{conn: conn} do
      check all(ms <- non_timeout_term(), max_runs: 2000) do
        assert {:ok, before} = Xqlite.get_pragma(conn, :busy_timeout)
        assert {:error, {:cannot_execute, reason}} = Xqlite.busy_timeout(conn, ms)
        assert is_binary(reason)
        assert {:ok, ^before} = Xqlite.get_pragma(conn, :busy_timeout)
      end
    end

    test "busy_timeout/2 accepts zero and a positive integer", %{conn: conn} do
      assert :ok = Xqlite.busy_timeout(conn, 0)
      assert {:ok, 0} = Xqlite.get_pragma(conn, :busy_timeout)
      assert :ok = Xqlite.busy_timeout(conn, 250)
      assert {:ok, 250} = Xqlite.get_pragma(conn, :busy_timeout)
    end
  end
end
