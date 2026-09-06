# ARCHITECTURE

A map of the code as it stands. `lib/` is Elixir; `native/xqlitenif/src/`
is a Rust crate compiled into a NIF library by Rustler, talking to a
statically linked SQLite through rusqlite. `XqliteNIF` holds nothing but
97 raw NIF stub declarations (every body is `err()`, replaced at load
time by the native function); `Xqlite` wraps most of them with option
validation, result structs and telemetry.

## 1. Module map

Elixir paths are relative to `lib/`, Rust paths to
`native/xqlitenif/src/`.

- `xqlite.ex` — the high-level API: open/close, `query/4`, `execute/4`,
  `stream/4`, the prepared-statement calls, transactions and savepoints,
  the busy policy and observers, `register_progress_hook/3`,
  cancellation, backup/serialize, PRAGMA get/set, schema introspection,
  STRICT-table helpers. It has no wrapper for the update / WAL / commit /
  rollback / log hooks — those are called on `XqliteNIF` directly.
- `xqlite/xqlitenif.ex` — the 97 stubs plus `use RustlerPrecompiled`.
- `xqlite/result.ex`, `explain_analyze.ex` — result structs with
  `from_map/1`; `Result` also implements `Table.Reader`.
  `xqlite/stream_resource_callbacks.ex` and `stream_error.ex` hold the
  `Stream.resource/3` callbacks and the exception they raise;
  `xqlite/pragma.ex` and `pragma_spec.ex` hold 57 typed PRAGMAs with
  `get/4`, `put/4`, validation and per-schema targeting.
- `xqlite/type_extension.ex` and `type_extension/*.ex` — the
  `encode/1` / `decode/1` behaviour, the chain runners, and nine
  built-ins (`Date`, `DateTime`, `NaiveDateTime`, `Time`, `JSON`, `UUID`
  both ways; `Instant`, `Duration`, `Decimal` encode only).
- `xqlite/telemetry.ex`, `telemetry/bridge.ex`,
  `telemetry/open_telemetry.ex` — the compile-gated macros and
  `enabled?/0`, the GenServer re-emitting hook deliveries as
  `[:xqlite, :hook, :*]`, and a dependency-free map to OpenTelemetry
  attribute names.
- `xqlite/schema/*.ex` — the six structs the Rust side builds, plus
  `Types`; `mix/tasks/verify.ex` and `test_seq.ex` — the pre-commit gate
  (cargo runs with cwd set to the crate directory) and the test runner.
- `lib.rs` — atoms, module list, `rustler::init!`; `nif.rs` — all 97
  `#[rustler::nif]` functions, 92 of them `DirtyIo`; `connection.rs` —
  the `XqliteConn` resource (a `Mutex<Option<Connection>>`, the child
  registry, and every hook slot), `with_conn`, `with_conn_mut`,
  open/close, result encoding.
- `statement.rs`, `stream.rs`, `blob.rs` — the three raw-pointer
  resources (a shared `AtomicPtr` plus `with_live_*`),
  `take_and_finalize_raw`, `process_single_step`, the raw binders.
- `session.rs`, `cancel.rs` — `XqliteSession` with its
  leak-rather-than-dangle `close`; `XqliteCancelToken` with the RAII
  `ProgressHandlerGuard`.
- `hook_util.rs` — term helpers, the single-slot `AtomicPtr` lifecycle,
  the copy-on-write `HookList<T>`, `guard_ffi_callback`.
- `progress_dispatch.rs`, `busy_handler.rs`, `wal_hook.rs` — the three
  raw C callbacks: progress ticks and cancel checks, the busy slot, the
  WAL fan-out plus emulated checkpoint.
- `update_hook.rs`, `commit_hook.rs`, `rollback_hook.rs`, `log_hook.rs` —
  master closures installed once, fanning out to a `HookList`; the log
  one is process-wide, installed on the first register, and guards its
  `static` list with a mutex.
