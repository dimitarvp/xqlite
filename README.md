# Xqlite

[![Hex version](https://img.shields.io/hexpm/v/xqlite.svg?style=flat)](https://hex.pm/packages/xqlite)
[![Hexdocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/xqlite)
[![Downloads](https://img.shields.io/hexpm/dt/xqlite.svg)](https://hex.pm/packages/xqlite)
[![SQLite](https://img.shields.io/badge/SQLite-3.53.2-003B57?logo=sqlite&logoColor=white)](https://sqlite.org/releaselog/3_53_2.html)
[![Build Status](https://github.com/dimitarvp/xqlite/actions/workflows/ci.yml/badge.svg)](https://github.com/dimitarvp/xqlite/actions)
[![Coverage](https://coveralls.io/repos/github/dimitarvp/xqlite/badge.svg?branch=main)](https://coveralls.io/github/dimitarvp/xqlite?branch=main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Choose SQLite, and stay with it, instead of Postgres when you do not truly need Postgres. xqlite is an Elixir library for SQLite that gives your application what staying takes: queries any process can cancel, errors with structured fields, backups of a live database, change capture, full-text search, and messages on commits, rollbacks, row changes and lock waits.

Bundled SQLite 3.53.2 is compiled into the library, so there is nothing to install, and development, CI and production all run the same SQLite. The native layer is Rust, built on [rusqlite](https://crates.io/crates/rusqlite) and [Rustler](https://github.com/rusterlium/rustler). A value that xqlite or SQLite rejects comes back as `{:error, reason}`, and a panic in the Rust code raises in the calling process instead of taking the VM down. The [Security](guides/security.md#panic-freedom-and-where-it-ends) guide says where that guarantee ends.

For Ecto, see [xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3), the adapter built on xqlite (in development).

## Why xqlite

- **WAL mode and foreign keys by default.** `Xqlite.open/2` turns both on and waits up to 5 seconds when another connection holds a lock. It checks every option before it opens the file.
- **Cancel from any process.** `query/4`, `execute/4`, `execute_batch/3`, `multi_step/3`, `stream/4` and `backup_with_progress/4` take cancel tokens. Any process can signal a token with `Xqlite.cancel_operation/1`, without the connection.
- **Errors you can match on.** A rejected value or a failed statement comes back as `{:error, reason}` with structured fields. A constraint violation carries its kind and, where SQLite reports them, its table, columns, index and constraint name.
- **Elixir types in and out.** Type extensions store `DateTime`, `Date`, `Time`, `NaiveDateTime`, `Decimal`, `Duration`, UUIDs and JSON, and read most of them back.
- **STRICT tables for existing data.** Find what stops a table from becoming STRICT, then rebuild it as STRICT in one transaction.
- **See what SQLite is doing.** Messages on row changes, commits, rollbacks, WAL writes, lock waits and SQLite's own log. Per-connection counters. `EXPLAIN ANALYZE` with row counts per scan. Opt-in `:telemetry` events.
- **Backups, snapshots and change capture.** Online backup with progress messages, restore, whole-database snapshots as binaries, and SQLite's session extension for shipping changes to a replica.
- **Full-text search built in.** FTS5 is compiled into the bundled SQLite.
- **53 typed PRAGMAs** with validated get/set; 34 of them are writable.

## Installation

```elixir
def deps do
  [
    {:xqlite, "~> 0.16.0"}
  ]
end
```

xqlite is pre-1.0, so its minor version carries breaking changes, and `~> 0.16.0` takes patch releases only. Each release of the Ecto adapter, xqlite_ecto3, pins one xqlite minor series, and its README names that series.

Precompiled binaries cover macOS (ARM and x86_64), Linux (ARM and x86_64 on glibc and musl, RISC-V on glibc) and Windows (x86_64), so these platforms need no Rust toolchain. The binaries are built for NIF version 2.17, which came with OTP 26 ([erl_nif.h](https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_nif.h)), so they need OTP 26 or newer. xqlite needs Elixir 1.17 or newer. CI runs the tests on Linux, macOS and Windows with Elixir 1.17 and 1.18 on OTP 26 and 27, Elixir 1.19 on OTP 26 to 28, and Elixir 1.20 on OTP 27 to 29.

To build from source, on a platform without a binary or by choice, set `XQLITE_BUILD=true`:

```bash
XQLITE_BUILD=true mix deps.compile xqlite
```

A source build needs Rust 1.91 or newer. It also needs `{:rustler, "~> 0.38.0"}` in your own deps: xqlite declares Rustler as an optional dependency, which [Mix](https://hexdocs.pm/mix/Mix.Tasks.Deps.html) does not add to the projects that depend on xqlite, and [RustlerPrecompiled](https://hexdocs.pm/rustler_precompiled/precompilation_guide.html) needs Rustler to build.

## Quickstart

```elixir
{:ok, conn} = Xqlite.open_in_memory()

{:ok, _} =
  Xqlite.execute(conn, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")

{:ok, %Xqlite.Result{changes: 1}} =
  Xqlite.execute(conn, "INSERT INTO users (name) VALUES (?1)", ["Alice"])

{:ok, %Xqlite.Result{columns: ["id", "name"], rows: [[1, "Alice"]], num_rows: 1}} =
  Xqlite.query(conn, "SELECT id, name FROM users")

:ok = Xqlite.close(conn)
```

The examples below assume an open `conn` with this `users` table.

## Features

`Xqlite` is the everyday API. `XqliteNIF` holds the raw NIF calls, among them the row, commit, rollback, WAL and log hooks, the sessions and the blob handles, which `Xqlite` does not wrap. [Hexdocs](https://hexdocs.pm/xqlite) has the full API.

- **Connections**: `open/2` with checked options, `open_in_memory/1`, `open_readonly/1`, `open_in_memory_readonly/1`, `open_temporary/0` and `close/1`. Closing a connection finalizes its statements, streams and blobs.
- **Queries**: `query/4`, `execute/4` and `execute_batch/3`. All three take `:cancel_tokens`. `query/4` and `execute/4` take `:type_extensions` and return `%Xqlite.Result{}` with `num_rows` and `changes`.
- **Streaming**: `stream/4` reads rows in batches as maps keyed by column name, with `:batch_size`, `:cancel_tokens`, `:type_extensions` and an `:on_error` mode. The raw `XqliteNIF.stream_open/3`, `stream_fetch/2` and `stream_close/1` return rows as lists.
- **Prepared statements**: `prepare/2`, `bind/3` with positional or named parameters, `step/1`, `multi_step/3`, `reset/1`, `clear_bindings/1`, `column_names/1` and `finalize/1`. A statement you drop is finalized after garbage collection.
- **Transactions**: `begin/2` in `:deferred`, `:immediate` or `:exclusive` mode, `commit/1`, `rollback/1`, `savepoint/2`, `release_savepoint/2` and `rollback_to_savepoint/2`.
- **Cancellation**: `create_cancel_token/0` and `cancel_operation/1`. Signalling a token stops every call that holds it. A token stays signalled, so create a new one per operation.
- **Type extensions**: bidirectional encode/decode; nine built in: `DateTime` (the offset is written, values read back as UTC), `Date`, `Time`, `NaiveDateTime`, `JSON` (plain maps and lists), `UUID` (canonical text to a compact 16-byte blob), `Instant` and `Duration` (int64 nanoseconds, encode only) and `Decimal` (encode only, needs the optional `:decimal` dependency). They encode the parameters of `query/4`, `execute/4`, `stream/4`, `bind/3` and `explain_analyze/4`, and decode the rows of `query/4` and `stream/4`. An extension that claims a value but cannot store it, such as a `Decimal` that is `NaN`, fails the call with a structured error that names the parameter, instead of writing a wrong value.
- **PRAGMAs**: `Xqlite.Pragma`, a typed schema with validation for 53 PRAGMAs, 34 of them writable. A value a PRAGMA cannot take is rejected before SQLite sees it, and a write that SQLite answers with another value returns `{:error, {:pragma_not_applied, _}}`. The PRAGMAs that act are functions: `optimize/1`, `shrink_memory/1` and `wal_checkpoint/3`.
- **Limits**: `get_limit/2` and `put_limit/3` read and set SQLite's thirteen per-connection limits, such as the longest value and the longest SQL text.
- **Schema introspection**: `schema_databases/1`, `schema_list_objects/2`, `schema_columns/2`, `schema_foreign_keys/2`, `schema_indexes/2`, `schema_index_columns/2` and `get_create_sql/2` return structs that include generated columns, STRICT and WITHOUT ROWID markers, the collation of each index column and the MATCH clause of each foreign key. Column defaults come back classified, such as `{:literal, 42}`, `{:blob, bytes}`, `{:current, :timestamp}` or `{:expr, "datetime('now')"}`.
- **STRICT tables**: `check_strict_violations/2` lists the stored values and declared types that stop a table from becoming STRICT. `enable_strict_table/2` rebuilds the table as STRICT in one transaction and keeps its rows, indexes and triggers.
- **Hooks**: row changes (`{:xqlite_update, action, db_name, table, rowid}`), commits, rollbacks, WAL writes (`{:xqlite_wal, db_name, pages}`), progress ticks and SQLite's global log, each with any number of subscribers. Lock waits get a retry policy, one per connection (`set_busy_policy/2`), and any number of observers that receive `{:xqlite_busy, retries_so_far, elapsed_ms}`.
- **Authorizer**: `set_authorizer/2` denies chosen kinds of action (`:insert`, `:delete`, `:pragma`, `:attach`, ...) while a statement is prepared, before it touches a row, and `remove_authorizer/1` clears the list. A denied action answers `{:error, {:authorization_denied, code, message}}`, except a denied `:function`, which SQLite reports as an error in the statement, with code 1 (see `Xqlite.set_authorizer/2`). While a busy policy or observer is installed, xqlite adds two rules of its own: a `busy_timeout` write is rejected, and xqlite's own read of `busy_timeout` passes a `:pragma` deny.
- **Telemetry**: opt-in at compile time. Spans and events cover opening and closing, queries, executes, batches, streams, transactions, savepoints, backups, restores, snapshots, checkpoints, extensions and cancellation, timed in nanoseconds. `Xqlite.Telemetry.bridge/2` turns hook messages into `[:xqlite, :hook, :*]` events.
- **Backup and restore**: `backup/3` and `restore/3` copy in one step. `backup_with_progress/4` copies in steps, with progress messages and cancel tokens.
- **Snapshots**: `serialize/2` and `deserialize/4` move a whole database into a binary and back.
- **Sessions**: SQLite's session extension through `XqliteNIF`: capture changes, apply them with a conflict strategy, invert them, or join two changesets.
- **Blob I/O**: `XqliteNIF.blob_open/6`, `blob_read/3`, `blob_write/3`, `blob_size/1`, `blob_reopen/2` and `blob_close/1` read and write a BLOB in pieces.
- **Extensions**: `load_extension/3` works once `enable_load_extension/1` turns loading on, and `disable_load_extension/1` turns it off again. Read the [Security](guides/security.md#loading-an-extension-runs-native-code-in-your-process) guide before you load one.
- **Diagnostics**: `explain_analyze/4`, `connection_stats/1` (SQLite's `sqlite3_db_status` counters), `compile_options/1`, `sqlite_version/0`, `autocommit/1`, `txn_state/2`, `changes/1`, `total_changes/1` and `last_insert_rowid/1`.
- **Results**: `Xqlite.Result` implements the `Table.Reader` protocol of the [table](https://hex.pm/packages/table) package, so [Explorer](https://hexdocs.pm/explorer/Explorer.DataFrame.html#new/2) and [Kino](https://hexdocs.pm/kino/Kino.DataTable.html#new/2) take a result as it is.

Errors are `{:error, reason}` tuples whose `reason` is an atom or a tagged tuple with structured fields, such as `{:constraint_violation, :constraint_unique, %{table: ..., columns: [...], ...}}` or `{:read_only_database, code, message}`. The `Xqlite.error_reason` type lists 92 typed reason variants, including twelve SQLite constraint subtypes plus a generic fallback. Match on the tags and fields, not on message text.

## Guides

- [Gotchas](guides/gotchas.md): behaviour that is defined but surprising, and what to do about it.
- [Security](guides/security.md): the trust boundary, extensions, the authorizer, and where the crash-safety guarantee ends.
- [Known limitations](guides/known_limitations.md): every limitation the library documents, with what to do instead.
- [Parallel writes on the BEAM](guides/parallel_writes.md): many processes writing to one database, how a call waits for the write lock, and what to expect from heavy writes.
- [Wiring xqlite telemetry](guides/wiring_telemetry.md): the events, the hook bridge, and sample handlers.
- [Full-text search with FTS5](guides/full_text_search.md).
- [Spatial data with SpatiaLite](guides/spatialite.md).

## Examples

### Streaming with type decoding

```elixir
alias Xqlite.TypeExtension

extensions = [TypeExtension.DateTime, TypeExtension.Date]

{:ok, _} = Xqlite.execute(conn, "CREATE TABLE events (ts TEXT, day TEXT)")

{:ok, %Xqlite.Result{changes: 1}} =
  Xqlite.execute(
    conn,
    "INSERT INTO events (ts, day) VALUES (?1, ?2)",
    [~U[2024-01-15 10:30:00Z], ~D[2024-06-15]],
    type_extensions: extensions
  )

conn
|> Xqlite.stream("SELECT ts, day FROM events", [], type_extensions: extensions)
|> Enum.to_list()
# => [%{"ts" => ~U[2024-01-15 10:30:00Z], "day" => ~D[2024-06-15]}]
```

`stream/4` fetches rows in batches, so a consumer that handles each row as it arrives keeps about one batch in memory ([Gotchas](guides/gotchas.md#query-materializes-the-whole-result-stream-bounds-the-peak)). When the statement cannot be prepared, `stream/4` returns `{:error, reason}` instead of a stream, so match on the result before you pipe it in application code. A mid-stream error raises `Xqlite.StreamError` by default, and `on_error: :emit_error` hands it over as a value instead.

### Cancel a query from another process

```elixir
{:ok, token} = Xqlite.create_cancel_token()

endless = """
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n)
SELECT count(*) FROM n
"""

task = Task.async(fn -> Xqlite.query(conn, endless, [], cancel_tokens: token) end)

:ok = Xqlite.cancel_operation(token)

{:error, :operation_cancelled} = Task.await(task)
```

The query never ends on its own, so the token is what stops it. `stream/4`, `execute_batch/3`, `multi_step/3` and `backup_with_progress/4` take the same option. A token stays signalled, so create a new one per operation ([Gotchas](guides/gotchas.md#cancel-tokens-are-single-use)). A write cancelled while it runs rolls back its whole transaction ([Gotchas](guides/gotchas.md#a-write-cancelled-while-it-runs-rolls-back-the-whole-transaction)).

### Row change notifications

```elixir
{:ok, handle} = XqliteNIF.register_update_hook(conn, self())

{:ok, _} = Xqlite.execute(conn, "INSERT INTO users (name) VALUES ('Bob')")

receive do
  {:xqlite_update, :insert, "main", "users", rowid} -> rowid
end

:ok = XqliteNIF.unregister_update_hook(conn, handle)
```

Each subscriber gets its own handle, and removing one leaves the others in place. The message is sent before the commit, so a subscriber also hears of a change whose transaction later rolls back.

### Transaction lifecycle hooks

```elixir
{:ok, commit_handle} = XqliteNIF.register_commit_hook(conn, self())
{:ok, rollback_handle} = XqliteNIF.register_rollback_hook(conn, self())
{:ok, wal_handle} = XqliteNIF.register_wal_hook(conn, self())

# This process now receives:
#   {:xqlite_commit}                 just before each commit
#   {:xqlite_rollback}               after each rollback
#   {:xqlite_wal, db_name, pages}    after each commit in WAL mode

:ok = XqliteNIF.unregister_commit_hook(conn, commit_handle)
:ok = XqliteNIF.unregister_rollback_hook(conn, rollback_handle)
:ok = XqliteNIF.unregister_wal_hook(conn, wal_handle)
```

Every hook takes any number of subscribers. The commit hook only watches: it never stops a commit. No rollback message comes for `ROLLBACK TO` a savepoint, for a failed commit that leaves its transaction open, or for the rollback that `Xqlite.close/1` does.

SQLite gives each connection one WAL callback, and its automatic checkpoint uses it. xqlite takes that callback for WAL subscribers and runs the checkpoint itself, at the `wal_autocheckpoint` threshold (1000 pages unless you change it). Set the threshold with `Xqlite.Pragma.put/3`. A `PRAGMA wal_autocheckpoint = N` statement run as SQL puts SQLite's own callback back: WAL subscribers hear nothing more until `Xqlite.Pragma.put/3` writes the threshold again, and `Xqlite.Pragma.get/2` and `XqliteNIF.get_pragma/2` keep answering xqlite's threshold while SQLite checkpoints at the N the statement set, or never for 0 or less.

### Lock waits: a retry policy and observers

```elixir
:ok = Xqlite.set_busy_policy(conn, max_retries: 50, max_elapsed_ms: 5_000, sleep_ms: 10)

{:ok, handle} = Xqlite.register_busy_observer(conn, self())
# Each retry of a call waiting for a lock sends {:xqlite_busy, retries_so_far, elapsed_ms}.

:ok = Xqlite.unregister_busy_observer(conn, handle)
:ok = Xqlite.remove_busy_policy(conn)
:ok = Xqlite.put_busy_timeout(conn, 1_000)
```

When another connection holds a lock a statement needs, the policy decides whether to retry or give up, by count and by time for each wait. A connection has one policy, because two retry decisions cannot be combined. Observers only watch: any number of them, with or without a policy, and `Xqlite.Telemetry.bridge/2` can turn their messages into `[:xqlite, :hook, :busy]` events.

A call that meets a lock waits in the process that made it, sleeping between attempts, so a waiting call holds no VM thread and the connection stays free for other calls. A raw `XqliteNIF` call answers the busy error at once; `Xqlite.retry_busy/3` waits for it the same way. `Xqlite.put_busy_timeout/2`, or `PRAGMA busy_timeout = N` sent as SQL, sets the wait, and `Xqlite.get_busy_timeout/1` reads it; the connection waits that long whenever no policy is set.

### Online backup with progress and cancellation

```elixir
{:ok, token} = Xqlite.create_cancel_token()

:ok =
  Xqlite.backup_with_progress(conn, "/path/to/backup.db", self(),
    pages_per_step: 10,
    cancel_tokens: token
  )
```

After each step, the given process receives `{:xqlite_backup_progress, %{remaining: r, total: t, status: :copied | :busy}}`. The call returns when the copy ends, so another process stops it between two steps with `Xqlite.cancel_operation(token)`. `Xqlite.backup/3` copies in a single step, and `Xqlite.restore/3` copies a backup file over a schema of an open connection.

### Prepared statements

```elixir
{:ok, stmt} = Xqlite.prepare(conn, "INSERT INTO users (name) VALUES (?1)")

for name <- ["Dave", "Erin"] do
  :ok = Xqlite.bind(stmt, [name])
  :done = Xqlite.step(stmt)
  :ok = Xqlite.reset(stmt)
end

:ok = Xqlite.finalize(stmt)
```

SQLite parses and plans the statement once. `Xqlite.multi_step/3` reads a query's rows in batches. A statement that takes parameters does not run until a bind sets them, where SQLite would read each missing one as NULL.

### Session extension: capture and apply

```elixir
{:ok, session} = XqliteNIF.session_new(conn)
:ok = XqliteNIF.session_attach(session, :all)

{:ok, _} = Xqlite.execute(conn, "INSERT INTO users (name) VALUES ('Carol')")

{:ok, changeset} = XqliteNIF.session_changeset(session)
:ok = XqliteNIF.session_delete(session)

# On another connection with the same tables:
:ok = XqliteNIF.changeset_apply(replica, changeset, :replace)
```

A changeset holds the net change of every row since its table was attached, for tables with a primary key. `changeset_apply/3` takes `:omit`, `:replace` or `:abort` for conflicts, and rolls back a changeset that would leave a foreign key broken. `changeset_invert/1` turns a changeset into the one that undoes it, and `changeset_concat/2` joins two. To ship changes in rounds, start a new session after each capture ([Gotchas](guides/gotchas.md#a-session-capture-holds-the-net-change-since-the-attach)).

### Incremental blob I/O

```elixir
{:ok, _} = Xqlite.execute(conn, "CREATE TABLE files (id INTEGER PRIMARY KEY, data BLOB)")
{:ok, _} = Xqlite.execute(conn, "INSERT INTO files (id, data) VALUES (1, zeroblob(1048576))")

{:ok, blob} = XqliteNIF.blob_open(conn, "main", "files", "data", 1, false)
:ok = XqliteNIF.blob_write(blob, 0, chunk1)
:ok = XqliteNIF.blob_write(blob, byte_size(chunk1), chunk2)
{:ok, header} = XqliteNIF.blob_read(blob, 0, 64)
:ok = XqliteNIF.blob_close(blob)
```

A read returns up to the length asked for, fewer bytes when the blob ends first, and `{:ok, ""}` at or past the end. A write cannot grow a blob: one that would run past the end writes nothing and returns an error, so create the value at its full size with `zeroblob(n)` first.

### Snapshots: serialize and deserialize

```elixir
{:ok, image} = Xqlite.serialize(conn)

{:ok, copy} = Xqlite.open_in_memory()
:ok = Xqlite.deserialize(copy, image)
```

`Xqlite.serialize/2` copies a whole database into one binary, inside one read transaction, with what a WAL database still holds in its WAL file. For an ordinary database file, that binary is a copy of the file ([sqlite3_serialize](https://www.sqlite.org/c3ref/serialize.html)), so `File.write/2` turns it into a database file. `Xqlite.deserialize/4` loads such a binary into a connection, which then works on it in memory. The bytes of a database file load the same way, but only while no connection has that database open and no `-wal` or `-journal` file lies beside it.

Use snapshots to copy a database between processes or nodes, or to clone an in-memory database. A backup copies into a file instead, and a session holds changes, not the whole database. Both calls check first. `serialize/2` answers `{:error, :transaction_in_progress}` while the connection holds a write transaction on that schema, so the image never holds that transaction's uncommitted pages. `deserialize/4` answers an error and replaces nothing while a statement, stream or blob of the connection is running, or when the bytes are not a database it can read.

## Connections and concurrency

A connection is one SQLite connection behind a Rust `Mutex`. Any process can use it, and calls on it run one at a time. rusqlite opens SQLite connections with `SQLITE_OPEN_NO_MUTEX`, which turns off SQLite's own per-connection mutex, and the Rust `Mutex` serializes access instead ([Security](guides/security.md#thread-safety-model)).

SQLite lets one writer at a time write to a database file. In WAL mode, the default here, readers keep reading while it writes ([SQLite: Write-Ahead Logging](https://www.sqlite.org/wal.html)). For parallel work, open one connection per process, or keep a pool of connections, as the Ecto adapter does. A call that meets another connection's lock waits in its own process and holds no VM thread; [Parallel writes on the BEAM](guides/parallel_writes.md) says which calls wait and what each busy answer means.

Calls that touch a connection run on dirty schedulers, so a slow query does not hold up the BEAM's normal schedulers. A process that shares a connection with a slow query still waits for it ([Gotchas](guides/gotchas.md#concurrency-and-busy-handling)).

## FAQ

**Why Rust and not C?**
Native code runs inside the VM without memory protection, and "if the native function does not behave well, the whole VM will misbehave" ([erl_nif](https://www.erlang.org/doc/apps/erts/erl_nif.html)). Rust does not compile a `match` that leaves a case out ([The Rust Book](https://doc.rust-lang.org/book/ch06-02-match.html#matches-are-exhaustive)), and xqlite turns its errors into Elixir terms with such a `match`; its error mapping gives all twelve SQLite constraint subtypes a tag of their own. The Rust code has no `unwrap`, `expect`, `panic!` or indexing outside its unit tests (see `Xqlite.close/1`), and Rustler turns a panic that does happen into an exception in the calling process. Statements, streams and blobs are released when their connection closes, or after garbage collection when you drop them; the one exception, a session still referenced when its connection closes, is in the [Gotchas](guides/gotchas.md#delete-sessions-before-the-connection) guide. The cost is more layers between Elixir and SQLite: C, `libsqlite3-sys`, `rusqlite` and `rustler`.

**What SQLite version is bundled?**
Currently: SQLite 3.53.2. `Xqlite.sqlite_version/0` returns the version at runtime.

**Can I use xqlite and exqlite in one application?**
They are separate packages with separate native libraries. Do not open the same database file through both. xqlite links its own copy of SQLite, so the VM then holds two copies, and SQLite warns that two copies in one process can corrupt a database they both open, through POSIX advisory locks ([How To Corrupt An SQLite Database File](https://www.sqlite.org/howtocorrupt.html), "Multiple copies of SQLite linked into the same application").

**Is the API stable?**
xqlite is pre-1.0, so its minor version carries breaking changes. Pin `~> 0.16.0`, and read the [CHANGELOG](CHANGELOG.md) before you move to the next minor version. Report bugs and surprises as [GitHub issues](https://github.com/dimitarvp/xqlite/issues).

**Does xqlite support telemetry and OpenTelemetry?**
Yes, through `:telemetry`, switched on at compile time in your `config/config.exs`:

```elixir
config :xqlite, :telemetry_enabled, true
```

Then rebuild the dependency with `mix deps.compile xqlite --force`. With the switch off, the default, the compiled code holds no `:telemetry` call. xqlite has no OpenTelemetry dependency: `Xqlite.Telemetry.OpenTelemetry` maps its events to OpenTelemetry's [stable database attributes](https://opentelemetry.io/docs/specs/semconv/database/database-spans/), such as `db.system.name` and `db.query.text`, for a handler you write. The [Wiring xqlite telemetry](guides/wiring_telemetry.md) guide has sample handlers for StatsD, OpenTelemetry, Logger and Prometheus.

## Known limitations

The [Known limitations](guides/known_limitations.md) guide is the one place for every limitation the library documents, each with what to do instead: from the ways a read-only connection can still write to the SQLite rules that xqlite cannot change, such as a PRAGMA that stays applied when a syntax error follows it.

Limits of xqlite:

- A generated column's `default_value` in `Xqlite.schema_columns/2` is `:none`. `Xqlite.get_create_sql/2` returns the table's SQL, the expression included.
- No user-defined functions: xqlite cannot register SQL functions written in Elixir.

Limits of SQLite's design:

- **One writer at a time per database file.** WAL mode lets readers run during a write, not a second writer ([SQLite: Write-Ahead Logging](https://www.sqlite.org/wal.html)).
- **No network access.** SQLite is a library inside your process, not a server ([Security](guides/security.md#the-trust-boundary)).
- **No built-in replication.** Tools fill that gap, such as [Litestream](https://litestream.io), which streams SQLite changes to cloud storage or local files, and [LiteFS](https://fly.io/docs/litefs/), a distributed file system that replicates SQLite databases.
- **No row-level locks.** Locks cover the whole database file, and `SELECT` has no `FOR UPDATE` ([File Locking](https://www.sqlite.org/lockingv3.html), [SELECT](https://www.sqlite.org/lang_select.html)).
- **No users, roles or `GRANT`.** The operating system's file permissions are the only access control ([SQL Features That SQLite Does Not Implement](https://www.sqlite.org/omitted.html)).
- **No schemas inside a database.** Each attached database file has a name, and `name.table` reaches its tables ([ATTACH DATABASE](https://www.sqlite.org/lang_attach.html)).
- **A foreign key error names no key.** SQLite's message, "FOREIGN KEY constraint failed", names no table, column or constraint ([Foreign Key Support](https://www.sqlite.org/foreignkeys.html)), so the error carries none.
- **`last_insert_rowid/1` does not see `WITHOUT ROWID` tables.** SQLite does not record inserts into them ([sqlite3_last_insert_rowid](https://www.sqlite.org/c3ref/last_insert_rowid.html)). Use `INSERT ... RETURNING` there.
- **Five storage classes.** NULL, INTEGER, REAL, TEXT and BLOB ([Datatypes In SQLite](https://www.sqlite.org/datatype3.html)). Dates, UUIDs, decimals and JSON are stored as one of them, and the type extensions convert them.

## Design notes

### Cancellation through the progress handler

xqlite cancels through SQLite's progress handler, not `sqlite3_interrupt()`. An interrupt stops every statement running on the connection, and also a statement that starts while another is still running, and it needs the connection handle ([sqlite3_interrupt](https://www.sqlite.org/c3ref/interrupt.html)). A cancel token stops only the calls it was handed, and any process can signal it without the connection. SQLite runs the handler at certain jumps in a statement and at the end of each step, not on a clock. The [Gotchas](guides/gotchas.md#a-write-cancelled-while-it-runs-rolls-back-the-whole-transaction) guide says exactly when, and what a cancelled write rolls back.

### Backup is one call, not a handle

`Xqlite.backup/3` copies a database to a file in one step, inside one read transaction, so a commit from another connection cannot restart it. `Xqlite.backup_with_progress/4` copies in steps of `pages_per_step` pages, reports each step to a process, and checks its cancel tokens between steps. Under a steady writer, a stepped copy can start over: SQLite restarts it from the first page whenever another connection commits between two steps, and `pages_per_step: 2_147_483_647` copies in one step.

Both functions run the whole copy inside one call on a dirty I/O scheduler, and open the destination file themselves. SQLite's backup API needs the source and the destination open at the same time. Taking a file path means a backup never needs a second connection from your pool, and leaves no handle for you to close.

### Affected row counts

`Xqlite.query/4` and `Xqlite.execute/4` return two counts in `%Xqlite.Result{}`: `num_rows`, the rows the statement returned, and `changes`, the rows it inserted, updated or deleted. xqlite reads `changes` in the same hold of the connection lock as the statement, and reports it only when SQLite's total change count moved, so `SELECT`, DDL and PRAGMA statements report 0.

SQLite's own count is sticky: "Executing any other type of SQL statement does not modify the value returned by these functions" ([sqlite3_changes](https://www.sqlite.org/c3ref/changes.html)). `Xqlite.changes/1` reads that count, so after a `SELECT` it still reports the previous write's rows.

Two kinds of DDL do report a count. With `foreign_keys` on, a `DROP TABLE` that SQLite runs a `DELETE` for first (a table a foreign key references, or one with a deferred foreign key of its own while a deferred violation is pending) reports the rows of that `DELETE`. A `CREATE VIRTUAL TABLE` whose module writes rows into its own tables while it creates them, such as `rtree` and `fts5`, reports 1.

## Roadmap

Planned, in priority order:

1. **SQLCipher support**, optional, for databases encrypted at rest.
2. **Deeper SpatiaLite support** than the [SpatiaLite](guides/spatialite.md) guide gives, if users ask for it: a way to bundle SpatiaLite, and type extensions for geometry.
3. **[xqlite_ecto3](https://github.com/dimitarvp/xqlite_ecto3)**, a full Ecto 3 adapter with `DBConnection`, migrations, associations, streaming and the same structured errors.

## Acknowledgements

xqlite is inspired by [exqlite](https://github.com/elixir-sqlite/exqlite), which showed how an Elixir binding to SQLite is shaped. xqlite exists to reach more of SQLite's features, not to compete: per-operation cancellation, structured constraint errors, change capture with sessions, incremental blob I/O, backup with progress and more. If exqlite covers what you need, it is a solid choice.

## Contributing

Issues and pull requests are welcome.

## License

MIT. See [LICENSE.md](LICENSE.md).
