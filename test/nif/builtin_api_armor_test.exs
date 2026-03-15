defmodule Xqlite.NIF.BuiltinApiArmorTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  # ENABLE_API_ARMOR adds defensive NULL-pointer and invalid-argument checks
  # at the entry point of every public SQLite C API function. Without it,
  # misuse (NULL handles, finalized statements, etc.) is undefined behavior.
  #
  # Our Rust layer guards against most misuse: Mutex<Option<Connection>>
  # prevents use-after-close, AtomicPtr manages statement lifecycle, etc.
  # API_ARMOR is a defense-in-depth safety net beneath our Rust guards,
  # most critical in the raw FFI paths in stream.rs and util.rs where we
  # call sqlite3_step, sqlite3_column_*, sqlite3_bind_*, and
  # sqlite3_finalize directly on raw pointers.

  test "ENABLE_API_ARMOR is present in compile options" do
    {:ok, conn} = NIF.open_in_memory()

    assert {:ok, %{rows: rows}} =
             NIF.query(conn, "SELECT compile_options FROM pragma_compile_options", [])

    options = Enum.map(rows, &hd/1)
    assert "ENABLE_API_ARMOR" in options
    NIF.close(conn)
  end

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "API_ARMOR raw FFI safety using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # stream_fetch after stream_close — exercises sqlite3_step guard
      #
      # Our AtomicPtr swap returns null and we return :done without calling
      # sqlite3_step. If we had a bug and called step anyway, API_ARMOR
      # returns SQLITE_MISUSE instead of segfaulting.
      # -------------------------------------------------------------------

      test "stream_fetch after stream_close returns :done", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE aa_fetch (id INTEGER);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO aa_fetch VALUES (1)", [])

        {:ok, stream} = NIF.stream_open(conn, "SELECT * FROM aa_fetch", [], [])
        :ok = NIF.stream_close(stream)

        assert :done = NIF.stream_fetch(stream, 10)
      end

      test "stream_fetch after stream_close is repeatable", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE aa_rpt (id INTEGER);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO aa_rpt VALUES (1)", [])

        {:ok, stream} = NIF.stream_open(conn, "SELECT * FROM aa_rpt", [], [])
        :ok = NIF.stream_close(stream)

        assert :done = NIF.stream_fetch(stream, 10)
        assert :done = NIF.stream_fetch(stream, 10)
        assert :done = NIF.stream_fetch(stream, 10)
      end

      # -------------------------------------------------------------------
      # stream_close idempotency — exercises sqlite3_finalize guard
      #
      # AtomicPtr swap ensures only one thread finalizes. Second call gets
      # null, skips finalize. API_ARMOR catches sqlite3_finalize(NULL) if
      # our null check had a bug.
      # -------------------------------------------------------------------

      test "stream_close is idempotent", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE aa_idem (id INTEGER);")

        {:ok, stream} = NIF.stream_open(conn, "SELECT * FROM aa_idem", [], [])
        assert :ok = NIF.stream_close(stream)
        assert :ok = NIF.stream_close(stream)
        assert :ok = NIF.stream_close(stream)
      end

      # -------------------------------------------------------------------
      # stream operations after connection close
      #
      # Our Mutex<Option<Connection>> returns ConnectionClosed. The raw
      # sqlite3_stmt* still exists but its parent sqlite3* is gone.
      # API_ARMOR catches sqlite3_step on an orphaned stmt if our guard
      # failed.
      # -------------------------------------------------------------------

      test "stream_fetch after connection close returns error", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE aa_cc (id INTEGER);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO aa_cc VALUES (1)", [])

        {:ok, stream} = NIF.stream_open(conn, "SELECT * FROM aa_cc", [], [])
        NIF.close(conn)

        assert {:error, :connection_closed} = NIF.stream_fetch(stream, 10)
      end

      # -------------------------------------------------------------------
      # Partial stream consumption then close — sqlite3_finalize on an
      # in-progress statement
      #
      # Calling sqlite3_finalize on a statement mid-iteration is legal but
      # API_ARMOR validates the pointer isn't already finalized.
      # -------------------------------------------------------------------

      test "stream_close mid-iteration finalizes cleanly", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE aa_mid (id INTEGER);")

        for i <- 1..100 do
          {:ok, 1} = NIF.execute(conn, "INSERT INTO aa_mid VALUES (?1)", [i])
        end

        {:ok, stream} = NIF.stream_open(conn, "SELECT * FROM aa_mid", [], [])

        # Fetch only first batch
        assert {:ok, %{rows: rows}} = NIF.stream_fetch(stream, 5)
        assert length(rows) == 5

        # Close mid-iteration — must not crash or leak
        assert :ok = NIF.stream_close(stream)

        # Subsequent operations are safe
        assert :done = NIF.stream_fetch(stream, 10)
        assert :ok = NIF.stream_close(stream)
      end

      # -------------------------------------------------------------------
      # Rapid open/fetch/close cycling — stress the AtomicPtr lifecycle
      # -------------------------------------------------------------------

      test "rapid stream open/close cycles", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE aa_cycle (id INTEGER);")
        {:ok, 1} = NIF.execute(conn, "INSERT INTO aa_cycle VALUES (1)", [])

        for _ <- 1..50 do
          {:ok, stream} = NIF.stream_open(conn, "SELECT * FROM aa_cycle", [], [])
          assert {:ok, %{rows: [[1]]}} = NIF.stream_fetch(stream, 10)
          assert :done = NIF.stream_fetch(stream, 10)
          assert :ok = NIF.stream_close(stream)
        end
      end

      # -------------------------------------------------------------------
      # stream_get_columns after close — read-only metadata access
      # -------------------------------------------------------------------

      test "stream_get_columns still works after stream_close", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE aa_cols (x INTEGER, y TEXT);")

        {:ok, stream} = NIF.stream_open(conn, "SELECT x, y FROM aa_cols", [], [])
        :ok = NIF.stream_close(stream)

        assert {:ok, ["x", "y"]} = NIF.stream_get_columns(stream)
      end
    end
  end
end
