defmodule Xqlite.TypeExtension.UUID do
  @moduledoc """
  Type extension for canonical UUID text ↔ compact 16-byte storage.

  Encodes a canonical hyphenated UUID string (36 chars, `8-4-4-4-12` hex,
  case-insensitive) to the raw 16-byte binary it represents — half the size of
  the textual form. SQLite stores that binary with BLOB affinity in the common
  case (real UUIDs are not valid UTF-8); the rare value whose bytes *do* form
  valid UTF-8 (e.g. the nil UUID) is stored as TEXT instead. Both are 16 bytes
  and decode identically.

  Only the canonical hyphenated form is encoded. A raw 16-byte binary passed to
  `encode/1` returns `:skip` — encoding it would be indistinguishable from an
  ordinary blob a caller wanted stored verbatim.

  > #### Decode is a 16-byte heuristic, not a type {: .warning}
  >
  > SQLite has no UUID type, and rows arrive as plain Elixir binaries with no
  > storage-class tag attached. `decode/1` therefore **cannot tell a 16-byte
  > BLOB from a 16-character TEXT value** — it converts *any* 16-byte binary to
  > a UUID string. A column holding the 16-character string `"abcdefghijklmnop"`
  > will decode to `"61626364-6566-6768-696a-6b6c6d6e6f70"`.
  >
  > Enable this extension only when every 16-byte value your query returns is a
  > UUID, and order it in the chain accordingly (place extensions that match
  > other 16-byte shapes first — they win via first-match).

  Decoded strings are always lowercase and hyphenated.
  """

  @behaviour Xqlite.TypeExtension

  @impl true
  def encode(value) when is_binary(value) and byte_size(value) == 36 do
    case value do
      <<a::binary-size(8), ?-, b::binary-size(4), ?-, c::binary-size(4), ?-, d::binary-size(4),
        ?-, e::binary-size(12)>> ->
        encode_hex(a <> b <> c <> d <> e)

      _ ->
        :skip
    end
  end

  def encode(_), do: :skip

  @impl true
  def decode(value) when is_binary(value) and byte_size(value) == 16 do
    <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
      e::binary-size(6)>> = value

    hyphenated =
      [a, b, c, d, e]
      |> Enum.map_join("-", fn part -> Base.encode16(part, case: :lower) end)

    {:ok, hyphenated}
  end

  def decode(_), do: :skip

  defp encode_hex(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> :skip
    end
  end
end
