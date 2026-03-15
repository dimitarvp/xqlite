defmodule Xqlite.NIF.SessionTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "session using #{prefix}" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        assert {:ok, conn} = apply(mod, fun, args)

        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      # -------------------------------------------------------------------
      # Session lifecycle
      # -------------------------------------------------------------------

      test "create and delete session", %{conn: conn} do
        assert {:ok, session} = NIF.session_new(conn)
        assert :ok = NIF.session_delete(session)
      end

      test "session_delete is idempotent", %{conn: conn} do
        {:ok, session} = NIF.session_new(conn)
        assert :ok = NIF.session_delete(session)
        assert :ok = NIF.session_delete(session)
      end

      test "new session is empty", %{conn: conn} do
        {:ok, session} = NIF.session_new(conn)
        assert NIF.session_is_empty(session) == {:ok, true}
        NIF.session_delete(session)
      end

      # -------------------------------------------------------------------
      # Attach and track changes
      # -------------------------------------------------------------------

      test "attach specific table", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE sess_t1 (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, session} = NIF.session_new(conn)
        assert :ok = NIF.session_attach(session, "sess_t1")

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_t1 VALUES (1, 'hello')", [])
        assert NIF.session_is_empty(session) == {:ok, false}

        NIF.session_delete(session)
      end

      test "attach nil tracks all tables", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE sess_all1 (id INTEGER PRIMARY KEY, val TEXT);
          CREATE TABLE sess_all2 (id INTEGER PRIMARY KEY, val TEXT);
          """)

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_all1 VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_all2 VALUES (1, 'b')", [])

        assert NIF.session_is_empty(session) == {:ok, false}

        NIF.session_delete(session)
      end

      test "untracked table changes are not recorded", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE sess_tracked (id INTEGER PRIMARY KEY, val TEXT);
          CREATE TABLE sess_untracked (id INTEGER PRIMARY KEY, val TEXT);
          """)

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, "sess_tracked")

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_untracked VALUES (1, 'ignored')", [])

        assert NIF.session_is_empty(session) == {:ok, true}

        NIF.session_delete(session)
      end

      # -------------------------------------------------------------------
      # Changeset capture
      # -------------------------------------------------------------------

      test "changeset captures INSERT", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE TABLE sess_cs_ins (id INTEGER PRIMARY KEY, val TEXT);"
          )

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_cs_ins VALUES (1, 'hello')", [])

        assert {:ok, changeset} = NIF.session_changeset(session)
        assert is_binary(changeset)
        assert byte_size(changeset) > 0

        NIF.session_delete(session)
      end

      test "changeset captures UPDATE", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE TABLE sess_cs_upd (id INTEGER PRIMARY KEY, val TEXT);"
          )

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_cs_upd VALUES (1, 'old')", [])

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        {:ok, 1} = NIF.execute(conn, "UPDATE sess_cs_upd SET val = 'new' WHERE id = 1", [])

        assert {:ok, changeset} = NIF.session_changeset(session)
        assert byte_size(changeset) > 0

        NIF.session_delete(session)
      end

      test "changeset captures DELETE", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE TABLE sess_cs_del (id INTEGER PRIMARY KEY, val TEXT);"
          )

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_cs_del VALUES (1, 'doomed')", [])

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        {:ok, 1} = NIF.execute(conn, "DELETE FROM sess_cs_del WHERE id = 1", [])

        assert {:ok, changeset} = NIF.session_changeset(session)
        assert byte_size(changeset) > 0

        NIF.session_delete(session)
      end

      test "empty changeset when no changes", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE sess_cs_empty (id INTEGER PRIMARY KEY);")

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        assert {:ok, changeset} = NIF.session_changeset(session)
        assert byte_size(changeset) == 0

        NIF.session_delete(session)
      end

      # -------------------------------------------------------------------
      # Patchset capture
      # -------------------------------------------------------------------

      test "patchset captures changes", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE sess_ps (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_ps VALUES (1, 'patch')", [])

        assert {:ok, patchset} = NIF.session_patchset(session)
        assert is_binary(patchset)
        assert byte_size(patchset) > 0

        NIF.session_delete(session)
      end

      # -------------------------------------------------------------------
      # Apply changeset
      # -------------------------------------------------------------------

      test "apply changeset replicates INSERT to another connection", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE sess_ap (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_ap VALUES (1, 'replicated')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_ap VALUES (2, 'also')", [])

        {:ok, changeset} = NIF.session_changeset(session)
        NIF.session_delete(session)

        {:ok, conn2} = NIF.open_in_memory()

        :ok =
          NIF.execute_batch(conn2, "CREATE TABLE sess_ap (id INTEGER PRIMARY KEY, val TEXT);")

        assert :ok = NIF.changeset_apply(conn2, changeset, :omit)

        assert {:ok, %{rows: rows, num_rows: 2}} =
                 NIF.query(conn2, "SELECT * FROM sess_ap ORDER BY id", [])

        assert rows == [[1, "replicated"], [2, "also"]]
        NIF.close(conn2)
      end

      test "apply changeset replicates UPDATE", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE sess_ap_u (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_ap_u VALUES (1, 'before')", [])

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        {:ok, 1} = NIF.execute(conn, "UPDATE sess_ap_u SET val = 'after' WHERE id = 1", [])

        {:ok, changeset} = NIF.session_changeset(session)
        NIF.session_delete(session)

        {:ok, conn2} = NIF.open_in_memory()

        :ok =
          NIF.execute_batch(conn2, """
          CREATE TABLE sess_ap_u (id INTEGER PRIMARY KEY, val TEXT);
          INSERT INTO sess_ap_u VALUES (1, 'before');
          """)

        :ok = NIF.changeset_apply(conn2, changeset, :omit)

        assert {:ok, %{rows: [[1, "after"]]}} =
                 NIF.query(conn2, "SELECT * FROM sess_ap_u", [])

        NIF.close(conn2)
      end

      test "apply changeset replicates DELETE", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE sess_ap_d (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_ap_d VALUES (1, 'doomed')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_ap_d VALUES (2, 'safe')", [])

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        {:ok, 1} = NIF.execute(conn, "DELETE FROM sess_ap_d WHERE id = 1", [])

        {:ok, changeset} = NIF.session_changeset(session)
        NIF.session_delete(session)

        {:ok, conn2} = NIF.open_in_memory()

        :ok =
          NIF.execute_batch(conn2, """
          CREATE TABLE sess_ap_d (id INTEGER PRIMARY KEY, val TEXT);
          INSERT INTO sess_ap_d VALUES (1, 'doomed');
          INSERT INTO sess_ap_d VALUES (2, 'safe');
          """)

        :ok = NIF.changeset_apply(conn2, changeset, :omit)

        assert {:ok, %{rows: [[2, "safe"]], num_rows: 1}} =
                 NIF.query(conn2, "SELECT * FROM sess_ap_d", [])

        NIF.close(conn2)
      end

      # -------------------------------------------------------------------
      # Changeset invert
      # -------------------------------------------------------------------

      test "inverted changeset undoes changes", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE sess_inv (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_inv VALUES (1, 'hello')", [])

        {:ok, changeset} = NIF.session_changeset(session)
        NIF.session_delete(session)

        {:ok, inverted} = NIF.changeset_invert(changeset)
        assert is_binary(inverted)
        assert byte_size(inverted) > 0

        :ok = NIF.changeset_apply(conn, inverted, :omit)

        assert {:ok, %{rows: [], num_rows: 0}} =
                 NIF.query(conn, "SELECT * FROM sess_inv", [])
      end

      test "double invert produces equivalent changeset", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE sess_dinv (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_dinv VALUES (1, 'test')", [])

        {:ok, changeset} = NIF.session_changeset(session)
        NIF.session_delete(session)

        {:ok, inv1} = NIF.changeset_invert(changeset)
        {:ok, inv2} = NIF.changeset_invert(inv1)

        # Double-inverted should be equivalent to original — apply to fresh DB
        {:ok, conn2} = NIF.open_in_memory()

        :ok =
          NIF.execute_batch(
            conn2,
            "CREATE TABLE sess_dinv (id INTEGER PRIMARY KEY, val TEXT);"
          )

        :ok = NIF.changeset_apply(conn2, inv2, :omit)

        assert {:ok, %{rows: [[1, "test"]], num_rows: 1}} =
                 NIF.query(conn2, "SELECT * FROM sess_dinv", [])

        NIF.close(conn2)
      end

      # -------------------------------------------------------------------
      # Changeset concat
      # -------------------------------------------------------------------

      test "concatenated changesets apply as one", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE sess_cat (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, s1} = NIF.session_new(conn)
        :ok = NIF.session_attach(s1, nil)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_cat VALUES (1, 'first')", [])
        {:ok, cs1} = NIF.session_changeset(s1)
        NIF.session_delete(s1)

        {:ok, s2} = NIF.session_new(conn)
        :ok = NIF.session_attach(s2, nil)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_cat VALUES (2, 'second')", [])
        {:ok, cs2} = NIF.session_changeset(s2)
        NIF.session_delete(s2)

        {:ok, combined} = NIF.changeset_concat(cs1, cs2)
        assert byte_size(combined) > 0

        {:ok, conn2} = NIF.open_in_memory()

        :ok =
          NIF.execute_batch(conn2, "CREATE TABLE sess_cat (id INTEGER PRIMARY KEY, val TEXT);")

        :ok = NIF.changeset_apply(conn2, combined, :omit)

        assert {:ok, %{rows: [[1, "first"], [2, "second"]], num_rows: 2}} =
                 NIF.query(conn2, "SELECT * FROM sess_cat ORDER BY id", [])

        NIF.close(conn2)
      end

      # -------------------------------------------------------------------
      # Conflict strategies
      # -------------------------------------------------------------------

      test "conflict :omit skips conflicting rows", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE sess_omit (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_omit VALUES (1, 'from_source')", [])
        {:ok, changeset} = NIF.session_changeset(session)
        NIF.session_delete(session)

        {:ok, conn2} = NIF.open_in_memory()

        :ok =
          NIF.execute_batch(conn2, """
          CREATE TABLE sess_omit (id INTEGER PRIMARY KEY, val TEXT);
          INSERT INTO sess_omit VALUES (1, 'existing');
          """)

        :ok = NIF.changeset_apply(conn2, changeset, :omit)

        assert {:ok, %{rows: [[1, "existing"]]}} =
                 NIF.query(conn2, "SELECT * FROM sess_omit", [])

        NIF.close(conn2)
      end

      test "conflict :replace overwrites conflicting rows", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE sess_repl (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_repl VALUES (1, 'from_source')", [])
        {:ok, changeset} = NIF.session_changeset(session)
        NIF.session_delete(session)

        {:ok, conn2} = NIF.open_in_memory()

        :ok =
          NIF.execute_batch(conn2, """
          CREATE TABLE sess_repl (id INTEGER PRIMARY KEY, val TEXT);
          INSERT INTO sess_repl VALUES (1, 'existing');
          """)

        :ok = NIF.changeset_apply(conn2, changeset, :replace)

        assert {:ok, %{rows: [[1, "from_source"]]}} =
                 NIF.query(conn2, "SELECT * FROM sess_repl", [])

        NIF.close(conn2)
      end

      test "invalid conflict strategy returns error", %{conn: conn} do
        :ok = NIF.execute_batch(conn, "CREATE TABLE sess_bad (id INTEGER PRIMARY KEY);")

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_bad VALUES (1)", [])
        {:ok, changeset} = NIF.session_changeset(session)
        NIF.session_delete(session)

        assert {:error, :invalid_conflict_strategy} =
                 NIF.changeset_apply(conn, changeset, :invalid)
      end

      # -------------------------------------------------------------------
      # Multiple operations in one changeset
      # -------------------------------------------------------------------

      test "changeset with INSERT + UPDATE + DELETE", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE sess_mix (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_mix VALUES (1, 'keep')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_mix VALUES (2, 'update_me')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_mix VALUES (3, 'delete_me')", [])

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_mix VALUES (4, 'new')", [])
        {:ok, 1} = NIF.execute(conn, "UPDATE sess_mix SET val = 'updated' WHERE id = 2", [])
        {:ok, 1} = NIF.execute(conn, "DELETE FROM sess_mix WHERE id = 3", [])

        {:ok, changeset} = NIF.session_changeset(session)
        NIF.session_delete(session)

        {:ok, conn2} = NIF.open_in_memory()

        :ok =
          NIF.execute_batch(conn2, """
          CREATE TABLE sess_mix (id INTEGER PRIMARY KEY, val TEXT);
          INSERT INTO sess_mix VALUES (1, 'keep');
          INSERT INTO sess_mix VALUES (2, 'update_me');
          INSERT INTO sess_mix VALUES (3, 'delete_me');
          """)

        :ok = NIF.changeset_apply(conn2, changeset, :omit)

        assert {:ok, %{rows: rows}} =
                 NIF.query(conn2, "SELECT * FROM sess_mix ORDER BY id", [])

        assert rows == [[1, "keep"], [2, "updated"], [4, "new"]]
        NIF.close(conn2)
      end

      # -------------------------------------------------------------------
      # Edge cases
      # -------------------------------------------------------------------

      test "changeset with NULL values", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE sess_null (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sess_null VALUES (1, NULL)", [])

        {:ok, changeset} = NIF.session_changeset(session)
        NIF.session_delete(session)

        {:ok, conn2} = NIF.open_in_memory()

        :ok =
          NIF.execute_batch(
            conn2,
            "CREATE TABLE sess_null (id INTEGER PRIMARY KEY, val TEXT);"
          )

        :ok = NIF.changeset_apply(conn2, changeset, :omit)

        assert {:ok, %{rows: [[1, nil]]}} =
                 NIF.query(conn2, "SELECT * FROM sess_null", [])

        NIF.close(conn2)
      end

      test "changeset with all SQLite types", %{conn: conn} do
        :ok =
          NIF.execute_batch(
            conn,
            "CREATE TABLE sess_types (id INTEGER PRIMARY KEY, i INTEGER, r REAL, t TEXT, b BLOB);"
          )

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO sess_types VALUES (1, 42, 3.14, 'hello', X'DEADBEEF')",
            []
          )

        {:ok, changeset} = NIF.session_changeset(session)
        NIF.session_delete(session)

        {:ok, conn2} = NIF.open_in_memory()

        :ok =
          NIF.execute_batch(
            conn2,
            "CREATE TABLE sess_types (id INTEGER PRIMARY KEY, i INTEGER, r REAL, t TEXT, b BLOB);"
          )

        :ok = NIF.changeset_apply(conn2, changeset, :omit)

        assert {:ok, %{rows: [[1, 42, pi, "hello", blob]]}} =
                 NIF.query(conn2, "SELECT * FROM sess_types", [])

        assert_in_delta pi, 3.14, 0.001
        assert blob == <<0xDE, 0xAD, 0xBE, 0xEF>>
        NIF.close(conn2)
      end

      test "large batch of changes in one session", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, "CREATE TABLE sess_bulk (id INTEGER PRIMARY KEY, val TEXT);")

        {:ok, session} = NIF.session_new(conn)
        :ok = NIF.session_attach(session, nil)

        for i <- 1..500 do
          {:ok, 1} =
            NIF.execute(conn, "INSERT INTO sess_bulk VALUES (?1, ?2)", [i, "row_#{i}"])
        end

        {:ok, changeset} = NIF.session_changeset(session)
        NIF.session_delete(session)

        assert byte_size(changeset) > 0

        {:ok, conn2} = NIF.open_in_memory()

        :ok =
          NIF.execute_batch(
            conn2,
            "CREATE TABLE sess_bulk (id INTEGER PRIMARY KEY, val TEXT);"
          )

        :ok = NIF.changeset_apply(conn2, changeset, :omit)

        assert {:ok, %{rows: [[500]]}} =
                 NIF.query(conn2, "SELECT COUNT(*) FROM sess_bulk", [])

        assert {:ok, %{rows: [[1, "row_1"]]}} =
                 NIF.query(conn2, "SELECT * FROM sess_bulk WHERE id = 1", [])

        assert {:ok, %{rows: [[500, "row_500"]]}} =
                 NIF.query(conn2, "SELECT * FROM sess_bulk WHERE id = 500", [])

        NIF.close(conn2)
      end
    end
  end

  # -------------------------------------------------------------------
  # Edge cases outside connection_openers loop
  # -------------------------------------------------------------------

  test "session_new on closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory()
    NIF.close(conn)

    assert {:error, _} = NIF.session_new(conn)
  end

  test "changeset_apply on closed connection returns error" do
    {:ok, conn} = NIF.open_in_memory()
    NIF.close(conn)

    assert {:error, _} = NIF.changeset_apply(conn, <<>>, :omit)
  end
end
