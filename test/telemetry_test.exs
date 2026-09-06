defmodule Xqlite.TelemetryTest do
  use ExUnit.Case, async: true

  import Xqlite.Telemetry.TestSupport, only: [attach_capture: 1, detach: 1]
  import Xqlite.TestUtil, only: [tmp_db_path: 1, test_extension_path: 0]

  alias Xqlite.Telemetry

  @emitting_macros [:emit, :span, :span_with_stop_metadata]

  # A bracketed event name as the docs write it, e.g. `[:xqlite, :pragma, :get]`.
  @documented_name ~r/\[:xqlite\s*,([^\[\]]*)\]/

  @endless_sql "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT count(*) FROM n"

  @reachable_operations [
    [:xqlite, :open, :start],
    [:xqlite, :open, :stop],
    [:xqlite, :close, :start],
    [:xqlite, :close, :stop],
    [:xqlite, :query, :start],
    [:xqlite, :query, :stop],
    [:xqlite, :execute, :start],
    [:xqlite, :execute, :stop],
    [:xqlite, :execute_batch, :start],
    [:xqlite, :execute_batch, :stop],
    [:xqlite, :query_with_changes, :start],
    [:xqlite, :query_with_changes, :stop],
    [:xqlite, :explain_analyze, :start],
    [:xqlite, :explain_analyze, :stop],
    [:xqlite, :transaction, :begin],
    [:xqlite, :transaction, :commit],
    [:xqlite, :transaction, :rollback],
    [:xqlite, :savepoint, :create],
    [:xqlite, :savepoint, :release],
    [:xqlite, :savepoint, :rollback_to],
    [:xqlite, :pragma, :get],
    [:xqlite, :pragma, :set],
    [:xqlite, :stream, :open, :start],
    [:xqlite, :stream, :open, :stop],
    [:xqlite, :stream, :fetch],
    [:xqlite, :stream, :close]
  ]

  @reachable_io [
    [:xqlite, :serialize, :start],
    [:xqlite, :serialize, :stop],
    [:xqlite, :deserialize, :start],
    [:xqlite, :deserialize, :stop],
    [:xqlite, :backup, :start],
    [:xqlite, :backup, :stop],
    [:xqlite, :restore, :start],
    [:xqlite, :restore, :stop],
    [:xqlite, :wal_checkpoint, :start],
    [:xqlite, :wal_checkpoint, :stop],
    [:xqlite, :extension, :load, :start],
    [:xqlite, :extension, :load, :stop],
    [:xqlite, :extension, :enable]
  ]

  @reachable_cancel [
    [:xqlite, :cancel, :token_created],
    [:xqlite, :cancel, :signalled],
    [:xqlite, :cancel, :honored]
  ]

  @reachable_hooks [
    [:xqlite, :hook, :commit],
    [:xqlite, :hook, :rollback],
    [:xqlite, :hook, :update],
    [:xqlite, :hook, :wal],
    [:xqlite, :hook, :progress],
    [:xqlite, :hook, :busy],
    [:xqlite, :hook, :log]
  ]

  describe "compile-time flag" do
    test "enabled?/0 reflects the compile_env value" do
      # Test config sets :telemetry_enabled to true.
      assert Telemetry.enabled?() == true
    end

    test "enabled?/0 returns a constant (no runtime lookup)" do
      # Calling twice must give the same value — flag is fixed at
      # compile time, not read from Application env at runtime.
      assert Telemetry.enabled?() == Telemetry.enabled?()
    end
  end

  describe "monotonic_time/0" do
    test "returns an integer in nanoseconds" do
      t = Telemetry.monotonic_time()
      assert is_integer(t)
    end

    test "is non-decreasing across consecutive calls" do
      t1 = Telemetry.monotonic_time()
      t2 = Telemetry.monotonic_time()
      assert t2 >= t1
    end

    test "matches System.monotonic_time(:nanosecond) order of magnitude" do
      ours = Telemetry.monotonic_time()
      theirs = System.monotonic_time(:nanosecond)
      # Same clock; values should be within milliseconds of each other.
      assert abs(theirs - ours) < 1_000_000_000
    end
  end

  describe "emit/3 macro" do
    require Telemetry

    test "fires a :telemetry event when enabled" do
      :telemetry.attach(
        "telemetry-test-emit",
        [:xqlite, :test, :unit],
        fn name, measurements, metadata, _ ->
          send(self_pid(metadata), {:emitted, name, measurements, metadata})
        end,
        nil
      )

      Telemetry.emit([:xqlite, :test, :unit], %{count: 1}, %{
        pid: self(),
        token: :unit_test
      })

      assert_receive {:emitted, [:xqlite, :test, :unit], %{count: 1}, %{token: :unit_test}}

      detach("telemetry-test-emit")
    end

    test "fires no event when no handler is attached (smoke test)" do
      # Disable side-effect: this just confirms emit/3 doesn't crash
      # when there are zero handlers. It's the cheap baseline.
      assert Telemetry.emit([:xqlite, :test, :no_handler], %{}, %{}) == :ok
    end
  end

  describe "span/3 macro" do
    require Telemetry

    test "fires :start and :stop when block succeeds" do
      handler_id =
        attach_capture([
          [:xqlite, :test, :span, :start],
          [:xqlite, :test, :span, :stop],
          [:xqlite, :test, :span, :exception]
        ])

      result =
        Telemetry.span([:xqlite, :test, :span], %{tag: :ok_path}, do: 42)

      assert result == 42

      assert_receive {:telemetry_event, [:xqlite, :test, :span, :start],
                      %{monotonic_time: _, system_time: _}, %{tag: :ok_path}}

      assert_receive {:telemetry_event, [:xqlite, :test, :span, :stop], %{duration: dur},
                      %{tag: :ok_path}}

      assert is_integer(dur) and dur >= 0

      detach(handler_id)
    end

    test "fires :exception when block raises and re-raises" do
      handler_id =
        attach_capture([
          [:xqlite, :test, :span2, :start],
          [:xqlite, :test, :span2, :stop],
          [:xqlite, :test, :span2, :exception]
        ])

      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span([:xqlite, :test, :span2], %{tag: :err_path}, do: raise("boom"))
      end

      assert_receive {:telemetry_event, [:xqlite, :test, :span2, :start], %{monotonic_time: _},
                      %{tag: :err_path}}

      assert_receive {:telemetry_event, [:xqlite, :test, :span2, :exception], %{duration: _},
                      metadata}

      assert metadata.tag == :err_path
      assert metadata.kind == :error
      assert metadata.reason == %RuntimeError{message: "boom"}

      detach(handler_id)
    end
  end

  describe "span_with_stop_metadata/3 macro" do
    require Telemetry

    test "merges start metadata with block-returned stop metadata" do
      handler_id =
        attach_capture([
          [:xqlite, :test, :merge, :start],
          [:xqlite, :test, :merge, :stop]
        ])

      result =
        Telemetry.span_with_stop_metadata [:xqlite, :test, :merge], %{
          phase: :start
        } do
          {:computed, %{phase: :start, rows: 7}}
        end

      assert result == :computed

      assert_receive {:telemetry_event, [:xqlite, :test, :merge, :start], _measurements,
                      %{phase: :start}}

      assert_receive {:telemetry_event, [:xqlite, :test, :merge, :stop], _measurements,
                      %{phase: :start, rows: 7}}

      detach(handler_id)
    end
  end

  describe "span time units" do
    require Telemetry

    test ":stop reports duration and monotonic_time as nanoseconds" do
      handler_id = attach_capture([[:xqlite, :test, :ns, :stop]])
      beside = System.monotonic_time(:nanosecond)

      :ok = Telemetry.span([:xqlite, :test, :ns], %{tag: :ns}, do: Process.sleep(20))

      assert_receive {:telemetry_event, [:xqlite, :test, :ns, :stop], measurements, _}
      assert measurements.duration >= 20_000_000
      assert measurements.duration <= 5_000_000_000
      assert abs(measurements.monotonic_time - beside) <= 5_000_000_000

      detach(handler_id)
    end

    test ":start reports system_time as nanoseconds" do
      handler_id = attach_capture([[:xqlite, :test, :sys, :start]])
      beside = System.system_time(:nanosecond)

      42 = Telemetry.span([:xqlite, :test, :sys], %{tag: :sys}, do: 42)

      assert_receive {:telemetry_event, [:xqlite, :test, :sys, :start], measurements, _}
      assert abs(measurements.system_time - beside) <= 5_000_000_000

      detach(handler_id)
    end

    test ":start and :stop share one telemetry_span_context reference" do
      handler_id =
        attach_capture([[:xqlite, :test, :ctx, :start], [:xqlite, :test, :ctx, :stop]])

      :done = Telemetry.span([:xqlite, :test, :ctx], %{tag: :ctx}, do: :done)

      assert_receive {:telemetry_event, [:xqlite, :test, :ctx, :start], _, start_metadata}
      assert_receive {:telemetry_event, [:xqlite, :test, :ctx, :stop], _, stop_metadata}

      assert is_reference(start_metadata.telemetry_span_context)
      assert start_metadata.telemetry_span_context == stop_metadata.telemetry_span_context

      detach(handler_id)
    end

    test "a throwing block fires :exception with kind :throw and throws on" do
      handler_id = attach_capture([[:xqlite, :test, :thr, :exception]])

      assert catch_throw(
               Telemetry.span([:xqlite, :test, :thr], %{tag: :thr}, do: throw(:tossed))
             ) == :tossed

      assert_receive {:telemetry_event, [:xqlite, :test, :thr, :exception], measurements,
                      metadata}

      assert metadata.kind == :throw
      assert metadata.reason == :tossed
      assert is_list(metadata.stacktrace)
      assert is_integer(measurements.duration)

      detach(handler_id)
    end

    test "an exiting block fires :exception with kind :exit and exits on" do
      handler_id = attach_capture([[:xqlite, :test, :ext, :exception]])

      assert catch_exit(Telemetry.span([:xqlite, :test, :ext], %{tag: :ext}, do: exit(:bye))) ==
               :bye

      assert_receive {:telemetry_event, [:xqlite, :test, :ext, :exception], measurements,
                      metadata}

      assert metadata.kind == :exit
      assert metadata.reason == :bye
      assert is_list(metadata.stacktrace)
      assert is_integer(measurements.duration)

      detach(handler_id)
    end

    test "a raising block fires :exception with a nanosecond duration" do
      handler_id = attach_capture([[:xqlite, :test, :rai, :exception]])
      beside = System.monotonic_time(:nanosecond)

      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span([:xqlite, :test, :rai], %{tag: :rai}, do: raise("boom"))
      end

      assert_receive {:telemetry_event, [:xqlite, :test, :rai, :exception], measurements, _}
      assert measurements.duration >= 0
      assert measurements.duration <= 5_000_000_000
      assert abs(measurements.monotonic_time - beside) <= 5_000_000_000

      detach(handler_id)
    end

    test "a block returning {value, extra_measurements, stop_metadata} merges the extras" do
      handler_id = attach_capture([[:xqlite, :test, :extra, :stop]])

      result =
        Telemetry.span_with_stop_metadata [:xqlite, :test, :extra], %{phase: :start} do
          {:computed, %{rows_returned: 7}, %{phase: :stop}}
        end

      assert result == :computed

      assert_receive {:telemetry_event, [:xqlite, :test, :extra, :stop], measurements,
                      metadata}

      assert measurements.rows_returned == 7
      assert is_integer(measurements.duration)
      assert is_integer(measurements.monotonic_time)
      assert metadata.phase == :stop
      assert is_reference(metadata.telemetry_span_context)

      detach(handler_id)
    end
  end

  describe "events/0" do
    test "lists 35 events, 14 of them spans, with no duplicates" do
      events = Telemetry.events()

      assert length(events) == 35
      assert Enum.count(events, &span_entry?/1) == 14

      names = Enum.map(events, &entry_name/1)
      assert names -- Enum.uniq(names) == []
    end
  end

  describe "the catalogue and the code agree" do
    test "every emission site in lib/ spells out a catalogued event" do
      sites = lib_emission_sites()

      assert Enum.reject(sites, &literal_site?/1) == []

      assert sites |> MapSet.new(&site_entry/1) ==
               MapSet.new(Telemetry.events())
    end
  end

  describe "the catalogue and the docs agree" do
    test "the moduledoc's event surface is exactly the catalogue" do
      assert {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(Telemetry)

      documented = moduledoc |> event_surface() |> documented_names()

      assert documented -- Enum.uniq(documented) == []
      assert MapSet.new(documented) == MapSet.new(expanded_catalogue())
    end

    test "the telemetry guide's event surface is exactly the catalogue" do
      assert {:ok, guide} =
               File.read(Path.join([__DIR__, "..", "guides", "wiring_telemetry.md"]))

      documented = guide |> event_surface() |> documented_names()

      assert documented -- Enum.uniq(documented) == []
      assert MapSet.new(documented) == MapSet.new(expanded_catalogue())
    end
  end

  describe "every catalogued event is reachable" do
    test "the triggers below cover every catalogued event" do
      triggered =
        [@reachable_operations, @reachable_io, @reachable_cancel, @reachable_hooks]
        |> Enum.concat()
        |> MapSet.new()

      # `:exception` fires only when a block raises, throws or exits; the span
      # tests above are what pin those three names.
      expected =
        expanded_catalogue()
        |> Enum.reject(&exception_name?/1)
        |> MapSet.new()

      assert triggered == expected
    end

    test "connection, statement, transaction, pragma and stream events fire" do
      handler_id = attach_capture(@reachable_operations)

      {:ok, conn} = Xqlite.open_in_memory()
      :ok = Xqlite.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);")
      {:ok, _} = Xqlite.execute(conn, "INSERT INTO t VALUES (1, 'a')", [])
      {:ok, _} = Xqlite.query(conn, "SELECT id, v FROM t", [])
      {:ok, token} = Xqlite.create_cancel_token()
      {:ok, _} = Xqlite.query_with_changes_cancellable(conn, "SELECT id FROM t", [], token)
      {:ok, _} = Xqlite.explain_analyze(conn, "SELECT id FROM t", [])
      :ok = Xqlite.begin(conn)
      :ok = Xqlite.commit(conn)
      :ok = Xqlite.begin(conn)
      :ok = Xqlite.rollback(conn)
      :ok = Xqlite.savepoint(conn, "sp")
      :ok = Xqlite.rollback_to_savepoint(conn, "sp")
      :ok = Xqlite.release_savepoint(conn, "sp")
      {:ok, _} = Xqlite.get_pragma(conn, :cache_size)
      {:ok, _} = Xqlite.set_pragma(conn, :cache_size, 2_000)
      [_ | _] = conn |> Xqlite.stream("SELECT id FROM t", [], batch_size: 1) |> Enum.to_list()
      :ok = Xqlite.close(conn)

      assert_all_fired(@reachable_operations)
      detach(handler_id)
    end

    test "backup, restore, serialize, checkpoint and extension events fire" do
      handler_id = attach_capture(@reachable_io)

      path = tmp_db_path("reachable")
      backup_path = tmp_db_path("reachable_backup")

      {:ok, conn} = Xqlite.open(path)

      :ok =
        Xqlite.execute_batch(
          conn,
          "CREATE TABLE t(id INTEGER PRIMARY KEY); INSERT INTO t VALUES (1);"
        )

      {:ok, _} = Xqlite.wal_checkpoint(conn, :passive, "main")

      {:ok, image} = Xqlite.serialize(conn, "main")
      {:ok, memory} = Xqlite.open_in_memory()
      :ok = Xqlite.deserialize(memory, image, "main", false)

      :ok = Xqlite.backup(conn, backup_path)
      {:ok, restored} = Xqlite.open_in_memory()
      :ok = Xqlite.restore(restored, backup_path)

      :ok = Xqlite.enable_load_extension(conn, true)
      :ok = Xqlite.load_extension(conn, test_extension_path())
      :ok = Xqlite.enable_load_extension(conn, false)

      :ok = Xqlite.close(restored)
      :ok = Xqlite.close(memory)
      :ok = Xqlite.close(conn)

      assert_all_fired(@reachable_io)
      detach(handler_id)
    end

    test "cancel token, signal and honoured events fire" do
      handler_id = attach_capture(@reachable_cancel)

      {:ok, conn} = Xqlite.open_in_memory()
      {:ok, token} = Xqlite.create_cancel_token()
      :ok = Xqlite.cancel_operation(token)

      {:error, :operation_cancelled} = Xqlite.query_cancellable(conn, @endless_sql, [], token)

      :ok = Xqlite.close(conn)

      assert_all_fired(@reachable_cancel)
      detach(handler_id)
    end

    test "all seven bridged hook events fire" do
      handler_id = attach_capture(@reachable_hooks)

      path = tmp_db_path("reachable_hooks")
      {:ok, log_bridge} = Xqlite.Telemetry.bridge_log(tag: :reachable)

      {:ok, conn} = Xqlite.open(path)

      {:ok, bridge} =
        Xqlite.Telemetry.bridge(conn,
          hooks: [:commit, :rollback, :update, :wal, :progress],
          tag: :reachable,
          progress: [every_n: 1]
        )

      :ok = Xqlite.execute_batch(conn, "CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);")
      {:ok, _} = XqliteNIF.execute(conn, "INSERT INTO t VALUES (1, 'a')", [])
      :ok = XqliteNIF.begin(conn, :deferred)
      {:ok, _} = XqliteNIF.execute(conn, "INSERT INTO t VALUES (2, 'b')", [])
      :ok = XqliteNIF.rollback(conn)
      :ok = Xqlite.Telemetry.unbridge(bridge)

      trigger_busy(path)
      trigger_log_message()

      :ok = Xqlite.Telemetry.unbridge(log_bridge)
      :ok = Xqlite.close(conn)

      assert_all_fired(@reachable_hooks)
      detach(handler_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp self_pid(%{pid: pid}), do: pid

  defp span_entry?(%{kind: kind}), do: kind == :span

  defp entry_name(%{name: name}), do: name

  defp exception_name?(name), do: List.last(name) == :exception

  defp expanded_catalogue, do: Enum.flat_map(Telemetry.events(), &expand_entry/1)

  defp expand_entry(%{name: name, kind: :span}),
    do: Enum.map([:start, :stop, :exception], fn suffix -> name ++ [suffix] end)

  defp expand_entry(%{name: name, kind: :event}), do: [name]

  # ---- the code census ------------------------------------------------------

  defp lib_emission_sites do
    [__DIR__, "..", "lib", "**", "*.ex"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.flat_map(&emission_sites_in/1)
  end

  defp emission_sites_in(path) do
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source) do
      {_, sites} = Macro.prewalk(ast, [], &collect_site(&1, &2, path))
      Enum.reject(sites, &macro_definition?/1)
    else
      _ -> []
    end
  end

  defp collect_site({macro, _meta, [name | _]} = node, acc, path)
       when macro in @emitting_macros, do: {node, [{path, site_kind(macro), name} | acc]}

  defp collect_site(
         {{:., _, [{:__aliases__, _, _}, macro]}, _meta, [name | _]} = node,
         acc,
         path
       )
       when macro in @emitting_macros, do: {node, [{path, site_kind(macro), name} | acc]}

  defp collect_site(node, acc, _path), do: {node, acc}

  defp site_kind(:emit), do: :event
  defp site_kind(_), do: :span

  # The macro definitions themselves take the event name as a parameter.
  defp macro_definition?({path, _kind, name}),
    do: Path.basename(path) == "telemetry.ex" and not literal_name?(name)

  defp literal_site?({_path, _kind, name}), do: literal_name?(name)

  defp site_entry({_path, kind, name}), do: %{name: name, kind: kind}

  defp literal_name?(name) when is_list(name), do: Enum.all?(name, &is_atom/1)
  defp literal_name?(_), do: false

  # ---- the documented catalogues --------------------------------------------

  defp event_surface(text) do
    text
    |> String.split(~r/^## /m)
    |> Enum.filter(&String.starts_with?(&1, "Event surface"))
    |> Enum.join("\n")
  end

  defp documented_names(text) do
    @documented_name
    |> Regex.scan(text)
    |> Enum.flat_map(&names_from_match/1)
  end

  defp names_from_match([_whole, inside]), do: documented_name(inside)
  defp names_from_match(_), do: []

  defp documented_name(inside) do
    segments =
      inside
      |> String.split(",")
      |> Enum.map(&segment_alternatives/1)

    case Enum.member?(segments, :invalid) do
      true -> []
      false -> segments |> cartesian() |> Enum.map(fn tail -> [:xqlite | tail] end)
    end
  end

  defp segment_alternatives(segment) do
    tokens =
      segment
      |> String.split(["|", "/"])
      |> Enum.map(&String.trim/1)

    case Enum.all?(tokens, &documented_token?/1) do
      true -> Enum.flat_map(tokens, &expand_token/1)
      false -> :invalid
    end
  end

  defp documented_token?(token), do: Regex.match?(~r/^:(\*|[a-z_][a-zA-Z_0-9]*[?!]?)$/, token)

  defp expand_token(":*"), do: [:start, :stop, :exception]

  defp expand_token(token), do: [token |> String.trim_leading(":") |> String.to_atom()]

  defp cartesian([]), do: [[]]

  defp cartesian([alternatives | rest]) do
    tails = cartesian(rest)
    for alternative <- alternatives, tail <- tails, do: [alternative | tail]
  end

  # ---- reachability ---------------------------------------------------------

  defp assert_all_fired(expected) do
    deadline = System.monotonic_time(:millisecond) + 5_000
    missing = collect_until_seen(MapSet.new(expected), deadline)

    assert MapSet.to_list(missing) == []
  end

  defp collect_until_seen(missing, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    case MapSet.size(missing) > 0 and remaining > 0 do
      false ->
        missing

      true ->
        receive do
          {:telemetry_event, name, _measurements, _metadata} ->
            missing |> MapSet.delete(name) |> collect_until_seen(deadline)
        after
          remaining -> missing
        end
    end
  end

  defp trigger_busy(path) do
    {:ok, holder} = XqliteNIF.open(path)
    {:ok, probe} = XqliteNIF.open(path)
    {:ok, _} = XqliteNIF.execute(holder, "BEGIN IMMEDIATE", [])

    :ok = Xqlite.set_busy_policy(probe, max_retries: 3, sleep_ms: 5)
    {:ok, bridge} = Xqlite.Telemetry.bridge(probe, hooks: [:busy], tag: :reachable)

    {:error, _} = XqliteNIF.execute(probe, "INSERT INTO t VALUES (3, 'c')", [])

    :ok = Xqlite.Telemetry.unbridge(bridge)
    {:ok, _} = XqliteNIF.execute(holder, "COMMIT", [])
    :ok = XqliteNIF.close(holder)
    :ok = XqliteNIF.close(probe)
  end

  # An unindexed join over two small tables makes SQLite report that it built
  # an automatic index, which reaches the global log hook.
  defp trigger_log_message do
    {:ok, conn} = Xqlite.open_in_memory()

    :ok =
      XqliteNIF.execute_batch(conn, """
      CREATE TABLE log_a (a TEXT, b TEXT);
      CREATE TABLE log_b (x TEXT, y TEXT);
      """)

    for i <- 1..30 do
      {:ok, 1} =
        XqliteNIF.execute(conn, "INSERT INTO log_a VALUES (?1, ?2)", ["v#{i}", "d#{i}"])

      {:ok, 1} =
        XqliteNIF.execute(conn, "INSERT INTO log_b VALUES (?1, ?2)", ["v#{i}", "e#{i}"])
    end

    {:ok, _} = XqliteNIF.query(conn, "SELECT * FROM log_a, log_b WHERE log_a.a = log_b.x", [])
    :ok = XqliteNIF.close(conn)
  end
end