- `authorizer.rs` — the deny-list closure; `query.rs` — the four `core_*`
  entry points and the two input checks that reject bad SQL; `util.rs` —
  term to `rusqlite::Value` conversion both ways, row encoding,
  identifier quoting, `singular_ok_or_error_tuple`;
  `error.rs` and `constraint_parse.rs` —
  `XqliteError` (43 variants) with `classify_sqlite_error`, and the
  constraint message-text parser.
- `schema.rs`, `explain_analyze.rs`, `pragma.rs`, `transaction.rs` — the
  schema structs, their PRAGMA readers and the column-default
  classifier; the scanstatus and plan collector; PRAGMA name validation;
  the transaction and savepoint SQL, names quoted.

## 2. Data flows

### 2.1 A query

`xqlite.ex:query/4` → `TypeExtension.encode_params/2` → a
`[:xqlite, :query]` span → `nif.rs:query_with_changes` (dirty I/O) →
`connection.rs:with_conn`, which locks the `Mutex` and proves the inner
`Option<Connection>` is `Some`, else `ConnectionClosed` →
`query.rs:core_query_with_changes`, which brackets `core_query` with two
`conn.total_changes()` reads. `core_query` runs `reject_interior_nul`,
prepares, runs `reject_no_statement`, then binds: an empty list binds
nothing, a keyword list goes through
`util.rs:decode_exec_keyword_params` (each atom key gains a leading `:`),
any other list through `decode_plain_list_params`, `nil` means none,
anything else is `ExpectedList`. `util.rs:process_rows` encodes each
value with `encode_val` → `encode_f64` / `encode_text` / `encode_blob`.
`nif.rs:encode_query_result_with_changes` builds the map, the Mutex
releases, and `query/4` builds `%Xqlite.Result{}` and runs
`decode_result_rows/2`. `execute/4` is the same path through
`core_execute`, with the affected count in `Result.changes` and no rows.

### 2.2 Prepared statements

`nif.rs:stmt_prepare` calls `sqlite3_prepare_v2` under `with_conn`,
routing failures through `error.rs:prepare_failure` and snapshotting
column names into the resource. Every later call goes through
`statement.rs:with_live_stmt`, which locks the connection *before*
loading the `AtomicPtr` — that order makes a concurrent finalize safe,
because the finalizer can null the pointer at any moment but cannot call
`sqlite3_finalize` without the same Mutex. Stepping goes through
`stream.rs:process_single_step`, which reads the column count *after* the
step so automatic re-prepare is reflected. `stmt_finalize` and `Drop`
both call `stream.rs:take_and_finalize_raw`: take the connection lock,
swap the shared pointer cell to null, finalize, drop the connection's
registry entry, discard the return code.

### 2.3 Streams

`xqlite.ex:stream/4` → `stream_resource_callbacks.ex:start_fun/1`
(validate `:on_error` and `:cancel_tokens`, `nif.rs:stream_open`,
`stream_get_columns`, closing the handle if that fails) → `next_fun/1` →
`nif.rs:stream_fetch_cancellable`, which locks the connection once and
steps up to `batch_size` rows in a single hold, growing the row vector on
demand because pre-sizing to an unvalidated `batch_size` could abort the
VM. On exhaustion or error it swaps the pointer to null and finalizes
there and then, replying `:done` or `{:error, reason}`. `next_fun/1` maps
rows to `%{column => value}` after `TypeExtension.decode_rows/2` and
shapes each element per `:on_error`; `after_fun/1` calls the idempotent
`stream_close`. `stream_open` compiles through
`statement.rs:prepare_one`, so SQL holding no statement and SQL holding a
second one are refused at open rather than becoming an empty stream or a
stream over the first statement alone. `build_acc/5` keeps the connection
and the wrapped `:cancel_tokens` in the accumulator, so every fetch
carries the same token list; an empty list makes the cancellable fetch
byte-for-byte the plain one.

