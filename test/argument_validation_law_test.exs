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
  behind. A raw `XqliteNIF` row generates only terms its decoding takes.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias XqliteNIF, as: NIF

  @begin_modes [:deferred, :immediate, :exclusive]
  @checkpoint_modes [:passive, :full, :restart, :truncate]
  @raw_atoms_taken @begin_modes ++ @checkpoint_modes ++ [:omit, :replace, :abort]
  @usize_max 2 ** 64 - 1

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
    StreamData.filter(any_term(), fn term -> not (is_binary(term) or term == :all) end)
  end

  defp non_timeout_term do
    StreamData.one_of([
      StreamData.filter(any_term(), fn term -> term not in 0..2_147_483_647 end),
      StreamData.integer(2_147_483_648..(2 ** 70))
    ])
  end

  defp atom_other_than(accepted) do
    StreamData.filter(StreamData.atom(:alphanumeric), fn atom -> atom not in accepted end)
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
        assert {:error, {:invalid_transaction_mode, ^mode}} = Xqlite.begin(conn, mode)
        assert {:ok, true} == Xqlite.autocommit(conn)
      end
    end

    # The atoms any of the three takes are left out of all three: one atom serves all.
    property "the raw functions reject every atom that is not a mode or a strategy",
             %{conn: conn} do
      check all(a <- atom_other_than(@raw_atoms_taken), max_runs: 2000) do
        assert {:error, {:invalid_transaction_mode, ^a}} = NIF.begin(conn, a)
        assert {:error, {:invalid_checkpoint_mode, ^a}} = NIF.wal_checkpoint(conn, a, "main")
        assert {:error, {:invalid_conflict_strategy, ^a}} = NIF.changeset_apply(conn, <<>>, a)
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
        assert {:error, {:invalid_checkpoint_mode, ^mode}} =
                 Xqlite.wal_checkpoint(conn, mode, "main")
      end
    end

    property "wal_checkpoint/3 refuses a schema that is not a string", %{conn: conn} do
      check all(
              schema <- StreamData.filter(any_term(), &(not is_binary(&1))),
              max_runs: 2000
            ) do
        assert {:error, {:invalid_schema_name, ^schema}} =
                 Xqlite.wal_checkpoint(conn, :passive, schema)
      end
    end

    property "txn_state/2 rejects a schema that is neither a string nor :all", %{conn: conn} do
      check all(schema <- non_schema_term(), max_runs: 2000) do
        assert {:error, {:invalid_schema_name, ^schema}} = Xqlite.txn_state(conn, schema)
      end
    end

    test "txn_state/2 accepts a string schema and :all", %{conn: conn} do
      assert {:ok, :none} == Xqlite.txn_state(conn, "main")
      assert {:ok, :none} == Xqlite.txn_state(conn, :all)
      assert {:ok, :none} == Xqlite.txn_state(conn)
    end

    test "busy_timeout/2 refuses a negative integer, a string and 2^64", %{conn: conn} do
      for ms <- [-1, "5", 2 ** 64] do
        assert {:error, {:invalid_pragma_value, %{pragma: :busy_timeout, value: ^ms}}} =
                 Xqlite.busy_timeout(conn, ms)
      end
    end

    property "busy_timeout/2 refuses every term that is not an integer from 0 to 2^31 - 1",
             %{conn: conn} do
      check all(ms <- non_timeout_term(), max_runs: 2000) do
        rejected = {:error, {:invalid_pragma_value, %{pragma: :busy_timeout, value: ms}}}
        assert {:ok, before} = Xqlite.get_pragma(conn, :busy_timeout)
        assert ^rejected = Xqlite.busy_timeout(conn, ms)
        assert {:ok, ^before} = Xqlite.get_pragma(conn, :busy_timeout)
      end
    end

    property "the raw setters reject a busy timeout past 2^31 - 1 and keep the wait",
             %{conn: conn} do
      check all(ms <- StreamData.integer(2_147_483_648..@usize_max), max_runs: 2000) do
        rejected = {:error, {:invalid_pragma_value, %{pragma: :busy_timeout, value: ms}}}
        assert {:ok, before} = NIF.get_pragma(conn, "busy_timeout")
        assert ^rejected = NIF.set_busy_timeout(conn, ms)
        assert ^rejected = NIF.set_pragma(conn, "busy_timeout", ms)
        assert {:ok, ^before} = NIF.get_pragma(conn, "busy_timeout")
      end
    end

    property "blob_write/3 rejects every write that runs past the end and writes nothing",
             %{conn: conn} do
      :ok = NIF.execute_batch(conn, "CREATE TABLE b(d); INSERT INTO b VALUES (zeroblob(67))")
      {:ok, blob} = NIF.blob_open(conn, "main", "b", "d", 1, false)
      bytes = StreamData.binary(max_length: 80)

      check all(data <- bytes, past <- StreamData.integer(0..12), max_runs: 2000) do
        for at <- [max(68 - byte_size(data), 0) + past, @usize_max - past] do
          bounds = %{offset: at, byte_size: byte_size(data), blob_size: 67}

          assert {:error, {:blob_write_out_of_bounds, ^bounds}} =
                   NIF.blob_write(blob, at, data)
        end
      end

      assert NIF.blob_read(blob, 0, 67) == {:ok, :binary.copy(<<0>>, 67)}
      assert :ok = NIF.blob_close(blob)
    end

    test "busy_timeout/2 accepts zero and a positive integer", %{conn: conn} do
      assert :ok = Xqlite.busy_timeout(conn, 0)
      assert {:ok, 0} = Xqlite.get_pragma(conn, :busy_timeout)
      assert :ok = Xqlite.busy_timeout(conn, 250)
      assert {:ok, 250} = Xqlite.get_pragma(conn, :busy_timeout)
    end
  end
end
