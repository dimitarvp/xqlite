defmodule Xqlite.NIF.UpdateHookTest do
  use ExUnit.Case, async: true

  import Xqlite.TestUtil, only: [connection_openers: 0, find_opener_mfa!: 1]

  alias XqliteNIF, as: NIF

  for {type_tag, prefix, _opener_mfa} <- connection_openers() do
    describe "#{prefix}: set_update_hook/2" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE hook_test (id INTEGER PRIMARY KEY, val TEXT);
          """)

        {:ok, conn: conn}
      end

      test "returns :ok", %{conn: conn} do
        assert :ok = NIF.set_update_hook(conn, self())
      end

      test "can be called multiple times to replace listener", %{conn: conn} do
        assert :ok = NIF.set_update_hook(conn, self())
        assert :ok = NIF.set_update_hook(conn, self())
      end
    end

    describe "#{prefix}: remove_update_hook/1" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "returns :ok after hook was set", %{conn: conn} do
        :ok = NIF.set_update_hook(conn, self())
        assert :ok = NIF.remove_update_hook(conn)
      end

      test "returns :ok even without prior set", %{conn: conn} do
        assert :ok = NIF.remove_update_hook(conn)
      end

      test "is idempotent", %{conn: conn} do
        :ok = NIF.set_update_hook(conn, self())
        assert :ok = NIF.remove_update_hook(conn)
        assert :ok = NIF.remove_update_hook(conn)
      end
    end

    describe "#{prefix}: INSERT notification" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE hook_test (id INTEGER PRIMARY KEY, val TEXT);
          """)

        :ok = NIF.set_update_hook(conn, self())
        {:ok, conn: conn}
      end

      test "delivers {:xqlite_update, :insert, ...} on INSERT", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (1, 'hello')", [])

        assert_receive {:xqlite_update, :insert, "main", "hook_test", 1}, 2_000
      end

      test "rowid matches inserted row", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (42, 'test')", [])

        assert_receive {:xqlite_update, :insert, "main", "hook_test", 42}, 2_000
      end

      test "fires for each row in multi-row insert", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (2, 'b')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (3, 'c')", [])

        assert_receive {:xqlite_update, :insert, "main", "hook_test", 1}, 2_000
        assert_receive {:xqlite_update, :insert, "main", "hook_test", 2}, 2_000
        assert_receive {:xqlite_update, :insert, "main", "hook_test", 3}, 2_000
      end

      test "fires for INSERT with params", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (?1, ?2)", [7, "param"])

        assert_receive {:xqlite_update, :insert, "main", "hook_test", 7}, 2_000
      end
    end

    describe "#{prefix}: UPDATE notification" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE hook_test (id INTEGER PRIMARY KEY, val TEXT);
          INSERT INTO hook_test VALUES (1, 'before');
          """)

        :ok = NIF.set_update_hook(conn, self())
        {:ok, conn: conn}
      end

      test "delivers {:xqlite_update, :update, ...} on UPDATE", %{conn: conn} do
        {:ok, 1} =
          NIF.execute(conn, "UPDATE hook_test SET val = 'after' WHERE id = 1", [])

        assert_receive {:xqlite_update, :update, "main", "hook_test", 1}, 2_000
      end

      test "fires for each updated row", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (2, 'x')", [])
        # Drain the insert notifications
        assert_receive {:xqlite_update, :insert, _, _, _}, 2_000

        {:ok, 2} = NIF.execute(conn, "UPDATE hook_test SET val = 'changed'", [])

        assert_receive {:xqlite_update, :update, "main", "hook_test", 1}, 2_000
        assert_receive {:xqlite_update, :update, "main", "hook_test", 2}, 2_000
      end
    end

    describe "#{prefix}: DELETE notification" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE hook_test (id INTEGER PRIMARY KEY, val TEXT);
          INSERT INTO hook_test VALUES (1, 'doomed');
          INSERT INTO hook_test VALUES (2, 'also doomed');
          """)

        :ok = NIF.set_update_hook(conn, self())
        {:ok, conn: conn}
      end

      test "delivers {:xqlite_update, :delete, ...} on DELETE", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "DELETE FROM hook_test WHERE id = 1", [])

        assert_receive {:xqlite_update, :delete, "main", "hook_test", 1}, 2_000
      end

      test "fires for each deleted row with real WHERE clause", %{conn: conn} do
        {:ok, 2} =
          NIF.execute(conn, "DELETE FROM hook_test WHERE id IN (1, 2)", [])

        assert_receive {:xqlite_update, :delete, "main", "hook_test", 1}, 2_000
        assert_receive {:xqlite_update, :delete, "main", "hook_test", 2}, 2_000
      end
    end

    describe "#{prefix}: hook lifecycle" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE hook_test (id INTEGER PRIMARY KEY, val TEXT);
          """)

        {:ok, conn: conn}
      end

      test "stops delivery after remove_update_hook", %{conn: conn} do
        :ok = NIF.set_update_hook(conn, self())
        :ok = NIF.remove_update_hook(conn)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (1, 'silent')", [])

        refute_receive {:xqlite_update, _, _, _, _}, 500
      end

      test "replacing listener sends events only to new pid", %{conn: conn} do
        old_listener = spawn_collector()
        new_listener = spawn_collector()

        :ok = NIF.set_update_hook(conn, old_listener)
        :ok = NIF.set_update_hook(conn, new_listener)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (1, 'test')", [])

        assert length(get_collected(new_listener)) > 0
        assert get_collected(old_listener) == []
      end

      test "re-register after remove works", %{conn: conn} do
        :ok = NIF.set_update_hook(conn, self())
        :ok = NIF.remove_update_hook(conn)
        :ok = NIF.set_update_hook(conn, self())

        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (1, 'back')", [])

        assert_receive {:xqlite_update, :insert, "main", "hook_test", 1}, 2_000
      end

      test "dead listener pid does not crash", %{conn: conn} do
        dead = spawn(fn -> :ok end)
        ref = Process.monitor(dead)
        receive do: ({:DOWN, ^ref, :process, ^dead, _} -> :ok)

        :ok = NIF.set_update_hook(conn, dead)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (1, 'ghost')", [])
      end
    end

    describe "#{prefix}: transaction interaction" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE hook_test (id INTEGER PRIMARY KEY, val TEXT);
          """)

        :ok = NIF.set_update_hook(conn, self())
        {:ok, conn: conn}
      end

      test "fires during transaction before commit", %{conn: conn} do
        :ok = NIF.begin(conn, :immediate)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (1, 'txn')", [])

        # Should receive notification even before commit
        assert_receive {:xqlite_update, :insert, "main", "hook_test", 1}, 2_000

        :ok = NIF.commit(conn)
      end

      test "fires even when transaction is rolled back", %{conn: conn} do
        :ok = NIF.begin(conn, :immediate)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (1, 'doomed')", [])

        assert_receive {:xqlite_update, :insert, "main", "hook_test", 1}, 2_000

        :ok = NIF.rollback(conn)

        # The row doesn't exist but we still got the notification
        {:ok, %{num_rows: 0}} =
          NIF.query(conn, "SELECT * FROM hook_test WHERE id = 1", [])
      end

      test "fires for each statement in a transaction", %{conn: conn} do
        :ok = NIF.begin(conn, :exclusive)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (1, 'a')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO hook_test VALUES (2, 'b')", [])
        {:ok, 1} = NIF.execute(conn, "UPDATE hook_test SET val = 'aa' WHERE id = 1", [])
        {:ok, 1} = NIF.execute(conn, "DELETE FROM hook_test WHERE id = 2", [])
        :ok = NIF.commit(conn)

        messages = collect_all_updates(500)

        actions = Enum.map(messages, fn {:xqlite_update, action, _, _, _} -> action end)
        assert :insert in actions
        assert :update in actions
        assert :delete in actions
      end
    end

    describe "#{prefix}: multiple tables" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
          CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER, body TEXT);
          """)

        :ok = NIF.set_update_hook(conn, self())
        {:ok, conn: conn}
      end

      test "reports correct table name for each table", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO users VALUES (1, 'alice')", [])

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO posts VALUES (1, 1, 'hello')", [])

        assert_receive {:xqlite_update, :insert, "main", "users", 1}, 2_000
        assert_receive {:xqlite_update, :insert, "main", "posts", 1}, 2_000
      end

      test "cascade delete fires for both tables", %{conn: conn} do
        # Enable foreign keys and recreate with cascade
        :ok = NIF.remove_update_hook(conn)
        {:ok, _} = NIF.set_pragma(conn, "foreign_keys", true)

        :ok =
          NIF.execute_batch(conn, """
          DROP TABLE posts;
          DROP TABLE users;
          CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);
          CREATE TABLE posts (
            id INTEGER PRIMARY KEY,
            user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
            body TEXT
          );
          """)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO users VALUES (1, 'alice')", [])

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO posts VALUES (1, 1, 'hello')", [])

        :ok = NIF.set_update_hook(conn, self())

        {:ok, 1} = NIF.execute(conn, "DELETE FROM users WHERE id = 1", [])

        messages = collect_all_updates(1_000)

        tables =
          Enum.map(messages, fn {:xqlite_update, _, _, table, _} -> table end)

        assert "users" in tables
        assert "posts" in tables
      end
    end

    describe "#{prefix}: concurrent access" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);")

        {:ok, conn: conn}
      end

      test "hook fires correctly under concurrent inserts", %{conn: conn} do
        collector = spawn_collector()
        :ok = NIF.set_update_hook(conn, collector)

        n = 30

        tasks =
          Enum.map(1..n, fn i ->
            Task.async(fn ->
              NIF.execute(conn, "INSERT INTO t VALUES (?1, ?2)", [i, "v#{i}"])
            end)
          end)

        results = Task.await_many(tasks, 10_000)
        assert Enum.all?(results, &match?({:ok, 1}, &1))

        messages = get_collected(collector)
        assert length(messages) == n

        Enum.each(messages, fn msg ->
          assert {:xqlite_update, :insert, "main", "t", _rowid} = msg
        end)
      end
    end

    describe "#{prefix}: execute_batch triggers" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);")

        {:ok, conn: conn}
      end

      test "fires for each statement in a batch", %{conn: conn} do
        :ok = NIF.set_update_hook(conn, self())

        :ok =
          NIF.execute_batch(conn, """
          INSERT INTO t VALUES (1, 'a');
          INSERT INTO t VALUES (2, 'b');
          INSERT INTO t VALUES (3, 'c');
          """)

        assert_receive {:xqlite_update, :insert, "main", "t", 1}, 2_000
        assert_receive {:xqlite_update, :insert, "main", "t", 2}, 2_000
        assert_receive {:xqlite_update, :insert, "main", "t", 3}, 2_000
      end
    end

    describe "#{prefix}: query with RETURNING" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT);")

        :ok = NIF.set_update_hook(conn, self())
        {:ok, conn: conn}
      end

      test "INSERT ... RETURNING fires insert notification", %{conn: conn} do
        {:ok, %{rows: [[1, "hi"]]}} =
          NIF.query(conn, "INSERT INTO t VALUES (1, 'hi') RETURNING id, v", [])

        assert_receive {:xqlite_update, :insert, "main", "t", 1}, 2_000
      end
    end

    describe "#{prefix}: closed connection" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        :ok = NIF.close(conn)
        {:ok, conn: conn}
      end

      test "set_update_hook on closed connection returns error", %{conn: conn} do
        assert {:error, :connection_closed} = NIF.set_update_hook(conn, self())
      end

      test "remove_update_hook on closed connection returns error", %{conn: conn} do
        assert {:error, :connection_closed} = NIF.remove_update_hook(conn)
      end
    end

    describe "#{prefix}: GenServer-like forwarding" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY);")

        {:ok, conn: conn}
      end

      test "process can forward update events to another pid", %{conn: conn} do
        test_pid = self()

        forwarder =
          spawn(fn ->
            receive do
              {:xqlite_update, _, _, _, _} = event ->
                send(test_pid, {:forwarded, event})
            end
          end)

        :ok = NIF.set_update_hook(conn, forwarder)
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (1)", [])

        assert_receive {:forwarded, {:xqlite_update, :insert, "main", "t", 1}}, 2_000
      end
    end

    describe "#{prefix}: realistic workload: user/posts CRUD" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        {:ok, _} = NIF.set_pragma(conn, "foreign_keys", true)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE users (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            email TEXT UNIQUE NOT NULL
          );
          CREATE TABLE posts (
            id INTEGER PRIMARY KEY,
            user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            body TEXT
          );
          """)

        :ok = NIF.set_update_hook(conn, self())
        {:ok, conn: conn}
      end

      test "tracks full user lifecycle: create, update profile, delete", %{conn: conn} do
        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO users (name, email) VALUES (?1, ?2)",
            ["alice", "alice@example.com"]
          )

        assert_receive {:xqlite_update, :insert, "main", "users", 1}, 2_000

        {:ok, 1} =
          NIF.execute(
            conn,
            "UPDATE users SET name = ?1 WHERE email = ?2",
            ["Alice Smith", "alice@example.com"]
          )

        assert_receive {:xqlite_update, :update, "main", "users", 1}, 2_000

        {:ok, 1} =
          NIF.execute(conn, "DELETE FROM users WHERE id = ?1", [1])

        assert_receive {:xqlite_update, :delete, "main", "users", 1}, 2_000
      end

      test "cascade delete removes posts and fires for both tables", %{conn: conn} do
        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO users (name, email) VALUES (?1, ?2)",
            ["bob", "bob@example.com"]
          )

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO posts (user_id, title, body) VALUES (?1, ?2, ?3)",
            [1, "Hello World", "My first post"]
          )

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO posts (user_id, title, body) VALUES (?1, ?2, ?3)",
            [1, "Second Post", "More content"]
          )

        # Drain insert notifications
        for _ <- 1..3, do: assert_receive({:xqlite_update, :insert, _, _, _}, 2_000)

        {:ok, 1} =
          NIF.execute(conn, "DELETE FROM users WHERE id = ?1", [1])

        messages = collect_all_updates(1_000)
        tables = Enum.map(messages, fn {:xqlite_update, _, _, t, _} -> t end)
        actions = Enum.map(messages, fn {:xqlite_update, a, _, _, _} -> a end)

        assert "users" in tables
        assert "posts" in tables
        assert Enum.count(actions, &(&1 == :delete)) >= 3
      end

      test "bulk insert with transaction tracks all rows", %{conn: conn} do
        :ok = NIF.begin(conn, :immediate)

        for i <- 1..10 do
          {:ok, 1} =
            NIF.execute(
              conn,
              "INSERT INTO users (name, email) VALUES (?1, ?2)",
              ["user_#{i}", "user_#{i}@example.com"]
            )
        end

        :ok = NIF.commit(conn)

        messages = collect_all_updates(2_000)

        insert_messages =
          Enum.filter(messages, fn
            {:xqlite_update, :insert, "main", "users", _} -> true
            _ -> false
          end)

        assert length(insert_messages) == 10

        rowids =
          Enum.map(insert_messages, fn {:xqlite_update, _, _, _, rid} -> rid end)
          |> Enum.sort()

        assert rowids == Enum.to_list(1..10)
      end

      test "update with subquery fires correct notifications", %{conn: conn} do
        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO users (name, email) VALUES (?1, ?2)",
            ["carol", "carol@example.com"]
          )

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO posts (user_id, title) VALUES (?1, ?2)",
            [1, "Draft"]
          )

        # Drain inserts
        for _ <- 1..2, do: assert_receive({:xqlite_update, :insert, _, _, _}, 2_000)

        {:ok, 1} =
          NIF.execute(
            conn,
            """
            UPDATE posts SET title = 'Published'
            WHERE user_id = (SELECT id FROM users WHERE email = ?1)
            """,
            ["carol@example.com"]
          )

        assert_receive {:xqlite_update, :update, "main", "posts", 1}, 2_000
      end
    end

    describe "#{prefix}: trigger-initiated changes" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "INSERT trigger fires hook for the triggered row", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE orders (id INTEGER PRIMARY KEY, product TEXT NOT NULL);
          CREATE TABLE audit_log (
            id INTEGER PRIMARY KEY,
            action TEXT NOT NULL,
            order_id INTEGER NOT NULL,
            created_at TEXT DEFAULT (datetime('now'))
          );
          CREATE TRIGGER log_new_order AFTER INSERT ON orders
          BEGIN
            INSERT INTO audit_log (action, order_id) VALUES ('created', NEW.id);
          END;
          """)

        :ok = NIF.set_update_hook(conn, self())

        {:ok, 1} = NIF.execute(conn, "INSERT INTO orders (product) VALUES (?1)", ["widget"])

        assert_receive {:xqlite_update, :insert, "main", "orders", 1}, 2_000
        assert_receive {:xqlite_update, :insert, "main", "audit_log", 1}, 2_000
      end

      test "UPDATE trigger fires hook for the triggered row", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance REAL NOT NULL);
          CREATE TABLE balance_history (
            id INTEGER PRIMARY KEY,
            account_id INTEGER NOT NULL,
            old_balance REAL NOT NULL,
            new_balance REAL NOT NULL
          );
          CREATE TRIGGER track_balance AFTER UPDATE OF balance ON accounts
          BEGIN
            INSERT INTO balance_history (account_id, old_balance, new_balance)
            VALUES (OLD.id, OLD.balance, NEW.balance);
          END;
          """)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO accounts VALUES (1, 100.0)", [])

        :ok = NIF.set_update_hook(conn, self())

        {:ok, 1} = NIF.execute(conn, "UPDATE accounts SET balance = 75.0 WHERE id = 1", [])

        assert_receive {:xqlite_update, :update, "main", "accounts", 1}, 2_000
        assert_receive {:xqlite_update, :insert, "main", "balance_history", 1}, 2_000
      end

      test "DELETE trigger fires hook for the triggered row", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE sessions (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, token TEXT);
          CREATE TABLE session_tombstones (
            id INTEGER PRIMARY KEY,
            session_id INTEGER NOT NULL,
            user_id INTEGER NOT NULL
          );
          CREATE TRIGGER archive_session BEFORE DELETE ON sessions
          BEGIN
            INSERT INTO session_tombstones (session_id, user_id)
            VALUES (OLD.id, OLD.user_id);
          END;
          """)

        {:ok, 1} = NIF.execute(conn, "INSERT INTO sessions VALUES (1, 42, 'abc123')", [])

        :ok = NIF.set_update_hook(conn, self())

        {:ok, 1} = NIF.execute(conn, "DELETE FROM sessions WHERE id = 1", [])

        # Trigger fires first (BEFORE DELETE), then the actual delete
        assert_receive {:xqlite_update, :insert, "main", "session_tombstones", 1}, 2_000
        assert_receive {:xqlite_update, :delete, "main", "sessions", 1}, 2_000
      end

      test "multi-row trigger fires for each triggered row", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE items (id INTEGER PRIMARY KEY, status TEXT DEFAULT 'active');
          CREATE TABLE item_events (
            id INTEGER PRIMARY KEY,
            item_id INTEGER NOT NULL,
            event TEXT NOT NULL
          );
          CREATE TRIGGER log_item_delete AFTER DELETE ON items
          BEGIN
            INSERT INTO item_events (item_id, event) VALUES (OLD.id, 'deleted');
          END;
          INSERT INTO items VALUES (1, 'active');
          INSERT INTO items VALUES (2, 'active');
          INSERT INTO items VALUES (3, 'active');
          """)

        :ok = NIF.set_update_hook(conn, self())

        {:ok, 3} = NIF.execute(conn, "DELETE FROM items WHERE id IN (1, 2, 3)", [])

        messages = collect_all_updates(2_000)

        delete_msgs =
          Enum.filter(messages, fn
            {:xqlite_update, :delete, "main", "items", _} -> true
            _ -> false
          end)

        trigger_msgs =
          Enum.filter(messages, fn
            {:xqlite_update, :insert, "main", "item_events", _} -> true
            _ -> false
          end)

        assert length(delete_msgs) == 3
        assert length(trigger_msgs) == 3
      end

      test "chained triggers fire hooks for each level", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE t1 (id INTEGER PRIMARY KEY, val TEXT);
          CREATE TABLE t2 (id INTEGER PRIMARY KEY, t1_id INTEGER, val TEXT);
          CREATE TABLE t3 (id INTEGER PRIMARY KEY, t2_id INTEGER, val TEXT);
          CREATE TRIGGER t1_insert AFTER INSERT ON t1
          BEGIN
            INSERT INTO t2 (t1_id, val) VALUES (NEW.id, 'from_t1');
          END;
          CREATE TRIGGER t2_insert AFTER INSERT ON t2
          BEGIN
            INSERT INTO t3 (t2_id, val) VALUES (NEW.id, 'from_t2');
          END;
          """)

        :ok = NIF.set_update_hook(conn, self())

        {:ok, 1} = NIF.execute(conn, "INSERT INTO t1 (val) VALUES ('origin')", [])

        assert_receive {:xqlite_update, :insert, "main", "t1", 1}, 2_000
        assert_receive {:xqlite_update, :insert, "main", "t2", 1}, 2_000
        assert_receive {:xqlite_update, :insert, "main", "t3", 1}, 2_000
      end
    end

    describe "#{prefix}: WITHOUT ROWID tables" do
      # SQLite's update hook is NOT invoked for WITHOUT ROWID tables.
      # There is no rowid to report, so the callback is skipped entirely.
      # This is documented SQLite behavior, not a bug.
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)
        {:ok, conn: conn}
      end

      test "INSERT on WITHOUT ROWID table does NOT fire hook", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
          """)

        :ok = NIF.set_update_hook(conn, self())

        {:ok, 1} = NIF.execute(conn, "INSERT INTO kv VALUES ('foo', 'bar')", [])

        refute_receive {:xqlite_update, _, _, _, _}, 500
      end

      test "UPDATE on WITHOUT ROWID table does NOT fire hook", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
          INSERT INTO kv VALUES ('k1', 'v1');
          """)

        :ok = NIF.set_update_hook(conn, self())

        {:ok, 1} = NIF.execute(conn, "UPDATE kv SET value = 'v2' WHERE key = 'k1'", [])

        refute_receive {:xqlite_update, _, _, _, _}, 500
      end

      test "DELETE on WITHOUT ROWID table does NOT fire hook", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
          INSERT INTO kv VALUES ('k1', 'v1');
          """)

        :ok = NIF.set_update_hook(conn, self())

        {:ok, 1} = NIF.execute(conn, "DELETE FROM kv WHERE key = 'k1'", [])

        refute_receive {:xqlite_update, _, _, _, _}, 500
      end

      test "same hook fires for regular table but not WITHOUT ROWID", %{conn: conn} do
        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE regular (id INTEGER PRIMARY KEY, val TEXT);
          CREATE TABLE kv (key TEXT PRIMARY KEY, value TEXT) WITHOUT ROWID;
          """)

        :ok = NIF.set_update_hook(conn, self())

        {:ok, 1} = NIF.execute(conn, "INSERT INTO kv VALUES ('k', 'v')", [])
        {:ok, 1} = NIF.execute(conn, "INSERT INTO regular VALUES (1, 'hello')", [])

        # Only the regular table insert fires the hook
        assert_receive {:xqlite_update, :insert, "main", "regular", 1}, 2_000
        refute_receive {:xqlite_update, _, _, "kv", _}, 500
      end
    end

    describe "#{prefix}: large rowid boundary" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT);
          """)

        :ok = NIF.set_update_hook(conn, self())
        {:ok, conn: conn}
      end

      test "rowid at i64 max (9223372036854775807) is reported correctly", %{conn: conn} do
        max_rowid = 9_223_372_036_854_775_807

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO t VALUES (?1, 'max')", [max_rowid])

        assert_receive {:xqlite_update, :insert, "main", "t", ^max_rowid}, 2_000
      end

      test "rowid at 1 is reported correctly", %{conn: conn} do
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (1, 'one')", [])

        assert_receive {:xqlite_update, :insert, "main", "t", 1}, 2_000
      end

      test "large rowid update is reported correctly", %{conn: conn} do
        large_rowid = 9_000_000_000_000_000_000

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO t VALUES (?1, 'large')", [large_rowid])

        assert_receive {:xqlite_update, :insert, "main", "t", ^large_rowid}, 2_000

        {:ok, 1} =
          NIF.execute(
            conn,
            "UPDATE t SET val = 'updated' WHERE id = ?1",
            [large_rowid]
          )

        assert_receive {:xqlite_update, :update, "main", "t", ^large_rowid}, 2_000
      end

      test "large rowid delete is reported correctly", %{conn: conn} do
        large_rowid = 8_999_999_999_999_999_999

        {:ok, 1} =
          NIF.execute(conn, "INSERT INTO t VALUES (?1, 'big')", [large_rowid])

        assert_receive {:xqlite_update, :insert, "main", "t", ^large_rowid}, 2_000

        {:ok, 1} =
          NIF.execute(conn, "DELETE FROM t WHERE id = ?1", [large_rowid])

        assert_receive {:xqlite_update, :delete, "main", "t", ^large_rowid}, 2_000
      end
    end

    describe "#{prefix}: rapid set/remove cycling" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE t (id INTEGER PRIMARY KEY, val TEXT);
          """)

        {:ok, conn: conn}
      end

      test "survives rapid set/remove cycles on a single connection", %{conn: conn} do
        for _ <- 1..50 do
          :ok = NIF.set_update_hook(conn, self())
          :ok = NIF.remove_update_hook(conn)
        end

        :ok = NIF.set_update_hook(conn, self())

        {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (1, 'survived')", [])

        assert_receive {:xqlite_update, :insert, "main", "t", 1}, 2_000
      end

      test "survives rapid listener replacement", %{conn: conn} do
        pids =
          for _ <- 1..50 do
            pid = spawn(fn -> Process.sleep(5_000) end)
            :ok = NIF.set_update_hook(conn, pid)
            pid
          end

        :ok = NIF.set_update_hook(conn, self())

        {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (1, 'final')", [])

        assert_receive {:xqlite_update, :insert, "main", "t", 1}, 2_000

        Enum.each(pids, fn pid ->
          Process.exit(pid, :kill)
        end)
      end

      test "concurrent set/remove from multiple tasks does not crash", %{conn: conn} do
        tasks =
          Enum.map(1..10, fn _ ->
            Task.async(fn ->
              for _ <- 1..20 do
                NIF.set_update_hook(conn, self())
                NIF.remove_update_hook(conn)
              end
            end)
          end)

        Task.await_many(tasks, 10_000)

        :ok = NIF.set_update_hook(conn, self())
        {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (1, 'calm')", [])

        assert_receive {:xqlite_update, :insert, "main", "t", 1}, 2_000
      end

      test "set/remove interleaved with DML operations", %{conn: conn} do
        for i <- 1..20 do
          :ok = NIF.set_update_hook(conn, self())
          {:ok, 1} = NIF.execute(conn, "INSERT INTO t VALUES (?1, 'v')", [i])
          :ok = NIF.remove_update_hook(conn)
        end

        messages = collect_all_updates(2_000)
        assert length(messages) == 20

        rowids =
          Enum.map(messages, fn {:xqlite_update, :insert, _, _, rid} -> rid end)
          |> Enum.sort()

        assert rowids == Enum.to_list(1..20)
      end
    end

    describe "#{prefix}: realistic workload: inventory management" do
      @describetag type_tag

      setup context do
        {mod, fun, args} = find_opener_mfa!(context)
        {:ok, conn} = apply(mod, fun, args)
        on_exit(fn -> NIF.close(conn) end)

        :ok =
          NIF.execute_batch(conn, """
          CREATE TABLE products (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            price REAL NOT NULL,
            stock INTEGER NOT NULL DEFAULT 0
          );
          CREATE TABLE orders (
            id INTEGER PRIMARY KEY,
            product_id INTEGER NOT NULL,
            quantity INTEGER NOT NULL,
            created_at TEXT DEFAULT (datetime('now'))
          );
          """)

        :ok = NIF.set_update_hook(conn, self())
        {:ok, conn: conn}
      end

      test "order placement: insert order + decrement stock", %{conn: conn} do
        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO products (name, price, stock) VALUES (?1, ?2, ?3)",
            ["Widget", 9.99, 100]
          )

        assert_receive {:xqlite_update, :insert, "main", "products", 1}, 2_000

        :ok = NIF.begin(conn, :immediate)

        {:ok, 1} =
          NIF.execute(
            conn,
            "INSERT INTO orders (product_id, quantity) VALUES (?1, ?2)",
            [1, 5]
          )

        {:ok, 1} =
          NIF.execute(
            conn,
            "UPDATE products SET stock = stock - ?1 WHERE id = ?2",
            [5, 1]
          )

        :ok = NIF.commit(conn)

        assert_receive {:xqlite_update, :insert, "main", "orders", 1}, 2_000
        assert_receive {:xqlite_update, :update, "main", "products", 1}, 2_000

        {:ok, %{rows: [[95]]}} =
          NIF.query(conn, "SELECT stock FROM products WHERE id = 1", [])
      end
    end
  end

  # --- Tests outside the for loop ---
  # Only tests that inherently require multiple independent connections
  # belong here. Everything else must be inside the for loop.

  describe "per-connection isolation" do
    test "hook on conn1 does not fire for conn2 changes" do
      {:ok, conn1} = NIF.open_in_memory(":memory:")
      {:ok, conn2} = NIF.open_in_memory(":memory:")

      on_exit(fn ->
        NIF.close(conn1)
        NIF.close(conn2)
      end)

      :ok =
        NIF.execute_batch(conn1, "CREATE TABLE t (id INTEGER PRIMARY KEY);")

      :ok =
        NIF.execute_batch(conn2, "CREATE TABLE t (id INTEGER PRIMARY KEY);")

      listener1 = spawn_collector()
      :ok = NIF.set_update_hook(conn1, listener1)

      # Only insert on conn2 — conn1's hook should not fire
      {:ok, 1} = NIF.execute(conn2, "INSERT INTO t VALUES (1)", [])

      assert get_collected(listener1) == []
    end

    test "each connection has its own independent hook" do
      {:ok, conn1} = NIF.open_in_memory(":memory:")
      {:ok, conn2} = NIF.open_in_memory(":memory:")

      on_exit(fn ->
        NIF.close(conn1)
        NIF.close(conn2)
      end)

      :ok =
        NIF.execute_batch(conn1, "CREATE TABLE t (id INTEGER PRIMARY KEY);")

      :ok =
        NIF.execute_batch(conn2, "CREATE TABLE t (id INTEGER PRIMARY KEY);")

      listener1 = spawn_collector()
      listener2 = spawn_collector()
      :ok = NIF.set_update_hook(conn1, listener1)
      :ok = NIF.set_update_hook(conn2, listener2)

      {:ok, 1} = NIF.execute(conn1, "INSERT INTO t VALUES (1)", [])
      {:ok, 1} = NIF.execute(conn2, "INSERT INTO t VALUES (2)", [])

      msgs1 = get_collected(listener1)
      msgs2 = get_collected(listener2)

      assert length(msgs1) == 1
      assert length(msgs2) == 1

      [{:xqlite_update, :insert, "main", "t", 1}] = msgs1
      [{:xqlite_update, :insert, "main", "t", 2}] = msgs2
    end

    test "removing hook from conn1 does not affect conn2" do
      {:ok, conn1} = NIF.open_in_memory(":memory:")
      {:ok, conn2} = NIF.open_in_memory(":memory:")

      on_exit(fn ->
        NIF.close(conn1)
        NIF.close(conn2)
      end)

      :ok =
        NIF.execute_batch(conn1, "CREATE TABLE t (id INTEGER PRIMARY KEY);")

      :ok =
        NIF.execute_batch(conn2, "CREATE TABLE t (id INTEGER PRIMARY KEY);")

      :ok = NIF.set_update_hook(conn1, self())
      :ok = NIF.set_update_hook(conn2, self())
      :ok = NIF.remove_update_hook(conn1)

      {:ok, 1} = NIF.execute(conn2, "INSERT INTO t VALUES (1)", [])

      assert_receive {:xqlite_update, :insert, "main", "t", 1}, 2_000
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp spawn_collector do
    spawn(fn -> collector_loop([]) end)
  end

  defp collector_loop(acc) do
    receive do
      {:xqlite_update, _, _, _, _} = event ->
        collector_loop([event | acc])

      {:get, from} ->
        send(from, {:collected, Enum.reverse(acc)})
        collector_loop(acc)
    end
  end

  defp get_collected(pid) do
    send(pid, {:get, self()})

    receive do
      {:collected, msgs} -> msgs
    after
      1_000 -> []
    end
  end

  defp collect_all_updates(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_updates(deadline, [])
  end

  defp do_collect_updates(deadline, acc) do
    now = System.monotonic_time(:millisecond)
    wait = max(deadline - now, 0)

    receive do
      {:xqlite_update, _, _, _, _} = event ->
        do_collect_updates(deadline, [event | acc])
    after
      wait -> Enum.reverse(acc)
    end
  end
end