### 2.4 Hooks and callbacks

A per-connection master callback is installed exactly once, in
`connection.rs:handle_open_result`, and stays for the connection's life;
`register_*` / `unregister_*` only mutate a `hook_util.rs:HookList<T>`,
which is copy-on-write — writers clone the `Vec` and atomic-swap under
the connection Mutex, the C callback reads one atomic load. The update,
commit and rollback hooks use rusqlite's safe closure API, and the commit
closure always returns `false`, never vetoing. `wal_hook.rs` and
`progress_dispatch.rs` register raw `sqlite3_*` callbacks, since
rusqlite's wrappers cannot carry the state they need, and both run inside
`hook_util.rs:guard_ffi_callback` so a panic returns a neutral value
instead of unwinding into C. Each callback sends with `enif_send` on a
fresh `msg_env`, frees it unconditionally, and rebuilds atoms there.
`log_hook.rs` is process-wide (`sqlite3_config`), so no connection Mutex
is held when it fires; its `static MASTER_LOCK` is taken by the callback
as well as by register/unregister, or the lock-free read would race the
free of the old subscriber vector.

### 2.5 Cancellation

`nif.rs:create_cancel_token` returns a resource holding an
`Arc<AtomicBool>`; `cancel_operation` stores `true` and nothing resets
it. A `*_cancellable` NIF builds a `cancel.rs:ProgressHandlerGuard`
inside the `with_conn` closure — one `CancelSubscriber` per token onto
`progress_dispatch.cancels`, each owning `Arc` held so the raw
`*const AtomicBool` stays valid while reachable. The progress C callback,
installed at open time, fires every `PROGRESS_NUM_OPS` = 8 SQLite VM
instructions, walks `cancels` first, and returns 1 if any flag is set;
SQLite aborts with `SQLITE_INTERRUPT`, which
`error.rs:classify_sqlite_error` maps to `{:error, :operation_cancelled}`.
Dropping the guard unregisters before releasing the `Arc`s. Tick
subscribers share the callback, each with its own counter.

`nif.rs:stream_fetch_impl` is the one that does not use `with_conn`: it
declares the guard after its own connection lock guard and after the
connection is proved open, so reverse declaration order drops the guard
while the Mutex is still held. A cancelled fetch goes through the same
`Err` arm as any other fetch error — swap the pointer, finalize, return —
so the stream is closed and `next_fun/1` emits
`[:xqlite, :cancel, :honored]` with `operation: :stream_fetch` before
routing `{:error, :operation_cancelled}` through the `:on_error` mode.

### 2.6 The remaining flows

The busy slot, the WAL slot, error classification and the telemetry gate
are stated in full as facts in section 4. `nif.rs:backup` and `restore`
are one-shot rusqlite calls under the connection lock;
`backup_with_progress` loops `Backup::step`, checking every cancel token
between steps. `serialize` copies the image into an `OwnedBinary`;
`deserialize` needs `with_conn_mut`. A session is a `Session<'static>`
produced by transmuting away the connection borrow, kept sound by the
`ResourceArc<XqliteConn>` the resource also holds, and every
`sqlite3session_*` call takes the connection Mutex first, the per-session
Mutex second. Two facts live only here: `span_with_stop_metadata` treats
its block's last element as **stop metadata**, so `:stop` measurements
are always just `%{duration, monotonic_time}` and every extra a call
records arrives in the metadata map; and `Xqlite.Telemetry.run_span/3`
emits the three span events itself instead of calling
`:telemetry.span/3`, whose measurements are in the VM's native time
unit while every xqlite measurement is a nanosecond count.

## 3. State machines

### Connection (`connection.rs`)

| State | Event | Next | Function |
|---|---|---|---|
| — | any `open*` NIF | open | `handle_open_result` |
| open | any NIF | open | `with_conn` / `with_conn_mut` |
| open | `close` | closed | `close_connection`: drain the child registry, then `Option::take` |
| closed | `close` | closed | `close_connection` → `:ok` |
| closed | anything else | closed | `{:error, :connection_closed}` |

