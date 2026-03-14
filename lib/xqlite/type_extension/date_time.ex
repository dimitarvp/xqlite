defmodule Xqlite.TypeExtension.DateTime do
  @moduledoc """
  Type extension for `DateTime` ↔ ISO 8601 text.

  Encodes `DateTime` structs as ISO 8601 strings (e.g., `"2024-01-15T10:30:00Z"`).
  Decodes ISO 8601 strings back to `DateTime` structs.

  Microsecond precision is preserved in both directions.
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
