defmodule Xqlite.NIF.ChildDropTest do
  # Two connections to one file, so outside the `connection_openers` loop. One normal
  # scheduler runs every process here, and busy timeouts are the only waits.
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Xqlite.TestUtil, only: [tmp_db_path: 1]

  alias XqliteNIF, as: NIF

  @moduletag timeout: 300_000

  @kinds ~w(stmt stepped finalized stream fetched exhausted blob blob_rw blob_closed session deleted)a

  setup do
    online = :erlang.system_flag(:schedulers_online, 1)
    on_exit(fn -> :erlang.system_flag(:schedulers_online, online) end)
    main = tmp_db_path("child_drop")
    aux = tmp_db_path("child_drop_aux")
    {:ok, a} = Xqlite.open(main, synchronous: :off)
    {:ok, b} = Xqlite.open(main, busy_timeout: 10_000, synchronous: :off)
    {:ok, _} = Xqlite.execute(a, "CREATE TABLE t (x)")
    {:ok, _} = Xqlite.execute(a, "INSERT INTO t VALUES ('seed')")
    {:ok, _} = Xqlite.execute(a, "ATTACH DATABASE ?1 AS aux", [aux])
    {:ok, _} = Xqlite.execute(a, "CREATE TABLE aux.u (x, b)")
    {:ok, _} = Xqlite.execute(a, "INSERT INTO aux.u VALUES (1, x'00'), (2, x'00')")
    # `aux` keeps the rollback journal: a read of `a`'s there holds a lock `c` meets.
    {:ok, c} = Xqlite.open(aux, journal_mode: :delete, busy_timeout: 10_000)
    {:ok, _} = Xqlite.register_busy_observer(a, self())
    :ok = Xqlite.put_busy_timeout(a, 10_000)
    on_exit(fn -> for conn <- [a, b, c], do: :ok = Xqlite.close(conn) end)
    %{a: a, b: b, c: c}
  end

  test "a statement collected while its connection waits lets the wait finish", %{a: a, b: b} do
    Process.put(:children, [child(a, :stmt)])
    assert {:ok, %Xqlite.Result{changes: 1}} = collect_while_a_waits(a, b)
    assert {:ok, %{rows: rows}} = Xqlite.query(b, "SELECT x FROM t ORDER BY rowid")
    assert rows == [["seed"], ["from b"], ["from a"]]
  end

  test "a holder that exits while its connection waits lets the wait finish", %{a: a, b: b} do
    {:ok, holder} = Agent.start(fn -> prepare(a, "SELECT 1") end)
    exit_holder = fn -> Agent.stop(holder) end
    assert {:ok, %Xqlite.Result{changes: 1}} = collect_while_a_waits(a, b, exit_holder)
  end

  for kind <- [:stepped, :fetched, :blob] do
    test "a #{kind} handle collected in a wait is released by it", %{a: a, b: b, c: c} do
      Process.put(:children, [child(a, unquote(kind))])
      assert {:ok, :read} = Xqlite.txn_state(a, "aux")
      assert {:ok, %Xqlite.Result{changes: 1}} = collect_while_a_waits(a, b)
      assert exclusive(c) == :ok
    end
  end

  test "a deleted session collected while its connection waits takes no lock", %{a: a, b: b} do
    Process.put(:children, [child(a, :deleted)])
    assert {:ok, %Xqlite.Result{changes: 1}} = collect_while_a_waits(a, b)
  end

  test "a write collected while idle commits once the reader is gone", %{a: a, c: c} do
    reader = c |> prepare("SELECT x FROM u") |> step()
    Process.put(:children, [child(a, {:write, "aux.u"})])
    collect(:children)
    :ok = NIF.stmt_finalize(reader)
    assert {:ok, :none} = Xqlite.txn_state(a, "aux")
    assert {:ok, %{rows: [[1]]}} = Xqlite.query(c, "SELECT count(*) FROM u WHERE x = 'w'")
  end

  test "a write collected on an idle connection lets the next writer in", %{a: a, b: b} do
    Process.put(:children, [child(a, {:write, "t"})])
    collect(:children)
    assert {:ok, %Xqlite.Result{changes: 1}} = Xqlite.execute(b, "INSERT INTO t VALUES ('b')")
  end

  test "a busy connection never holds up another connection's release", %{a: a, b: b} do
    Process.put(:children, [child(a, :stmt)])
    Process.put(:write, child(b, {:write, "t"}))
    insert = Task.async(fn -> Xqlite.execute(a, "INSERT INTO t VALUES ('from a')") end)
    assert_receive {:xqlite_busy, _, _}, 10_000
    collect(:children)
    collect(:write)
    assert {:ok, %Xqlite.Result{changes: 1}} = Task.await(insert, 20_000)
  end

  property "collected children are released while `a` waits or idles", %{a: a, b: b, c: c} do
    check all(
            kinds <- list_of(member_of(@kinds), min_length: 1, max_length: 6),
            waits <- boolean(),
            max_runs: 2_000,
            max_shrinking_steps: 10
          ) do
      flush_busy()
      {:ok, %{rows: [[before]]}} = Xqlite.query(b, "SELECT count(*) FROM t")
      Process.put(:children, Enum.map(kinds, &child(a, &1)))

      if waits,
        do: assert({:ok, %Xqlite.Result{changes: 1}} = collect_while_a_waits(a, b)),
        else: collect(:children)

      # Before any call on `a`, whose first release would hide a handle still queued.
      assert exclusive(c) == :ok
      grown = before + if(waits, do: 2, else: 0)
      assert {:ok, %{rows: [[^grown]]}} = Xqlite.query(b, "SELECT count(*) FROM t")
      assert {:ok, :none} = Xqlite.txn_state(a, "aux")
    end
  end

  # `a`'s insert waits on `b`'s write lock, holding `a`'s lock, while the children go.
  defp collect_while_a_waits(a, b, drop \\ fn -> collect(:children) end) do
    :ok = Xqlite.begin(b, :immediate)
    {:ok, _} = Xqlite.execute(b, "INSERT INTO t VALUES ('from b')")
    insert = Task.async(fn -> Xqlite.execute(a, "INSERT INTO t VALUES ('from a')") end)
    assert_receive {:xqlite_busy, _, _}, 10_000
    drop.()
    :ok = Xqlite.commit(b)
    Task.await(insert, 20_000)
  end

  # Children live only in the process dictionary: a test body's stack could keep one.
  # The yield lets the scheduler run the destructors the collection queued, first.
  defp collect(key) do
    Process.delete(key)
    :erlang.garbage_collect()
    :erlang.yield()
  end

  # Any read or write `a` holds on aux.db keeps its exclusive lock from `c`.
  defp exclusive(c), do: with(:ok <- Xqlite.begin(c, :exclusive), do: Xqlite.rollback(c))

  defp flush_busy do
    receive do
      {:xqlite_busy, _, _} -> flush_busy()
    after
      0 -> :ok
    end
  end

  defp child(a, :stmt), do: prepare(a, "SELECT 1")
  defp child(a, :stepped), do: a |> prepare("SELECT x FROM aux.u") |> step()
  defp child(a, :finalized), do: a |> child(:stmt) |> tap(&(:ok = NIF.stmt_finalize(&1)))
  defp child(a, :stream), do: a |> NIF.stream_open("SELECT x FROM aux.u", []) |> ok()
  defp child(a, :fetched), do: a |> child(:stream) |> fetch(1)
  defp child(a, :exhausted), do: a |> child(:stream) |> fetch(3)
  defp child(a, :blob), do: a |> NIF.blob_open("aux", "u", "b", 1, true) |> ok()
  defp child(a, :blob_rw), do: a |> NIF.blob_open("aux", "u", "b", 2, false) |> ok()
  defp child(a, :blob_closed), do: a |> child(:blob) |> tap(&(:ok = NIF.blob_close(&1)))
  defp child(a, :session), do: a |> session() |> tap(&(:ok = NIF.session_attach(&1, "t")))
  defp child(a, :deleted), do: a |> session() |> tap(&(:ok = NIF.session_delete(&1)))

  defp child(a, {:write, table}),
    do: a |> prepare("INSERT INTO #{table} (x) VALUES ('w') RETURNING x") |> step()

  defp prepare(conn, sql), do: conn |> NIF.stmt_prepare(sql) |> ok()
  defp step(stmt), do: tap(stmt, &({:row, _} = NIF.stmt_step(&1)))
  defp fetch(stream, n), do: tap(stream, &({:ok, _} = NIF.stream_fetch(&1, n)))
  defp session(a), do: a |> NIF.session_new() |> ok()
  defp ok({:ok, value}), do: value
end
