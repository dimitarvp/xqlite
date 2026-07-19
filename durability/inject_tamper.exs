# Durability crash-harness NEGATIVE-CONTROL injector (typed-value leg):
# corrupts ONE row's stored interior-NUL TEXT value WITHOUT touching the file
# structure (a normal UPDATE, so PRAGMA integrity_check stays "ok"). This proves
# the verifier's byte-exact TYPED-VALUE check fires (CORRUPTION) before any real
# PASS is trusted — the teeth for the A8xA9 cross-axis value leg. integrity_check
# alone cannot catch a wrong-but-well-formed value; the byte-exact recompute can.
#
# argv: <db_path> <journal_mode> <synchronous> <id>
Code.require_file("harness_common.exs", __DIR__)

[db_path, jmode_s, sync_s, id_s] = System.argv()

jmode = Durability.Row.journal_mode!(jmode_s)
sync = Durability.Row.synchronous!(sync_s)
id = Durability.Row.int!(id_s)

open_opts = [journal_mode: jmode, synchronous: sync, foreign_keys: false, busy_timeout: 5_000]

conn =
  case Xqlite.open(db_path, open_opts) do
    {:ok, conn} ->
      conn

    {:error, reason} ->
      IO.puts(:stderr, "tamper: open failed: #{inspect(reason)}")
      System.halt(2)
  end

# Flip the typed TEXT value to a byte-different (but same-storage-class) value so
# integrity_check stays "ok" yet the byte-exact recompute in verify.exs fails.
tampered = "TAMPERED" <> <<0>> <> Integer.to_string(id)

case Xqlite.execute(conn, "UPDATE t SET nt = ?1 WHERE id = ?2", [tampered, id]) do
  {:ok, %{changes: 1}} ->
    Xqlite.close(conn)
    IO.puts("TAMPERED #{id}")

  other ->
    IO.puts(:stderr, "tamper: unexpected update result: #{inspect(other)}")
    System.halt(3)
end
