defmodule Xqlite.NIF.BitstringParamLawTest do
  @moduledoc """
  A parameter whose bit size is not a whole number of bytes, over every door.

  The BEAM has one term type for binaries and bitstrings alike, so the binder
  meets both in the same arm; a binary binds as TEXT or BLOB by its UTF-8
  validity (`Xqlite.NIF.BlobParamLawTest` states that half), and the only value
  left for the arm to refuse is a bitstring that is not a whole number of
  bytes. The law: every door that takes parameters refuses it as
  `{:unsupported_data_type, :bitstring}`, wherever in the parameter list it
  sits and whatever the door.

  The shape carries no position, so the law varies where the bitstring sits and
  asserts the shape alone. The anchor beside it pins one bitstring and one pid,
  the pid guarding the shared term-type table this arm reads.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  @moduletag timeout: 300_000

  @refusal {:unsupported_data_type, :bitstring}

  for_each_opener "a partial-byte bitstring parameter" do
    test "the anchor: a bitstring is refused, a pid still names itself", %{conn: conn} do
      assert {:error, @refusal} = Xqlite.query(conn, "SELECT ?1", [<<1::7>>])

      assert {:error, {:unsupported_data_type, :pid}} =
               Xqlite.query(conn, "SELECT ?1", [self()])
    end

    property "every parameter door refuses it, wherever it sits", %{conn: conn} do
      check all({bits, position, count} <- placement(), max_runs: 2000) do
        params = params_with(bits, position, count)

        for {door, answer} <- doors(conn, count, params, bits) do
          assert {^door, {:error, @refusal}} = {door, answer}
        end
      end
    end
  end

  defp doors(conn, count, params, bits) do
    sql = positional_sql(count)

    [
      {:query, Xqlite.query(conn, sql, params)},
      {:execute, Xqlite.execute(conn, sql, params)},
      {:stream, Xqlite.stream(conn, sql, params)},
      {:keyword, Xqlite.query(conn, "SELECT :only", only: bits)},
      {:bind, bound(conn, sql, params)}
    ]
  end

  defp bound(conn, sql, params) do
    assert {:ok, stmt} = Xqlite.prepare(conn, sql)
    answer = Xqlite.bind(stmt, params)
    assert :ok = Xqlite.finalize(stmt)

    answer
  end

  defp positional_sql(count) do
    placeholders = Enum.map_join(1..count//1, ", ", &placeholder/1)
    "SELECT " <> placeholders
  end

  defp placeholder(index), do: "?#{index}"

  defp params_with(bits, position, count) do
    1..count//1
    |> Enum.to_list()
    |> List.replace_at(position - 1, bits)
  end

  defp placement do
    gen all(
          bits <- partial_byte_bitstring(),
          count <- StreamData.integer(1..4),
          position <- StreamData.integer(1..count)
        ) do
      {bits, position, count}
    end
  end

  defp partial_byte_bitstring do
    StreamData.bitstring()
    |> StreamData.scale(fn size -> min(size, 32) end)
    |> StreamData.filter(&partial_byte?/1)
  end

  defp partial_byte?(bits), do: rem(bit_size(bits), 8) != 0
end
