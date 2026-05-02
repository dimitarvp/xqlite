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
      `:savepoint`).
    * **Spans:** every operation that has a clear "start" and "end"
      uses `:telemetry.span/3`'s convention — `:start`, `:stop`,
      `:exception` events with a stable `:telemetry_span_context`
      reference linking them.
    * **Time units:** **integer nanoseconds** everywhere. No `_ns`
      suffix on key names — `duration` and `monotonic_time` are
      always nanoseconds. Convert to microseconds (`/1_000`) or
      milliseconds (`/1_000_000`) at handler time.
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

  ## Event surface — Tier A (operations)

  These events fire automatically when telemetry is compiled in. No
  registration needed; just attach a handler with `:telemetry.attach/4`.

  ### Connection lifecycle

      [:xqlite, :open, :start | :stop | :exception]
        measurements: %{monotonic_time, duration}
        metadata:     %{path, mode, result_class, error_reason}

      [:xqlite, :close, :start | :stop]
        measurements: %{monotonic_time, duration}
        metadata:     %{conn, path}

  `:mode` is one of `:file`, `:memory`, `:readonly`, `:memory_readonly`,
  `:temp`. `:result_class` is `:ok` or `:error`. `:error_reason` is
  `nil` on success or the structured error reason atom on failure.

  ### Query / Execute

      [:xqlite, :query, :start | :stop | :exception]
        measurements: %{monotonic_time, duration, num_rows (on :stop)}
        metadata:     %{conn, sql, params_count, cancellable?, result_class, error_reason}

      [:xqlite, :execute, :start | :stop | :exception]
        measurements: %{monotonic_time, duration, affected_rows (on :stop)}
        metadata:     %{conn, sql, params_count, cancellable?, result_class, error_reason}

      [:xqlite, :execute_batch, :start | :stop | :exception]
        measurements: %{monotonic_time, duration}
        metadata:     %{conn, sql_batch_size_bytes, cancellable?, result_class, error_reason}

      [:xqlite, :query_with_changes, :start | :stop | :exception]
        measurements: %{monotonic_time, duration, num_rows, changes}
        metadata:     %{conn, sql, params_count, cancellable?, result_class, error_reason}

      [:xqlite, :explain_analyze, :start | :stop | :exception]
        measurements: %{monotonic_time, duration, wall_time_ns, rows_produced, scan_count}
        metadata:     %{conn, sql, result_class, error_reason}

  `wall_time_ns` is SQLite's own clock measurement of the executed
  statement (from `EXPLAIN ANALYZE`). `:cancellable?` is `true` iff
  the operation was invoked through a `*_cancellable` NIF or
  `Xqlite.query_cancellable` etc.

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
  on rollback is `:user_initiated`, `:constraint`, `:deferred_fk`,
  or `:error`.

  ### Streams

      [:xqlite, :stream, :open, :start | :stop | :exception]
        measurements: %{monotonic_time, duration}
        metadata:     %{conn, sql, batch_size, type_extensions_count}

      [:xqlite, :stream, :fetch]
        measurements: %{monotonic_time, duration, rows_returned}
        metadata:     %{stream_handle, done?}

      [:xqlite, :stream, :close]
        measurements: %{monotonic_time, total_duration, total_rows}
        metadata:     %{stream_handle, reason}

  `[:xqlite, :stream, :fetch]` fires **every batch** — potentially
  thousands of times per stream. The cost is sub-microsecond when
  no handler is attached and zero when telemetry is disabled at
  compile time. If you attach a heavy handler, expect proportional
  cost; consider sampling or a dedicated metrics handler.

  ### Backup

      [:xqlite, :backup, :start | :stop | :exception]
        measurements: %{monotonic_time, duration, byte_size}
        metadata:     %{conn, schema, dest_path, result_class, error_reason}

      [:xqlite, :backup_with_progress, :start | :step | :stop | :exception]
        :start measurements: %{monotonic_time}
        :step  measurements: %{monotonic_time, pages_remaining, pagecount, step_duration}
        :stop  measurements: %{monotonic_time, total_duration, total_pages}
        metadata:             %{conn, schema, dest_path, pages_per_step, result_class, error_reason}

  ### WAL checkpoint, serialize, deserialize, extension

      [:xqlite, :wal_checkpoint, :start | :stop | :exception]
        measurements: %{monotonic_time, duration, log_pages, checkpointed_pages}
        metadata:     %{conn, mode, schema, busy?}

      [:xqlite, :serialize, :start | :stop | :exception]
        measurements: %{monotonic_time, duration, byte_size}
        metadata:     %{conn, schema}

      [:xqlite, :deserialize, :start | :stop | :exception]
        measurements: %{monotonic_time, duration, byte_size}
        metadata:     %{conn, schema, read_only?}

      [:xqlite, :extension, :load, :start | :stop | :exception]
        measurements: %{monotonic_time, duration}
        metadata:     %{conn, path, entry_point}

  WAL `:mode` is `:passive`, `:full`, `:restart`, or `:truncate`.
  `:busy?` is `true` if the checkpoint did not complete because of
  reader/writer contention.

  ### PRAGMA

      [:xqlite, :pragma, :get | :set]
        measurements: %{monotonic_time, duration}
        metadata:     %{conn, name, value (on :set only)}

  ### Session extension

      [:xqlite, :session, :new | :attach | :delete]
        measurements: %{monotonic_time}
        metadata:     %{session, conn (on :new), table (on :attach)}

      [:xqlite, :session, :changeset | :patchset]
        measurements: %{monotonic_time, duration, byte_size}
        metadata:     %{session}

      [:xqlite, :session, :apply, :start | :stop | :exception]
        measurements: %{monotonic_time, duration}
        metadata:     %{conn, conflict_strategy}

  ### Blob I/O

      [:xqlite, :blob, :open | :close | :reopen]
        measurements: %{monotonic_time, byte_size (on :open / :reopen)}
        metadata:     %{blob, conn (on :open), table, column, row_id, read_only?}

      [:xqlite, :blob, :read | :write]
        measurements: %{monotonic_time, duration, bytes, offset}
        metadata:     %{blob}

  ### Cancellation

      [:xqlite, :cancel, :token_created]
        measurements: %{monotonic_time}
        metadata:     %{token}

      [:xqlite, :cancel, :signalled]
        measurements: %{monotonic_time}
        metadata:     %{token}

      [:xqlite, :cancel, :honored]
        measurements: %{monotonic_time, lag}
        metadata:     %{token, operation, conn}

  `:lag` is the duration in nanoseconds between
  `[:xqlite, :cancel, :signalled]` and `[:xqlite, :cancel, :honored]`
  for the same token. `:operation` is the operation that the cancel
  signal interrupted: `:query`, `:execute`, `:execute_batch`, or
  `:backup_with_progress`.

  ## Event surface — Tier B (hook bridge, opt-in registration)

  The hook bridge layer turns multi-subscriber hook deliveries into
  telemetry events. NOT auto-attached — the user explicitly calls
  `bridge/2` on a connection to wire the hooks they care about.

      [:xqlite, :hook, :busy]
        measurements: %{retries, elapsed}
        metadata:     %{conn, tag}

      [:xqlite, :hook, :commit]
        measurements: %{monotonic_time}
        metadata:     %{conn, tag}

      [:xqlite, :hook, :rollback]
        measurements: %{monotonic_time}
        metadata:     %{conn, tag}

      [:xqlite, :hook, :update]
        measurements: %{monotonic_time}
        metadata:     %{conn, action, db_name, table, rowid, tag}

      [:xqlite, :hook, :wal]
        measurements: %{pages}
        metadata:     %{conn, db_name, tag}

      [:xqlite, :hook, :progress]
        measurements: %{count, elapsed}
        metadata:     %{conn, hook_tag, tag}

      [:xqlite, :hook, :log]
        measurements: %{}
        metadata:     %{code, base_code, message}

  `:tag` (in the metadata) is the user-supplied tag from `bridge/2`
  for distinguishing connections in dashboards. `:hook_tag` (only
  on `[:xqlite, :hook, :progress]`) is the tag passed to
  `Xqlite.register_progress_hook/3`.

  See `bridge/2` and `unbridge/2` for the registration API. Bridge
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

  This module is small on purpose. The two macros (`emit/3` and
  `span/3`) are what every call site in `lib/xqlite/*.ex` invokes.
  They take the `:telemetry_enabled` flag at compile time and either
  emit normal `:telemetry` calls or expand to direct evaluation of
  the inner block. The macros live here, not in each caller, so the
  compile-time check happens in one place.
  """

  @enabled Application.compile_env(:xqlite, :telemetry_enabled, false)

  @doc """
  Returns whether telemetry is compiled in.

  Reads the value of `:telemetry_enabled` at xqlite compile time.
  Always a constant after compilation; safe to call anywhere.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: unquote(@enabled)

  if @enabled do
    @doc """
    Emit a single telemetry event.

    Wraps `:telemetry.execute/3`. When telemetry is compiled out,
    expands to a no-op (the arguments are not evaluated).
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
    Run `block` inside a `:telemetry.span/3`.

    The block must evaluate to a value; that value is returned. Both
    the `:start` and `:stop` events carry the supplied `metadata`.
    If the block raises or throws, an `:exception` event fires
    instead of `:stop`, with `kind`, `reason`, and `stacktrace` added
    to the metadata, and the exception re-raises.

    When telemetry is compiled out, the block evaluates directly with
    no telemetry calls.
    """
    defmacro span(event_name, metadata, do: block) do
      quote do
        :telemetry.span(unquote(event_name), unquote(metadata), fn ->
          {unquote(block), unquote(metadata)}
        end)
      end
    end

    @doc """
    Like `span/3` but lets the block return `{value, extra_metadata}`
    so the `:stop` event can carry per-operation metadata that wasn't
    known at `:start`.
    """
    defmacro span_with_stop_metadata(event_name, start_metadata, do: block) do
      quote do
        :telemetry.span(unquote(event_name), unquote(start_metadata), fn ->
          unquote(block)
        end)
      end
    end
  else
    # Disabled-mode macros: still evaluate the AST arguments so that
    # variables referenced in the call site stay "used" from the
    # compiler's perspective (no unused-variable warnings on bindings
    # that exist only to feed measurements / metadata maps). The
    # evaluated values are immediately discarded — no `:telemetry`
    # call ever happens. Cost: constructing the measurement / metadata
    # maps anyway. Typical maps are small; the cost is sub-microsecond.
    # If a future use case demands zero-cost-even-on-arg-eval, we can
    # switch to a per-callsite `if Xqlite.Telemetry.enabled?() do`
    # pattern. For now, this keeps call sites clean and reads nicely.

    @doc false
    defmacro emit(event_name, measurements, metadata) do
      quote do
        _ = unquote(event_name)
        _ = unquote(measurements)
        _ = unquote(metadata)
        :ok
      end
    end

    @doc false
    defmacro span(event_name, metadata, do: block) do
      quote do
        _ = unquote(event_name)
        _ = unquote(metadata)
        unquote(block)
      end
    end

    @doc false
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

  # ---------------------------------------------------------------------------
  # Hook → telemetry bridge (Tier B)
  # ---------------------------------------------------------------------------

  @doc """
  Bridges per-connection hook deliveries into `:telemetry` events.

  Subscribes to the requested hooks on `conn` via the standard
  `register_*_hook` API and forwards each delivery as an
  `[:xqlite, :hook, :*]` telemetry event. Returns
  `{:ok, %Xqlite.Telemetry.Bridge{}}` on success — pass that struct
  to `unbridge/1` to tear down.

  ## Options

    * `:hooks` — list of hook kinds to subscribe to. Either an explicit
      list (`[:wal, :commit, :rollback, :update, :progress]`) or `:all`
      (default) for every per-connection hook.
    * `:tag` — arbitrary term forwarded as `:tag` in every
      `[:xqlite, :hook, :*]` event's metadata. Useful when one
      handler receives bridged events from multiple connections.
    * `:progress` — keyword opts forwarded to
      `register_progress_hook/3` (default `every_n: 1000`).

  Returns `{:error, :telemetry_disabled}` when telemetry is
  compile-disabled — the bridge would otherwise install hooks that
  produce nothing.

  > #### Note on busy_handler {: .info}
  >
  > `busy_handler` is single-subscriber and not part of the per-conn
  > bridge. To get busy events as telemetry, register your own busy
  > handler with a forwarder pid that emits the desired event.
  > See `Xqlite.Telemetry.Bridge` for the rationale.
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
