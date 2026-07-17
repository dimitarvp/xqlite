# Durability crash-harness NEGATIVE-CONTROL injector: deterministically deletes
# one committed row from a post-crash DB, simulating a lost committed write.
# Used by the teeth self-test to prove the verifier's LOSTWRITE classifier
# actually fires before any real PASS is trusted.
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
      IO.puts(:stderr, "inject: open failed: #{inspect(reason)}")
      System.halt(2)
  end

case Xqlite.execute(conn, "DELETE FROM t WHERE id = ?1", [id]) do
  {:ok, %{changes: 1}} ->
    Xqlite.close(conn)
    IO.puts("DELETED #{id}")

  other ->
    IO.puts(:stderr, "inject: unexpected delete result: #{inspect(other)}")
    System.halt(3)
end
