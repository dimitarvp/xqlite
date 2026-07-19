# Binary-crossing correctness edges for xqlite (review axis A12, Run 11).
#
# Runtime teeth for the INBOUND/OUTBOUND source audit claims that a read alone
# cannot settle. Every check is a hard assertion; any failure -> rc 1.
#
#   E1  empty (0-byte) BLOB round-trips as <<>> on BOTH outbound paths: query
#       (encode_val, size-adaptive: 0 <= 64 so it copies into a 0-byte
#       OwnedBinary) and stream (sqlite_row_to_elixir_terms null-ptr + len-0
#       branch). Neither may crash.
#   E2  a SUB-BINARY of a huge parent, passed as a blob param and as blob_write
#       data, round-trips byte-exact (inbound copies the view; never retains the
#       parent past the call — the source claim, here exercised for real).
#   E3  a BLOB returned by `query` (a resource binary that OWNS a copied-out Vec)
#       stays byte-exact AFTER the connection is closed and GC runs — proving the
#       crossed binary is independent of SQLite-owned memory (no escaped view).
#   E4  interior-NUL BLOB + TEXT cross byte-exact via query AND stream (the
#       length-delimited crossing, re-confirmed at the A12 boundary).
#   E5  the iodata story: an iolist passed where a binary/String is required is
#       REJECTED (rustler decodes binaries only; Binary::from_iolist is unused),
#       consistent with the binary()/String.t() typespecs. Pin the actual failure
#       mode so "iodata is not accepted" is evidence, not assertion.
#
# Isolated from CI (binary_crossing/, not test/, not elixirc_paths, not the
# formatter glob). Invoked by binary_crossing/run.sh.