`XqliteConn.children` holds one shared pointer cell per prepared
statement, stream and blob xqlite opened on the connection.
`close_connection` finalizes them all under the connection `Mutex` before
dropping the `Connection`, so `sqlite3_close` frees the handle instead of
answering `SQLITE_BUSY`. Statements a virtual-table module owns are not in
the registry — SQLite disconnects those itself during close. A session
registers nothing and is still leaked by an explicit close.

### Prepared statement (`statement.rs`)

| State | Event | Next | Function |
|---|---|---|---|
| — | `stmt_prepare` | live | `nif.rs:stmt_prepare` |
| live | bind / reset / clear | live | `with_live_stmt` |
| live | `stmt_step` → `{:row, _}` | live | `process_single_step` |
| live | `stmt_step` → `:done` | live | auto-resets on next step |
| live | `stmt_finalize` or GC | final | `take_and_finalize_raw` |
| live | the connection is closed | final | `close_connection` drains the registry |
| final | any step or bind | final | `{:error, :statement_finalized}` |
| final | `stmt_column_names` | final | prepare-time snapshot |
| final | `stmt_finalize` | final | `:ok` |

### Stream (`stream.rs`, `stream_resource_callbacks.ex`)

| State | Event | Next | Function |
|---|---|---|---|
| — | `stream_open` | open | `nif.rs:stream_open` |
| — | `stream_open` with no statement, or with a second one | — | refused by `statement.rs:prepare_one`, no handle |
| open | `stream_fetch` → rows | open | `nif.rs:stream_fetch` |
| open | `stream_fetch` exhausts | closed | swap + finalize in place |
| open | `stream_fetch` errors | closed | swap + finalize, then error |
| open | `stream_fetch_cancellable` with a signalled token | closed | swap + finalize, then `{:error, :operation_cancelled}` |
| any | `stream_close` or GC | closed | `take_and_finalize_atomic_stmt` |
| open | the connection is closed | closed | `close_connection` drains the registry |
| closed | `stream_fetch` | closed | `:done` |

`stream_fetch` proves the connection open before it reads the statement
pointer: after a close both are gone, and the caller must still hear
`{:error, :connection_closed}` rather than `:done`.

The busy slot's own transitions are in section 4
(`busy-slot-policy-single-observers-many` and
`busy-slot-restores-displaced-timeout`): the slot moves between empty,
policy, observers and both, restoring the displaced `busy_timeout` on
every transition into empty and recording the current one on the way out.

Blobs share the stream's two-state shape, closing on the connection's
close as well; a session does not, and an explicit close leaks it. A poisoned
`Mutex` is terminal everywhere: `{:error, {:lock_error, _}}`.
`nif.rs:txn_state` maps rusqlite's `TransactionState` to `:none`,
`:read`, `:write`, or `:unknown`; `transaction_status/1` and
`autocommit/1` are its two boolean views.

## 4. Shared facts with consumers

Facts more than one place in the tree relies on. For every row, the full
consumer list and the `rg` / `ast-grep` patterns that regenerate it live
in the review registry, in the workdir that `AGENTS.md` names. Paths
below are relative: Elixir to `lib/`, Rust to `native/xqlitenif/src/`,
pins to `test/`.

