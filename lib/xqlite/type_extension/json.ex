defmodule Xqlite.TypeExtension.JSON do
  @moduledoc """
  Type extension for plain maps and lists ↔ JSON text.

  Encodes plain (non-struct) maps and lists to JSON text via `Jason.encode/1`.
  Decodes TEXT that looks like a JSON object or array back to Elixir terms via
  `Jason.decode/1`.

  Structs are deliberately *not* encoded — a `Date`, `NaiveDateTime`, `Decimal`,
  etc. belongs to its own extension, and capturing it here would shadow the more
  specific converter. Terms `Jason` cannot encode (for example a map holding an
  invalid-UTF-8 binary value) return `:skip`, so they fall through to the NIF's
  own structured rejection instead of being swallowed.

  ## Round-trip caveat

  Decoding is shape-driven: **any** stored TEXT whose first non-whitespace byte
  is `{` or `[` and which parses as JSON will be decoded to a map or list. That
  is the point of opting in — but it means a column that merely *happens* to
  hold JSON-shaped text is also decoded. Place more specific extensions before
  this one in the chain (they win on `decode/1` via first-match), and only enable
  `JSON` for queries whose JSON-shaped columns you actually want parsed.

  Object keys round-trip as strings (JSON has no atom keys): encoding
  `%{a: 1}` and decoding yields `%{"a" => 1}`.
  """

  @behaviour Xqlite.TypeExtension

  @impl true
  def encode(value) when is_map(value) and not is_struct(value), do: encode_json(value)
  def encode(value) when is_list(value), do: encode_json(value)
  def encode(_), do: :skip

  @impl true
  def decode(value) when is_binary(value) do
    case json_shaped?(value) do
      true -> decode_json(value)
      false -> :skip
    end
  end

  def decode(_), do: :skip

  defp encode_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> {:ok, json}
      {:error, _} -> :skip
    end
  end

  defp decode_json(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> :skip
    end
  end

  defp json_shaped?(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: json_shaped?(rest)
  defp json_shaped?(<<?{, _::binary>>), do: true
  defp json_shaped?(<<?[, _::binary>>), do: true
  defp json_shaped?(_), do: false
end
