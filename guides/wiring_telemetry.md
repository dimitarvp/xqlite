# Wiring xqlite telemetry

xqlite emits `:telemetry` events for every observable operation
(query / execute / transaction / stream / backup / wal_checkpoint /
serialize / pragma / extension / cancellation) plus an opt-in bridge
that turns multi-subscriber hook deliveries (`commit` / `rollback` /
`update` / `wal` / `progress` / `log`) into telemetry. Everything is
**compile-time opt-in** — when telemetry is disabled (the default),
no `:telemetry` calls exist in the bytecode at all.

## Enable telemetry

In your application's `config/config.exs`:

```elixir
config :xqlite, :telemetry_enabled, true
```

Rebuild the xqlite dep so the flag takes effect:

```bash
mix deps.compile xqlite --force
```

To verify at runtime:

```elixir
iex> Xqlite.Telemetry.enabled?()
true
```

When `false`, every emission site in xqlite compiles to a no-op —
including `:telemetry.execute/3` calls that would otherwise be a few
hundred nanoseconds each. Designed for resource-constrained
environments (Nerves, embedded, hot loops where every nanosecond
counts).

## Conventions

* **Time units:** integer **nanoseconds** everywhere. Convert at
  handler time (`/1_000` for µs, `/1_000_000` for ms).
* **Time source:** `System.monotonic_time(:nanosecond)`. Stable
  across NTP drift; consumers convert to wall-clock at handler time
  if needed.
* **Identifiers:** raw refs (`reference()`) for connections, tokens,
  streams. No abstraction layer — map at attach time if you need
  stable IDs.
* **Cancellation:** an operation that was cancelled fires
  `:stop` with `metadata.error_reason == :operation_cancelled` —
  NOT `:exception`. A separate `[:xqlite, :cancel, :honored]` event
  also fires.

## Event surface (Tier A — operations, always-on)

See `Xqlite.Telemetry` moduledoc for the complete schema with every
measurement and metadata key. Highlights:

| Event | Trigger | Key metadata |
|---|---|---|
| `[:xqlite, :query, :*]` | `Xqlite.query/3`, `Xqlite.query_cancellable/4` | `:sql`, `:cancellable?`, `:num_rows` (on stop) |
| `[:xqlite, :execute, :*]` | `Xqlite.execute/3` and cancellable variant | `:sql`, `:affected_rows` (on stop) |
| `[:xqlite, :execute_batch, :*]` | `Xqlite.execute_batch/2` and cancellable variant | `:sql_batch_size_bytes` |
| `[:xqlite, :explain_analyze, :*]` | `Xqlite.explain_analyze/3` | `:wall_time_ns`, `:rows_produced`, `:scan_count` |
| `[:xqlite, :transaction, :begin / :commit / :rollback]` | `Xqlite.begin/2`, `commit/1`, `rollback/1` | `:mode` (begin), `:reason` (rollback) |
| `[:xqlite, :savepoint, :create / :release / :rollback_to]` | `Xqlite.savepoint/2` etc. | `:name` |
| `[:xqlite, :stream, :open, :*]` | `Xqlite.stream/4` opens a NIF stream | `:batch_size` |
| `[:xqlite, :stream, :fetch]` | every batch (potentially thousands per stream) | `:rows_returned`, `:done?` |
| `[:xqlite, :stream, :close]` | stream consumed / dropped | `:total_rows`, `:reason` |
| `[:xqlite, :backup, :*]` | `Xqlite.backup/3` | `:dest_path`, `:byte_size` |
| `[:xqlite, :backup_with_progress, :*]` | one-shot via `Xqlite.backup_with_progress/6` (see notes) | `:pages_per_step` |
| `[:xqlite, :wal_checkpoint, :*]` | `Xqlite.wal_checkpoint/3` | `:mode`, `:log_pages`, `:checkpointed_pages`, `:busy?` |
| `[:xqlite, :serialize, :*]` | `Xqlite.serialize/2` | `:byte_size` |
| `[:xqlite, :deserialize, :*]` | `Xqlite.deserialize/4` | `:read_only?`, `:byte_size` |
| `[:xqlite, :extension, :load, :*]` | `Xqlite.load_extension/3` | `:path`, `:entry_point` |
| `[:xqlite, :extension, :enable]` | `Xqlite.enable_load_extension/2` | `:enabled` |
| `[:xqlite, :pragma, :get / :set]` | `Xqlite.get_pragma/2`, `Xqlite.set_pragma/3` | `:name`, `:value` (on set) |
| `[:xqlite, :cancel, :token_created]` | `Xqlite.create_cancel_token/0` | `:token` |
| `[:xqlite, :cancel, :signalled]` | `Xqlite.cancel_operation/1` | `:token` |
| `[:xqlite, :cancel, :honored]` | a cancellable operation observed cancellation | `:operation`, `:tokens` |

