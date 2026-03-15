defmodule Xqlite.NIF.BuiltinRtreeTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "R-Tree using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # Table creation
      # -------------------------------------------------------------------

      test "create rtree virtual table", %{conn: conn} do
        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "CREATE VIRTUAL TABLE rt_demo USING rtree(id, x1, x2, y1, y2)",
                   []
                 )
      end

      test "create rtree with 1D bounding box", %{conn: conn} do
        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "CREATE VIRTUAL TABLE rt_1d USING rtree(id, lo, hi)",
                   []
                 )
      end

      test "create rtree with 3D bounding box", %{conn: conn} do
        assert {:ok, 1} =
                 NIF.execute(
                   conn,
                   "CREATE VIRTUAL TABLE rt_3d USING rtree(id, x1, x2, y1, y2, z1, z2)",
                   []
                 )
      end

      # -------------------------------------------------------------------
      # Insert and basic queries
      # -------------------------------------------------------------------

      test "insert and select a single entry", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE rt_ins USING rtree(id, x1, x2, y1, y2);"
          )

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO rt_ins VALUES (1, 0.0, 10.0, 0.0, 10.0)",
            []
          )

        assert {:ok, %{rows: [[1, x1, 10.0, y1, 10.0]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM rt_ins WHERE id = 1", [])

        assert_in_delta x1, 0.0, 0.001
        assert_in_delta y1, 0.0, 0.001
      end

      test "insert multiple non-overlapping entries", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE rt_multi USING rtree(id, x1, x2, y1, y2);"
          )

        {:ok, 1} = NIF.execute(conn, "INSERT INTO rt_multi VALUES (1, 0, 5, 0, 5)", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO rt_multi VALUES (2, 10, 15, 10, 15)", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO rt_multi VALUES (3, 20, 25, 20, 25)", [])

        assert {:ok, %{num_rows: 3}} =
                 NIF.query(conn, "SELECT * FROM rt_multi", [])
      end

      # -------------------------------------------------------------------
      # Spatial queries — bounding box intersection
      # -------------------------------------------------------------------

      test "query finds entries whose bbox intersects the search region", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE rt_q USING rtree(id, x1, x2, y1, y2);
          INSERT INTO rt_q VALUES (1, 0, 10, 0, 10);
          INSERT INTO rt_q VALUES (2, 20, 30, 20, 30);
          INSERT INTO rt_q VALUES (3, 5, 15, 5, 15);
          """)

        # Query region [8,12] x [8,12] should intersect entries 1 and 3
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT id FROM rt_q WHERE x1 <= 12 AND x2 >= 8 AND y1 <= 12 AND y2 >= 8 ORDER BY id",
                   []
                 )

        assert rows == [[1], [3]]
      end

      test "query returns empty when no intersection", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE rt_empty USING rtree(id, x1, x2, y1, y2);
          INSERT INTO rt_empty VALUES (1, 0, 5, 0, 5);
          """)

        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(
                   conn,
                   "SELECT id FROM rt_empty WHERE x1 <= -10 AND x2 >= -15 AND y1 <= -10 AND y2 >= -15",
                   []
                 )
      end

      test "containment query — find entries fully inside a region", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE rt_cont USING rtree(id, x1, x2, y1, y2);
          INSERT INTO rt_cont VALUES (1, 2, 4, 2, 4);
          INSERT INTO rt_cont VALUES (2, 0, 10, 0, 10);
          INSERT INTO rt_cont VALUES (3, 3, 5, 3, 5);
          """)

        # Entries fully contained within [1,6] x [1,6]
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT id FROM rt_cont WHERE x1 >= 1 AND x2 <= 6 AND y1 >= 1 AND y2 <= 6 ORDER BY id",
                   []
                 )

        assert rows == [[1], [3]]
      end

      # -------------------------------------------------------------------
      # Update and delete
      # -------------------------------------------------------------------

      test "update an rtree entry", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE rt_upd USING rtree(id, x1, x2, y1, y2);
          INSERT INTO rt_upd VALUES (1, 0, 10, 0, 10);
          """)

        {:ok, 1} =
          NIF.execute(
            conn,
            "UPDATE rt_upd SET x1 = 5, x2 = 15 WHERE id = 1",
            []
          )

        assert {:ok, %{rows: [[1, 5.0, 15.0, y1, 10.0]]}} =
                 NIF.query(conn, "SELECT * FROM rt_upd WHERE id = 1", [])

        assert_in_delta y1, 0.0, 0.001
      end

      test "delete an rtree entry", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE rt_del USING rtree(id, x1, x2, y1, y2);
          INSERT INTO rt_del VALUES (1, 0, 10, 0, 10);
          INSERT INTO rt_del VALUES (2, 20, 30, 20, 30);
          """)

        {:ok, 1} = NIF.execute(conn, "DELETE FROM rt_del WHERE id = 1", [])

        assert {:ok, %{rows: [[2]], num_rows: 1}} =
                 NIF.query(conn, "SELECT id FROM rt_del", [])
      end

      # -------------------------------------------------------------------
      # Coordinate edge cases
      # -------------------------------------------------------------------

      test "zero-area point entries", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE rt_pt USING rtree(id, x1, x2, y1, y2);"
          )

        {:ok, 1} = NIF.execute(conn, "INSERT INTO rt_pt VALUES (1, 5, 5, 5, 5)", [])

        assert {:ok, %{rows: [[1, 5.0, 5.0, 5.0, 5.0]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM rt_pt WHERE id = 1", [])
      end

      test "negative coordinates", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE rt_neg USING rtree(id, x1, x2, y1, y2);"
          )

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO rt_neg VALUES (1, -100, -50, -200, -100)", [])

        assert {:ok, %{rows: [[1, x1, x2, y1, y2]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM rt_neg WHERE id = 1", [])

        assert_in_delta x1, -100.0, 0.001
        assert_in_delta x2, -50.0, 0.001
        assert_in_delta y1, -200.0, 0.001
        assert_in_delta y2, -100.0, 0.001
      end

      test "very large coordinates", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE rt_big USING rtree(id, x1, x2, y1, y2);"
          )

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO rt_big VALUES (1, -1.0e12, 1.0e12, -1.0e12, 1.0e12)",
            []
          )

        assert {:ok, %{rows: [[1 | _]], num_rows: 1}} =
                 NIF.query(conn, "SELECT * FROM rt_big WHERE id = 1", [])
      end

      test "fractional coordinates preserve precision", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE rt_frac USING rtree(id, x1, x2, y1, y2);"
          )

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO rt_frac VALUES (1, 1.5, 2.5, 3.25, 4.75)",
            []
          )

        assert {:ok, %{rows: [[1, x1, x2, y1, y2]]}} =
                 NIF.query(conn, "SELECT * FROM rt_frac WHERE id = 1", [])

        assert_in_delta x1, 1.5, 0.001
        assert_in_delta x2, 2.5, 0.001
        assert_in_delta y1, 3.25, 0.001
        assert_in_delta y2, 4.75, 0.001
      end

      # -------------------------------------------------------------------
      # Many entries — spatial index performance proof
      # -------------------------------------------------------------------

      test "spatial query on 1000 entries returns correct subset", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE rt_perf USING rtree(id, x1, x2, y1, y2);"
          )

        for i <- 1..1000 do
          x = rem(i, 100) * 10
          y = div(i, 100) * 10

          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO rt_perf VALUES (?1, ?2, ?3, ?4, ?5)", [
              i,
              x,
              x + 5,
              y,
              y + 5
            ])
        end

        # Small query window should return a subset, not all 1000
        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT id FROM rt_perf WHERE x1 <= 25 AND x2 >= 15 AND y1 <= 15 AND y2 >= 5",
                   []
                 )

        assert length(rows) > 0
        assert length(rows) < 1000
      end

      # -------------------------------------------------------------------
      # 3D R-Tree
      # -------------------------------------------------------------------

      test "3D rtree insert and spatial query", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE VIRTUAL TABLE rt_3dq USING rtree(id, x1, x2, y1, y2, z1, z2);
          INSERT INTO rt_3dq VALUES (1, 0, 10, 0, 10, 0, 10);
          INSERT INTO rt_3dq VALUES (2, 20, 30, 20, 30, 20, 30);
          INSERT INTO rt_3dq VALUES (3, 5, 15, 5, 15, 5, 15);
          """)

        assert {:ok, %{rows: rows}} =
                 NIF.query(
                   conn,
                   "SELECT id FROM rt_3dq WHERE x1 <= 12 AND x2 >= 8 AND y1 <= 12 AND y2 >= 8 AND z1 <= 12 AND z2 >= 8 ORDER BY id",
                   []
                 )

        assert rows == [[1], [3]]
      end

      # -------------------------------------------------------------------
      # R-Tree with auxiliary columns (rtree + content)
      # -------------------------------------------------------------------

      test "rtree with auxiliary columns stores extra data", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE rt_aux USING rtree(id, x1, x2, y1, y2, +label TEXT, +priority INTEGER);"
          )

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO rt_aux VALUES (1, 0, 10, 0, 10, 'building', 5)",
            []
          )

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO rt_aux VALUES (2, 20, 30, 20, 30, 'park', 3)",
            []
          )

        assert {:ok, %{rows: [[1, x1, 10.0, y1, 10.0, "building", 5]]}} =
                 NIF.query(conn, "SELECT * FROM rt_aux WHERE id = 1", [])

        assert_in_delta x1, 0.0, 0.001
        assert_in_delta y1, 0.0, 0.001

        # Spatial query with auxiliary column filter
        assert {:ok, %{rows: [["building"]]}} =
                 NIF.query(
                   conn,
                   "SELECT label FROM rt_aux WHERE x1 <= 5 AND x2 >= 5 AND y1 <= 5 AND y2 >= 5 AND priority > 4",
                   []
                 )
      end

      # -------------------------------------------------------------------
      # Error cases
      # -------------------------------------------------------------------

      test "rtree rejects x1 > x2", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE rt_inv USING rtree(id, x1, x2, y1, y2);"
          )

        assert {:error, _} =
                 NIF.execute(conn, "INSERT INTO rt_inv VALUES (1, 10, 5, 0, 10)", [])
      end

      test "rtree coerces NULL coordinates to 0.0", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE VIRTUAL TABLE rt_null USING rtree(id, x1, x2, y1, y2);"
          )

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO rt_null VALUES (1, NULL, 5, 0, 10)", [])

        assert {:ok, %{rows: [[1, x1, 5.0, y1, 10.0]]}} =
                 NIF.query(conn, "SELECT * FROM rt_null WHERE id = 1", [])

        assert_in_delta x1, 0.0, 0.001
        assert_in_delta y1, 0.0, 0.001
      end
    end
  end
end
