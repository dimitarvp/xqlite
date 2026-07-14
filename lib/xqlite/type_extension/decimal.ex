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

    ## Availability

    This module is compiled only when the optional `:decimal` dependency is
    installed. Without it, the module does not exist. Add `{:decimal, "~> 2.0"}`
    to your deps to enable it.
    """

    @behaviour Xqlite.TypeExtension

    @impl true
    def encode(%Decimal{} = d), do: {:ok, Decimal.to_string(d, :normal)}
    def encode(_), do: :skip

    @impl true
    def decode(_), do: :skip
  end
end