| id | statement | producer | pin |
|---|---|---|---|
| `changes-reported-on-total-delta` | `query_with_changes` reports `sqlite3_changes()` only when `sqlite3_total_changes()` moved across the statement, else 0; the counter itself is sticky across SELECT, DDL and PRAGMA. | `query.rs:core_query_with_changes` | `nif/query_with_changes_test.exs: "DDL after DML returns changes 0 (no sticky leak)"` |
| `conn-mutex-covers-every-sqlite-call` | Every `sqlite3_*` C call holds the connection `Mutex` for its whole duration; an `AtomicPtr` swap gives pointer ownership, not connection access. | `connection.rs:with_conn` | unpinned |
| `cancel-check-every-8-vm-ops` | The progress handler fires every 8 SQLite VM instructions; that is both the cancellation-latency bound and the unit `every_n` counts. | `progress_dispatch.rs:PROGRESS_NUM_OPS` | unpinned |
| `cancel-token-single-use` | A token's flag is set once and never reset; a cancellable call takes a list and any set token aborts it. A stream hands its `:cancel_tokens` to every fetch, so a signalled token ends that stream and every later stream it is handed to. | `cancel.rs:XqliteCancelToken::cancel` | `nif/statement_cancel_test.exs: "an already-signalled token cancels before any stepping"`, `nif/stream_cancel_test.exs: "after a cancel the connection is clean and the token stays spent"` |
| `wal-hook-and-autocheckpoint-share-one-slot` | Holding the WAL hook disables SQLite's autocheckpoint, so the master callback checkpoints itself from a threshold starting at SQLite's own 1000 pages; `set_pragma` reinstalls the callback and `get_pragma` reports the emulated value. | `wal_hook.rs:wal_hook_callback`, `DEFAULT_WAL_AUTOCHECKPOINT_PAGES` | `nif/wal_hook_test.exs: "emulated autocheckpoint defaults to SQLite's stock 1000 pages"` |
| `busy-slot-policy-single-observers-many` | One retry policy (replaced on re-set) and any number of observer pids share one C callback; observers fire with or without a policy. | `busy_handler.rs:BusySlotState` | `nif/busy_handler_test.exs: "re-setting the policy replaces the previous one"` |
| `busy-slot-restores-displaced-timeout` | Taking the slot records the current `busy_timeout` and emptying it puts that back; a policy-less slot emulates the timeout with SQLite's own delay schedule. | `busy_handler.rs:swap_in` | `nif/busy_handler_test.exs: "unregistering the last observer restores the busy_timeout"` |
| `busy-timeout-fits-c-int` | A `busy_timeout` above `c_int::MAX` (2 147 483 647 ms) is refused with `{:cannot_execute, reason}`, never clamped. | `busy_handler.rs:busy_timeout_c_int` | `nif/busy_handler_test.exs: "busy_timeout refuses a value past SQLite's 32-bit limit"` |
| `raw-pragma-busy-timeout-steals-the-slot` | `PRAGMA busy_timeout = N` run as SQL, or through `XqliteNIF.set_pragma/3`, puts SQLite's own handler in the busy slot and silently disables the policy and every observer. | `busy_handler.rs:swap_in`, `pragma.rs:set` | unpinned |
| `extended-code-masking` | Classification masks the extended code with `& 0xFF` and compares against SQLite's C constants, because rusqlite's `ErrorCode` values differ from them. | `error.rs:classify_sqlite_error` | unpinned |
| `error-shapes-per-class` | Each class has one Elixir shape: bare atoms for lifecycle and input errors; `{tag, extended_code, message}` for busy/locked, read-only, schema-changed and authorization-denied; `{:constraint_violation, kind, details}`; the fallback `{:sqlite_failure, code, extended_code, message}`; and `{:sql_input_error, %{code, message, sql, offset}}` when a `SqlInputError` would otherwise classify generically. | `error.rs` `impl Encoder for XqliteError` | `nif/authorizer_test.exs: "denying :delete blocks DELETE but leaves SELECT working"` |
| `constraint-details-map` | A constraint violation carries `%{message, table, columns, index_name, constraint_name, source_type, target_type}`, `nil` for whatever the message did not name. | `constraint_parse.rs:parse_details` | `strict_table_test.exs: "converts clean table to STRICT"` |
| `message-text-parsing-is-confined` | Classification reads message text in exactly two places: `constraint_parse.rs`, and the four name-prefix arms in `classify_sqlite_error`. | `error.rs:classify_sqlite_error` | `nif/execution_test.exs: "execute/3 returns error for NoSuchTable on INSERT"` |
| `hook-message-shapes` | Subscribers receive eight tuples: `{:xqlite_update, action, db, table, rowid}`, `{:xqlite_wal, db_name, pages}`, `{:xqlite_commit}`, `{:xqlite_rollback}`, `{:xqlite_busy, retries, elapsed_ms}`, `{:xqlite_progress, count, elapsed_ms}` (or with a `tag` second), `{:xqlite_log, code, message}`, `{:xqlite_backup_progress, remaining, pagecount}`. The telemetry bridge re-emits the first seven; backup progress is not bridged. | the `send_*_to_pid` of each hook module, `nif.rs:send_backup_progress` | `nif/update_hook_test.exs: "delivers {:xqlite_update, :insert, ...} on INSERT"` |
| `hook-handles-are-opaque-and-idempotent` | `register_*` returns a `u64` handle unique within its own list; unregistering an unknown or repeated handle is a no-op that still answers `:ok`. | `hook_util.rs:HookList::register` / `unregister` | `nif/wal_hook_test.exs: "register / unregister returns handle and is idempotent"` |
| `type-extension-chain-first-match-wins` | `encode/1` and `decode/1` answer `{:ok, value}` or `:skip`; the chain runs in list order, the first `{:ok, _}` wins and the rest are not consulted, unmatched values pass through unchanged. | `type_extension.ex:encode_value/2` and `decode_value/2` | `type_extension_test.exs: "first matching extension wins"` |
| `default-value-classification` | A column default arrives as `:none`, `{:literal, v}`, `{:blob, bytes}`, `{:current, :time \| :date \| :timestamp}` or `{:expr, sql}`; nothing is constant-folded, and an integer past 64 bits or a non-finite float falls back to `{:expr, _}`. | `schema.rs:classify_default` | `schema_default_value_test.exs: "the full default-value matrix classifies as designed"`, plus the grammar property in `schema_default_value_property_test.exs` |
| `non-finite-floats-become-atoms` | A REAL that is not finite reads back as `:positive_infinity` or `:negative_infinity`, and NaN as `nil`, because the BEAM cannot hold a non-finite double. | `util.rs:encode_f64` | `nif/query_test.exs: "query/3 reads non-finite floats as sentinel atoms and stays usable"` |
| `blob-encoding-threshold-64-bytes` | On the query path a BLOB over 64 bytes comes back as a zero-copy resource binary and one of 64 bytes or fewer is copied onto the process heap; the stream and `blob_read` paths always copy. | `util.rs:HEAP_BINARY_THRESHOLD` and `encode_blob` | unpinned |
| `sql-input-rejections` | SQL is refused, never truncated or half-run: an interior NUL byte is `:null_byte_in_string` on every entry point; on query, execute, prepare, stream and explain_analyze, SQL holding no statement (empty, whitespace, comments, bare semicolons) is `{:cannot_execute, "SQL contains no statement"}` and a second statement after the first is `:multiple_statements`. Text after the first statement counts as a second statement only when re-compiling it yields one, so a trailing comment, extra semicolons and whitespace are accepted. | `query.rs:reject_interior_nul`, `reject_no_statement`, `statement.rs:prepare_one` | `nif/prepare_tail_law_test.exs: "the four prepare paths classify one SQL string identically"`, `nif/error_input_test.exs: "interior NUL in SQL text is rejected on query/execute/execute_batch"` |
| `batch-size-and-step-count-floors` | A batch size below 1 is `{:invalid_batch_size, %{provided: v, minimum: 1}}`, `every_n` below 1 is `{:cannot_execute, _}`, `pages_per_step` below 1 is `{:invalid_pages_per_step, v}`; none is clamped. The two `:invalid_batch_size` sites disagree on `provided`: `stmt_multi_step_impl` puts the bare integer, `stream_fetch_impl` a tagged pair such as `{:integer, 0}`. | `nif.rs:stmt_multi_step_impl`, `stream_fetch_impl`, `register_progress_hook`, `backup_with_progress` | `nif/statement_test.exs: "multi_step rejects a batch size below one"`, with one twin per floor in `nif/stream_test.exs`, `nif/progress_hook_test.exs` and `nif/backup_progress_test.exs` |
| `stream-on-error-modes` | `:raise` (the default) yields row maps and raises `Xqlite.StreamError`; `:halt` yields row maps, logs the reason and stops; `:emit_error` yields `{:ok, row}` then one terminal `{:error, reason}`; anything else is `{:error, {:invalid_on_error, value}}` at open. | `stream_resource_callbacks.ex:validate_on_error/1` and `handle_fetch_error/2` | `xqlite_test.exs: "stream/4 rejects an unsupported :on_error mode at open"`, plus one test per mode there |
| `statement-column-names-fall-back-after-finalize` | `stmt_column_names` reads live column metadata so automatic re-prepare is reflected, and serves the prepare-time snapshot only once the statement is finalized or the connection closed. | `nif.rs:stmt_column_names` | `nif/statement_test.exs: "operations after finalize report :statement_finalized; names stay cached"` |
| `authorizer-validates-the-whole-list-first` | An unrecognised action atom returns `{:invalid_authorizer_action, atom}` and installs nothing; the authorizer is one slot that a second call replaces. | `authorizer.rs:parse_denied` | `nif/authorizer_test.exs: "unrecognized atom is a structured error and installs nothing"` |
| `telemetry-is-compile-time-gated` | `:telemetry_enabled` is read at compile time and defaults to false: `enabled?/0` is a constant, the macros then expand to no `:telemetry` call at all, and both bridge constructors answer `{:error, :telemetry_disabled}`. | `xqlite/telemetry.ex` `@enabled` | `telemetry_test.exs: "enabled?/0 reflects the compile_env value"` |
| `result-struct-and-table-reader` | `%Xqlite.Result{}` carries `columns`, `rows`, `num_rows` and `changes`, and implements `Table.Reader` as `{:rows, %{columns: _, count: _}, rows}`. | `xqlite/result.ex` | `result_test.exs: "Table.Reader returns rows with metadata"` |
| `open-applies-a-fixed-pragma-set` | `open/2` and `open_in_memory/1` validate options against one NimbleOptions schema, then apply exactly the nine PRAGMAs of `@pragma_order` with `busy_timeout` first; an unknown key is `{:invalid_open_option, %{reason: :unknown_key, ...}}`, and the read-only and temporary openers apply none. | `xqlite.ex:apply_pragmas/2` and `@pragma_order` | `open_opts_test.exs: "rejects unknown option"`, plus one test per applied PRAGMA; the order itself is unpinned |
| `db-path-is-nil-without-a-file` | In-memory and temporary databases report `{:ok, nil}`; SQLite's empty filename is normalised away. | `nif.rs:db_path` | `nif/connection_test.exs: "db_path returns nil (no backing file)"` |
| `api-armor-and-threadsafe-are-compiled-in` | The bundled SQLite always reports `ENABLE_API_ARMOR` and a `THREADSAFE=` entry in `PRAGMA compile_options`. | `libsqlite3-sys`'s bundled build (section 5) | `nif/connection_test.exs: "compile_options returns known flags"` |
| `bare-ok-shares-one-encoder` | Every NIF whose success carries no value encodes its result through one helper, so success is the bare atom `:ok`, never `{:ok, _}`, and failure is `{:error, reason}` from the same reason set. | `util.rs:singular_ok_or_error_tuple` | `nif/connection_test.exs: "close is idempotent"` |
| `identifiers-are-double-quoted` | Identifiers that reach SQL as text are wrapped in double quotes with embedded double quotes doubled, by `quote_identifier` in Rust and `Xqlite.Pragma.quote_name/1` in Elixir; string values are bound as parameters, or, where SQL forbids a parameter (PRAGMA), quoted with the quote doubled by `Xqlite.Pragma.format_pragma_value/1`. | `util.rs:quote_identifier`, `xqlite/pragma.ex:quote_name/1` | `nif/transaction_test.exs: "isolated: savepoint with double quotes in name"` |
| `strict-rebuild-renames-by-token` | `enable_strict_table/2` rewrites the stored `CREATE TABLE` statement by its own name token, whatever its quoting style (double quotes, backticks, brackets, bare), and never compiles the caller's name into a pattern. | `xqlite.ex:rebuild_as_strict/3` | `strict_table_test.exs: "a table stored double-quoted converts"` |

