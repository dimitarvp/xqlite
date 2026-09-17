# ARCHITECTURE

A map of the code as it stands. `lib/` is Elixir; `native/xqlitenif/src/`
is a Rust crate compiled into a NIF library by Rustler, talking to a
statically linked SQLite through rusqlite. `XqliteNIF` holds nothing but
99 raw NIF stub declarations (every body is `err()`, replaced at load
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
- `xqlite/xqlitenif.ex` — the 99 stubs plus `use RustlerPrecompiled`.
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
- `lib.rs` — atoms, module list, `rustler::init!`; `nif.rs` — all 99
  `#[rustler::nif]` functions, 93 of them `DirtyIo`; `connection.rs` —
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
- `authorizer.rs` — the one authorizer closure, holding the caller's
  deny-list plus the busy slot's own two rules; `query.rs` — the four `core_*`
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

`xqlite.ex:query/4` → a `[:xqlite, :query]` span →
`TypeExtension.encode_params/2`, whose refusal ends the call inside the
span → `nif.rs:query_with_changes` (dirty I/O) →
`connection.rs:with_conn`, which locks the `Mutex` and proves the inner
`Option<Connection>` is `Some`, else `ConnectionClosed` →
`query.rs:core_query_with_changes`, which brackets `core_query` with two
`conn.total_changes()` reads. `core_query` runs `reject_interior_nul`,
prepares, runs `reject_no_statement`, then binds: an empty list binds
nothing, a keyword list goes through
`util.rs:decode_exec_keyword_params` (each atom key gains a leading `:`),
any other list through `decode_plain_list_params`, `nil` means none,
anything else is `ExpectedList`. Both hand each value to
`util.rs:elixir_term_to_rusqlite_value`, where a binary becomes `Text`
when its bytes are valid UTF-8 and `Blob` otherwise, and a map that is an
`%Xqlite.Blob{}` becomes `Blob` whatever its bytes are — any other map,
and `bytes` holding anything but a binary, is refused.
`util.rs:process_rows` encodes each
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
there and then, replying `:done` or `{:error, reason}` — except that an
error other than a cancellation, after rows were already read, hands those
rows back now and keeps the error for the next fetch. `next_fun/1` maps
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
| open | `close` | closed | `close_connection`: drain the child registry, then `free_handle` closes through `Connection::close()`; a refused close puts the connection back |
| closed | `close` | closed | `close_connection` → `:ok \| {:error, {:database_busy_or_locked, _, _}} \| {:error, {:lock_error, _}}` |
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
| open | `stream_fetch` errors with no row of that batch read | closed | swap + finalize, then error |
| open | `stream_fetch` errors after reading rows | closed, error held | swap + finalize, hand back the rows, keep the error in `XqliteStream.pending_error` |
| closed, error held | `stream_fetch` | closed | answer the held error and empty the slot, before any step |
| open | `stream_fetch_cancellable` with a signalled token | closed | swap + finalize, discard the batch's rows, then `{:error, :operation_cancelled}` |
| any | `stream_close` or GC | closed | `take_and_finalize_atomic_stmt`, which empties the held error first |
| open | the connection is closed | closed | `close_connection` drains the registry |
| closed | `stream_fetch` | closed | `:done` |

`stream_fetch` proves the connection open before it reads the statement
pointer: after a close both are gone, and the caller must still hear
`{:error, :connection_closed}` rather than `:done`. It then looks for a
held error, before the batch loop — a finalized statement's null pointer
would otherwise answer `:done` and the stream would look complete.

The busy slot's own transitions are in section 4
(`busy-slot-policy-single-observers-many` and
`busy-slot-restores-displaced-timeout`): the slot moves between empty,
policy, observers and both, restoring the displaced `busy_timeout` on
every transition into empty and recording the current one on the way out.
Both edges also re-install the connection's authorizer, since the held
slot adds rules of its own; a take that then fails puts the flag back and
re-installs again.

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
| `conn-mutex-covers-every-sqlite-call` | Every sqlite3_* C call runs with the connection Mutex held for its whole duration; an AtomicPtr swap gives pointer ownership, never connection access. The cancel-token guard a fetch registers is dropped before the connection lock is released, because the hook list frees the old subscriber vector right after its atomic swap while the C progress callback reads that vector without a lock. | `connection.rs:with_conn` | unpinned |
| `cancel-check-every-8-vm-ops` | The progress handler fires every 8 SQLite VM instructions, which bounds cancellation latency and sets the unit that a progress hook's every_n counts. | `progress_dispatch.rs:PROGRESS_NUM_OPS` | `nif/stream_cancel_test.exs: "a table scan reports the cancel within three single-row fetches"` |
| `cancel-token-single-use` | A token's flag is set once and never reset; a cancellable call takes a list and any set token aborts it. A stream hands its `:cancel_tokens` to every fetch, so a signalled token ends that stream and every later stream it is handed to. | `cancel.rs:XqliteCancelToken::cancel` | `nif/statement_cancel_test.exs: "an already-signalled token cancels before any stepping"`, `nif/stream_cancel_test.exs: "after a cancel the connection is clean and the token stays spent"` |
| `wal-hook-and-autocheckpoint-share-one-slot` | Holding the WAL hook disables SQLite's built-in autocheckpoint, so the master callback runs the passive checkpoint itself from a threshold that starts at SQLite's own default of 1000 pages; set_pragma reinstalls the callback and get_pragma reports the emulated threshold. Both comparisons match the pragma name without regard to ASCII case (eq_ignore_ascii_case), so a raw PRAGMA WAL_AUTOCHECKPOINT in any spelling is repaired and reported, not only the lower-case spelling. | `wal_hook.rs:wal_hook_callback`, `wal_hook.rs:DEFAULT_WAL_AUTOCHECKPOINT_PAGES` | `nif/wal_hook_test.exs: "emulated autocheckpoint defaults to SQLite's stock 1000 pages"` |
| `busy-slot-policy-single-observers-many` | One retry policy (replaced on re-set) and any number of observer pids share one C callback; observers fire with or without a policy. While either is installed the connection also carries an authorizer that rejects a `busy_timeout` write. | `busy_handler.rs:BusySlotState` | `nif/busy_handler_test.exs: "re-setting the policy replaces the previous one"` |
| `busy-slot-restores-displaced-timeout` | Taking the slot records the current `busy_timeout` and emptying it puts that back; a policy-less slot emulates the timeout with SQLite's own delay schedule. That read is xqlite's own and passes an authorizer denying `:pragma`; a read that fails takes nothing and answers the read's error. | `busy_handler.rs:swap_in`, `read_busy_timeout` | `nif/busy_handler_test.exs: "unregistering the last observer restores the busy_timeout"`, `"an observer registered under a :pragma deny keeps the connection's wait"` |
| `busy-timeout-fits-c-int` | A busy_timeout above c_int::MAX (2 147 483 647 ms) is refused with {:cannot_execute, reason}, never clamped, on busy_timeout/2, the open options and set_pragma/3; busy_timeout/2 refuses any term that is not a non-negative integer the same way, before anything reaches SQLite. | `busy_handler.rs:busy_timeout_c_int` | `nif/busy_handler_test.exs: "busy_timeout refuses a value past SQLite's 32-bit limit"` |
| `busy-timeout-write-refused-while-slot-held` | While the busy slot holds a policy or an observer, a statement writing `busy_timeout` — any spelling, `XqliteNIF.set_pragma/3` included — is rejected as it is prepared with `{:busy_timeout_write_refused, %{policy, observers}}`, never the generic authorization error; the read stays allowed and reads 0, and with the slot empty the write is accepted as before. | `authorizer.rs:decide`, `connection.rs:with_busy_timeout_rule` | `nif/busy_handler_test.exs: "a busy_timeout write is rejected in every spelling the slot is held for"` |
| `extended-code-masking` | Classification masks the extended code with `& 0xFF` and compares against SQLite's C constants, because rusqlite's `ErrorCode` values differ from them. | `error.rs:classify_sqlite_error` | unpinned |
| `error-shapes-per-class` | Each error class has a fixed Elixir shape: bare atoms for lifecycle and input errors (:connection_closed, :statement_finalized, :operation_cancelled, :multiple_statements, :null_byte_in_string); {tag, extended_code, message} for busy/locked, read-only, schema-changed and authorization-denied; {:constraint_violation, kind, details}; the catch-all {:sqlite_failure, code, extended_code, message}; and {:sql_input_error, %{code, message, sql, offset}} when a SqlInputError would otherwise classify generically.; {:busy_timeout_write_refused, %{policy, observers}} for xqlite's own authorizer rule. Also, made in Elixir, {:type_extension_refused, map}, {:read_only_pragma, atom}, {:invalid_pragma_value, map}, {:invalid_cancel_tokens, value}, {:unknown_pragma, the caller's atom or string}, {:invalid_pragma_name, a key that is neither}, {:not_a_plain_table, %{table, type}}, :transaction_in_progress and {:rowid_shadowed, name}; and, made in Rust, {:invalid_blob_bytes, %{position, type}}. {:unsupported_data_type, atom} names the term kind the binder cannot store, :bitstring for a bitstring that is not a whole number of bytes on the plain path as on the wrapper; {:invalid_cancel_tokens, value} is answered by every cancellable Xqlite door for a value that is not a live token or a list of them. Also made in Elixir: {:invalid_pragma_argument, %{pragma, value, reason}} from the pragma getters and {:invalid_hook_option, %{key, value, reason}} from register_progress_hook/3; a PRAGMA value handed to set_pragma answers :null_byte_in_string for a NUL byte, {:cannot_execute_pragma, name, reason} for bytes that are not UTF-8 and {:unsupported_data_type, :bitstring} for a partial bitstring. {:cannot_execute_pragma, name, reason} carries the bare pragma name in every arm. {:invalid_open_option, %{key: nil, reason: :not_a_pair, value}} answers an element of the options list that is not a {key, value} pair; options that are not a list at all raise from the openers' guards. | `error.rs:Encoder`, `error.rs:classify_sqlite_error` | `nif/authorizer_test.exs: "denying :delete blocks DELETE but leaves SELECT working"` |
| `constraint-details-map` | A constraint violation carries `%{message, table, columns, index_name, constraint_name, source_type, target_type}`, `nil` for whatever the message did not name. | `constraint_parse.rs:parse_details` | `strict_table_test.exs: "converts clean table to STRICT"` |
| `message-text-parsing-is-confined` | Classification reads SQLite message text in exactly two places: constraint_parse.rs, and the four name-prefix arms in classify_sqlite_error (no such table, no such index, table ... already exists, index ... already exists). The four arms only decide which prefix applies; the reading itself is done by three helpers beside them — strip_ascii_prefix, name_after and name_between — and name_between also strips the trailing " already exists". | `error.rs:classify_sqlite_error` | `nif/execution_test.exs: "execute/3 returns error for NoSuchTable on INSERT"` |
| `hook-message-shapes` | Subscribers receive eight tuple shapes: {:xqlite_update, action, db, table, rowid}, {:xqlite_wal, db_name, pages}, {:xqlite_commit}, {:xqlite_rollback}, {:xqlite_busy, retries, elapsed_ms}, {:xqlite_progress, count, elapsed_ms} (or with a tag second), {:xqlite_log, code, message}, and {:xqlite_backup_progress, remaining, pagecount}. The telemetry bridge re-emits the first seven; backup progress is not bridged. | `update_hook.rs:send_update_to_pid`, `wal_hook.rs:send_wal_to_pid`, `commit_hook.rs:send_commit_to_pid`, `rollback_hook.rs:send_rollback_to_pid`, `busy_handler.rs:send_busy_to_pid`, `progress_dispatch.rs:send_tick_to_pid`, `log_hook.rs:send_log_to_pid`, `nif.rs:send_backup_progress` | `nif/update_hook_test.exs: "delivers {:xqlite_update, :insert, ...} on INSERT"` |
| `hook-handles-are-opaque-and-idempotent` | `register_*` returns a `u64` handle unique within its own list; unregistering an unknown or repeated handle is a no-op that still answers `:ok`. | `hook_util.rs:HookList::register` / `unregister` | `nif/wal_hook_test.exs: "register / unregister returns handle and is idempotent"` |
| `type-extension-chain-first-match-wins` | encode/1 and decode/1 return {:ok, value} or :skip; the chain is walked in list order, the first {:ok, _} wins and the rest are not consulted, and unmatched values pass through unchanged. An encoder may answer {:error, reason}: the chain stops and the call answers {:type_extension_refused, %{position, extension, reason}} inside its telemetry span; encode_params/2 answers {:ok, params} or that tuple and accepts nil; the chain runs on every parameter-taking Xqlite function (bind/3, explain_analyze/4 and the three cancellable forms included) and decodes rows on every function that returns a result map; step/1, multi_step/2 and multi_step_cancellable/3 rows stay raw. | `xqlite/type_extension.ex:encode_value/2`, `xqlite/type_extension.ex:decode_value/2` | `type_extension_test.exs: "first matching extension wins"` |
| `default-value-classification` | A column default arrives as `:none`, `{:literal, v}`, `{:blob, bytes}`, `{:current, :time \| :date \| :timestamp}` or `{:expr, sql}`; nothing is constant-folded, and an integer past 64 bits or a non-finite float falls back to `{:expr, _}`. | `schema.rs:classify_default` | `schema_default_value_test.exs: "the full default-value matrix classifies as designed"`, plus the grammar property in `schema_default_value_property_test.exs` |
| `non-finite-floats-become-atoms` | A REAL that is not finite reads back as `:positive_infinity` or `:negative_infinity`, and NaN as `nil`, because the BEAM cannot hold a non-finite double. | `util.rs:encode_f64` | `nif/query_test.exs: "query/3 reads non-finite floats as sentinel atoms and stays usable"` |
| `blob-encoding-threshold-64-bytes` | On the query path a BLOB over 64 bytes comes back as a zero-copy resource binary and one of 64 bytes or fewer is copied onto the process heap; the stream and `blob_read` paths always copy. | `util.rs:HEAP_BINARY_THRESHOLD` and `encode_blob` | unpinned |
| `sql-input-rejections` | SQL is refused, never truncated or half-run: an interior NUL byte is :null_byte_in_string on every entry point; on query, execute, prepare, stream and explain_analyze, SQL holding no statement (empty, whitespace, comments, bare semicolons) is {:cannot_execute, "SQL contains no statement"} and a real second statement after the first is :multiple_statements, while trailing whitespace, comments and semicolons pass — one rule, statement.rs:prepare_one. When the text after the first statement is not itself a valid statement, the tail is re-compiled and the caller gets the compiler's own error with the tail as the SQL in it, a {:sql_input_error, _}, not :multiple_statements. The NUL rule holds for a PRAGMA value too: a value handed to set_pragma with an interior NUL byte is :null_byte_in_string before any statement is built (util.rs:pragma_text), for the same reason — SQLite's tokenizer would stop at the NUL and run a shorter statement than was built. | `query.rs:reject_interior_nul`, `query.rs:reject_no_statement`, `statement.rs:prepare_one` | `nif/error_input_test.exs: "interior NUL in SQL text is rejected on query/execute/execute_batch"` |
| `batch-size-and-step-count-floors` | A batch size below 1 is {:invalid_batch_size, %{provided: v, minimum: 1}} and pages_per_step below 1 is {:invalid_pages_per_step, v}; neither is clamped. For every_n the Elixir door Xqlite.register_progress_hook/3 answers {:invalid_hook_option, %{key: :every_n, value: v, reason: :invalid_value}} for a value that is not a positive integer, before the NIF is reached, while the raw NIF still answers {:cannot_execute, _} for 0. The two :invalid_batch_size producers disagree on provided: stmt_multi_step_impl puts the bare integer, stream_fetch_impl puts a tagged pair such as {:integer, 0}. | `nif.rs:stmt_multi_step_impl`, `nif.rs:stream_fetch_impl`, `nif.rs:register_progress_hook`, `nif.rs:backup_with_progress` | `nif/statement_test.exs: "multi_step rejects a batch size below one"` |
| `stream-on-error-modes` | `:raise` (the default) yields row maps and raises `Xqlite.StreamError`; `:halt` yields row maps, logs the reason and stops; `:emit_error` yields `{:ok, row}` then one terminal `{:error, reason}`; anything else is `{:error, {:invalid_on_error, value}}` at open. A failed value ends its batch early rather than discarding it: the rows read before it are delivered in every mode, whatever the batch size, and the error follows on the next fetch. A cancellation is the one exception and still discards the rows read in its batch. | `stream_resource_callbacks.ex:validate_on_error/1` and `handle_fetch_error/2`, `stream.rs:XqliteStream`, `nif.rs:stream_fetch_impl` | `xqlite_test.exs: "stream/4 rejects an unsupported :on_error mode at open"`, plus one test per mode there and the property `"every mode delivers the good rows and stops right after them"` |
| `statement-column-names-fall-back-after-finalize` | `stmt_column_names` reads live column metadata so automatic re-prepare is reflected, and serves the prepare-time snapshot only once the statement is finalized or the connection closed. | `nif.rs:stmt_column_names` | `nif/statement_test.exs: "operations after finalize report :statement_finalized; names stay cached"` |
| `authorizer-validates-the-whole-list-first` | An unrecognised action atom returns `{:invalid_authorizer_action, atom}` and installs nothing; the authorizer is one slot that a second call replaces. One composed closure serves the caller's denied kinds and the busy slot's two rules, installed while either is asked for and cleared when neither is. | `authorizer.rs:parse_denied`, `sync` | `nif/authorizer_test.exs: "unrecognized atom is a structured error and installs nothing"`, `"emptying the slot with no user rules leaves the connection unrestricted"` |
| `telemetry-is-compile-time-gated` | `:telemetry_enabled` is read at compile time and defaults to false: `enabled?/0` is a constant, the macros then expand to no `:telemetry` call at all, and both bridge constructors answer `{:error, :telemetry_disabled}`. | `xqlite/telemetry.ex` `@enabled` | `telemetry_test.exs: "enabled?/0 reflects the compile_env value"` |
| `result-struct-and-table-reader` | `%Xqlite.Result{}` carries `columns`, `rows`, `num_rows` and `changes`, and implements `Table.Reader` as `{:rows, %{columns: _, count: _}, rows}`. | `xqlite/result.ex` | `result_test.exs: "Table.Reader returns rows with metadata"` |
| `open-applies-a-fixed-pragma-set` | Xqlite.open/2 and open_in_memory/1 validate options against one NimbleOptions schema, then apply exactly the nine PRAGMAs in @pragma_order with busy_timeout first; an unknown key is {:invalid_open_option, %{reason: :unknown_key, ...}}, and the read-only and temporary openers apply none. Every value the open path hands the NIF passes Xqlite.Pragma.check_value/2, so an integer past what SQLite stores (busy_timeout, cache_size, wal_autocheckpoint) is refused at open instead of reading back 0. The openers guard their options with is_list/1 (a non-list raises FunctionClauseError, the documented kind), and an element that is not a {key, value} pair answers {:invalid_open_option, %{key: nil, reason: :not_a_pair, value: element}} before any option is validated. | `xqlite.ex:apply_pragmas/2`, `xqlite.ex:@pragma_order` | `open_opts_test.exs: "rejects unknown option"` |
| `pragma-values-validated-once` | `Xqlite.Pragma.check_value/2` is the one rule `Xqlite.set_pragma/3`, `Xqlite.Pragma.put/4` and the open path apply, and the value it answers is what reaches SQLite. Names match without regard to case. A true/false PRAGMA takes `true`, `false`, `1`, `0` and the words `on`, `off`, `yes`, `no`, `true`, `false` as atoms or strings in any case, answering `1` or `0`; a numeric PRAGMA takes an integer inside the spec's range and refuses a boolean; a mode PRAGMA takes the spec's words as atoms or strings in any case and the integers it lists, answering the spec's upper-case word. `nil` and anything else are `{:invalid_pragma_value, %{pragma, value}}`, a PRAGMA that can only be read is `{:read_only_pragma, name}`, and a name the spec does not model keeps the raw path through `Xqlite.set_pragma/3` while `put/4` refuses it. | `pragma.ex:check_value/2`, `xqlite.ex:set_pragma/3` and `set_pragma_value/3` | `pragma_test.exs: "a value outside the spec is refused by both setters, and nothing moves"`, `"a spelling the spec lists is accepted the same way by both setters"`, `"an option past what SQLite stores is refused at open"` |
| `db-path-is-nil-without-a-file` | In-memory and temporary databases report `{:ok, nil}`; SQLite's empty filename is normalised away. | `nif.rs:db_path` | `nif/connection_test.exs: "db_path returns nil (no backing file)"` |
| `api-armor-and-threadsafe-are-compiled-in` | The bundled SQLite always reports `ENABLE_API_ARMOR` and a `THREADSAFE=` entry in `PRAGMA compile_options`. | `libsqlite3-sys`'s bundled build (section 5) | `nif/connection_test.exs: "compile_options returns known flags"` |
| `bare-ok-shares-one-encoder` | Every NIF whose success carries no value encodes its result through one helper, so success is the bare atom `:ok`, never `{:ok, _}`, and failure is `{:error, reason}` from the same reason set. | `util.rs:singular_ok_or_error_tuple` | `nif/connection_test.exs: "close is idempotent"` |
| `identifiers-are-double-quoted` | Identifiers that reach SQL as text are wrapped in double quotes with embedded double quotes doubled, by `quote_identifier` in Rust and `Xqlite.Pragma.quote_name/1` in Elixir; string values are bound as parameters, or, where SQL forbids a parameter (PRAGMA), quoted with the quote doubled by `Xqlite.Pragma.format_pragma_value/1`. | `util.rs:quote_identifier`, `xqlite/pragma.ex:quote_name/1` | `nif/transaction_test.exs: "isolated: savepoint with double quotes in name"` |
| `strict-rebuild-renames-by-token` | `enable_strict_table/2` rewrites the stored `CREATE TABLE` statement by its own name token, whatever its quoting style (double quotes, backticks, brackets, bare), and never compiles the caller's name into a pattern. A saved index or trigger statement is replayed with its schema put in front of the stored name token instead, never over it, so SQLite stores the same bytes again. | `xqlite.ex:rebuild_as_strict/4`, `qualify_object_sql/2` | `strict_table_test.exs: "a table stored double-quoted converts"`, `"every index shape comes back byte-identical"` |
| `close-finalizes-children` | close finalizes every prepared statement, stream and blob still open on the connection under the Mutex first, then frees the SQLite handle through Connection::close() and passes SQLite's own refusal on as {:database_busy_or_locked, code, message} instead of dropping it (the connection goes back into its slot and can be closed again; no state the library can reach makes SQLite refuse today); a WAL database's -wal file is gone after close; a child's later operation answers :connection_closed and its finalize or close is :ok; a second close is :ok; sessions are not covered. | `connection.rs:close_connection` | `nif/connection_test.exs: "an unstepped prepared statement does not keep the handle open"; native/xqlitenif/src/connection.rs: tests::a_refused_close_answers_the_classified_error` |
| `telemetry-units-are-nanoseconds` | Every duration and timestamp measurement xqlite emits (duration, monotonic_time, system_time, wall_time_ns, total_duration, elapsed) is an integer nanosecond count from System.monotonic_time(:nanosecond) or System.system_time(:nanosecond), on spans and on point events alike; counts such as rows_returned are not durations. | `xqlite/telemetry.ex:run_span/3`, `xqlite/telemetry.ex:monotonic_time/0` | `telemetry_test.exs: ":stop reports duration and monotonic_time as nanoseconds"` |
| `telemetry-events-have-one-catalogue` | Xqlite.Telemetry.events/0 is the event catalogue (35 entries, 14 of them spans): a source census test proves every emit and span literal in lib/ is in it, drift tests prove the moduledoc and the guide list exactly it, and a reachability test proves every entry fires. The telemetry guide's metadata column lists every start-metadata key except the common conn and sql (stop-only keys may be named), and a census test keeps the column in step with the module doc's maps. | `xqlite/telemetry.ex:events/0` | `telemetry_test.exs: "every emission site in lib/ spells out a catalogued event"` |
| `poisoned-connection-lock-is-never-recovered` | A poisoned connection Mutex is never recovered: every conn.lock() maps the poison error to LockError and the connection is abandoned (close included), because after a panic SQLite's own state may be half written and must not be touched; a poisoned child-map lock makes close return before the handle is taken, so that connection stays open and usable and every later close repeats the same error. into_inner() appears only on the process-global log registry lock, the per-session guard and the stream's pending-error slot, never on a connection lock. | `connection.rs:with_conn`, `connection.rs:with_conn_mut` | unpinned |
| `stream-close-reason-is-the-outcome` | The [:xqlite, :stream, :close] event's reason is the stream's own outcome — :drained when every row was read, :halted when the consumer stopped early, :errored when a fetch failed in any :on_error mode — never the result of the close call; a failed close adds close_error to the metadata instead. | `xqlite/stream_resource_callbacks.ex:after_fun/1` | `stream_close_reason_law_test.exs: "an error stream in :emit_error mode closes with :errored"` |
| `pragma-accessors-refuse-unknown-names` | The typed doors Xqlite.Pragma.get/3,4 and Xqlite.Pragma.put/4 refuse a name outside the typed schema with {:error, {:unknown_pragma, name}} carrying the caller's own atom or string, before any PRAGMA statement is built (SQLite would otherwise parse and ignore the unknown pragma and report success). The raw doors Xqlite.get_pragma/2 and Xqlite.set_pragma/3 resolve a name the schema knows the same way, but hand a name outside the schema to SQLite as written, and a read of a name SQLite ignores answers {:ok, :no_value}. Every door answers {:invalid_pragma_name, key} for a key that is neither an atom nor a string. The fold is ASCII (String.downcase/2 with :ascii), as SQLite folds, for atoms and strings alike. After the name, the getters judge the argument position against what the PRAGMA reads with: a scalar (string, atom, integer) is the argument, a keyword list ([] included) is the options, and any other list, a missing argument on a PRAGMA that reads only with one, or an argument on a PRAGMA with no one-argument read form answers {:invalid_pragma_argument, %{pragma, value, reason}} (reason :not_a_scalar, :missing or :takes_no_argument) before any statement is built — so a getter never builds the PRAGMA name(value) form SQLite reads as a write. An integer argument is written into the statement as a number and a binary or atom as a quoted name, so the number-reading pragmas (integrity_check, quick_check, optimize, incremental_vacuum) take their number through the getter. | `xqlite/pragma.ex:do_put/4`, `xqlite/pragma.ex:read_without_arg/4`, `xqlite/pragma.ex:resolve_name/1`, `xqlite/pragma.ex:read_pragma/5` | `pragma_test.exs: "an unknown name is refused before any statement reaches SQLite"` |
| `strict-helpers-resolve-temp-first` | check_strict_violations/2 and enable_strict_table/2 resolve an unqualified name the way SQLite does — the temp schema first, then main, then the attached databases, comparing names with ASCII case folded and no other letter — read the columns from the object that resolved, schema-qualified, refuse anything that is not a plain table ({:not_a_plain_table, %{table, type}} for a view, a virtual table or a shadow table) and a WITHOUT ROWID table, report declared types STRICT would refuse before any row query, return :ok without work on an already-STRICT table, and rebuild inside the schema the table was found in under the spelling stored there (temp.-qualified sources, an unqualified RENAME TO target). | `xqlite.ex:strict_target/2`, `xqlite.ex:resolve_object/2`, `xqlite.ex:convert_to_strict/3` | `strict_table_test.exs: "a temporary table shadowing a main one converts only the temporary one"` |
| `child-handle-registration-is-rollback-safe` | Every raw SQLite handle xqlite hands to Elixir is put into the owning connection's child map while that connection's Mutex is held, and a handle whose registration fails is given straight back to SQLite instead of being returned; the two locks are always taken in the same order, the connection Mutex first and the child map second. | `connection.rs:register_child` | unpinned |
| `span-events-share-one-shape` | Every span fires three events with fixed measurement keys: :start carries monotonic_time and system_time, :stop and :exception carry duration and monotonic_time, and all three carry the same telemetry_span_context reference. The :stop metadata replaces the :start metadata instead of merging into it, and a span block may return {value, stop_metadata} or {value, extra_measurements, stop_metadata}. | `xqlite/telemetry.ex:run_span/3`, `xqlite/telemetry.ex:emit_stop/4` | `telemetry_test.exs: ":start and :stop share one telemetry_span_context reference"; "a block returning {value, extra_measurements, stop_metadata} merges the extras"` |
| `object-name-errors-carry-the-name` | The four errors that name a database object carry that name, not the sentence around it: {:no_such_table, name}, {:no_such_index, name}, {:table_exists, name} and {:index_exists, name}. The quoting and the schema qualifier are SQLite's own and differ between the pairs — the two 'no such' errors give the resolved name unquoted and keep a qualifier the statement wrote, the two 'already exists' errors never carry a qualifier, :table_exists echoes the identifier exactly as the statement spelled it and :index_exists gives the resolved name. A reworded SQLite message leaves the whole text in the payload. | `error.rs:classify_sqlite_error`, `error.rs:name_after`, `error.rs:name_between` | `nif/execution_test.exs: "execute/3 returns error for NoSuchTable on INSERT"` |
| `object-type-atoms-match-across-the-boundary` | The object types the schema reader reports are one set of atoms on both sides — :table, :view, :shadow, :virtual, :sequence — spelled the same in the Rust atom table and in Xqlite.Schema.Types.object_type/0; a Rust raw identifier gets an explicit string so the atom is not named after its escape. | `lib.rs:atoms` | `schema_introspection_test.exs: "schema_list_objects names a virtual table and its shadow tables"` |
| `callback-sends-run-on-a-dirty-scheduler` | Every enif_send with a NULL calling environment in this crate runs inside a NIF scheduled DirtyIo; nif.rs carries 99 #[rustler::nif] functions, 93 of them scheduled DirtyIo, and the six that carry no schedule (create_cancel_token, cancel_operation, is_cancel_token, sqlite_version, register_log_hook, unregister_log_hook) drive no SQLite callback, so none of them can reach such a send. | `hook_util.rs` | unpinned |
| `blob-wrapper-forces-blob-storage` | A plain binary parameter is stored as TEXT when its bytes are valid UTF-8 and as a BLOB otherwise, while %Xqlite.Blob{bytes: bytes} is always stored as a BLOB; the wrapper is accepted as a positional element and as the value of a keyword pair on every parameter-taking path; bytes is an enforced key (the literal without it does not compile, struct! raises), and a bytes field that is not a binary — a nil built through struct/2 included — answers {:invalid_blob_bytes, %{position, type}} with the one-based position in the list the caller passed and type naming the term found (one of eleven term-type atoms, :bitstring for a bitstring that is not a whole number of bytes, never :binary); and a value read back is a plain binary, never wrapped. | `util.rs:blob_struct_bytes`, `util.rs:blob_struct_value`, `util.rs:elixir_term_to_rusqlite_value` | `nif/blob_param_test.exs: "the same bytes are TEXT plain and BLOB wrapped"` |
| `strict-rebuild-restores-the-two-pragmas` | The STRICT rebuild reads PRAGMA foreign_keys and PRAGMA legacy_alter_table before it starts, turns foreign_keys off before the BEGIN (SQLite ignores that pragma inside a transaction) and legacy_alter_table on just before the RENAME TO, and puts both back on every path, success or failure; it rejects a call inside a caller's transaction with :transaction_in_progress and an existing <table>_xqlite_strict_rebuild in the same schema with {:table_exists, name}, both before any statement runs. | `xqlite.ex:rebuild_pragmas/1`, `xqlite.ex:suspend_foreign_keys/2`, `xqlite.ex:restore_pragmas/3` | `strict_table_test.exs: "a successful rebuild preserves the schema, the rows and the pragmas"` |
| `param-list-shape-decided-by-the-first-element` | Whether a parameter list is positional or a keyword list is decided once, from the first element — a two-element tuple with an atom key means keyword, anything else means positional — and the whole list is then treated that way. | `util.rs:is_keyword` | `nif/blob_param_test.exs: "a positional list whose first element is a wrapper binds every element"; "a named parameter called :blob still binds by name"` |
| `cancel-tokens-validated-before-the-nif` | A :cancel_tokens value — one token or a list — is validated before any cancellable NIF runs: Xqlite.validate_cancel_tokens/1 asks the NIF is_cancel_token/1, which takes the term undecoded and answers true only for a token from create_cancel_token/0, so every Xqlite door that takes tokens (query_cancellable/5, execute_cancellable/5, execute_batch_cancellable/3, query_with_changes_cancellable/5, multi_step_cancellable/3, backup_with_progress/6, stream/4, cancel_operation/1) answers {:error, {:invalid_cancel_tokens, value}} with the caller's value unchanged, inside its telemetry span, instead of raising; the raw XqliteNIF functions still raise ArgumentError on a wrong-typed argument, as every raw NIF does; nil is refused (pass [] for no tokens). | `xqlite.ex:validate_cancel_tokens/1`, `nif.rs:is_cancel_token` | `cancel_token_law_test.exs: "the anchor: a stream refuses a reference that is not a token"` |
| `bad-input-raises-or-answers` | An argument of the wrong type raises where it is met — a guard in Xqlite or in Xqlite.Pragma, or the native argument decoding inside a raw XqliteNIF stub — while a value of the right type that the library or SQLite refuses comes back as an {:error, reason} answer; the pragma doors judge every argument this way except the connection, which raises. | `xqlite.ex:@moduledoc`, `xqlite/pragma.ex:@moduledoc` | `bad_input_answers_test.exs: "a guard on an Xqlite function raises", "the native argument decoding raises", "a value of the right type is an answer", "a pragma door raises only for a connection that is not one", "a raw NIF stub raises on a term it cannot decode"` |
| `readme-counts-come-from-the-code` | The four counted numbers in README.md are read off the code, not written as prose: the count of typed error reasons is the size of Xqlite.error_reason/0, the count of constraint subtypes is the size of Xqlite.constraint_kind/0 minus its fallback, the two PRAGMA counts are the size of Xqlite.Pragma's schema and of its writable half, and the count of built-in type extensions is the number of modules under lib/xqlite/type_extension/. | `readme_census_test.exs` | `readme_census_test.exs: "the README's count of typed error reasons is the union's size", "the README's count of constraint subtypes is the union minus its fallback", "the README's PRAGMA counts are the schema's size and its writable half", "the README's count of built-in type extensions is the number of modules"` |

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
