defmodule Xqlite.TypeExtension.NaiveDateTime do
  @moduledoc """
  Type extension for `NaiveDateTime` ↔ ISO 8601 text.

  Encodes `NaiveDateTime` structs as ISO 8601 strings (e.g., `"2024-01-15T10:30:00"`).
  Decodes ISO 8601 strings back to `NaiveDateTime` structs.

  Microsecond precision is preserved in both directions.
  """

  @behaviour Xqlite.TypeExtension

  @impl true
  def encode(%NaiveDateTime{} = ndt), do: {:ok, NaiveDateTime.to_iso8601(ndt)}
  def encode(_), do: :skip

  @impl true
  def decode(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, ndt} -> {:ok, ndt}
      {:error, _} -> :skip
    end
  end

  def decode(_), do: :skip
end
