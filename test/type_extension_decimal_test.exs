defmodule Xqlite.TypeExtension.DecimalTest do
  use ExUnit.Case, async: true

  import Xqlite.ConnCase

  alias Xqlite.TypeExtension
  alias Xqlite.TypeExtension.Decimal, as: DecimalExt
  alias XqliteNIF, as: NIF

  # ---------------------------------------------------------------------------
  # Compile-gate wiring: the module exists only when :decimal is installed.
  # :decimal is an optional dep, but optional deps of the top-level project are
  # fetched for dev/test, so it must be present (and loaded) here.
  # ---------------------------------------------------------------------------

  describe "compile gate" do
    test "the extension module is compiled and loadable" do
      assert Code.ensure_loaded?(Xqlite.TypeExtension.Decimal)
    end
  end

  # ---------------------------------------------------------------------------
  # Unit tests: encode
  # ---------------------------------------------------------------------------

  describe "encode/1" do
    test "encodes a Decimal to its plain string form" do
      assert {:ok, "123.45"} = DecimalExt.encode(Decimal.new("123.45"))
    end

    test "preserves trailing zeros (exact digits)" do
      assert {:ok, "123.4500"} = DecimalExt.encode(Decimal.new("123.4500"))
    end

    test "encodes negatives and integers" do
      assert {:ok, "-42"} = DecimalExt.encode(Decimal.new("-42"))
      assert {:ok, "1000"} = DecimalExt.encode(Decimal.new("1000"))
    end

    test "renders exponent notation in :normal (non-scientific) form" do
      assert {:ok, "1000"} = DecimalExt.encode(Decimal.new("1E3"))
      assert {:ok, "0.0015"} = DecimalExt.encode(Decimal.new("1.5E-3"))
    end

    test "skips non-Decimal values" do
      assert :skip = DecimalExt.encode(42)
      assert :skip = DecimalExt.encode(3.14)
      assert :skip = DecimalExt.encode("123.45")
      assert :skip = DecimalExt.encode(nil)
      assert :skip = DecimalExt.encode(%{})
      assert :skip = DecimalExt.encode(~D[2024-01-15])
    end
  end

  # ---------------------------------------------------------------------------
  # Unit tests: decode (encode-only extension — always skips)
  # ---------------------------------------------------------------------------

  describe "decode/1" do
    test "always skips (deciding a string is a Decimal is application-specific)" do
      assert :skip = DecimalExt.decode("123.45")
      assert :skip = DecimalExt.decode("0")
      assert :skip = DecimalExt.decode(42)
      assert :skip = DecimalExt.decode(3.14)
      assert :skip = DecimalExt.decode(nil)
      assert :skip = DecimalExt.decode(Decimal.new("1"))
    end
  end

  # ---------------------------------------------------------------------------
  # Integration: round-trip through a real connection (stream + type_extensions)
  # ---------------------------------------------------------------------------

  for_each_opener "Decimal round-trip" do
    setup %{conn: conn} do
      :ok =
        NIF.execute_batch(conn, """
        CREATE TABLE dec_test (id INTEGER PRIMARY KEY, amount TEXT);
        """)

      :ok
    end

    test "encodes to exact TEXT; decode leaves it a string to re-parse", %{conn: conn} do
      d = Decimal.new("12345.67890")
      params = TypeExtension.encode_params([1, d], [DecimalExt])

      {:ok, 1} = NIF.execute(conn, "INSERT INTO dec_test (id, amount) VALUES (?1, ?2)", params)

      # Stored losslessly as TEXT (no float coercion in a TEXT column).
      {:ok, %{rows: [["text"]]}} =
        NIF.query(conn, "SELECT typeof(amount) FROM dec_test WHERE id = 1", [])

      # Decode is a no-op for Decimal, so the value returns as its exact string.
      [row] =
        Xqlite.stream(conn, "SELECT amount FROM dec_test WHERE id = 1", [],
          type_extensions: [DecimalExt]
        )
        |> Enum.to_list()

      assert row["amount"] == "12345.67890"
      assert Decimal.equal?(Decimal.new(row["amount"]), d)
    end
  end
end