## 5. Build facts

- **SQLite compile flags.** `native/xqlitenif/.cargo/config.toml` sets
  `LIBSQLITE3_FLAGS = "-DSQLITE_ENABLE_STMT_SCANSTATUS=1"`, without which
  `sqlite3_stmt_scanstatus_v2` returns `SQLITE_MISUSE` and
  `Xqlite.explain_analyze/3` has nothing to report. Everything else comes
  from `libsqlite3-sys`'s bundled build, which always passes
  `-DSQLITE_ENABLE_API_ARMOR`, `-DSQLITE_THREADSAFE=1`,
  `-DSQLITE_DEFAULT_FOREIGN_KEYS=1`, `-DSQLITE_ENABLE_FTS5`,
  `-DSQLITE_ENABLE_RTREE`, `-DSQLITE_ENABLE_STAT4`,
  `-DSQLITE_ENABLE_COLUMN_METADATA`, `-DSQLITE_ENABLE_DBSTAT_VTAB` and
  more; the `session` cargo feature adds `-DSQLITE_ENABLE_SESSION` and
  `-DSQLITE_ENABLE_PREUPDATE_HOOK`. Nothing here can turn API_ARMOR off.
- **Cargo must run from the crate directory,** because it finds
  `.cargo/config.toml` only by walking up from its working directory;
  `--manifest-path` from the repo root loses `LIBSQLITE3_FLAGS`, so
  `lib/mix/tasks/verify.ex:run_cargo/1` sets `cd: "native/xqlitenif"`.
