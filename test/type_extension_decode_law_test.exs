defmodule Xqlite.TypeExtensionDecodeLawTest do
  @moduledoc """
  Both callbacks of `Xqlite.TypeExtension` answer `{:ok, value}`, `:skip` or
  `{:error, reason}`.

  The law: a stored value `decode/1` refuses with `{:error, reason}` makes
  every function that decodes rows answer `{:error, {:type_extension_refused,
  %{column: n, extension: module, reason: reason}}}`, `n` being the value's
  one-based place in its row, whatever the row's width. A stream answers it
  under its `:on_error` mode, after the rows decoded before it. Any other
  callback answer is the same refusal with `reason: {:bad_return, answer}`.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase
  import Xqlite.Telemetry.TestSupport, only: [attach_capture: 1, assert_emitted: 2, detach: 1]

  @moduletag timeout: 300_000

  @doors [:query, :query_cancellable, :query_with_changes_cancellable, :stream, :decode_rows]
  @seed "CREATE TABLE t (v TEXT); INSERT INTO t VALUES ('a'), ('b'), ('refuse:c'), ('d');"
  @four_rows "SELECT v FROM t ORDER BY rowid"

  defmodule Picky do
    @behaviour Xqlite.TypeExtension

    @impl true
    def encode(:neither), do: :neither
    def encode(_value), do: :skip

    @impl true
    def decode("refuse:" <> _rest = value), do: {:error, {:cannot_read, value}}
    def decode("neither"), do: :neither
    def decode("legacy"), do: {:ok, {:error, :legacy}}
    def decode(_value), do: :skip
  end

  for_each_opener "a decode refusal" do
    setup %{conn: conn} do
      assert :ok = XqliteNIF.execute_batch(conn, @seed)
      :ok
    end

    test "the anchor: a value refused in the second of three columns", %{conn: conn} do
      assert refusal(2, "refuse:b") == read(:query, conn, "SELECT 1, 'refuse:b', 3", [])
    end

    property "every door answers the refusal with the value's place in its row", %{conn: conn} do
      check all(
              {values, column} <- row_with_refused_value(),
              door <- member_of(@doors),
              max_runs: 2000
            ) do
        assert {:ok, value} = Enum.fetch(values, column - 1)
        assert refusal(column, value) == read(door, conn, select_sql(length(values)), values)
      end
    end

    test "under :emit_error the rows before the refused one arrive, then the refusal",
         %{conn: conn} do
      assert [{:ok, %{"v" => "a"}}, {:ok, %{"v" => "b"}}, error] =
               conn |> Xqlite.stream(@four_rows, [], opts(:emit_error)) |> Enum.to_list()

      assert refusal(1, "refuse:c") == error
    end

    @tag capture_log: true
    test "under :halt the rows before the refused one arrive, then the stream stops",
         %{conn: conn} do
      assert [%{"v" => "a"}, %{"v" => "b"}] =
               conn |> Xqlite.stream(@four_rows, [], opts(:halt)) |> Enum.to_list()
    end

    test "under :raise the rows before the refused one arrive, then the raise", %{conn: conn} do
      stream = Xqlite.stream(conn, @four_rows, [], opts(:raise))
      error = assert_raise Xqlite.StreamError, fn -> Enum.each(stream, &send(self(), &1)) end
      assert refusal(1, "refuse:c") == {:error, error.reason}
      assert_received %{"v" => "a"}
      assert_received %{"v" => "b"}
      refute_received %{"v" => _v}
    end

    test "a callback answer outside the three shapes is a bad return, on both sides",
         %{conn: conn} do
      assert {:error,
              {:type_extension_refused, %{position: 1, reason: {:bad_return, :neither}}}} =
               Xqlite.query(conn, "SELECT ?1", [:neither], opts())

      assert {:error, {:type_extension_refused, %{column: 1, reason: {:bad_return, :neither}}}} =
               Xqlite.query(conn, "SELECT 'neither'", [], opts())
    end

    test "a value an extension decodes to an error tuple is data, not a refusal",
         %{conn: conn} do
      assert {:ok, %{rows: [[{:error, :legacy}]]}} =
               Xqlite.query(conn, "SELECT 'legacy'", [], opts())
    end

    test "a refusal comes after the statement ran: its changes stand, the stop event says so",
         %{conn: conn} do
      stop = [:xqlite, :query, :stop]
      handler_id = attach_capture([stop])
      sql = "INSERT INTO t VALUES ('refuse:x') RETURNING v"
      assert {:error, {:type_extension_refused, _} = reason} = read(:query, conn, sql, [])
      assert_emitted(stop, metadata: %{result_class: :error, error_reason: reason})
      detach(handler_id)
      assert {:ok, %{rows: [[5]]}} = Xqlite.query(conn, "SELECT count(*) FROM t")
    end
  end

  defp row_with_refused_value do
    gen all(
          width <- integer(1..8),
          column <- integer(1..width),
          others <- list_of(skipped_value(), length: width - 1),
          suffix <- binary(max_length: 8)
        ) do
      {List.insert_at(others, column - 1, "refuse:" <> suffix), column}
    end
  end

  defp skipped_value do
    skipped = filter(binary(max_length: 8), fn bytes -> Picky.decode(bytes) == :skip end)
    one_of([integer(), constant(nil), skipped])
  end

  defp refusal(column, value) do
    details = %{column: column, extension: Picky, reason: {:cannot_read, value}}
    {:error, {:type_extension_refused, details}}
  end

  defp select_sql(width),
    do: "SELECT " <> Enum.map_join(1..width, ", ", fn index -> "?#{index} AS c#{index}" end)

  defp read(:query, conn, sql, params), do: Xqlite.query(conn, sql, params, opts())

  defp read(:query_cancellable, conn, sql, params),
    do: Xqlite.query_cancellable(conn, sql, params, new_token(), opts())

  defp read(:query_with_changes_cancellable, conn, sql, params),
    do: Xqlite.query_with_changes_cancellable(conn, sql, params, new_token(), opts())

  defp read(:stream, conn, sql, params) do
    assert [only] = conn |> Xqlite.stream(sql, params, opts(:emit_error)) |> Enum.to_list()
    only
  end

  defp read(:decode_rows, conn, sql, params) do
    assert {:ok, %{rows: rows}} = Xqlite.query(conn, sql, params)
    Xqlite.TypeExtension.decode_rows(rows, [Picky])
  end

  defp opts, do: [type_extensions: [Picky]]
  defp opts(mode), do: [type_extensions: [Picky], batch_size: 10, on_error: mode]

  defp new_token do
    assert {:ok, token} = Xqlite.create_cancel_token()
    token
  end
end
