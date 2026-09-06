defmodule Xqlite.Telemetry do
  @moduledoc """
  `:telemetry` integration for xqlite.

  > #### Strictly opt-in {: .info}
  >
  > Telemetry is gated by a **compile-time** flag. Default: `false`.
  > When disabled, every emission site in xqlite compiles to a no-op —
  > there are no `:telemetry.execute/3` or `:telemetry.span/3` calls in
  > the bytecode at all. Zero per-call overhead. Designed for
  > resource-constrained environments (Nerves, embedded, hot loops)
  > where the cost of even an unused `:telemetry.execute/3` matters.
  >
  > To enable, set this in your application's `config/config.exs` and
  > rebuild xqlite (`mix deps.compile xqlite --force`):
  >
  > ```elixir
  > config :xqlite, :telemetry_enabled, true
  > ```

  ## Conventions

    * **Event names:** atom lists prefixed with `:xqlite`. Sub-systems
      get their own segment (`:hook`, `:cancel`, `:transaction`,
      `:savepoint`). `events/0` returns the whole list as data.
    * **Spans:** every operation that has a clear "start" and "end"
      follows `:telemetry.span/3`'s convention — `:start`, `:stop`,
      `:exception` events with a stable `:telemetry_span_context`
      reference linking them. xqlite emits the three itself rather
      than calling `:telemetry.span/3`, which measures in the VM's
      native time unit; xqlite measures in nanoseconds.
    * **Time units:** **integer nanoseconds** for every time-valued
      measurement — `monotonic_time`, `system_time`, `duration`,
      `total_duration` and `elapsed`. No `_ns` suffix on those key
      names. Counts (`rows_returned`, `total_rows`, `pages`,
      `retries`, `count`) ride in the same map and are not times.
      Convert to microseconds (`/1_000`) or milliseconds
      (`/1_000_000`) at handler time.
    * **Time source:** **`System.monotonic_time(:nanosecond)`**, not
      `:os.system_time/0`. Stable across NTP adjustments and clock
      changes; consumers map to wall-clock at handler time if needed.
    * **Identifiers:** raw refs (`reference()`) for connections,
      tokens, streams. No abstraction layer — consumers map to
      stable IDs themselves at attach time.
    * **Cancellation outcome:** an operation that gets cancelled fires
      its normal `:stop` event with `metadata.error_reason ==
      :operation_cancelled` (NOT `:exception`). A separate
      `[:xqlite, :cancel, :honored]` event also fires.

  ## Event surface — operation events (always-on)

  These events fire automatically when telemetry is compiled in. No
  registration needed; just attach a handler with `:telemetry.attach/4`.

  Every span fires the same three events with the same measurements:
  `:start` carries `%{monotonic_time, system_time}`, and `:stop` and
  `:exception` carry `%{duration, monotonic_time}`. Numbers a span
  learns while it runs travel in its `:stop` metadata, not in its
  measurements. `:exception` metadata is the start metadata plus
  `kind`, `reason` and `stacktrace`. All three carry the same
  `telemetry_span_context` reference.

  ### Connection lifecycle

      [:xqlite, :open, :start | :stop | :exception]
        start metadata: %{path, mode}
        stop metadata:  %{path, mode, result_class, error_reason}

      [:xqlite, :close, :start | :stop | :exception]
        start metadata: %{conn, path}
        stop metadata:  %{conn, path}

  `:mode` is one of `:file`, `:memory`, `:readonly`, `:memory_readonly`,
  `:temp`. `:result_class` is `:ok` or `:error`. `:error_reason` is
  `nil` on success or the structured error reason on failure.

  ### Query / Execute

      [:xqlite, :query, :start | :stop | :exception]
        start metadata: %{conn, sql, params_count, cancellable?}
        stop metadata:  %{conn, sql, params_count, cancellable?,
                          result_class, error_reason, num_rows, changes}

      [:xqlite, :execute, :start | :stop | :exception]
        start metadata: %{conn, sql, params_count, cancellable?}
        stop metadata:  %{conn, sql, params_count, cancellable?,
                          result_class, error_reason, affected_rows}

      [:xqlite, :execute_batch, :start | :stop | :exception]
        start metadata: %{conn, sql_batch_size_bytes, cancellable?}
        stop metadata:  %{conn, sql_batch_size_bytes, cancellable?,
                          result_class, error_reason}

      [:xqlite, :query_with_changes, :start | :stop | :exception]
        start metadata: %{conn, sql, params_count, cancellable?}
        stop metadata:  %{conn, sql, params_count, cancellable?,
                          result_class, error_reason, num_rows, changes}

      [:xqlite, :explain_analyze, :start | :stop | :exception]
        start metadata: %{conn, sql, params_count}
        stop metadata:  %{conn, sql, params_count, result_class,
                          error_reason, wall_time_ns, rows_produced,
                          scan_count}

  `wall_time_ns` is SQLite's own nanosecond measurement of the executed
  statement (from `EXPLAIN ANALYZE`). `:cancellable?` is `true` iff
  the operation was invoked through a `*_cancellable` NIF or
  `Xqlite.query_cancellable/4` and its siblings. `changes` is
  `sqlite3_changes()` read beside the rows; it is `nil` on error and on
  the cancellable query path.

  ### Transactions

  Transactions span across multiple NIF calls; we emit single events
  rather than spans because the matching `:stop` may come from any
  later commit/rollback at any time.

      [:xqlite, :transaction, :begin]
        measurements: %{monotonic_time}
        metadata:     %{conn, mode}

      [:xqlite, :transaction, :commit]
        measurements: %{monotonic_time}
        metadata:     %{conn}

      [:xqlite, :transaction, :rollback]
        measurements: %{monotonic_time}
        metadata:     %{conn, reason}

      [:xqlite, :savepoint, :create | :release | :rollback_to]
        measurements: %{monotonic_time}
        metadata:     %{conn, name}

  `:mode` is `:deferred`, `:immediate`, or `:exclusive`. `:reason`
  on rollback is `:user_initiated` — the only value xqlite emits,
  since these three events fire from the explicit transaction API.

  ### Streams

      [:xqlite, :stream, :open, :start | :stop | :exception]
        start metadata: %{conn, sql, batch_size, type_extensions_count,
                          cancellable?}
        stop metadata:  %{conn, sql, batch_size, type_extensions_count,
                          cancellable?, result_class, error_reason}

      [:xqlite, :stream, :fetch]
        measurements: %{monotonic_time, duration, rows_returned}
        metadata:     %{stream_handle, done?}

      [:xqlite, :stream, :close]
        measurements: %{monotonic_time, total_duration, total_rows}
        metadata:     %{stream_handle, reason}

  The fetch event fires **every batch** — potentially thousands of
  times per stream. The cost is sub-microsecond when no handler is
  attached and zero when telemetry is disabled at compile time. If you
  attach a heavy handler, expect proportional cost; consider sampling
  or a dedicated metrics handler.

  ### Backup, restore, serialize, deserialize

      [:xqlite, :backup, :start | :stop | :exception]
        start metadata: %{conn, schema, dest_path}
        stop metadata:  %{conn, schema, dest_path, result_class,
                          error_reason, byte_size}

      [:xqlite, :restore, :start | :stop | :exception]
        start metadata: %{conn, schema, src_path}
        stop metadata:  %{conn, schema, src_path, result_class, error_reason}

      [:xqlite, :serialize, :start | :stop | :exception]
        start metadata: %{conn, schema}
        stop metadata:  %{conn, schema, result_class, error_reason, byte_size}

      [:xqlite, :deserialize, :start | :stop | :exception]
        start metadata: %{conn, schema, read_only?, byte_size}
        stop metadata:  %{conn, schema, read_only?, byte_size,
                          result_class, error_reason}

  `byte_size` is `nil` on a failed backup or serialize.
  `Xqlite.backup_with_progress/6` reports to a pid instead and emits
  no telemetry of its own.

  ### WAL checkpoint and extensions

      [:xqlite, :wal_checkpoint, :start | :stop | :exception]
        start metadata: %{conn, mode, schema}
        stop metadata:  %{conn, mode, schema, result_class, error_reason,
                          log_pages, checkpointed_pages, busy?}

      [:xqlite, :extension, :load, :start | :stop | :exception]
        start metadata: %{conn, path, entry_point}
        stop metadata:  %{conn, path, entry_point, result_class, error_reason}

      [:xqlite, :extension, :enable]
        measurements: %{monotonic_time}
        metadata:     %{conn, enabled}

  WAL `:mode` is `:passive`, `:full`, `:restart`, or `:truncate`.
  `:busy?` is `true` if the checkpoint did not complete because of
  reader/writer contention. The three checkpoint counters are present
  only when the checkpoint succeeded.

  ### PRAGMA

      [:xqlite, :pragma, :get | :set]
        measurements: %{monotonic_time}
        metadata:     %{conn, name, value (on :set only)}

  ### Cancellation

      [:xqlite, :cancel, :token_created]
        measurements: %{monotonic_time}
        metadata:     %{token}

      [:xqlite, :cancel, :signalled]
        measurements: %{monotonic_time}
        metadata:     %{token}

      [:xqlite, :cancel, :honored]
        measurements: %{monotonic_time}
        metadata:     %{conn, operation, tokens}

  `:operation` is the operation that the cancel signal interrupted:
  `:query`, `:execute`, `:execute_batch`, `:query_with_changes`, or
  `:stream_fetch`. `:tokens` is the list of tokens that operation was
  watching.

  ## Event surface — hook bridge events (opt-in registration)

  The hook bridge layer turns multi-subscriber hook deliveries into
  telemetry events. NOT auto-attached — the user explicitly calls
  `bridge/2` on a connection to wire the hooks they care about.

      [:xqlite, :hook, :commit]
        measurements: %{monotonic_time}
        metadata:     %{conn, tag}

      [:xqlite, :hook, :rollback]
        measurements: %{monotonic_time}
        metadata:     %{conn, tag}

      [:xqlite, :hook, :update]
        measurements: %{monotonic_time}
        metadata:     %{conn, tag, action, db_name, table, rowid}

      [:xqlite, :hook, :wal]
        measurements: %{monotonic_time, pages}
        metadata:     %{conn, tag, db_name}

      [:xqlite, :hook, :progress]
        measurements: %{monotonic_time, count, elapsed}
        metadata:     %{conn, tag, hook_tag}

      [:xqlite, :hook, :busy]
        measurements: %{monotonic_time, retries, elapsed}
        metadata:     %{conn, tag}

      [:xqlite, :hook, :log]
        measurements: %{monotonic_time}
        metadata:     %{tag, code, base_code, message}

  `:tag` (in the metadata) is the user-supplied tag from `bridge/2`
  for distinguishing connections in dashboards. `:hook_tag`, only on
  the progress event, is the tag passed to
  `Xqlite.register_progress_hook/3`. `:elapsed` is a nanosecond count,
  converted from the milliseconds SQLite reports.

  See `bridge/2` and `unbridge/1` for the registration API. Bridge
  is implemented on top of the same multi-subscriber primitives that
  power direct hook usage — registering the bridge on a connection
  is independent of any other subscribers, and unbridging never
  affects them.

  ## Compile-time disabled mode

  When `:telemetry_enabled` is `false` (the default), the macros in
  this module expand to no-ops and the underlying operations skip
  emission entirely. Verify with `enabled?/0`:

      iex> Xqlite.Telemetry.enabled?()
      false

  In this mode, `bridge/2` returns `{:error, :telemetry_disabled}`
  rather than silently registering hooks that produce no events.

  ## Reading the source

  This module is small on purpose. The three macros (`emit/3`,
  `span/3` and `span_with_stop_metadata/3`) are what every call site
  in `lib/xqlite/*.ex` invokes. They read the `:telemetry_enabled`
  flag at compile time and either expand to `:telemetry` calls or to
  direct evaluation of the inner block. The macros live here, not in
  each caller, so the compile-time check happens in one place; the
  span bodies expand to `run_span/3`, which emits the three span
  events with nanosecond measurements.
  """

  @enabled Application.compile_env(:xqlite, :telemetry_enabled, false)

  @doc """
  Returns whether telemetry is compiled in.

  Reads the value of `:telemetry_enabled` at xqlite compile time.
  Always a constant after compilation; safe to call anywhere.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: unquote(@enabled)

  @events [
    %{name: [:xqlite, :open], kind: :span},
    %{name: [:xqlite, :close], kind: :span},
    %{name: [:xqlite, :query], kind: :span},
    %{name: [:xqlite, :execute], kind: :span},
    %{name: [:xqlite, :execute_batch], kind: :span},
    %{name: [:xqlite, :query_with_changes], kind: :span},
    %{name: [:xqlite, :explain_analyze], kind: :span},
    %{name: [:xqlite, :transaction, :begin], kind: :event},
    %{name: [:xqlite, :transaction, :commit], kind: :event},
    %{name: [:xqlite, :transaction, :rollback], kind: :event},
    %{name: [:xqlite, :savepoint, :create], kind: :event},
    %{name: [:xqlite, :savepoint, :release], kind: :event},
    %{name: [:xqlite, :savepoint, :rollback_to], kind: :event},
    %{name: [:xqlite, :stream, :open], kind: :span},
    %{name: [:xqlite, :stream, :fetch], kind: :event},
    %{name: [:xqlite, :stream, :close], kind: :event},
    %{name: [:xqlite, :backup], kind: :span},
    %{name: [:xqlite, :restore], kind: :span},
    %{name: [:xqlite, :serialize], kind: :span},
    %{name: [:xqlite, :deserialize], kind: :span},
    %{name: [:xqlite, :wal_checkpoint], kind: :span},
    %{name: [:xqlite, :extension, :load], kind: :span},
    %{name: [:xqlite, :extension, :enable], kind: :event},
    %{name: [:xqlite, :pragma, :get], kind: :event},
    %{name: [:xqlite, :pragma, :set], kind: :event},
    %{name: [:xqlite, :cancel, :token_created], kind: :event},
    %{name: [:xqlite, :cancel, :signalled], kind: :event},
    %{name: [:xqlite, :cancel, :honored], kind: :event},
    %{name: [:xqlite, :hook, :commit], kind: :event},
    %{name: [:xqlite, :hook, :rollback], kind: :event},
    %{name: [:xqlite, :hook, :update], kind: :event},
    %{name: [:xqlite, :hook, :wal], kind: :event},
    %{name: [:xqlite, :hook, :progress], kind: :event},
    %{name: [:xqlite, :hook, :busy], kind: :event},
    %{name: [:xqlite, :hook, :log], kind: :event}
  ]

  @doc """
  Returns every event xqlite can emit, in the order the moduledoc
  presents them.

  Each entry is `%{name: [atom()], kind: :span | :event}`. A `:span`
  entry stands for three event names — its `name` with `:start`,
  `:stop` and `:exception` appended. An `:event` entry is the whole
  name on its own.

  Useful for attaching one handler to everything:

      names =
        Enum.flat_map(Xqlite.Telemetry.events(), fn
          %{name: name, kind: :span} ->
            Enum.map([:start, :stop, :exception], &(name ++ [&1]))

          %{name: name, kind: :event} ->
            [name]
        end)

      :telemetry.attach_many("my-app-xqlite", names, &MyApp.handle/4, nil)

  The list is the one source for the event surface: the moduledoc
  above, `guides/wiring_telemetry.md`, and the emission sites in
  `lib/` are all checked against it by the test suite.
  """
  @spec events() :: [%{name: [atom()], kind: :span | :event}]
  def events, do: @events

  if @enabled do
    @doc """
    Emit a single telemetry event.

    Wraps `:telemetry.execute/3`. When telemetry is compiled out, the
    arguments are still evaluated and then discarded — no `:telemetry`
    call happens.
    """
    defmacro emit(event_name, measurements, metadata) do
      quote do
        :telemetry.execute(
          unquote(event_name),
          unquote(measurements),
          unquote(metadata)
        )
      end
    end

    @doc """
    Run `block` inside a span: a `:start` event, then a `:stop` one.

    The block must evaluate to a value; that value is returned. Both
    the `:start` and `:stop` events carry the supplied `metadata`.
    If the block raises, throws or exits, an `:exception` event fires
    instead of `:stop`, with `kind`, `reason`, and `stacktrace` added
    to the metadata, and the exception re-raises unchanged.

    When telemetry is compiled out, the block evaluates directly with
    no telemetry calls.
    """
    defmacro span(event_name, metadata, do: block) do
      quote do
        start_metadata = unquote(metadata)

        Xqlite.Telemetry.run_span(unquote(event_name), start_metadata, fn ->
          {unquote(block), start_metadata}
        end)
      end
    end

    @doc """
    Like `span/3` but lets the block return `{value, stop_metadata}` or
    `{value, extra_measurements, stop_metadata}`, so the `:stop` event
    can carry numbers and metadata that weren't known at `:start`. The
    stop metadata replaces the start metadata; the extra measurements
    are merged under `duration` and `monotonic_time`.
    """
    defmacro span_with_stop_metadata(event_name, start_metadata, do: block) do
      quote do
        Xqlite.Telemetry.run_span(unquote(event_name), unquote(start_metadata), fn ->
          unquote(block)
        end)
      end
    end

    @doc false
    @spec run_span([atom()], map(), (-> term())) :: term()
    def run_span(event_name, start_metadata, block) do
      context = make_ref()
      metadata = with_span_context(start_metadata, context)
      start_time = monotonic_time()

      :telemetry.execute(
        event_name ++ [:start],
        %{monotonic_time: start_time, system_time: System.system_time(:nanosecond)},
        metadata
      )

      # The one try/catch the Elixir layer keeps: it turns the caller's own
      # exception into an `:exception` event and re-raises it untouched.
      try do
        block.()
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          stop_time = monotonic_time()

          :telemetry.execute(
            event_name ++ [:exception],
            %{duration: stop_time - start_time, monotonic_time: stop_time},
            Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
          )

          :erlang.raise(kind, reason, stacktrace)
      else
        outcome -> emit_stop(event_name, start_time, context, outcome)
      end
    end

    defp emit_stop(event_name, start_time, context, {result, stop_metadata}) do
      stop_time = monotonic_time()

      :telemetry.execute(
        event_name ++ [:stop],
        %{duration: stop_time - start_time, monotonic_time: stop_time},
        with_span_context(stop_metadata, context)
      )

      result
    end

    defp emit_stop(event_name, start_time, context, {result, extra, stop_metadata}) do
      stop_time = monotonic_time()

      :telemetry.execute(
        event_name ++ [:stop],
        Map.merge(extra, %{duration: stop_time - start_time, monotonic_time: stop_time}),
        with_span_context(stop_metadata, context)
      )

      result
    end

    defp with_span_context(%{telemetry_span_context: _} = metadata, _context), do: metadata

    defp with_span_context(metadata, context),
      do: Map.put(metadata, :telemetry_span_context, context)
  else
    # Disabled-mode macros still evaluate their arguments: bindings that
    # exist only to feed measurement / metadata maps would otherwise trip
    # the unused-variable warning, which is an error here. The values are
    # discarded — no `:telemetry` call ever happens.

    @doc """
    Emit a single telemetry event.

    Wraps `:telemetry.execute/3`. When telemetry is compiled out,
    expands to a no-op that still evaluates the arguments and discards
    their values.
    """
    defmacro emit(event_name, measurements, metadata) do
      quote do
        _ = unquote(event_name)
        _ = unquote(measurements)
        _ = unquote(metadata)
        :ok
      end
    end

    @doc """
    Run `block` inside a span: a `:start` event, then a `:stop` one.

    The block must evaluate to a value; that value is returned. Both
    the `:start` and `:stop` events carry the supplied `metadata`.
    If the block raises, throws or exits, an `:exception` event fires
    instead of `:stop`, with `kind`, `reason`, and `stacktrace` added
    to the metadata, and the exception re-raises unchanged.

    When telemetry is compiled out, the block evaluates directly with
    no telemetry calls.
    """
    defmacro span(event_name, metadata, do: block) do
      quote do
        _ = unquote(event_name)
        _ = unquote(metadata)
        unquote(block)
      end
    end

    @doc """
    Like `span/3` but lets the block return `{value, stop_metadata}`,
    so the `:stop` event can carry metadata that wasn't known at
    `:start`. With telemetry compiled out only that two-element shape
    is accepted; the `{value, extra_measurements, stop_metadata}` shape
    needs the enabled macro, which has measurements to merge them into.
    """
    defmacro span_with_stop_metadata(event_name, start_metadata, do: block) do
      quote do
        _ = unquote(event_name)
        _ = unquote(start_metadata)

        case unquote(block) do
          {value, _stop_metadata} -> value
        end
      end
    end
  end

  @doc """
  Returns the current monotonic time in nanoseconds.

  Inlined helper used in metadata maps that record event timestamps.
  Equivalent to `System.monotonic_time(:nanosecond)`; provided for
  readability at call sites and for a single canonical source for
  the rest of xqlite.
  """
  @spec monotonic_time() :: integer()
  def monotonic_time, do: System.monotonic_time(:nanosecond)

  @doc """
  Bridges per-connection hook deliveries into `:telemetry` events.

  Subscribes to the requested hooks on `conn` via the standard
  `register_*_hook` API and forwards each delivery as an
  `[:xqlite, :hook, :*]` telemetry event. Returns
  `{:ok, %Xqlite.Telemetry.Bridge{}}` on success — pass that struct
  to `unbridge/1` to tear down.

  ## Options

    * `:hooks` — list of hook kinds to subscribe to. Either an explicit
      list (`[:wal, :commit, :rollback, :update, :progress, :busy]`) or
      `:all` (default) for every per-connection hook.
    * `:tag` — arbitrary term forwarded as `:tag` in every
      `[:xqlite, :hook, :*]` event's metadata. Useful when one
      handler receives bridged events from multiple connections.
    * `:progress` — keyword opts forwarded to
      `register_progress_hook/3` (default `every_n: 1000`).

  Returns `{:error, :telemetry_disabled}` when telemetry is
  compile-disabled — the bridge would otherwise install hooks that
  produce nothing.

  > #### Note on busy handling {: .info}
  >
  > Busy observation is part of the per-conn bridge: pass `hooks: [:busy]`
  > (or the default `:all`) and every contention callback re-emits as
  > `[:xqlite, :hook, :busy]`. The retry policy is the half that is not
  > bridged — it stays a single slot per connection, set with
  > `Xqlite.set_busy_policy/2`. See `Xqlite.Telemetry.Bridge` for the
  > rationale.
  """
  @spec bridge(reference(), keyword()) :: {:ok, struct()} | {:error, term()}
  def bridge(conn, opts \\ []) when is_reference(conn) do
    Xqlite.Telemetry.Bridge.bridge_per_conn(conn, opts)
  end

  @doc """
  Bridges the global SQLite log hook into `:telemetry` events.

  Subscribes to the process-wide log hook and re-emits each diagnostic
  as `[:xqlite, :hook, :log]`. Returns
  `{:ok, %Xqlite.Telemetry.Bridge{}}` — call `unbridge/1` to detach.

  ## Options

    * `:tag` — arbitrary term forwarded as `:tag` in event metadata.
  """
  @spec bridge_log(keyword()) :: {:ok, struct()} | {:error, term()}
  def bridge_log(opts \\ []) when is_list(opts) do
    Xqlite.Telemetry.Bridge.bridge_log_global(opts)
  end

  @doc """
  Tears down a bridge — unregisters every subscribed hook and stops
  the forwarder GenServer.
  """
  @spec unbridge(struct()) :: :ok
  def unbridge(bridge) do
    Xqlite.Telemetry.Bridge.unbridge(bridge)
  end
end
