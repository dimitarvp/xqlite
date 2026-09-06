defmodule Xqlite.StreamCloseReasonLawTest do
  @moduledoc """
  `[:xqlite, :stream, :close]` reports how the stream ended, not how the
  closing call went: `:drained` when every row was read, `:halted` when the
  consumer stopped early, `:errored` when a fetch failed — in all three
  `:on_error` modes, the raising one included.

  A failed close no longer changes that reason; it adds `close_error` to the
  metadata instead.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.Telemetry.TestSupport, only: [attach_capture: 1, detach: 1]

  alias XqliteNIF, as: NIF

  @moduletag capture_log: true

  @row_count 20

  setup do
    assert {:ok, conn} = Xqlite.open_in_memory()

    :ok =
      NIF.execute_batch(conn, """
      CREATE TABLE t (id INTEGER PRIMARY KEY);
      CREATE TABLE bad (id INTEGER PRIMARY KEY, v TEXT);
      """)

    for id <- 1..@row_count do
      assert {:ok, 1} = NIF.execute(conn, "INSERT INTO t (id) VALUES (?1);", [id])
    end

    for id <- 1..@row_count do
      value =
        case id do
          2 -> "CAST(X'FF41' AS TEXT)"
          _ -> "'ok#{id}'"
        end

      assert {:ok, 1} =
               NIF.execute(conn, "INSERT INTO bad (id, v) VALUES (#{id}, #{value});", [])
    end

    handler_id = attach_capture([[:xqlite, :stream, :close]])

    on_exit(fn ->
      detach(handler_id)
      Xqlite.close(conn)
    end)

    {:ok, conn: conn}
  end

  defp scenario do
    gen all(
          outcome <- StreamData.member_of([:drained, :halted, :errored]),
          rows <- StreamData.integer(2..@row_count),
          batch <- StreamData.integer(1..6),
          take <- StreamData.integer(1..@row_count),
          on_error <- StreamData.member_of([:raise, :halt, :emit_error])
        ) do
      {outcome, rows, batch, min(take, rows - 1), on_error}
    end
  end

  defp good_stream(conn, rows, batch) do
    Xqlite.stream(conn, "SELECT id FROM t WHERE id <= #{rows} ORDER BY id", [],
      batch_size: batch
    )
  end

  defp bad_stream(conn, rows, batch, on_error) do
    Xqlite.stream(conn, "SELECT v FROM bad WHERE id <= #{rows} ORDER BY id", [],
      batch_size: batch,
      on_error: on_error
    )
  end

  defp consume(conn, :drained, rows, batch, _take, _on_error) do
    conn |> good_stream(rows, batch) |> Enum.to_list()
  end

  defp consume(conn, :halted, rows, batch, take, _on_error) do
    conn |> good_stream(rows, batch) |> Enum.take(take)
  end

  defp consume(conn, :errored, rows, batch, _take, :raise) do
    stream = bad_stream(conn, rows, batch, :raise)
    assert_raise Xqlite.StreamError, fn -> Enum.to_list(stream) end
  end

  defp consume(conn, :errored, rows, batch, _take, on_error) do
    conn |> bad_stream(rows, batch, on_error) |> Enum.to_list()
  end

  describe "close reason" do
    property "the close event reports the outcome the consumer produced",
             %{conn: conn} do
      check all({outcome, rows, batch, take, on_error} <- scenario(), max_runs: 2000) do
        consume(conn, outcome, rows, batch, take, on_error)

        assert_receive {:telemetry_event, [:xqlite, :stream, :close], _measurements, metadata}

        assert metadata.reason == outcome
        refute Map.has_key?(metadata, :close_error)
      end
    end

    test "an error stream in :emit_error mode closes with :errored", %{conn: conn} do
      results = conn |> bad_stream(@row_count, 1, :emit_error) |> Enum.to_list()

      assert [{:ok, _} | _] = results
      assert {:error, _reason} = List.last(results)

      assert_receive {:telemetry_event, [:xqlite, :stream, :close], _, %{reason: :errored}}
    end

    test "a consumer that stops early closes with :halted", %{conn: conn} do
      assert [_, _] = conn |> good_stream(@row_count, 3) |> Enum.take(2)

      assert_receive {:telemetry_event, [:xqlite, :stream, :close], _, %{reason: :halted}}
    end

    test "a fully read stream closes with :drained", %{conn: conn} do
      assert @row_count = conn |> good_stream(@row_count, 3) |> Enum.to_list() |> length()

      assert_receive {:telemetry_event, [:xqlite, :stream, :close], _, %{reason: :drained}}
    end
  end
end