defmodule A12.Edges do
  alias XqliteNIF

  def check(name, fun) do
    case fun.() do
      :ok ->
        IO.puts("   PASS  #{name}")
        true

      {:fail, why} ->
        IO.puts("   FAIL  #{name}: #{why}")
        false
    end
  rescue
    e ->
      IO.puts("   FAIL  #{name}: raised #{inspect(e)}")
      false
  catch
    k, r ->
      IO.puts("   FAIL  #{name}: #{inspect(k)} #{inspect(r)}")
      false
  end

  # Read every row-cell back through both outbound crossings.
  defp query_one(conn, sql, params \\ []) do
    {:ok, %{rows: rows}} = XqliteNIF.query(conn, sql, params)
    rows
  end

  defp stream_all(conn, sql, params \\ []) do
    {:ok, h} = XqliteNIF.stream_open(conn, sql, params, [])
    rows = drain(h, [])
    :ok = XqliteNIF.stream_close(h)
    rows
  end

  defp drain(h, acc) do
    case XqliteNIF.stream_fetch(h, 100) do
      {:ok, %{rows: r}} -> drain(h, [r | acc])
      :done -> acc |> Enum.reverse() |> Enum.concat()
    end
  end

  # ---- E1: empty blob on both paths --------------------------------------
  def e1 do
    {:ok, conn} = Xqlite.open_in_memory()
    {:ok, _} = XqliteNIF.query(conn, "CREATE TABLE t(b BLOB)", [])
    {:ok, _} = XqliteNIF.query(conn, "INSERT INTO t VALUES(zeroblob(0))", [])

    q = query_one(conn, "SELECT b FROM t")
    s = stream_all(conn, "SELECT b FROM t")

    cond do
      q != [[<<>>]] -> {:fail, "query empty blob = #{inspect(q)}"}
      s != [[<<>>]] -> {:fail, "stream empty blob = #{inspect(s)}"}
      true -> :ok
    end
  end

  # ---- E2: sub-binary of a huge parent as inbound param + blob_write ------
  def e2 do
    parent = :binary.copy(<<0xAB>>, 8_000_000)
    # a 32-byte window carved out of the 8 MB parent (a real sub-binary term)
    sub = :binary.part(parent, 1_000_000, 32)
    true = byte_size(sub) == 32

    {:ok, conn} = Xqlite.open_in_memory()
    {:ok, _} = XqliteNIF.query(conn, "CREATE TABLE t(b BLOB)", [])
    # force a BLOB param (invalid UTF-8 bytes -> Value::Blob path)
    {:ok, _} = XqliteNIF.query(conn, "INSERT INTO t VALUES(?1)", [sub])

    got = query_one(conn, "SELECT b FROM t")

    # blob_write path: open a blob sized to the sub, write the sub in
    {:ok, _} = XqliteNIF.query(conn, "CREATE TABLE w(b BLOB)", [])
    {:ok, _} = XqliteNIF.query(conn, "INSERT INTO w(rowid, b) VALUES(1, zeroblob(32))", [])
    {:ok, blob} = XqliteNIF.blob_open(conn, "main", "w", "b", 1, false)
    :ok = XqliteNIF.blob_write(blob, 0, sub)
    {:ok, wrote} = XqliteNIF.blob_read(blob, 0, 32)
    :ok = XqliteNIF.blob_close(blob)

    expect = :binary.copy(<<0xAB>>, 32)

    cond do
      got != [[expect]] -> {:fail, "param sub-binary = #{inspect(got)}"}
      wrote != expect -> {:fail, "blob_write sub-binary read back = #{inspect(wrote)}"}
      true -> :ok
    end
  end

  # ---- E3: query-path resource binary outlives the connection ------------
  def e3 do
    {:ok, conn} = Xqlite.open_in_memory()
    {:ok, _} = XqliteNIF.query(conn, "CREATE TABLE t(b BLOB)", [])
    {:ok, _} = XqliteNIF.query(conn, "INSERT INTO t VALUES(randomblob(4096))", [])
    [[blob]] = query_one(conn, "SELECT b FROM t")
    snapshot = :binary.copy(blob)
    true = byte_size(blob) == 4096

    # close the connection; the resource binary owns a copied-out Vec, so it must
    # remain byte-exact (it never referenced SQLite-owned memory).
    :ok = Xqlite.close(conn)
    :erlang.garbage_collect()
    Process.sleep(20)

    if blob == snapshot and byte_size(blob) == 4096 do
      :ok
    else
      {:fail, "blob mutated/invalidated after connection close"}
    end
  end

  # ---- E4: interior-NUL BLOB + TEXT byte-exact, both paths ----------------
  def e4 do
    {:ok, conn} = Xqlite.open_in_memory()
    {:ok, _} = XqliteNIF.query(conn, "CREATE TABLE t(b BLOB, s TEXT)", [])
    blob = <<1, 0, 255, 0, 2>>
    text = "a\0b\0c"
    {:ok, _} = XqliteNIF.query(conn, "INSERT INTO t VALUES(?1, ?2)", [blob, text])

    q = query_one(conn, "SELECT b, s FROM t")
    s = stream_all(conn, "SELECT b, s FROM t")

    cond do
      q != [[blob, text]] -> {:fail, "query = #{inspect(q)}"}
      s != [[blob, text]] -> {:fail, "stream = #{inspect(s)}"}
      true -> :ok
    end
  end

  # ---- E5: iodata is NOT accepted (binary-only), the actual failure mode --
  def e5 do
    {:ok, conn} = Xqlite.open_in_memory()
    # a non-flat iolist for the SQL text arg (String decode = enif_inspect_binary,
    # binary-only -> BadArg -> ArgumentError).
    sql_iolist = ["SELECT ", [?1]]

    sql_result =
      try do
        {:raised_no, XqliteNIF.query(conn, sql_iolist, [])}
      rescue
        e in ArgumentError -> {:argument_error, e}
        e -> {:other_raise, e}
      end

    # an iolist as a bind param value (List term -> UnsupportedDataType, a
    # STRUCTURED error, not a crossing).
    {:ok, _} = XqliteNIF.query(conn, "CREATE TABLE t(x)", [])

    param_result = XqliteNIF.query(conn, "INSERT INTO t VALUES(?1)", [["io", "list"]])

    case {sql_result, param_result} do
      {{:argument_error, _}, {:error, {:unsupported_data_type, _}}} ->
        :ok

      {{:argument_error, _}, {:error, other}} ->
        # param rejected structurally (any structured reason is acceptable; pin it)
        IO.puts("      (iolist param -> #{inspect(other)})")
        :ok

      {sqlr, pr} ->
        {:fail, "sql=#{inspect(sqlr)} param=#{inspect(pr)}"}
    end
  end

  def main do
    IO.puts("=== xqlite A12 binary-crossing correctness edges ===")

    results = [
      check("E1 empty blob (query 0-byte OwnedBinary + stream len-0)", &e1/0),
      check("E2 sub-binary param + blob_write round-trip byte-exact", &e2/0),
      check("E3 query blob (owned resource binary) survives conn close", &e3/0),
      check("E4 interior-NUL blob+text byte-exact both paths", &e4/0),
      check("E5 iodata rejected (binary-only), failure mode pinned", &e5/0)
    ]

    if Enum.all?(results) do
      IO.puts("RESULT: all edges PASS")
      System.halt(0)
    else
      IO.puts("RESULT: an edge FAILED")
      System.halt(1)
    end
  end
end

A12.Edges.main()
