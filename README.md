# Xqlite

[![Hex version](https://img.shields.io/hexpm/v/xqlite.svg?style=flat)](https://hex.pm/packages/xqlite)
[![Hexdocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/xqlite)
[![Downloads](https://img.shields.io/hexpm/dt/xqlite.svg)](https://hex.pm/packages/xqlite)
[![SQLite](https://img.shields.io/badge/SQLite-3.51.3-003B57?logo=sqlite&logoColor=white)](https://sqlite.org/releaselog/3_51_3.html)
[![Build Status](https://github.com/dimitarvp/xqlite/actions/workflows/ci.yml/badge.svg)](https://github.com/dimitarvp/xqlite/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Low-level, fast, panic-free NIF bindings to SQLite 3 for Elixir. Will never crash the BEAM VM. Powered by Rust with [rusqlite](https://crates.io/crates/rusqlite) and [rustler](https://github.com/rusterlium/rustler). Bundled SQLite 3.51.3 -- no need to have SQLite already installed on your machine.

For Ecto 3.x integration see [xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3), built on top of xqlite (work in progress).

## Acknowledgements

Xqlite is inspired by [exqlite](https://github.com/elixir-sqlite/exqlite), which was my starting point for understanding how a production-grade Elixir+SQLite binding is shaped. Xqlite exists as a separate library not to compete but because I needed more of SQLite's features in my personal projects and wanted to see if they are doable and practical to use f.ex. per-operation cancellation, structured constraint errors, session/changeset capture, incremental blob I/O, backup with progress, the session extension features, and more. If exqlite is working well for your needs today, it's a solid choice and you should continue using it.

## Why Xqlite?

- **Bundled SQLite.** No need to have SQLite already installed on your machine. No version differences between dev, CI, and production. The precompiled NIFs cover macOS, Linux, Windows, including ARM and RISC-V.
- **Per-operation cancellation.** Any process can abort an in-progress query by sending `cancel_operation/1` to a cancel token (that you create yourself beforehand) -- no need to hold the connection handle. Progress-handler-based, fine-grained, and mostly deterministic (fine-tuning it is really difficult and it's an ongoing work in finding the ideal tradeoff between raw speed and ability to cancel early).
- **Structured errors with parsed details.** Constraint violation error values contain the table, columns, index name, and constraint name as structured fields -- I tried very hard to avoid parsing textual errors with regexes and mostly succeeded.
- **Bidirectional type extensions.** Elixir<->SQLite type conversion: `DateTime`, `Date`, `Time`, `NaiveDateTime` included; other custom types (duration / interval, array, UUID, timezone-aware datetime) are available today at the Ecto layer via [xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3). They may be mirrored at the raw xqlite layer if demand materializes.
- **Streaming.** `Stream.resource/3`-based row iterator with optional type-extension decoding per-row.
- **EXPLAIN ANALYZE with per-scan stats.** `Xqlite.explain_analyze/3` returns a structured report combining `EXPLAIN QUERY PLAN`, per-scan runtime counters from `sqlite3_stmt_scanstatus_v2` (loops, rows visited, estimated rows, name, parent), statement-level counters from `sqlite3_stmt_status`, and wall-clock execution time.
- **Sessions & changesets.** Exposes SQLite's built-in session extension: capture changes to a set of tables, invert/concat changesets, apply to a replica with conflict strategies.
- **Incremental blob I/O.** Read and write multi-GB column values without loading them into memory.
- **Online backup with progress and cancellation.** Single-call backup API to a file path, progress messages to a PID, canceling respected even mid-backup.
- **Structured schema introspection.** `PRAGMA table_list`, `table_xinfo`, `index_list`, `index_xinfo`, `foreign_key_list`, and others are all converted and returned as struct-shaped data -- generated columns, STRICT/WITHOUT ROWID markers, collation per index column, FK match clauses all included.
- **68 typed PRAGMAs** with validated get/set.

## Installation

```elixir
def deps do
  [
    {:xqlite, "~> 0.5.2"}
  ]
end
```

Precompiled NIF binaries are included for multiple targets -- no Rust toolchain needed. To force source compilation:

```bash
XQLITE_BUILD=true mix deps.compile xqlite
```

## Quickstart

```elixir
{:ok, conn} = Xqlite.open_in_memory()
{:ok, _} = XqliteNIF.execute(conn, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", [])
{:ok, 1} = XqliteNIF.execute(conn, "INSERT INTO users (name) VALUES (?1)", ["Alice"])
{:ok, result} = XqliteNIF.query(conn, "SELECT id, name FROM users", [])
# => %{columns: ["id", "name"], rows: [[1, "Alice"]], num_rows: 1}
:ok = XqliteNIF.close(conn)
```

## Features

Two modules: `Xqlite` for high-level helpers, `XqliteNIF` for direct NIF access. See [hexdocs](https://hexdocs.pm/xqlite) for the full API.

- **Queries & execution:** `query/3`, `query_cancellable/4`, `query_with_changes/3`, `execute/3`, `execute_batch/2` and cancellable variants
- **Streaming:** `Xqlite.stream/4` (with optional `:type_extensions`) and the lower-level `stream_open/fetch/close`
- **Transactions:** `:deferred`/`:immediate`/`:exclusive` modes, savepoints with release and rollback-to
- **Cancellation:** per-operation, progress-handler-based, any process can cancel
- **Schema introspection:** `schema_databases/1`, `schema_list_objects/2`, `schema_columns/2`, `schema_foreign_keys/2`, `schema_indexes/2`, `schema_index_columns/2`, `get_create_sql/2`
- **PRAGMAs:** `Xqlite.Pragma` -- typed schema with validation for 68 PRAGMAs
- **Type extensions:** bidirectional encode/decode; `DateTime`, `Date`, `Time`, `NaiveDateTime` built-in
- **Hooks:** SQLite log hook (global, forwarded to a PID), update hook (per-connection, `{:xqlite_update, action, db, table, rowid}`)
- **Serialize / deserialize:** atomic in-memory snapshots to/from binary
- **Extensions:** opt-in `load_extension/2` and `load_extension/3`
- **Backup / restore:** one-shot to/from file path; incremental with progress messages and cancellation
- **Sessions:** session extension -- changeset capture, apply with conflict strategies, invert, concat
- **Blob I/O:** `blob_open/read/write/close` for incremental access
- **Diagnostics:** `compile_options/1`, `sqlite_version/0`
- **Result integration:** `Xqlite.Result` implements `Table.Reader` (works with Explorer, Kino, VegaLite)

Errors are structured tuples: `{:error, {:constraint_violation, :constraint_unique, %{table: ..., columns: [...], ...}}}`, `{:error, {:read_only_database, msg}}`, etc. 30+ typed reason variants including all 13 SQLite constraint subtypes.

## Focused examples

### Streaming with automatic type decoding

```elixir
alias Xqlite.TypeExtension

extensions = [TypeExtension.DateTime, TypeExtension.Date, TypeExtension.Time]
params = TypeExtension.encode_params([~U[2024-01-15 10:30:00Z], ~D[2024-06-15]], extensions)
{:ok, 1} = XqliteNIF.execute(conn, "INSERT INTO events (ts, day) VALUES (?1, ?2)", params)

Xqlite.stream(conn, "SELECT ts, day FROM events", [],
  type_extensions: [TypeExtension.DateTime, TypeExtension.Date])
|> Enum.to_list()
# => [%{"ts" => ~U[2024-01-15 10:30:00Z], "day" => ~D[2024-06-15]}]
```

### Cancellation from another process

```elixir
{:ok, token} = XqliteNIF.create_cancel_token()
task = Task.async(fn -> XqliteNIF.query_cancellable(conn, slow_sql, [], token) end)
:ok = XqliteNIF.cancel_operation(token)
{:error, :operation_cancelled} = Task.await(task)
```

### Receive per-connection change notifications

```elixir
{:ok, handle} = XqliteNIF.register_update_hook(conn, self())
{:ok, 1} = XqliteNIF.execute(conn, "INSERT INTO users (name) VALUES ('Bob')", [])
# => receive {:xqlite_update, :insert, "main", "users", 2}
:ok = XqliteNIF.unregister_update_hook(conn, handle)
```

Multiple subscribers can coexist on the same connection — each
registration returns a distinct handle, and unregistering one never
affects the others.

### Transaction lifecycle hooks

```elixir
{:ok, c_h} = XqliteNIF.register_commit_hook(conn, self())     # {:xqlite_commit} before each commit
{:ok, r_h} = XqliteNIF.register_rollback_hook(conn, self())   # {:xqlite_rollback} after each rollback
{:ok, w_h} = XqliteNIF.register_wal_hook(conn, self())        # {:xqlite_wal, db_name, pages} after WAL commits
# ...later, unregister specific subscribers by their handles:
:ok = XqliteNIF.unregister_commit_hook(conn, c_h)
```

All transaction-lifecycle hooks (commit, rollback, WAL) are
multi-subscriber — multiple processes can subscribe to the same
connection independently. The commit hook is observation-only and
never vetoes the commit. Combined with `register_update_hook/2` and
`set_busy_handler/5`, the connection exposes every SQLite-visible
lifecycle event for telemetry without touching the SQL stream.

### Busy handler -- observe contention, retry, give up on a budget

```elixir
:ok = Xqlite.set_busy_handler(conn, self(), max_retries: 50, max_elapsed_ms: 5_000, sleep_ms: 10)
# every SQLITE_BUSY retry delivers: {:xqlite_busy, retries_so_far, elapsed_ms}
# surfaces SQLITE_BUSY to the caller once either ceiling is hit

:ok = Xqlite.remove_busy_handler(conn)                     # back to "fail fast" behavior
:ok = Xqlite.busy_timeout(conn, 1_000)                     # plain timeout, no handler
```

> **Warning.** `PRAGMA busy_timeout` / `sqlite3_busy_timeout` silently
> replaces any installed busy handler at the SQLite C level. If you
> install an xqlite handler and then run `PRAGMA busy_timeout`, SQLite
> replaces our callback with its built-in sleep-and-retry one and
> `{:xqlite_busy, …}` messages stop. No memory is leaked (our internal
> state is reclaimed on the next `set_busy_handler`, `remove_busy_handler`,
> or connection close), but the message stream goes quiet. Use
> `Xqlite.busy_timeout/2` — it removes our handler cleanly first, then
> installs the plain timeout.

### Online backup with progress and cancellation

```elixir
{:ok, token} = XqliteNIF.create_cancel_token()
:ok = XqliteNIF.backup_with_progress(conn, "main", "/path/to/backup.db", self(), 10, token)
# receive {:xqlite_backup_progress, remaining, pagecount} messages
# cancel from any process: XqliteNIF.cancel_operation(token)
```

### Session extension -- capture, apply, invert

```elixir
{:ok, session} = XqliteNIF.session_new(conn)
:ok = XqliteNIF.session_attach(session, nil)
{:ok, 1} = XqliteNIF.execute(conn, "INSERT INTO users VALUES (1, 'alice')", [])
{:ok, changeset} = XqliteNIF.session_changeset(session)
:ok = XqliteNIF.session_delete(session)

# Apply to a replica with conflict strategy (:omit, :replace, :abort)
:ok = XqliteNIF.changeset_apply(replica_conn, changeset, :replace)
```

### Incremental blob I/O

```elixir
{:ok, 1} = XqliteNIF.execute(conn, "INSERT INTO files VALUES (1, zeroblob(1048576))", [])
{:ok, blob} = XqliteNIF.blob_open(conn, "main", "files", "data", 1, false)
:ok = XqliteNIF.blob_write(blob, 0, chunk1)
:ok = XqliteNIF.blob_write(blob, byte_size(chunk1), chunk2)
{:ok, header} = XqliteNIF.blob_read(blob, 0, 64)
:ok = XqliteNIF.blob_close(blob)
```

### Serialize / deserialize -- atomic in-memory snapshots

`serialize/1` captures the entire live database as a single self-contained binary. That binary is byte-for-byte what the database's disk file would look like -- write it with `File.write/2` and it is a valid SQLite file you can open from any other SQLite tool. `deserialize/2` loads the binary back into a fresh connection where it behaves as a normal in-memory DB (read, write, indexes, everything).

Different from `backup_with_progress/6`, which streams page by page while the source is live, and from sessions, which capture _changes_ since a point in time. Serialize is a one-shot atomic snapshot of the _whole_ database into a BEAM binary, useful for shipping DB state between nodes/processes, cloning a DB without disk I/O, or handing off to a Task without worrying about file locks.

```elixir
{:ok, binary} = Xqlite.serialize(conn)
{:ok, conn2} = Xqlite.open_in_memory()
:ok = Xqlite.deserialize(conn2, binary)
```

## FAQ

**Why Rust and not C?**
For me the choice came down to _not panicking_ and never bringing down the BEAM VM. Rust's exhaustive pattern matching on tagged unions (`enum`s) means the compiler will not let me forget a case -- all 13 SQLite constraint subtypes, every error variant, and every storage class get a dedicated code branch. The code refuses to compile if one is missing. C gives me none of that, and I don't trust myself (or decades of accreted C and `sqlite3_*` idioms) to avoid footguns when every NULL check and every `free` is a decision I make by hand.

The cost is of course real: the stack is C -> `libsqlite3-sys` -> `rusqlite` -> `rustler` -> Elixir, and architecturally I don't like it. In practice, every benchmark I've run shows the overhead is anywhere from minuscule to invisible. In return I get a pure-Rust error list/taxonomy, `ResourceArc` + `Mutex<Connection>` + `Drop` as first-class citizens rather than convention-driven discipline (no resource leaks due to human forgetfulness), and the exhaustiveness guarantee mentioned above. The tradeoff has been worth it so far. I am very happy with the Rust code, even its ugly parts -- they are needed to get the job done and fulfill the promises that this library makes.

**What SQLite version is bundled?**
Currently: SQLite 3.51.3. The exact version is also available at runtime via `XqliteNIF.sqlite_version/0`.

**Can I use Xqlite and [exqlite](https://github.com/elixir-sqlite/exqlite) in the same application?**
Yes. They're separate Hex packages with separate NIFs and no shared runtime state. Projects could use Xqlite for one specific capability (e.g. session changesets for sync, or incremental blob I/O) while keeping exqlite for the main query path. There is no conflict at the BEAM level, though concurrent access remains an immutable SQLite limitation none of us can do anything about until SQLite gets fundamentally modified (which is extremely unlikely).

**Is Xqlite production-ready?**
I run it in my own projects (currently not as much as I'd like to). The test coverage is extensive and the test suite runs in an ad-hoc manner that was impossible to avoid due to SQLite's parallelization limitations. That said, it's still on a 0.X.Y release cadence. Semantic versioning is respected, but the public API may still change before 1.0. Please report anything surprising or unpleasant (or bugs, or high memory usage) -- I am open to discussion, and I am responsive on ElixirForum.

**What's the concurrency / parallelization story?**
SQLite permits a single writer at a time per database file. I use the WAL mode by default to make sure readers remain fully parallel and writers are limited to one at a time, but that can only take you so far. Xqlite serializes access to each connection via a Rust `Mutex`; concurrent writers across _different_ connections to the same file fall back on SQLite's own WAL mode and busy-timeout logic. For a connection pool with parallel readers plus a serialised writer, use `xqlite_ecto3` (or DBConnection directly, or your own pooling solution). For anything requiring true multi-master replication, tools like [Litestream](https://litestream.io) and [LiteFS](https://fly.io/docs/litefs/) live outside of SQLite itself.

**Does Xqlite support telemetry / OpenTelemetry?**
Not yet. The plan is to emit structured `[:xqlite, ...]` events via the standard `:telemetry` Erlang package — no direct OpenTelemetry dependency. Users who want OTel spans wire the `opentelemetry_telemetry` bridge in their own application; users who only want Prometheus metrics via `:telemetry_metrics` do that; users who want nothing pay nothing. It will be added and it will be thorough.

## Thread safety

Each `rusqlite::Connection` is wrapped in `Arc<Mutex<_>>` via Rustler's `ResourceArc`. One Elixir process accesses a given connection at a time. Connection pooling belongs in higher layers (DBConnection / Ecto adapter). You can easily open many connections to the same DB and use them all in parallel -- your only limitation then is SQLite's WAL and internal mechanics that prevent fully parallel access.

SQLite is opened with `SQLITE_OPEN_NO_MUTEX` (rusqlite's default) -- serialization lives in the Rust Mutex, not SQLite's internal one.

## Known limitations

Xqlite-specific:

- **Generated column `default_value`** in `schema_columns/2` is `nil`. Use `get_create_sql/2` to recover the expression.
- **User-Defined Functions** -- not planned due to implementation complexity across NIF boundaries. Might reconsider when the library matures enough, but it's one of the lowest priorities for me as a maintainer.

Architectural limits SQLite imposes (not Xqlite choices):

- **Single writer per database file** -- WAL relaxes this for _readers_, not writers
- **No network / remote access** -- SQLite is embedded by design; libSQL / rqlite / Turso bolt a server on if needed
- **No built-in replication** -- Litestream and LiteFS are the common external-tool solutions (disk-to-S3 streaming and FUSE-based sync, respectively)
- **No row-level locking** -- there is no `SELECT ... FOR UPDATE`
- **No user / role / GRANT system** -- file permissions are the only access gate
- **No schemas or namespaces** -- `ATTACH DATABASE` is a potential workaround, but IMO it would be a fairly leaky and ugly abstraction, so I'm nearly certain I'll never go for it.
- **Foreign key constraint errors don't carry the FK name** -- SQLite reports `SQLITE_CONSTRAINT_FOREIGNKEY` without enough detail to map back to a specific constraint
- **`last_insert_rowid` returns nothing useful for `WITHOUT ROWID` tables** -- those tables have no rowid by definition, so the underlying SQLite C function has nothing to report. Use `INSERT ... RETURNING` (SQLite >= 3.35.0) to get autogenerated primary-key values for such tables.
- **Storage types are 5 classes (NULL, INTEGER, REAL, TEXT, BLOB)** -- no native TIMESTAMPTZ, UUID, interval/duration, decimal, array, JSON, or ENUM. Xqlite's type extensions layer provides encode/decode affordances for some of these

## Design notes

### Cancellation over `sqlite3_interrupt`

Xqlite cancels operations via SQLite's progress handler, checked every 8 VM instructions, rather than via `sqlite3_interrupt()`. The interrupt API is fire-and-forget, per-connection, and is known to let slow operations continue running after being asked to stop. The progress-handler approach is per-operation, fine-grained, and any process can cancel without holding the connection handle -- which maps well onto DBConnection's timeout model and, by extension, to most Ecto-using apps.

### Rust `Mutex` vs SQLite's `NO_MUTEX`

Rusqlite opens connections with `SQLITE_OPEN_NO_MUTEX` (disabling SQLite's own mutex). The Rust-side `Mutex<Connection>` is still required because `rusqlite::Connection` is `!Sync`. The two are complementary: `NO_MUTEX` is safe _because_ the Rust `Mutex` serializes access. Removing the Rust mutex would mean re-enabling SQLite's internal one at the rusqlite level, which isn't a knob rusqlite currently exposes.

### Backup API: single call, not resource handle

Xqlite provides two backup interfaces: one-shot (`backup/2`, `restore/2`) and incremental with progress (`backup_with_progress/6`).

The incremental variant runs the entire backup inside a single NIF call on a dirty I/O scheduler, sending `{:xqlite_backup_progress, remaining, pagecount}` messages after each step. A cancel token -- the same one used for `query_cancellable/4` -- allows another process to abort the backup at any time.

I chose this single-call design over exposing a step-by-step `Backup` resource handle because:

- **Two pool connections at once is practically begging for a deadlock or confusing pool timeout errors.** SQLite's incremental backup API needs the source and destination connections open at the same time. If both come from the same Ecto pool -- and they almost always do in a backup scenario -- the second checkout can block waiting for a slot the first one still holds. Taking a file path as the destination sidesteps the potential deadlock: the backup owns its own connection internally, no pool coordination required.
- **No manual management of interim handles and no babysitting of the library's implementation details.** A step-by-step API would force users to explicitly close the backup handle. Forgotten handles leak resources; the single-call API creates, runs, and cleans up in a single function call.
- **Cancellation and progress are covered for you.** The cancel token plus progress messages give callers everything that SQLite supports for surfacing UI feedback and/or enforcing timeouts.

If people actually start asking for a step-by-step backup handle, I'll engage with them and likely add one.

### Affected row counts (`changes/1`)

`query/3` returns `%{columns, rows, num_rows}` where `num_rows` is the count of _result rows_ -- not SQLite's `sqlite3_changes()`. For `SELECT` these are the same. For DML (`INSERT`/`UPDATE`/`DELETE` without `RETURNING`), `query/3` returns `num_rows: 0` because there are no result rows, even though rows were affected.

To get the actual affected row count after DML, call `changes/1` immediately after the statement -- or use `query_with_changes/3` which captures the count atomically.

**Important SQLite behavior:** `sqlite3_changes()` is sticky -- per [the official docs](https://www.sqlite.org/c3ref/changes.html), "executing any other type of SQL statement does not modify the value returned by these functions." This means `changes/1` after a `SELECT` returns the _previous_ DML's count, not 0. It never resets on its own.

`query_with_changes/3` solves this by reading `sqlite3_changes()` inside the same `Mutex` hold as the query execution and returning 0 for non-DML statements (detected by empty result columns). This is the recommended function for callers who need reliable affected row counts -- including the `xqlite_ecto3` adapter.

## Roadmap

Planned for Xqlite core, in priority order:

1. **Multi-writer concurrency observability.** Expose SQLite's transaction-state, WAL checkpoint progress, busy-retry events, and per-connection counters as structured data so callers can build their own concurrency strategies. Concretely: `sqlite3_busy_handler` forwarded to a PID, `sqlite3_wal_hook` forwarded to a PID, `sqlite3_commit_hook` + `sqlite3_rollback_hook`, `sqlite3_txn_state`, `sqlite3_db_status` counters, a structured wrapper around `sqlite3_wal_checkpoint_v2`. I hate black boxes with a passion — one of the main goals of this library is to let you poke into the guts of your SQLite databases without introducing quantum uncertainty or cryptic crashes.
2. **`:telemetry` integration.** Every significant operation (query, execute, stream, transaction, savepoint, backup, cancellation, extension load, session capture, serialize/deserialize, each of the observability hooks above) emits structured `[:xqlite, ...]` events via the standard `:telemetry` package. OpenTelemetry integration is a downstream bridge via `opentelemetry_telemetry` — no adapter-side OTel dependency.
3. **Manual statement lifecycle** — optional prepare/bind/step/reset/release for patterns not covered by the existing helpers. Still not 100% certain about this one but I've heard it enough times from people that I'm considering adding it proactively (before being asked to). Feedback on whether this would have a direct value for you is very welcome.
4. **SQLCipher support (optional)** — for encrypted-at-rest use cases.

Lower priority (though UDFs remain the lowest priority for now):

- Geometry / Geography support (via SpatiaLite)
- GIN / GiST / SP-GiST-style index equivalents
- Mirroring the Ecto-layer custom types (duration, array, UUID, timezone-aware datetime) at the raw xqlite layer — today they live in [xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3) as `Ecto.Type` modules and won't move unless raw-xqlite users ask

Then: [xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3) — full Ecto 3.x adapter with `DBConnection`, migrations, associations, streaming, and the same structured-error surface.

## Contributing

Contributions are welcome. Please open issues or submit pull requests.

## License

MIT -- see [`LICENSE.md`](LICENSE.md).
