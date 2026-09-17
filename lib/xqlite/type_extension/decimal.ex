if Code.ensure_loaded?(Decimal) do
  defmodule Xqlite.TypeExtension.Decimal do
    @moduledoc """
    Type extension for `Decimal` → arbitrary-precision TEXT.

    Encodes `Decimal` structs to their plain (non-scientific) string form via
    `Decimal.to_string(d, :normal)`, preserving every significant digit.

    This extension is **encode-only**: `decode/1` always returns `:skip`.
    Deciding that a numeric-looking string should become a `Decimal` (rather
    than a float, integer, or plain string) is application-specific divination
    the library refuses to guess — load your stored decimals with an
    `Ecto.Type` or an explicit `Decimal.new/1` at the call site.

    ## Precision caveat

    Store the encoded text in a **TEXT-affinity** column. SQLite's NUMERIC and
    REAL affinities coerce any value that "looks like" a number to a 64-bit
    float on insert, silently discarding the arbitrary precision `Decimal`
    exists to preserve. A `TEXT` (or affinity-less) column keeps the exact
    digits.

    ## What it refuses

    Two kinds of `Decimal` have no plain text form and are refused rather
    than written as a word or a truncated number:

      * a value that is not a number — `NaN`, `-NaN`, `Infinity` and
        `-Infinity` — answers
        `{:error, {:non_finite, kind}}` with `kind` one of `:nan`,
        `:negative_nan`, `:infinity`, `:negative_infinity`. Writing them as
        the words `"NaN"` or `"Infinity"` would store text no reader could
        tell from data.

      * a number whose plain form needs more than 6178 digit characters
        answers `{:error, {:too_many_digits, %{digits: n, maximum: 6178}}}`.
        The count is the digits the plain form really writes: the
        coefficient's digits plus the exponent when the exponent is zero or
        more, the coefficient's digits when the exponent is negative and
        still leaves a whole part, and otherwise the leading zero plus the
        places after the point. 6178 is xqlite's own ceiling on every
        supported `:decimal` version: `Decimal.to_string/2` raises there on
        3.x and renders any length on 2.x, and refusing at one fixed point
        keeps the answer the same on both.

    Everything within the ceiling is written exactly as
    `Decimal.to_string(d, :normal)` writes it.

    ## Availability

    This module is compiled only when the optional `:decimal` dependency is
    installed. Without it, the module does not exist. Add
    `{:decimal, "~> 2.0 or ~> 3.0"}` to your deps to enable it.
    """

    @behaviour Xqlite.TypeExtension

    @max_digits 6178

    @impl true
    def encode(%Decimal{coef: :NaN, sign: 1}), do: {:error, {:non_finite, :nan}}
    def encode(%Decimal{coef: :NaN, sign: -1}), do: {:error, {:non_finite, :negative_nan}}
    def encode(%Decimal{coef: :inf, sign: 1}), do: {:error, {:non_finite, :infinity}}
    def encode(%Decimal{coef: :inf, sign: -1}), do: {:error, {:non_finite, :negative_infinity}}

    def encode(%Decimal{coef: coef, exp: exp} = d) when is_integer(coef) do
      coef
      |> digit_count()
      |> plain_digits(exp)
      |> render(d)
    end

    def encode(_), do: :skip

    @impl true
    def decode(_), do: :skip

    defp render(digits, _d) when digits > @max_digits do
      {:error, {:too_many_digits, %{digits: digits, maximum: @max_digits}}}
    end

    defp render(_digits, d), do: {:ok, Decimal.to_string(d, :normal)}

    # The rule `Decimal` itself applies before it renders the plain form.
    defp plain_digits(digits, exp) when exp >= 0, do: digits + exp
    defp plain_digits(digits, exp) when digits + exp > 0, do: digits
    defp plain_digits(_digits, exp), do: 1 - exp

    defp digit_count(coef) do
      coef
      |> abs()
      |> Integer.to_string()
      |> String.length()
    end
  end
end
