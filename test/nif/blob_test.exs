defmodule Xqlite.NIF.BlobTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "blob I/O using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # Open and close
      # -------------------------------------------------------------------

      test "open and close a blob handle", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_oc (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_oc VALUES (1, zeroblob(100));
          """)

        assert {:ok, blob} = NIF.blob_open(conn, "main", "bl_oc", "data", 1, false)
        assert :ok = NIF.blob_close(blob)
      end

      test "blob_close is idempotent", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_idem (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_idem VALUES (1, zeroblob(10));
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_idem", "data", 1, false)
        assert :ok = NIF.blob_close(blob)
        assert :ok = NIF.blob_close(blob)
      end

      # -------------------------------------------------------------------
      # Size
      # -------------------------------------------------------------------

      test "blob_size returns correct size", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_sz (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_sz VALUES (1, zeroblob(4096));
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_sz", "data", 1, true)
        assert {:ok, 4096} = NIF.blob_size(blob)
        NIF.blob_close(blob)
      end

      test "blob_size of zero-length blob", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_sz0 (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_sz0 VALUES (1, zeroblob(0));
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_sz0", "data", 1, true)
        assert {:ok, 0} = NIF.blob_size(blob)
        NIF.blob_close(blob)
      end

      # -------------------------------------------------------------------
      # Read
      # -------------------------------------------------------------------

      test "read entire blob", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_rd (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_rd VALUES (1, X'DEADBEEF');
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_rd", "data", 1, true)
        assert {:ok, <<0xDE, 0xAD, 0xBE, 0xEF>>} = NIF.blob_read(blob, 0, 4)
        NIF.blob_close(blob)
      end

      test "read partial blob from offset", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_rdp (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_rdp VALUES (1, X'0102030405');
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_rdp", "data", 1, true)
        assert {:ok, <<3, 4>>} = NIF.blob_read(blob, 2, 2)
        NIF.blob_close(blob)
      end

      test "read past end clamps to available bytes", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_rdc (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_rdc VALUES (1, X'AABB');
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_rdc", "data", 1, true)
        assert {:ok, <<0xBB>>} = NIF.blob_read(blob, 1, 100)
        NIF.blob_close(blob)
      end

      test "read at offset beyond size returns empty", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_rdb (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_rdb VALUES (1, X'FF');
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_rdb", "data", 1, true)
        assert {:ok, <<>>} = NIF.blob_read(blob, 100, 10)
        NIF.blob_close(blob)
      end

      test "read zeroblob returns all zeros", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_rdz (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_rdz VALUES (1, zeroblob(1024));
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_rdz", "data", 1, true)
        assert {:ok, data} = NIF.blob_read(blob, 0, 1024)
        assert data == :binary.copy(<<0>>, 1024)
        NIF.blob_close(blob)
      end

      # -------------------------------------------------------------------
      # Write
      # -------------------------------------------------------------------

      test "write and read back", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_wr (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_wr VALUES (1, zeroblob(10));
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_wr", "data", 1, false)
        :ok = NIF.blob_write(blob, 0, <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>)
        assert {:ok, <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>} = NIF.blob_read(blob, 0, 10)
        NIF.blob_close(blob)
      end

      test "write at offset", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_wro (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_wro VALUES (1, zeroblob(10));
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_wro", "data", 1, false)
        :ok = NIF.blob_write(blob, 5, <<0xFF, 0xFE>>)

        assert {:ok, data} = NIF.blob_read(blob, 0, 10)
        assert binary_part(data, 5, 2) == <<0xFF, 0xFE>>
        assert binary_part(data, 0, 5) == <<0, 0, 0, 0, 0>>
        NIF.blob_close(blob)
      end

      test "write persists after blob close", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_wrp (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_wrp VALUES (1, zeroblob(4));
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_wrp", "data", 1, false)
        :ok = NIF.blob_write(blob, 0, <<0xCA, 0xFE, 0xBA, 0xBE>>)
        NIF.blob_close(blob)

        assert {:ok, %{rows: [[<<0xCA, 0xFE, 0xBA, 0xBE>>]]}} =
                 NIF.query(conn, "SELECT data FROM bl_wrp WHERE id = 1", [])
      end

      test "write on read-only blob returns error", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_wro_ro (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_wro_ro VALUES (1, zeroblob(10));
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_wro_ro", "data", 1, true)
        assert {:error, _} = NIF.blob_write(blob, 0, <<1, 2, 3>>)
        NIF.blob_close(blob)
      end

      test "write exceeding blob size returns error", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_overflow (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_overflow VALUES (1, zeroblob(5));
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_overflow", "data", 1, false)
        assert {:error, _} = NIF.blob_write(blob, 0, <<1, 2, 3, 4, 5, 6, 7, 8>>)
        NIF.blob_close(blob)
      end

      test "write at offset that would exceed blob size returns error", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_off_overflow (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_off_overflow VALUES (1, zeroblob(10));
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_off_overflow", "data", 1, false)
        assert {:error, _} = NIF.blob_write(blob, 8, <<1, 2, 3, 4, 5>>)
        NIF.blob_close(blob)
      end

      # -------------------------------------------------------------------
      # Reopen — switch to different row
      # -------------------------------------------------------------------

      test "reopen moves to different row", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_ro (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_ro VALUES (1, X'AAAA');
          INSERT INTO bl_ro VALUES (2, X'BBBB');
          INSERT INTO bl_ro VALUES (3, X'CCCC');
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_ro", "data", 1, true)
        assert {:ok, <<0xAA, 0xAA>>} = NIF.blob_read(blob, 0, 2)

        :ok = NIF.blob_reopen(blob, 2)
        assert {:ok, <<0xBB, 0xBB>>} = NIF.blob_read(blob, 0, 2)

        :ok = NIF.blob_reopen(blob, 3)
        assert {:ok, <<0xCC, 0xCC>>} = NIF.blob_read(blob, 0, 2)

        NIF.blob_close(blob)
      end

      test "reopen updates blob_size", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_ros (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_ros VALUES (1, zeroblob(100));
          INSERT INTO bl_ros VALUES (2, zeroblob(200));
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_ros", "data", 1, true)
        assert {:ok, 100} = NIF.blob_size(blob)

        :ok = NIF.blob_reopen(blob, 2)
        assert {:ok, 200} = NIF.blob_size(blob)

        NIF.blob_close(blob)
      end

      test "reopen to nonexistent row returns error", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_rone (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_rone VALUES (1, zeroblob(10));
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_rone", "data", 1, true)
        assert {:error, _} = NIF.blob_reopen(blob, 999)
        NIF.blob_close(blob)
      end

      # -------------------------------------------------------------------
      # Large blob — 100KB of zeros, chunked read/write
      # -------------------------------------------------------------------

      test "write and read 100KB blob in chunks", %{conn: conn} do
        blob_size = 100 * 1024

        :ok =
          NIF.execute_batch(
            conn,
            "CREATE TABLE bl_100k (id INTEGER PRIMARY KEY, data BLOB);"
          )

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO bl_100k VALUES (1, zeroblob(?1))",
            [blob_size]
          )

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_100k", "data", 1, false)
        assert {:ok, ^blob_size} = NIF.blob_size(blob)

        # Write in 10KB chunks with a recognizable pattern
        chunk_size = 10 * 1024

        for i <- 0..9 do
          offset = i * chunk_size
          pattern_byte = rem(i + 1, 256)
          chunk = :binary.copy(<<pattern_byte>>, chunk_size)
          :ok = NIF.blob_write(blob, offset, chunk)
        end

        # Read back and verify each chunk
        for i <- 0..9 do
          offset = i * chunk_size
          pattern_byte = rem(i + 1, 256)
          expected = :binary.copy(<<pattern_byte>>, chunk_size)
          assert {:ok, ^expected} = NIF.blob_read(blob, offset, chunk_size)
        end

        NIF.blob_close(blob)
      end

      test "read entire 100KB blob at once", %{conn: conn} do
        blob_size = 100 * 1024

        :ok =
          NIF.execute_batch(
            conn,
            "CREATE TABLE bl_100k_r (id INTEGER PRIMARY KEY, data BLOB);"
          )

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO bl_100k_r VALUES (1, zeroblob(?1))",
            [blob_size]
          )

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_100k_r", "data", 1, false)

        # Write a pattern
        pattern = :binary.copy(<<0xAB>>, blob_size)
        :ok = NIF.blob_write(blob, 0, pattern)

        # Read all at once
        assert {:ok, data} = NIF.blob_read(blob, 0, blob_size)
        assert byte_size(data) == blob_size
        assert data == pattern

        NIF.blob_close(blob)
      end

      # -------------------------------------------------------------------
      # Multiple blobs on same connection
      # -------------------------------------------------------------------

      test "multiple blob handles on different rows", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_multi (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_multi VALUES (1, X'1111');
          INSERT INTO bl_multi VALUES (2, X'2222');
          """)

        {:ok, b1} = NIF.blob_open(conn, "main", "bl_multi", "data", 1, true)
        {:ok, b2} = NIF.blob_open(conn, "main", "bl_multi", "data", 2, true)

        assert {:ok, <<0x11, 0x11>>} = NIF.blob_read(b1, 0, 2)
        assert {:ok, <<0x22, 0x22>>} = NIF.blob_read(b2, 0, 2)

        NIF.blob_close(b1)
        NIF.blob_close(b2)
      end

      # -------------------------------------------------------------------
      # Error cases
      # -------------------------------------------------------------------

      test "open blob on nonexistent table returns error", %{conn: conn} do
        assert {:error, _} =
                 NIF.blob_open(conn, "main", "nonexistent", "data", 1, true)
      end

      test "open blob on nonexistent column returns error", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE bl_nocol (id INTEGER PRIMARY KEY);")

        assert {:error, _} =
                 NIF.blob_open(conn, "main", "bl_nocol", "nonexistent", 1, true)
      end

      test "open blob on nonexistent row returns error", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_norow (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_norow VALUES (1, zeroblob(10));
          """)

        assert {:error, _} =
                 NIF.blob_open(conn, "main", "bl_norow", "data", 999, true)
      end

      test "blob operations after close return error", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE bl_closed (id INTEGER PRIMARY KEY, data BLOB);
          INSERT INTO bl_closed VALUES (1, zeroblob(10));
          """)

        {:ok, blob} = NIF.blob_open(conn, "main", "bl_closed", "data", 1, false)
        NIF.blob_close(blob)

        assert {:error, _} = NIF.blob_read(blob, 0, 10)
        assert {:error, _} = NIF.blob_write(blob, 0, <<1>>)
        assert {:error, _} = NIF.blob_size(blob)
        assert {:error, _} = NIF.blob_reopen(blob, 1)
      end
    end
  end

  # -------------------------------------------------------------------
  # Edge cases outside connection_openers loop
  # -------------------------------------------------------------------

  test "blob_open on closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory(":memory:")
    NIF.close(conn)

    assert {:error, _} = NIF.blob_open(conn, "main", "t", "c", 1, true)
  end
end
