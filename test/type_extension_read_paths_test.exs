defmodule Xqlite.TypeExtensionReadPathsTest do
  @moduledoc """
  A value written with a type-extension chain reads back the same through
  both read paths.

  `query/4` decodes its rows with the chain. A prepared statement does not:
  `step/1`, `multi_step/2` and `multi_step_cancellable/3` hand back what
  SQLite stored, and `Xqlite.TypeExtension.decode_rows/2` is where the caller
  decodes them. The law below drives one generator per built-in extension
  through both paths, asserts the two answers are equal, and pins the raw row
  and its storage class to what that extension's `encode/1` produced.

  Three built-ins are encode-only (`Decimal`, `Duration`, `Instant`), `UUID`
  lower-cases its text and `JSON` turns atom keys into strings, so the law
  compares the two read paths with one another rather than against the value
  that went in. For the encode-only three it also asserts what "encode-only"
  means: `decode/1` answers `:skip` on the value SQLite stored.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Xqlite.TypeExtension
  alias XqliteNIF, as: NIF

  @encode_only [TypeExtension.Decimal, TypeExtension.Duration, TypeExtension.Instant]

  setup do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    on_exit(fn -> NIF.close(conn) end)
    :ok = NIF.execute_batch(conn, "CREATE TABLE held (x);")
    {:ok, conn: conn}
  end

  test "the anchor: a UUID is raw through step/1 and decoded through decode_rows/2",
       %{conn: conn} do
    exts = [type_extensions: [TypeExtension.UUID]]
    uuid = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
    bytes = Base.decode16!(String.replace(uuid, "-", ""), case: :lower)

    assert {:ok, %Xqlite.Result{changes: 1}} =
             Xqlite.execute(conn, "INSERT INTO held (x) VALUES (?1)", [uuid], exts)

    assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT x FROM held WHERE x = ?1")
    assert :ok = Xqlite.bind(stmt, [uuid], exts)
    assert {:row, [^bytes]} = Xqlite.step(stmt)
    assert {:ok, [[^uuid]]} = TypeExtension.decode_rows([[bytes]], [TypeExtension.UUID])
    assert :ok = Xqlite.finalize(stmt)
  end

  property "every built-in extension answers a member of the parameter type" do
    check all({extension, value} <- claimed_value(), max_runs: 2000) do
      assert {:ok, encoded} = extension.encode(value)
      assert param_member?(encoded)
    end
  end

  property "the two read paths answer the same under one chain", %{conn: conn} do
    check all({extension, value} <- claimed_value(), max_runs: 2000) do
      exts = [type_extensions: [extension]]
      assert {:ok, %Xqlite.Result{}} = Xqlite.execute(conn, "DELETE FROM held", [])

      assert {:ok, %Xqlite.Result{changes: 1}} =
               Xqlite.execute(conn, "INSERT INTO held (x) VALUES (?1)", [value], exts)

      assert {:ok, %Xqlite.Result{rows: [[decoded]]}} =
               Xqlite.query(conn, "SELECT x FROM held WHERE x = ?1", [value], exts)

      assert {:ok, %Xqlite.Result{rows: [[class]]}} =
               Xqlite.query(conn, "SELECT typeof(x) FROM held", [])

      assert {:ok, stmt} = Xqlite.prepare(conn, "SELECT x FROM held WHERE x = ?1")
      assert :ok = Xqlite.bind(stmt, [value], exts)

      assert {:row, [raw] = row} = Xqlite.step(stmt)
      assert {^raw, ^class} = encoded_form(extension, value)
      assert_skipped(extension, raw)
      assert {:ok, [[^decoded]]} = TypeExtension.decode_rows([row], [extension])

      assert :ok = Xqlite.reset(stmt)
      assert {:ok, %{rows: [^row]}} = Xqlite.multi_step(stmt, 10)
      assert {:ok, [[^decoded]]} = TypeExtension.decode_rows([row], [extension])

      assert :ok = Xqlite.reset(stmt)
      assert {:ok, token} = Xqlite.create_cancel_token()
      assert {:ok, %{rows: [^row]}} = Xqlite.multi_step_cancellable(stmt, 10, token)
      assert {:ok, [[^decoded]]} = TypeExtension.decode_rows([row], [extension])

      assert :ok = Xqlite.finalize(stmt)
    end
  end

  # An encode-only extension reads nothing back: deciding that a stored
  # number or string is one of its values is the application's call, not
  # this library's, so `decode/1` hands the raw value on untouched.
  defp assert_skipped(extension, raw) when extension in @encode_only do
    assert :skip = extension.decode(raw)
  end

  defp assert_skipped(_extension, _raw), do: :ok

  defp param_member?(%Xqlite.Blob{}), do: true

  defp param_member?(value) do
    is_integer(value) or is_float(value) or is_binary(value) or is_boolean(value) or
      is_nil(value)
  end

  defp encoded_form(extension, value) do
    assert {:ok, encoded} = extension.encode(value)
    stored_form(encoded)
  end

  defp stored_form(%Xqlite.Blob{bytes: bytes}), do: {bytes, "blob"}
  defp stored_form(encoded), do: {encoded, storage_class(encoded)}

  defp storage_class(value) when is_integer(value) or is_boolean(value), do: "integer"
  defp storage_class(value) when is_float(value), do: "real"
  defp storage_class(nil), do: "null"
  defp storage_class(value) when is_binary(value), do: binary_class(value)

  defp binary_class(value) do
    case String.valid?(value) do
      true -> "text"
      false -> "blob"
    end
  end

  # One generator per built-in extension, over values that extension claims.
  defp claimed_value do
    StreamData.one_of([
      claimed(TypeExtension.Date, date_value()),
      claimed(TypeExtension.Time, time()),
      claimed(TypeExtension.NaiveDateTime, naive_date_time()),
      claimed(TypeExtension.DateTime, date_time()),
      claimed(TypeExtension.Instant, date_time()),
      claimed(TypeExtension.UUID, uuid_text()),
      claimed(TypeExtension.JSON, json_value()),
      claimed(TypeExtension.Decimal, decimal()),
      claimed(TypeExtension.Duration, duration())
    ])
  end

  defp claimed(extension, generator) do
    StreamData.map(generator, fn value -> {extension, value} end)
  end

  defp date_value do
    -100_000..100_000
    |> StreamData.integer()
    |> StreamData.map(fn days -> Date.add(~D[2000-01-01], days) end)
  end

  defp time do
    0..86_399_999_999
    |> StreamData.integer()
    |> StreamData.map(fn us -> Time.add(~T[00:00:00.000000], us, :microsecond) end)
  end

  defp naive_date_time do
    StreamData.map(offset_microseconds(), fn us ->
      NaiveDateTime.add(~N[2000-01-01 00:00:00.000000], us, :microsecond)
    end)
  end

  defp date_time do
    StreamData.map(offset_microseconds(), fn us ->
      DateTime.add(~U[2000-01-01 00:00:00.000000Z], us, :microsecond)
    end)
  end

  defp offset_microseconds,
    do: StreamData.integer(-3_155_760_000_000_000..3_155_760_000_000_000)

  # Canonical text in either case: the extension takes both, and the blob it
  # produces is the same sixteen bytes either way.
  defp uuid_text do
    StreamData.bind(StreamData.binary(length: 16), fn bytes ->
      StreamData.map(StreamData.boolean(), fn upper -> cased_uuid(bytes, upper) end)
    end)
  end

  defp cased_uuid(<<a::binary-4, b::binary-2, c::binary-2, d::binary-2, e::binary-6>>, upper) do
    [a, b, c, d, e]
    |> Enum.map_join("-", fn part -> Base.encode16(part, case: hex_case(upper)) end)
  end

  defp hex_case(true), do: :upper
  defp hex_case(false), do: :lower

  defp json_value do
    StreamData.one_of([
      StreamData.map_of(json_key(), json_scalar(), max_length: 4),
      StreamData.list_of(json_scalar(), max_length: 4)
    ])
  end

  defp json_key do
    StreamData.one_of([
      StreamData.atom(:alphanumeric),
      StreamData.string(:alphanumeric, min_length: 1, max_length: 6)
    ])
  end

  defp json_scalar do
    StreamData.one_of([
      StreamData.integer(),
      StreamData.boolean(),
      StreamData.constant(nil),
      StreamData.string(:alphanumeric, max_length: 6)
    ])
  end

  defp decimal do
    StreamData.map(
      StreamData.tuple({
        StreamData.member_of([1, -1]),
        StreamData.integer(0..1_000_000_000),
        StreamData.integer(-8..8)
      }),
      fn {sign, coefficient, exponent} -> Decimal.new(sign, coefficient, exponent) end
    )
  end

  # Only exact units convert; a year or a month has no fixed length and the
  # extension skips it, so the generator never produces one.
  defp duration do
    StreamData.map(
      StreamData.tuple({
        StreamData.integer(-1000..1000),
        StreamData.integer(-59..59),
        StreamData.integer(-59..59),
        StreamData.integer(0..999_999)
      }),
      fn {hour, minute, second, microsecond} ->
        %Duration{hour: hour, minute: minute, second: second, microsecond: {microsecond, 6}}
      end
    )
  end
end
