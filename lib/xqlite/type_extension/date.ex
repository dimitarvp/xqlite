defmodule Xqlite.TypeExtension.Date do
  @moduledoc """
  Type extension for `Date` ↔ ISO 8601 text.

  Encodes `Date` structs as `YYYY-MM-DD` strings (e.g., `"2024-01-15"`).
  Decodes `YYYY-MM-DD` strings back to `Date` structs.
  """

  @behaviour Xqlite.TypeExtension

  @impl true
  def encode(%Date{} = d), do: {:ok, Date.to_iso8601(d)}
  def encode(_), do: :skip

  @impl true
  def decode(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, d} -> {:ok, d}
      {:error, _} -> :skip
    end
  end

  def decode(_), do: :skip
end