## Event surface (Tier B — hook bridge, opt-in)

The hook bridge turns the multi-subscriber hook fan-out (commit,
rollback, update, wal, progress) into telemetry events. NOT
attached automatically — call `Xqlite.Telemetry.bridge/2`:

```elixir
{:ok, bridge} =
  Xqlite.Telemetry.bridge(conn,
    hooks: [:wal, :commit, :rollback, :update, :progress],
    tag: :my_app_replica_a
  )

# Events fire as [:xqlite, :hook, :wal] etc. with `tag: :my_app_replica_a`
# in metadata.

:ok = Xqlite.Telemetry.unbridge(bridge)
```

Pass `hooks: :all` for the full set. For the global SQLite log hook,
use `Xqlite.Telemetry.bridge_log/1`.

`busy_handler` is intentionally not in the bridge — it's
single-subscriber by design. Register your own busy handler if you
want busy events as telemetry.

## Sample handlers

### Datadog / StatsD

```elixir
:telemetry.attach_many(
  "xqlite-statsd",
  [
    [:xqlite, :query, :stop],
    [:xqlite, :execute, :stop]
  ],
  fn _name, %{duration: ns}, %{result_class: class}, _ ->
    duration_ms = ns / 1_000_000
    StatsD.histogram("xqlite.query.duration_ms", duration_ms, tags: [class])
  end,
  nil
)
```

### Honeycomb / OpenTelemetry

Use `:opentelemetry_telemetry` — it's the standard bridge. xqlite
emits clean spans (start/stop with `telemetry_span_context`) so the
bridge can reconstruct OTel spans automatically:

```elixir
# In application.ex:
:opentelemetry_telemetry.attach(:xqlite_otel, [
  [:xqlite, :query],
  [:xqlite, :execute],
  [:xqlite, :execute_batch],
  [:xqlite, :explain_analyze]
])
```

xqlite does NOT depend on `:opentelemetry` directly — that's a
downstream concern.

### Logger

```elixir
:telemetry.attach(
  "xqlite-log",
  [:xqlite, :cancel, :honored],
  fn _, %{monotonic_time: t}, %{operation: op, tokens: tokens}, _ ->
    Logger.warning("xqlite #{op} cancelled, tokens: #{inspect(tokens)}")
  end,
  nil
)
```

### Prometheus

Use `:telemetry_metrics` and `:telemetry_metrics_prometheus_core` —
the standard pipeline. Define metrics declaratively:

```elixir
# In your supervisor:
def metrics do
  [
    Telemetry.Metrics.distribution("xqlite.query.duration",
      event_name: [:xqlite, :query, :stop],
      measurement: :duration,
      unit: {:native, :millisecond}
    ),
    Telemetry.Metrics.counter("xqlite.cancel.honored",
      event_name: [:xqlite, :cancel, :honored]
    )
  ]
end
```

## Composing with `xqlite_ecto3`

The Ecto adapter emits its own `[:xqlite_ecto3, :*]` events at the
`DBConnection` callback layer. Both layers fire — pick the layer
that matches your observability needs:

* `[:my_app, :repo, :query]` (Ecto's own) — the high-level Repo
  event, ideal for "how long did this Repo.all/insert take?"
* `[:xqlite_ecto3, :handle_execute, :*]` — adapter-internal,
  pre-DBConnection-pool wrap.
* `[:xqlite, :query, :*]` — xqlite-internal, raw NIF timing.

Together they give a layered view: pool → adapter → driver.

## Performance

Per-event cost when no handler is attached: ~hundreds of nanoseconds
(`:telemetry.execute/3` fast-path). When handlers are attached, the
cost depends on the handler. xqlite emits aggressively (every stream
fetch, every cancel signal) — a heavy handler attached to a hot
event will measurably slow queries down. If you need fine-grained
instrumentation in production, consider:

* Sampling at the handler (`if :rand.uniform() < 0.01, do: ...`)
* Buffering measurements and flushing in batches
* Using `:telemetry_metrics` (already does buffered aggregation)

## Verifying disabled-mode

If you've set `:telemetry_enabled, false`:

```elixir
iex> Xqlite.Telemetry.enabled?()
false
```

In this mode, `:telemetry.execute/3` is never called. Verify by
attaching a global handler and running queries:

```elixir
iex> :telemetry.attach("debug", [:xqlite, :query, :stop], fn _, _, _, _ ->
...>   IO.puts("event fired")
...> end, nil)
iex> {:ok, conn} = Xqlite.open_in_memory()
iex> Xqlite.query(conn, "SELECT 1", [])
# (no "event fired" output)
```
