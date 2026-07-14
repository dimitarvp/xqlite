defmodule Xqlite.TypeExtension.Instant do
  @moduledoc """
  Encode-only type extension: `DateTime` → int64 nanoseconds since the
  Unix epoch.

  The integer-instant alternative to `Xqlite.TypeExtension.DateTime`'s
  ISO 8601 text. Both claim `DateTime` structs, so pick ONE per chain —
  or rely on first-match ordering, where whichever extension is listed
  first wins the struct.

  There is deliberately no decode: a nanosecond instant is
  indistinguishable from any other stored integer. Read-side conversion
  belongs to the caller (or to the Ecto layer's
  `XqliteEcto3.Types.Instant`, which this module mirrors).
  """

  @behaviour Xqlite.TypeExtension

  @impl true
  def encode(%DateTime{} = dt), do: {:ok, DateTime.to_unix(dt, :nanosecond)}
  def encode(_), do: :skip

  @impl true
  def decode(_), do: :skip
end
