defmodule Xqlite.TypeExtension.DateTime do
  @moduledoc """
  Type extension for `DateTime` ↔ ISO 8601 text.

  Encodes `DateTime` structs as ISO 8601 strings (e.g., `"2024-01-15T10:30:00Z"`).
  Decodes ISO 8601 strings back to `DateTime` structs.

  Microsecond precision is preserved in both directions.

  The offset is written but not restored. `encode/1` writes whatever
  offset the value carries (`...Z`, `...+02:00`); `decode/1` applies
  that offset and hands back a UTC `DateTime`, so the instant survives
  the round trip and the original offset does not. Use
  `Xqlite.TypeExtension.Instant` when you want the instant as an
  integer, or the Ecto adapter's `XqliteEcto3.Types.TimestampTZ` when
  the offset itself has to come back.
  """

  @behaviour Xqlite.TypeExtension

  @impl true
  def encode(%DateTime{} = dt), do: {:ok, DateTime.to_iso8601(dt)}
  def encode(_), do: :skip

  @impl true
  def decode(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> :skip
    end
  end

  def decode(_), do: :skip
end
