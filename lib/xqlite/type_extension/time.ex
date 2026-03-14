defmodule Xqlite.TypeExtension.Time do
  @moduledoc """
  Type extension for `Time` ↔ ISO 8601 text.

  Encodes `Time` structs as `HH:MM:SS` strings (e.g., `"10:30:00"`).
  Decodes `HH:MM:SS` strings back to `Time` structs.

  Microsecond precision is preserved in both directions.
  """

  @behaviour Xqlite.TypeExtension

  @impl true
  def encode(%Time{} = t), do: {:ok, Time.to_iso8601(t)}
  def encode(_), do: :skip

  @impl true
  def decode(value) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, t} -> {:ok, t}
      {:error, _} -> :skip
    end
  end

  def decode(_), do: :skip
end