- **Threading.** `SQLITE_THREADSAFE=1` is the compiled mode, but rusqlite
  opens every connection with `SQLITE_OPEN_NO_MUTEX`, so the Rust
  `Mutex<Connection>` is the only serialization. The two are
  complementary: `rusqlite::Connection` is `!Sync`, so the Rust `Mutex`
  is required by the type system anyway, and NO_MUTEX is safe *because*
  it is there. `open_readonly` and `open_in_memory_readonly` pass
  NO_MUTEX explicitly; the rest inherit it from `OpenFlags::default()`.
- **Rustler and NIF versions.** `Cargo.toml` declares the cargo features
  `nif_version_2_15` / `2_16` / `2_17`, defaulting to `2_17`, and sets
  `lto = true` with `codegen-units = 1` for release builds; the Rust
  edition and toolchain floor live there too.
  `lib/xqlite/xqlitenif.ex` declares `nif_versions: ["2.17"]` and the
  eight precompiled targets, and drives `force_build:` off the
  `XQLITE_BUILD` environment variable.
- **Telemetry flag.** `lib/xqlite/telemetry.ex` reads
  `Application.compile_env(:xqlite, :telemetry_enabled, false)` — a
  compile-time value, so changing it needs
  `mix deps.compile xqlite --force`. **Warnings as errors:** `mix.exs`
  sets `elixirc_options: [warnings_as_errors: true]` for `lib/`, and the
  `test:` alias appends `--warnings-as-errors`, which `mix test.seq`
  inherits when it shells out to `mix test` per file.
