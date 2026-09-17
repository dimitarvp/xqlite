defmodule Xqlite.NIF.BlobParamLawTest do
  @moduledoc """
  The whole rule for binding a binary parameter, over a generated domain.

  For any binary `b`:

    * bound plain, SQLite stores `TEXT` exactly when `String.valid?(b)` and
      `BLOB` otherwise;
    * bound as `%Xqlite.Blob{bytes: b}`, SQLite stores `BLOB` always;
    * either way the value read back is byte-identical to `b`.

  SQLite itself is the oracle: `typeof(?1)` reports the storage class of the
  bound value, so the law compares the library against the engine rather than
  against a table written by hand.

  The expected class comes from `String.valid?/1` on the generated value, never
  from which generator produced it — `StreamData.binary/0` is valid UTF-8 a few
  per cent of the time, so a law that assumed "bytes generator means blob" would
  be asserting the wrong thing on those runs. The two counters make sure both
  classes really occur; a domain that drifted to one class would otherwise pass
  while testing half the rule.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias Xqlite.Blob
  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  @sql "SELECT typeof(?1), ?1"

  for_each_opener "parameter storage class" do
    test "the anchor: the same sixteen bytes, plain and wrapped", %{conn: conn} do
      bytes = "0123456789abcdef"

      assert {:ok, %{rows: [["text", ^bytes]]}} = NIF.query(conn, @sql, [bytes])
      assert {:ok, %{rows: [["blob", ^bytes]]}} = NIF.query(conn, @sql, [%Blob{bytes: bytes}])
    end

    property "plain follows UTF-8 validity, wrapped is always blob, bytes survive both",
             %{conn: conn} do
      seen = :counters.new(2, [])

      check all(value <- parameter_value(), max_runs: 2000) do
        expected = expected_class(value)

        assert {:ok, %{rows: [[^expected, plain_back]]}} = NIF.query(conn, @sql, [value])
        assert plain_back == value

        assert {:ok, %{rows: [["blob", wrapped_back]]}} =
                 NIF.query(conn, @sql, [%Blob{bytes: value}])

        assert wrapped_back == value

        :counters.add(seen, class_index(expected), 1)
      end

      assert :counters.get(seen, 1) > 0
      assert :counters.get(seen, 2) > 0
    end
  end

  # Printable strings are always valid UTF-8; random bytes almost never are.
  # Interleaving them puts both classes in the domain in useful numbers.
  defp parameter_value do
    StreamData.one_of([
      StreamData.string(:printable, max_length: 64),
      StreamData.binary(max_length: 64)
    ])
  end

  defp expected_class(value) do
    case String.valid?(value) do
      true -> "text"
      false -> "blob"
    end
  end

  defp class_index("text"), do: 1
  defp class_index("blob"), do: 2
end
