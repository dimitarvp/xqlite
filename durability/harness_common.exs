# Shared row/checksum logic for the durability crash-harness.
#
# Required (via Code.require_file/2) by BOTH writer.exs and verify.exs so the
# two processes derive payloads and checksums from an id in EXACTLY the same
# way. Any drift here would surface as a false CORRUPTION in the verifier, so
# the logic lives in one place on purpose.
defmodule Durability.Row do
  @moduledoc false

  # Deterministic BLOB payload of exactly `bytes` bytes derived from `id`:
  # a 32-byte SHA-256 of the id, tiled to the requested width, with one 0x00
  # forced in at a deterministic offset. The forced NUL makes this an A8xA9
  # cross-axis leg — a guaranteed interior-NUL BLOB must survive a mid-write
  # SIGKILL byte-exact on reopen (or be cleanly absent), never truncated at the
  # NUL nor a torn half-value. SHA output alone would carry an interior NUL only
  # ~12% of the time per 32 bytes; forcing it makes every row exercise the edge.
  # The verifier recomputes this identically.
  def payload(id, bytes) when is_integer(id) and is_integer(bytes) and bytes > 0 do
    seed = :crypto.hash(:sha256, <<id::64>>)
    reps = div(bytes, 32) + 1

    base =
      seed
      |> :binary.copy(reps)
      |> binary_part(0, bytes)

    nul_at = rem(id, bytes)
    <<head::binary-size(^nul_at), _::binary-size(1), tail::binary>> = base
    head <> <<0>> <> tail
  end

  # Deterministic TEXT value carrying interior NUL bytes, recomputable by the
  # verifier. A bound TEXT VALUE with interior NULs must round-trip byte-exact
  # (only a NUL in SQL *text* is rejected — the Run 9 distinction), so this
  # proves a pathological bound TEXT value also survives a mid-write crash.
  def nul_text(id) when is_integer(id) do
    "row" <> <<0>> <> Integer.to_string(id) <> <<0>> <> "end"
  end

  # Content checksum of a payload. CRC32 is enough to catch a torn/partial
  # page write that leaves a row whose bytes no longer match its id.
  def checksum(payload) when is_binary(payload), do: :erlang.crc32(payload)

  # Parse a positive integer argv value, halting loudly on garbage.
  def int!(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> raise ArgumentError, "expected integer, got #{inspect(str)}"
    end
  end

  # Map a journal-mode string to the atom Xqlite.open/2 expects.
  def journal_mode!("wal"), do: :wal
  def journal_mode!("delete"), do: :delete
  def journal_mode!("truncate"), do: :truncate
  def journal_mode!("memory"), do: :memory
  def journal_mode!("off"), do: :off

  # Map a synchronous string to the atom Xqlite.open/2 expects.
  def synchronous!("off"), do: :off
  def synchronous!("normal"), do: :normal
  def synchronous!("full"), do: :full
  def synchronous!("extra"), do: :extra
end
