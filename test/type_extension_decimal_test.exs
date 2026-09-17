defmodule Xqlite.TypeExtension.DecimalTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.ConnCase

  alias Xqlite.TypeExtension
  alias Xqlite.TypeExtension.Decimal, as: DecimalExt
  alias XqliteNIF, as: NIF

  @ceiling 6178

  defp nines(count) do
    "9"
    |> String.duplicate(count)
    |> String.to_integer()
  end

  # The digit characters the library really renders, with its own ceiling lifted.
  defp rendered_digits(d) do
    d
    |> Decimal.to_string(:normal, max_digits: :infinity)
    |> :binary.bin_to_list()
    |> Enum.count(fn byte -> byte >= ?0 and byte <= ?9 end)
  end

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
  # Refusals: the values the extension claims but cannot render as text
  # ---------------------------------------------------------------------------

  describe "encode/1 refuses non-finite values" do
    test "the four kinds each answer their own tag" do
      assert {:error, {:non_finite, :nan}} = DecimalExt.encode(%Decimal{sign: 1, coef: :NaN})

      assert {:error, {:non_finite, :negative_nan}} =
               DecimalExt.encode(%Decimal{sign: -1, coef: :NaN})

      assert {:error, {:non_finite, :infinity}} =
               DecimalExt.encode(%Decimal{sign: 1, coef: :inf})

      assert {:error, {:non_finite, :negative_infinity}} =
               DecimalExt.encode(%Decimal{sign: -1, coef: :inf})
    end

    test "a parsed infinity is refused, not stored as a word" do
      {parsed, ""} = Decimal.parse("Infinity")
      assert {:error, {:non_finite, :infinity}} = DecimalExt.encode(parsed)
    end

    test "an overflowing multiplication is refused, not stored as a word" do
      big = Decimal.new(1, 9, 6144)
      assert {:error, {:non_finite, :infinity}} = DecimalExt.encode(Decimal.mult(big, big))
    end
  end

  describe "encode/1 refuses more digits than it can render" do
    test "the ceiling is accepted and one digit past it is refused" do
      assert {:ok, _} = DecimalExt.encode(Decimal.new(1, nines(@ceiling), 0))

      assert {:error, {:too_many_digits, %{digits: 6179, maximum: @ceiling}}} =
               DecimalExt.encode(Decimal.new(1, nines(@ceiling + 1), 0))
    end

    test "a positive exponent counts toward the ceiling" do
      assert {:ok, _} = DecimalExt.encode(Decimal.new(1, 1, @ceiling - 1))

      assert {:error, {:too_many_digits, %{digits: 6179, maximum: @ceiling}}} =
               DecimalExt.encode(Decimal.new(1, 1, @ceiling))
    end

    test "a negative exponent does not add a digit to a long coefficient" do
      assert {:ok, _} = DecimalExt.encode(Decimal.new(1, nines(@ceiling), -1))

      assert {:error, {:too_many_digits, %{digits: 6179, maximum: @ceiling}}} =
               DecimalExt.encode(Decimal.new(1, nines(@ceiling + 1), -1))
    end

    test "a negative exponent past the coefficient counts the leading zero" do
      assert {:ok, _} = DecimalExt.encode(Decimal.new(1, 1, -(@ceiling - 1)))

      assert {:error, {:too_many_digits, %{digits: 6179, maximum: @ceiling}}} =
               DecimalExt.encode(Decimal.new(1, 1, -@ceiling))
    end

    test "what Decimal.parse/1 alone can build always renders" do
      {parsed, ""} = Decimal.parse(String.duplicate("9", 34) <> "e6144")
      assert rendered_digits(parsed) == @ceiling
      assert {:ok, _} = DecimalExt.encode(parsed)
    end

    property "an ordinary decimal still renders byte-identically" do
      check all(
              sign <- StreamData.member_of([1, -1]),
              coef <- StreamData.integer(0..99_999_999_999_999_999_999),
              exp <- StreamData.integer(-50..50),
              max_runs: 2000
            ) do
        d = Decimal.new(sign, coef, exp)

        assert {:ok, text} = DecimalExt.encode(d)
        assert text == Decimal.to_string(d, :normal)
        assert rendered_digits(d) <= @ceiling
      end
    end

    property "a shape at the ceiling is refused exactly when the library raises" do
      check all(
              extra <- StreamData.integer(-8..8),
              exp <- StreamData.integer(-3..3),
              max_runs: 2000
            ) do
        d = Decimal.new(1, nines(@ceiling + extra), exp)

        case DecimalExt.encode(d) do
          {:ok, text} ->
            # A library that refused this shape would raise right here.
            assert text == Decimal.to_string(d, :normal)
            assert rendered_digits(d) <= @ceiling

          {:error, {:too_many_digits, %{digits: counted, maximum: @ceiling}}} ->
            assert counted == rendered_digits(d)
            assert counted > @ceiling
            assert_raise ArgumentError, fn -> Decimal.to_string(d, :normal) end
        end
      end
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
        CREATE TABLE dec_four (a TEXT, b TEXT, c TEXT, d TEXT);
        """)

      :ok
    end

    test "encodes to exact TEXT; decode leaves it a string to re-parse", %{conn: conn} do
      d = Decimal.new("12345.67890")
      {:ok, params} = TypeExtension.encode_params([1, d], [DecimalExt])

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

    property "a non-finite decimal is refused at its own position and writes nothing", %{
      conn: conn
    } do
      check all(
              kind <-
                StreamData.member_of([:nan, :negative_nan, :infinity, :negative_infinity]),
              expected <- StreamData.integer(1..4),
              max_runs: 2000
            ) do
        params = List.replace_at(["w", "x", "y", "z"], expected - 1, non_finite(kind))

        assert {:error,
                {:type_extension_refused,
                 %{position: ^expected, extension: DecimalExt, reason: {:non_finite, ^kind}}}} =
                 Xqlite.query(
                   conn,
                   "INSERT INTO dec_four (a, b, c, d) VALUES (?1, ?2, ?3, ?4)",
                   params,
                   type_extensions: [DecimalExt]
                 )
      end

      assert {:ok, %Xqlite.Result{rows: [[0]]}} =
               Xqlite.query(conn, "SELECT count(*) FROM dec_four", [])
    end

    test "a refused parameter reaches no other entry point either", %{conn: conn} do
      params = [1, non_finite(:nan)]
      exts = [type_extensions: [DecimalExt]]

      assert {:error, {:type_extension_refused, %{position: 2}}} =
               Xqlite.execute(
                 conn,
                 "INSERT INTO dec_test (id, amount) VALUES (?1, ?2)",
                 params,
                 exts
               )

      assert {:error, {:type_extension_refused, %{position: 2}}} =
               Xqlite.stream(conn, "SELECT ?1, ?2", params, exts)
    end
  end

  defp non_finite(:nan), do: %Decimal{sign: 1, coef: :NaN}
  defp non_finite(:negative_nan), do: %Decimal{sign: -1, coef: :NaN}
  defp non_finite(:infinity), do: %Decimal{sign: 1, coef: :inf}
  defp non_finite(:negative_infinity), do: %Decimal{sign: -1, coef: :inf}
end
