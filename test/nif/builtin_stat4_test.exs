defmodule Xqlite.NIF.BuiltinStat4Test do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "STAT4 using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # sqlite_stat1 — basic ANALYZE
      # -------------------------------------------------------------------

      test "ANALYZE on 3-row table with single-column index", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE st1_3row (id INTEGER PRIMARY KEY, val TEXT);
          CREATE INDEX st1_3row_idx ON st1_3row(val);
          INSERT INTO st1_3row VALUES (1, 'alpha');
          INSERT INTO st1_3row VALUES (2, 'beta');
          INSERT INTO st1_3row VALUES (3, 'gamma');
          ANALYZE;
          """)

        assert {:ok, %{rows: [[tbl, idx, stat]]}} =
                 NIF.query(
                   conn,
                   "SELECT tbl, idx, stat FROM sqlite_stat1 WHERE idx = 'st1_3row_idx'",
                   []
                 )

        assert tbl == "st1_3row"
        assert idx == "st1_3row_idx"
        # stat is "3 1" — 3 rows, each val is unique (avg 1 row per distinct value)
        [nrow, avg_per_val] =
          stat |> String.split(" ") |> Enum.map(&String.to_integer/1)

        assert nrow == 3
        assert avg_per_val == 1
      end

      test "ANALYZE reflects duplicate distribution in stat", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE st1_dup (id INTEGER PRIMARY KEY, color TEXT);
          CREATE INDEX st1_dup_idx ON st1_dup(color);
          INSERT INTO st1_dup VALUES (1, 'red');
          INSERT INTO st1_dup VALUES (2, 'red');
          INSERT INTO st1_dup VALUES (3, 'red');
          INSERT INTO st1_dup VALUES (4, 'blue');
          INSERT INTO st1_dup VALUES (5, 'blue');
          INSERT INTO st1_dup VALUES (6, 'green');
          ANALYZE;
          """)

        assert {:ok, %{rows: [[stat]]}} =
                 NIF.query(
                   conn,
                   "SELECT stat FROM sqlite_stat1 WHERE idx = 'st1_dup_idx'",
                   []
                 )

        [nrow, avg_per_val] =
          stat |> String.split(" ") |> Enum.map(&String.to_integer/1)

        assert nrow == 6
        # 6 rows / 3 distinct = avg 2 per value
        assert avg_per_val == 2
      end

      test "ANALYZE with two indexes reports both", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE st1_two (id INTEGER PRIMARY KEY, a TEXT, b INTEGER);
          CREATE INDEX st1_two_a ON st1_two(a);
          CREATE INDEX st1_two_b ON st1_two(b);
          INSERT INTO st1_two VALUES (1, 'x', 10);
          INSERT INTO st1_two VALUES (2, 'y', 20);
          INSERT INTO st1_two VALUES (3, 'x', 30);
          INSERT INTO st1_two VALUES (4, 'z', 10);
          ANALYZE;
          """)

        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT idx, stat FROM sqlite_stat1 WHERE tbl = 'st1_two' ORDER BY idx",
                   []
                 )

        idx_map = Map.new(rows, fn [idx, stat] -> {idx, stat} end)

        assert Map.has_key?(idx_map, "st1_two_a")
        assert Map.has_key?(idx_map, "st1_two_b")

        # Index a: 4 rows, 3 distinct values (x appears twice) → avg ~1
        [nrow_a, avg_a] =
          idx_map["st1_two_a"] |> String.split(" ") |> Enum.map(&String.to_integer/1)

        assert nrow_a == 4
        assert avg_a >= 1 and avg_a <= 2

        # Index b: 4 rows, 3 distinct values (10 appears twice) → avg ~1
        [nrow_b, avg_b] =
          idx_map["st1_two_b"] |> String.split(" ") |> Enum.map(&String.to_integer/1)

        assert nrow_b == 4
        assert avg_b >= 1 and avg_b <= 2
      end

      # -------------------------------------------------------------------
      # sqlite_stat1 — multi-column index stat format
      # -------------------------------------------------------------------

      test "multi-column index stat has one estimate per column", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE st1_mc (id INTEGER PRIMARY KEY, a TEXT, b TEXT, c INTEGER);
          CREATE INDEX st1_mc_abc ON st1_mc(a, b, c);
          """)

        # 3 distinct a values, 10 distinct b values, 100 distinct c values
        for i <- 1..100 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO st1_mc VALUES (?1, ?2, ?3, ?4)", [
              i,
              "a_#{rem(i, 3)}",
              "b_#{rem(i, 10)}",
              i
            ])
        end

        :ok = NIF.execute_batch(conn, "ANALYZE;")

        assert {:ok, %{rows: [[stat]]}} =
                 NIF.query(
                   conn,
                   "SELECT stat FROM sqlite_stat1 WHERE idx = 'st1_mc_abc'",
                   []
                 )

        parts = stat |> String.split(" ") |> Enum.map(&String.to_integer/1)

        # Format: nrow est_a est_ab est_abc
        assert length(parts) == 4

        [nrow, est_a, est_ab, est_abc] = parts
        assert nrow == 100
        # est_a: 100/3 ≈ 33 rows per distinct a
        assert est_a >= 30 and est_a <= 35
        # est_ab: rows per distinct (a,b) combo — depends on rem distribution
        assert est_ab >= 3 and est_ab <= 10
        # est_abc: each (a,b,c) is unique → 1
        assert est_abc == 1
      end

      # -------------------------------------------------------------------
      # sqlite_stat4 — sample rows
      # -------------------------------------------------------------------

      test "sqlite_stat4 contains sample rows after ANALYZE", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE st4_samp (id INTEGER PRIMARY KEY, category TEXT);
          CREATE INDEX st4_samp_idx ON st4_samp(category);
          """)

        for i <- 1..200 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO st4_samp VALUES (?1, ?2)", [
              i,
              "cat_#{rem(i, 5)}"
            ])
        end

        :ok = NIF.execute_batch(conn, "ANALYZE;")

        assert {:ok, %{rows: rows, num_rows: num_rows}} =
                 NIF.query(
                   conn,
                   "SELECT tbl, idx, neq, nlt, ndlt, sample FROM sqlite_stat4 WHERE tbl = 'st4_samp'",
                   []
                 )

        # STAT4 collects ~24 samples by default (SQLITE_STAT4_SAMPLES)
        assert num_rows >= 5

        Enum.each(rows, fn [tbl, idx, neq, nlt, ndlt, sample] ->
          assert tbl == "st4_samp"
          assert idx == "st4_samp_idx"

          # neq, nlt, ndlt are space-separated integers
          neq_vals = neq |> String.split(" ") |> Enum.map(&String.to_integer/1)
          nlt_vals = nlt |> String.split(" ") |> Enum.map(&String.to_integer/1)
          ndlt_vals = ndlt |> String.split(" ") |> Enum.map(&String.to_integer/1)

          assert Enum.all?(neq_vals, &(&1 >= 1))
          assert Enum.all?(nlt_vals, &(&1 >= 0))
          assert Enum.all?(ndlt_vals, &(&1 >= 0))

          # sample is a binary (key encoding of the sampled row)
          assert is_binary(sample)
        end)
      end

      test "sqlite_stat4 neq reflects actual value frequency", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE st4_freq (id INTEGER PRIMARY KEY, tag TEXT);
          CREATE INDEX st4_freq_idx ON st4_freq(tag);
          """)

        # 100 rows with tag "common", 1 row with tag "rare"
        for i <- 1..100 do
          {:ok, 1} = NIF.execute(conn, "INSERT INTO st4_freq VALUES (?1, 'common')", [i])
        end

        {:ok, 1} = NIF.execute(conn, "INSERT INTO st4_freq VALUES (101, 'rare')", [])

        :ok = NIF.execute_batch(conn, "ANALYZE;")

        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT neq FROM sqlite_stat4 WHERE tbl = 'st4_freq'",
                   []
                 )

        neq_first_cols =
          Enum.map(rows, fn [neq] ->
            neq |> String.split(" ") |> hd() |> String.to_integer()
          end)

        # At least one sample should show the "common" tag with neq ~100
        assert Enum.any?(neq_first_cols, &(&1 >= 50))
        # At least one sample should show the "rare" tag with neq == 1
        assert Enum.any?(neq_first_cols, &(&1 == 1))
      end

      # -------------------------------------------------------------------
      # Re-ANALYZE updates statistics
      # -------------------------------------------------------------------

      test "re-ANALYZE updates row count after inserts", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE st4_rerun (id INTEGER PRIMARY KEY, val TEXT);
          CREATE INDEX st4_rerun_idx ON st4_rerun(val);
          INSERT INTO st4_rerun VALUES (1, 'a');
          INSERT INTO st4_rerun VALUES (2, 'b');
          ANALYZE;
          """)

        assert {:ok, %{rows: [[stat_before]]}} =
                 NIF.query(
                   conn,
                   "SELECT stat FROM sqlite_stat1 WHERE idx = 'st4_rerun_idx'",
                   []
                 )

        [count_before | _] =
          stat_before |> String.split(" ") |> Enum.map(&String.to_integer/1)

        assert count_before == 2

        for i <- 3..100 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO st4_rerun VALUES (?1, ?2)", [
              i,
              "val_#{rem(i, 5)}"
            ])
        end

        :ok = NIF.execute_batch(conn, "ANALYZE;")

        assert {:ok, %{rows: [[stat_after]]}} =
                 NIF.query(
                   conn,
                   "SELECT stat FROM sqlite_stat1 WHERE idx = 'st4_rerun_idx'",
                   []
                 )

        [count_after | _] =
          stat_after |> String.split(" ") |> Enum.map(&String.to_integer/1)

        assert count_after == 100
      end

      test "re-ANALYZE updates sqlite_stat4 sample count", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE st4_resamp (id INTEGER PRIMARY KEY, val TEXT);
          CREATE INDEX st4_resamp_idx ON st4_resamp(val);
          INSERT INTO st4_resamp VALUES (1, 'a');
          INSERT INTO st4_resamp VALUES (2, 'b');
          ANALYZE;
          """)

        assert {:ok, %{rows: _, num_rows: samples_before}} =
                 NIF.query(
                   conn,
                   "SELECT * FROM sqlite_stat4 WHERE tbl = 'st4_resamp'",
                   []
                 )

        for i <- 3..500 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO st4_resamp VALUES (?1, ?2)", [
              i,
              "val_#{rem(i, 25)}"
            ])
        end

        :ok = NIF.execute_batch(conn, "ANALYZE;")

        assert {:ok, %{rows: _, num_rows: samples_after}} =
                 NIF.query(
                   conn,
                   "SELECT * FROM sqlite_stat4 WHERE tbl = 'st4_resamp'",
                   []
                 )

        # More data → more or equal samples
        assert samples_after >= samples_before
      end

      # -------------------------------------------------------------------
      # ANALYZE on table without explicit index
      # -------------------------------------------------------------------

      test "ANALYZE on table with only PK autoindex", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE st4_pkonly (id INTEGER PRIMARY KEY, val TEXT);
          INSERT INTO st4_pkonly VALUES (1, 'a');
          INSERT INTO st4_pkonly VALUES (2, 'b');
          INSERT INTO st4_pkonly VALUES (3, 'c');
          ANALYZE;
          """)

        # sqlite_stat1 may or may not have an entry for the autoindex
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT tbl, idx, stat FROM sqlite_stat1 WHERE tbl = 'st4_pkonly'",
                   []
                 )

        # If there's an entry, it should be for the autoindex
        case rows do
          [] ->
            :ok

          [[tbl, _idx, stat]] ->
            assert tbl == "st4_pkonly"
            [nrow | _] = stat |> String.split(" ") |> Enum.map(&String.to_integer/1)
            assert nrow == 3
        end
      end

      # -------------------------------------------------------------------
      # ANALYZE with unique index
      # -------------------------------------------------------------------

      test "unique index has avg 1 row per distinct value", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE st4_uniq (id INTEGER PRIMARY KEY, email TEXT UNIQUE);
          CREATE UNIQUE INDEX st4_uniq_email ON st4_uniq(email);
          """)

        for i <- 1..50 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO st4_uniq VALUES (?1, ?2)", [
              i,
              "user_#{i}@example.com"
            ])
        end

        :ok = NIF.execute_batch(conn, "ANALYZE;")

        assert {:ok, %{rows: [[stat]]}} =
                 NIF.query(
                   conn,
                   "SELECT stat FROM sqlite_stat1 WHERE idx = 'st4_uniq_email'",
                   []
                 )

        [nrow, avg] = stat |> String.split(" ") |> Enum.map(&String.to_integer/1)
        assert nrow == 50
        assert avg == 1
      end

      # -------------------------------------------------------------------
      # DROP INDEX cleans up stat tables
      # -------------------------------------------------------------------

      test "dropping an index removes its stat entries", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE st4_drop (id INTEGER PRIMARY KEY, val TEXT);
          CREATE INDEX st4_drop_idx ON st4_drop(val);
          INSERT INTO st4_drop VALUES (1, 'a');
          INSERT INTO st4_drop VALUES (2, 'b');
          ANALYZE;
          """)

        assert {:ok, %{num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT * FROM sqlite_stat1 WHERE idx = 'st4_drop_idx'",
                   []
                 )

        :ok = NIF.execute_batch(conn, "DROP INDEX st4_drop_idx;")

        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(
                   conn,
                   "SELECT * FROM sqlite_stat1 WHERE idx = 'st4_drop_idx'",
                   []
                 )
      end

      # -------------------------------------------------------------------
      # ANALYZE single table vs full database
      # -------------------------------------------------------------------

      test "ANALYZE specific table only updates that table", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE st4_tbl1 (id INTEGER PRIMARY KEY, val TEXT);
          CREATE INDEX st4_tbl1_idx ON st4_tbl1(val);
          INSERT INTO st4_tbl1 VALUES (1, 'a');

          CREATE TABLE st4_tbl2 (id INTEGER PRIMARY KEY, val TEXT);
          CREATE INDEX st4_tbl2_idx ON st4_tbl2(val);
          INSERT INTO st4_tbl2 VALUES (1, 'b');

          ANALYZE st4_tbl1;
          """)

        assert {:ok, %{num_rows: 1}} =
                 NIF.query(
                   conn,
                   "SELECT * FROM sqlite_stat1 WHERE tbl = 'st4_tbl1'",
                   []
                 )

        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(
                   conn,
                   "SELECT * FROM sqlite_stat1 WHERE tbl = 'st4_tbl2'",
                   []
                 )
      end
    end
  end
end
