# Shared helpers for the A7 concurrency probe harness.
#
# Required (via Code.require_file/2) by every probe .exs so payload/checksum
# derivation and DB invariants are defined in exactly one place. Any drift
# would surface as a false CORRUPTION, so the logic lives here on purpose.
#
# This file is NOT under test/ and is never compiled by `mix compile` /
# `mix test.seq` — it is loaded only by `bash concurrency/run.sh`.
defmodule Concurrency.Probe do
  @moduledoc false

  # Deterministic payload of exactly `bytes` bytes derived from `id`: a
  # SHA-256 of the id, tiled and truncated. Lets the verifier recompute the
  # expected bytes for any present id and catch a torn / wrong value.
  def payload(id, bytes) when is_integer(id) and is_integer(bytes) and bytes > 0 do
    seed = :crypto.hash(:sha256, <<id::64>>)
    reps = div(bytes, 32) + 1

    seed
    |> :binary.copy(reps)
    |> binary_part(0, bytes)
  end

  def checksum(payload) when is_binary(payload), do: :erlang.crc32(payload)

  def int!(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> raise ArgumentError, "expected integer, got #{inspect(str)}"
    end
  end

  # Open a fresh file-backed connection with explicit, realistic options.
  def open!(path, jmode \\ :wal) do
    opts = [
      journal_mode: jmode,
      synchronous: :normal,
      foreign_keys: false,
      busy_timeout: 5_000
    ]

    case Xqlite.open(path, opts) do
      {:ok, conn} -> conn
      {:error, reason} -> raise "open failed: #{inspect(reason)}"
    end
  end

  def create_table!(conn) do
    {:ok, _} =
      Xqlite.execute(
        conn,
        "CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY, payload BLOB NOT NULL, ck INTEGER NOT NULL)",
        []
      )

    :ok
  end

  # PRAGMA integrity_check — the corruption oracle. Returns :ok or {:bad, detail}.
  def integrity(conn) do
    case Xqlite.query(conn, "PRAGMA integrity_check", []) do
      {:ok, %{rows: [["ok"]]}} -> :ok
      {:ok, %{rows: rows}} -> {:bad, {:integrity_check, rows}}
      {:error, reason} -> {:bad, {:integrity_check_error, reason}}
    end
  end

  # Read all rows and verify each present row's payload matches its id.
  # Returns {:ok, id_set} or {:bad, detail}.
  def read_and_check_rows(conn, row_bytes) do
    case Xqlite.query(conn, "SELECT id, payload, ck FROM t ORDER BY id", []) do
      {:ok, %{rows: rows}} ->
        bad =
          Enum.find(rows, fn [id, payload, ck] ->
            expected = payload(id, row_bytes)
            payload != expected or ck != checksum(expected)
          end)

        case bad do
          nil -> {:ok, MapSet.new(Enum.map(rows, fn [id, _p, _c] -> id end))}
          [id, _p, _c] -> {:bad, {:bad_checksum, id}}
        end

      {:error, reason} ->
        {:bad, {:select_error, reason}}
    end
  end

  # Insert one (id) row autocommit. Returns :ok on a durable single-row insert,
  # :busy on SQLITE_BUSY, or {:error, reason}. `payload/checksum` are derived
  # from id so the verifier can validate the bytes.
  def insert(conn, id, row_bytes) do
    p = payload(id, row_bytes)
    ck = checksum(p)

    case Xqlite.execute(conn, "INSERT INTO t(id, payload, ck) VALUES(?1, ?2, ?3)", [id, p, ck]) do
      {:ok, _n} -> :ok
      {:error, {:database_busy_or_locked, _ext_code, _msg}} -> :busy
      {:error, reason} -> {:error, reason}
    end
  end

  def emit(class, code, detail) do
    IO.puts("RESULT class=#{class} detail=#{inspect(detail)}")
    System.halt(code)
  end
end
