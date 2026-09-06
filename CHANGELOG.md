# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.12.0] - 2026-09-06

### Added

- **`Xqlite.Telemetry.events/0` lists every event xqlite emits.** One
  entry per name, each tagged `:span` (it stands for `:start`, `:stop`
  and `:exception`) or `:event`. It is the one source for the event
  surface: the `Xqlite.Telemetry` moduledoc, the telemetry guide and
  the emission sites in `lib/` are all checked against it by the test
  suite, so a name can no longer be documented without being emitted
  or emitted without being documented. Attaching a handler to
  everything is now a two-liner over that list.
- **Streams can be cancelled.** `Xqlite.stream/4` takes
  `:cancel_tokens` — one token from `create_cancel_token/0` or a list of
  them — and hands them to every batch it fetches, so signalling any one
  of them from any process ends the batch it lands in with
  `{:error, :operation_cancelled}` and closes the stream. That error
  then follows the `:on_error` mode like any other fetch error, and
  `[:xqlite, :cancel, :honored]` fires with `operation: :stream_fetch`.
  The raw NIF is `XqliteNIF.stream_fetch_cancellable/3`, the twin of
  `stream_fetch/2`; an empty token list makes the two identical.
  Before this, a fetch could spend the whole cost of an unindexed
  `ORDER BY`, an aggregate or a recursive CTE inside one dirty NIF call
  with no way to stop it.

### Changed

- **`[:xqlite, :stream, :close]` reports how the stream ended.** Its
  `:reason` was derived from the closing call, so a stream that hit a
  fetch error, or one whose consumer stopped after four rows of a
  thousand, both reported `:drained`. It is now the stream's own
  outcome: `:drained` when every row was read, `:halted` when the
  consumer stopped early, `:errored` when a fetch failed — in all three
  `:on_error` modes, the raising one included. A failed close no longer
  changes the reason; it adds `:close_error` to the metadata and keeps
  the log line.
- **`Xqlite.explain_analyze/3` builds its query plan without prefixing
  text to your SQL.** It used to compile `EXPLAIN QUERY PLAN ` <> sql,
  which turned SQL whose first statement is preceded by a bare semicolon
  or a comment-then-semicolon into a syntax error, while `prepare`,
  `query` and `stream` all accept it. The plan now comes from the
  statement that runs for real, through `sqlite3_stmt_explain`. The
  statement counters are zeroed before the real run, so `reprepare` and
  `vm_step` describe your query and not the plan preview.
- **`Xqlite.Pragma.put/4` and `get/3,4` refuse a name the schema does
  not know.** Both now answer `{:error, {:unknown_pragma, name}}` before
  any statement is built. SQLite parses an unknown PRAGMA and ignores
  it, so `put/4` used to report success while changing nothing, and
  `get/4` with an argument used to answer `{:ok, []}`. `{:unknown_pragma,
  atom()}` and `{:invalid_pragma_value, map()}` join `Xqlite.error_reason/0`,
  where neither was listed.
- **The constraint `kind` is never `nil`.** A bare `SQLITE_CONSTRAINT`
  and any extended constraint code this build does not know both report
  `:constraint_violation`, which is what the code already did; `nil`
  leaves `Xqlite.constraint_kind/0` and `:constraint_violation` joins it.
- **`:no_such_table`, `:no_such_index`, `:table_exists` and
  `:index_exists` carry the object name, not the whole message.** The
  four payloads shrink to the text SQLite prints after its own prefix,
  which is what the STRICT helpers in `Xqlite` already returned under
  `:no_such_table`. Before and after, for a plain name, a `main.`
  qualified one, and one quoted with a space in it:

  | tag | before | after |
  |---|---|---|
  | `:no_such_table` | `"no such table: t"` / `"no such table: main.t"` / `"no such table: a b"` | `"t"` / `"main.t"` / `"a b"` |
  | `:no_such_index` | `"no such index: i"` / `"no such index: main.i"` / `"no such index: a b"` | `"i"` / `"main.i"` / `"a b"` |
  | `:table_exists` | `"table t already exists"` / `"table t already exists"` / `"table \"a b\" already exists"` | `"t"` / `"t"` / `"\"a b\""` |
  | `:index_exists` | `"index i already exists"` / `"index i already exists"` / `"index a b already exists"` | `"i"` / `"i"` / `"a b"` |

  The rendering is SQLite's own, and it is not uniform: only the two
  "no such" messages carry a schema qualifier, and only the
  `:table_exists` one re-quotes a name that needs quoting, because it
  echoes the identifier token as the statement wrote it.

### Removed

- **`Xqlite.enable_strict_mode/1` and `Xqlite.disable_strict_mode/1`
  are gone.** Both ran `PRAGMA strict`, and SQLite has no pragma by
  that name — an unknown pragma is parsed and ignored, so the calls
  returned success and changed nothing while their docs promised a
  stricter connection. STRICT tables are the real mechanism and are
  untouched: declare a new table with `CREATE TABLE … STRICT`, or
  convert an existing one with `Xqlite.enable_strict_table/2`.

### Changed

- **The crate declares its Rust floor: `rust-version = "1.91"`.**
  Source builds have required Rust 1.91 since 0.11.0: rustler 0.38.0
  declares that floor, and cargo enforces a dependency's floor. So
  nothing that built before stops building. What is new is that the
  requirement is stated up front — cargo's own error names it on an
  older toolchain, and the README states it beside the OTP 26 floor
  of the precompiled binaries (NIF API 2.17).
- **`mix verify` and `mix test.seq` are no longer part of the Hex
  package.** They are development tasks for this repository, and
  shipping them put a `mix verify` task under a generic name into
  every dependent project's task list. They stay in the repository
  for contributors.
- **`cargo test` runs on macOS and Windows in CI.** The crate's own
  unit tests ran in one ubuntu job and nowhere else, so a platform
  difference in the Rust layer could only be found by a user. The
  Tests job now runs them on the newest Elixir/OTP pair of its macOS
  and Windows entries as well, reusing that job's toolchain and cache.
- **`cargo clippy` now fails on an `unsafe` block that has no
  `// SAFETY:` comment, whatever flags it is given.** The lint was set
  to warn, so only the project's own gate — `cargo clippy -- -D
  warnings` — turned it into a failure, and a plain `cargo clippy` let
  it through. It is set to deny. `cargo build` is unaffected either
  way: rustc ignores `clippy::` lints.
- **`scripts/release.sh` leaves the working tree clean when the Rust
  version bump fails its own check.** It rewrote `Cargo.toml`, found
  the new version missing, and exited with that edit still on disk. It
  now restores `Cargo.toml` and the crate's `Cargo.lock` and says so.
  The commit `mix version` made before that point holds the Elixir bump
  only; the message names it, since no checkout can undo a commit.

### Fixed

- **The STRICT pre-check reports a declared type STRICT cannot accept.**
  `Xqlite.check_strict_violations/2` only looked at values, so a table
  with a `VARCHAR(255)` or `DATETIME` column, or a column with no type
  at all, came back clean and `Xqlite.enable_strict_table/2` then died
  part-way through its rebuild with SQLite's raw "unknown datatype" or
  "missing datatype". STRICT accepts exactly `INT`, `INTEGER`, `REAL`,
  `TEXT`, `BLOB` and `ANY`, in any case; every other declared type is
  now a `%{kind: :unknown_declared_type, column: name, declared: type}`
  violation and an untyped column a
  `%{kind: :missing_declared_type, column: name}` one, both reported
  beside the value violations and both refused before any SQL runs.
  An `ANY` column is accepted and its values are checked by nothing.
- **Both STRICT helpers work on temporary tables.** They read `main`'s
  schema only, so a temporary table answered
  `{:error, {:no_such_table, name}}`, and a temporary table shadowing a
  `main` table of the same name produced a column-count mismatch,
  because the two helpers disagreed about which table the name meant.
  An unqualified name now resolves the way SQLite resolves it — `temp`
  first, then `main`, then the attached databases in attach order — and
  every statement of the rebuild names that schema, so the table that
  converts is the one the name reaches. The `WITHOUT ROWID` refusal
  reads the resolved table too; it used to read whichever schema listed
  the name first, and so could refuse the wrong table or miss the right
  one.
- **Views, virtual tables and shadow tables are refused by name.** A
  view failed inside the check's own query on "no such column: rowid",
  and an FTS5 or rtree table failed mid-rebuild with "table … already
  exists". Both helpers now answer
  `{:error, {:not_a_plain_table, %{table: name, type: type}}}` before
  any work, where `type` is `:view`, `:virtual` or `:shadow` — a shadow
  table is a virtual table's storage and is refused with it.
  `{:not_a_plain_table, map()}` joins `Xqlite.error_reason/0`.
- **A table that is already STRICT is left alone.**
  `Xqlite.enable_strict_table/2` returned `:ok` but ran the whole
  rebuild first — every row copied into a new table, the old one
  dropped, the stored `CREATE TABLE` statement re-quoted. It now
  returns `:ok` without running a statement.
- **`object_type` is `:virtual`, not `:"r#virtual"`.** Every virtual
  table listed by `Xqlite.schema_list_objects/1` carried an atom named
  after the Rust keyword escape rather than the one
  `Xqlite.Schema.Types.object_type/0` documents.

- **Fourteen documentation claims now match the code.** Every number
  below was counted from the source it describes.

  - The README said "30+ typed reason variants"; `Xqlite.error_reason`
    has 51 members, and one of them was shown as the two-tuple
    `{:read_only_database, msg}` where it is
    `{:read_only_database, code, message}`.
  - The README said "13 SQLite constraint subtypes" in the error
    paragraph and again in the FAQ. Twelve are named subtypes; the
    thirteenth slot is the generic fallback, not a subtype of its own.
  - The README said "68 typed PRAGMAs" in two places. `Xqlite.Pragma`
    carries 57, of which 34 are writable.
  - The README's type-extension feature bullet listed seven built-ins
    and omitted `Instant` and `Duration`. All nine are listed now.
  - The README's runtime floor read as if CI ran all sixteen Elixir/OTP
    combinations from 1.17-1.20 against 26-29. Ten of them run; the
    README names which, and the floor is the oldest of those pairs.
  - The README's `busy_timeout` warning covered one direction only.
    Taking the busy slot zeroes SQLite's own `busy_timeout`, and the
    slot emulates the timeout it displaced rather than dropping it.
  - `guides/security.md` and `guides/spatialite.md` wrote
    `{:ok, _} = Xqlite.load_extension(…)`; it returns `:ok`. The
    security guide's snippet now runs in the suite, so it cannot rot
    again.
  - `guides/gotchas.md` named `execute` among the paths that hand back
    a large blob without copying it. `execute/3` returns no column
    values at all.
  - `guides/wiring_telemetry.md` omitted `:conn` from the metadata of
    `[:xqlite, :cancel, :honored]`.
  - `XqliteNIF.register_progress_hook/4` said "~64 SQLite VM
    instructions", which holds only at `every_n: 8`. The subscriber
    hears from it every `8 × every_n` instructions.
  - `XqliteNIF.stream_fetch/2` now names 0 among the rejected batch
    sizes instead of leaving it to "anything else".
  - `XqliteNIF.session_is_empty/1` had `@spec … :: boolean()` while it
    returns `{:ok, boolean()}`.
  - `Xqlite.step/1`'s docs named `query_cancellable/4` as the only way
    to cancel. `multi_step_cancellable/3` and `stream/4`'s
    `:cancel_tokens` are named beside it now.
  - `Xqlite.Telemetry.bridge/2` said busy handling is not bridged. Busy
    observation is bridged as `[:xqlite, :hook, :busy]`; only the retry
    policy is not, and `:busy` was also missing from the `:hooks`
    example.

- **Span events now measure in nanoseconds, like every other event.**
  `:start`, `:stop` and `:exception` came from `:telemetry.span/3`,
  which reads the clock in the VM's native time unit. Every other
  xqlite event uses `System.monotonic_time(:nanosecond)`, and both the
  guide and the moduledoc promised nanoseconds throughout. On Linux
  the native unit *is* the nanosecond, so the numbers agreed by luck;
  on a platform where it is not — xqlite ships Windows and macOS
  binaries — every span's `duration` and `monotonic_time` was off by
  that ratio while the point events beside it were not. xqlite now
  emits the three events itself, with the same names, keys and
  `telemetry_span_context`, measured in nanoseconds, and re-raises a
  block's exception untouched as before.

- **The two event catalogues no longer drift from the code.** The
  moduledoc and the telemetry guide each listed events nothing emits
  (`[:xqlite, :backup_with_progress, …]` in both, plus whole `session`
  and `blob` blocks in the moduledoc) and each missed events that do
  fire (`open`, `close`, `restore` and `query_with_changes` in the
  guide; `restore`, `extension.enable` and `close.exception` in the
  moduledoc). Several entries also labelled metadata keys as
  measurements. Both are regenerated from the emission sites and
  checked against `Xqlite.Telemetry.events/0` by the suite.

- **Three documentation promises corrected.**
  `Xqlite.TypeExtension.DateTime` was described as offset-preserving in
  four places; it writes the offset and reads the value back as UTC, so
  the instant round-trips and the offset does not. `execute_batch/2`'s
  docs never said what a mid-batch failure leaves behind: the
  statements before it stay applied, and there is no implicit
  transaction. The authorizer docs said a `:pragma` deny disables every
  pragma read; two reads run no `PRAGMA` at all and still answer —
  `get_pragma(conn, :wal_autocheckpoint)`, served from xqlite's own WAL
  callback, and `get_create_sql/2`, which is a `SELECT` and obeys
  `:read` and `:select` instead.

- **Closing a connection no longer leaks its SQLite handle.** A
  connection closed while a prepared statement, a stream or an
  incremental blob was still open answered `:ok` while `sqlite3_close`
  refused to free the handle, so that connection's memory, file
  descriptors and WAL state stayed resident for the life of the OS
  process — one leak per mis-ordered teardown, unbounded over time.
  `Xqlite.close/1` now finalizes every statement, stream and blob it
  opened on the connection, under the same mutex, before freeing the
  handle: a WAL database's `-wal` sidecar is gone once close returns.
  Those handles stay usable as terms — an operation on one is
  `{:error, :connection_closed}`, and finalizing or closing one is
  `:ok` — and close stays idempotent. Sessions are still not covered:
  delete them before closing.

- **`Xqlite.enable_strict_table/2` works on tables whose stored
  `CREATE TABLE` quotes the name.** The rebuild looked for the table
  name in the stored statement with a pattern that could never match a
  quoted one, so every table an Ecto migration creates —
  `CREATE TABLE "users" (…)` — failed with
  `{:error, {:table_exists, _}}` and was left unconverted; backticked
  and bracketed spellings failed the same way, and so did a second
  conversion of a table the helper itself had already converted. The
  rebuild now rewrites the statement's own name token, whatever its
  spelling, so all four spellings convert and converting twice is `:ok`.

- **The STRICT-table helpers quote every name and bind every value.**
  `check_strict_violations/2` and `enable_strict_table/2` wrote table
  and column names into SQL without doubling an embedded double quote,
  and wrote the reported column name and expected type in as string
  literals without doubling an embedded single quote, so a table named
  `we"ird` or a column named `it's` failed with a SQL syntax error.
  Names now go through the library's one quoting function and the two
  labels are bound as parameters. `Xqlite.Pragma.put/4` doubles an
  embedded quote in a string value the same way — a PRAGMA takes no
  bound parameter, so its value has to be quoted into the statement.
  `WITHOUT ROWID` tables, which the helpers cannot check because they
  read each row's `rowid`, are now refused with
  `{:error, {:without_rowid_unsupported, table}}` instead of a raw SQL
  error.

- **Every entry point that compiles SQL now accepts and refuses the same
  strings.** `prepare/2`, `stream/4`, `explain_analyze/3` and `query/3` /
  `execute/3` each decided for themselves what to do with text after the
  first statement and with input holding no statement at all, and all
  three answers differed. `stream/4` compiled only the first statement
  and streamed it, so `"SELECT 1; DROP TABLE t"` returned rows and never
  said half the string had been dropped, and comment-only or empty SQL
  gave back a stream with no rows; `explain_analyze/3` reported a
  successful empty run for the same input; `prepare/2` refused a trailing
  comment or a doubled semicolon (`"SELECT 1;;"`) that `query/3` accepts.
  All four now share one rule, rusqlite's: input holding no statement is
  `{:cannot_execute, "SQL contains no statement"}`, and what follows the
  first statement is a second statement — `:multiple_statements` — only
  when re-compiling it yields one, so a trailing comment, extra
  semicolons and trailing whitespace pass everywhere. Two behaviour
  changes to note: `Xqlite.stream(conn, "")` returns
  `{:error, {:cannot_execute, _}}` instead of an enumerable with no
  elements, so a dynamically built string that can come out empty now
  needs an `{:error, _}` branch; and `explain_analyze/3` on the same
  input returns that error instead of a report of zeroes.

- **`Xqlite.busy_timeout/2` refuses a value past SQLite's 32-bit
  limit instead of clamping it.** A timeout above `2_147_483_647`
  milliseconds was silently stored as that ceiling while the docs
  promised the value would read back unchanged; it now returns
  `{:error, {:cannot_execute, reason}}` naming the limit, the same
  refusal the SQL-length guard uses. The `busy_timeout:` open option
  already mapped `:infinity` to that ceiling explicitly and is
  unchanged.

- **`Xqlite.busy_timeout/2` no longer loses its value when busy
  observers are registered.** It set the timeout with a raw
  `PRAGMA busy_timeout`, which hands SQLite's single busy callback to
  SQLite's own handler: the observers went silent, and the busy slot —
  still held, still remembering the timeout from before the call —
  put that older value back when the last observer was unregistered.
  Setting 7777 ms and then unregistering left the connection at
  whatever it had been before. The timeout now goes through the busy
  slot, so observers keep receiving `{:xqlite_busy, …}` messages, the
  requested wait applies, and unregistering the last observer keeps
  it. With no observers registered, SQLite's own handler takes over
  exactly as before.

- **SQL that is only whitespace or comments is now refused by `query/3`
  and `execute/3`, instead of failing as a misuse of the C API.** SQLite
  compiles such input to no statement at all, and running it came back as
  `{:sqlite_failure, 21, 21, _}` — code 21 is `SQLITE_MISUSE`, which says
  "the caller broke the library", not "your SQL was empty". Both
  functions, and the `_with_changes` and `_cancellable` variants that go
  through the same code, now return
  `{:cannot_execute, "SQL contains no statement"}` — the error `prepare/2`
  has always returned for it. Passing parameters used to fail even
  earlier, as a wrong parameter count; the new check runs before any
  binding. `stream/4` and `explain_analyze/3` refuse it too, as the entry
  below describes; `execute_batch/2` accepts it exactly as before, with
  nothing to run.

- **`prepare/2`, `stream/4` and `explain_analyze/3` now report a syntax
  error the way `query/3` does.** These three compile their SQL through
  SQLite directly and each built its error by hand, so one bad SQL string
  got two different answers: `query/3` returned
  `{:sql_input_error, %{sql: _, offset: _, code: _, message: _}}`, whose
  `offset` is the byte in the SQL that SQLite points at, while the other
  three flattened it to `{:sqlite_failure, 1, 1, message}` and dropped the
  offset. All four now build the error the same way. Errors SQLite names
  precisely — a missing table, for one — already matched on every path and
  still do.

- **Registering a busy observer no longer silently disables the
  connection's `busy_timeout`.** SQLite gives a connection one busy
  callback, and installing ours zeroes any timeout already set — so
  `Xqlite.register_busy_observer/2` used to turn a waiting connection
  into one that gave up on the first busy event, and unregistering did
  not put the timeout back. The busy slot now remembers the timeout in
  effect when it takes over, waits it out on SQLite's own retry
  schedule while observers are installed without a policy, and restores
  it when the slot empties. A retry policy still governs whenever one
  is installed. Note that a connection you never configured already
  carries a 5000 ms timeout (rusqlite sets it on open), so observing
  contention on one now waits where it used to fail at once.
- **Docs: the guides run as written.** A cold run of every guide
  snippet against the 0.11.0 package found six that did not: the
  security guide (and the README's feature list) still showed the
  old two-element `{:authorization_denied, message}` — it has been
  `{:authorization_denied, extended_code, message}` since the
  3-tuple change — and its authorizer example deleted from a table
  it never created; the telemetry guide's Honeycomb section called an
  `:opentelemetry_telemetry.attach/2` that does not exist (replaced
  by the real path: the shipped attribute mapping plus that
  package's span helpers) and its Logger sample lacked
  `require Logger`; the gotchas guide's `:emit_error` sample piped
  the `{:error, reason}` that `Xqlite.stream/4` returns on a setup
  failure straight into `Enum`. Two placeholder names are now
  labelled as such.

- **Docs: `query_with_changes/3` teaches its real rule.** The 0.11.0
  package still describes the abandoned empty-columns heuristic
  ("for SELECT statements (non-empty columns), `changes` is 0") — the
  shipped code reports the real count for RETURNING DML and 0 only
  when `total_changes` did not move. The corrected text and the
  README's compatibility statement for the Ecto adapter pairing were
  committed right after the 0.11.0 tag and have been main-only since;
  this release delivers them. The only code delta since the tag is
  a clippy 1.98 lint rewrite in the blob-literal parser — no behavior
  change.

- **Rowid-uniqueness violations carry the parsed table and column.**
  A duplicate explicit `rowid` on a table with no `INTEGER PRIMARY
  KEY` fails as `:constraint_rowid`, and SQLite spells the cause out
  ("UNIQUE constraint failed: t.rowid") — but the message parser had
  no arm for that code, so the details map arrived with `table: nil`
  and `columns: []`. It now reads the message the same way
  `:constraint_unique` does. SQLite's virtual tables report a
  violation with the bare text "constraint failed" instead (an FTS5
  duplicate rowid, for one), which names neither table nor column;
  that shape keeps returning empty details and is now pinned by
  tests so it cannot start guessing.

- **With telemetry compiled out, `span_with_stop_metadata/3` no longer
  rejects the three-element block shape.** The macro lets its block
  return `{value, stop_metadata}` or
  `{value, extra_measurements, stop_metadata}`, and the enabled build
  accepts both. The disabled build matched only the two-element shape,
  so the three-element one raised `CaseClauseError` — in the default
  build, where telemetry is off. Both builds now accept the same two
  shapes and reject everything else. No emission site inside xqlite
  returns the three-element shape, so the library itself was never
  affected; a caller writing its own span was.

- **A branch of the STRICT rewrite that could never run is gone.**
  `Xqlite.enable_strict_table/2` rebuilds a table by rewriting the
  table's own name token in the `CREATE TABLE` statement SQLite has
  stored, and the scanner carried a branch for a schema-qualified name
  such as `main.users`. SQLite strips the schema qualifier before
  storing the statement, so that branch was unreachable. Behaviour is
  unchanged. What the rewrite does preserve is now pinned by a
  property: whatever whitespace stood between the table name and the
  column list — one to three of the five bytes SQLite accepts there —
  comes back byte for byte after the conversion.

- **The full-text-search guide is executed by the test suite, not
  restated by it.** The test held its own copy of the guide's SQL, so
  editing a snippet in `guides/full_text_search.md` could not fail
  anything. It now reads the guide at test time and runs every fenced
  block in order against one connection, carrying bindings from block
  to block; only the Ecto adapter's block is skipped, and the number of
  skipped blocks is asserted, so a second unrunnable block cannot slip
  in. The guide's opening `Xqlite.open_in_memory/0` line moved into a
  fence of its own, which the test skips and supplies itself. Three
  claims of the guide were not covered anywhere and now are: the
  `detail = 'column'` / `'none'` knob, which gets a snippet; the sync
  triggers, which the guide now shows keeping the index right through
  an update and a delete; and `STRICT` on an FTS5 table, which the
  guide had wrong. FTS5 refuses `STRICT` and column constraints
  outright — a `STRICT` suffix is a syntax error, and `NOT NULL`,
  `PRIMARY KEY`, `CHECK`, `UNIQUE` or a type name on a column is
  rejected when the table is created — rather than accepting and
  ignoring them, as the guide claimed.

## [0.11.0] - 2026-08-20

### Changed

- Raised the minimum supported Elixir to `~> 1.17`, matching the CI
  test matrix (Elixir 1.17–1.20 × OTP 26–29). Elixir 1.15/1.16 were
  claimed but never exercised by CI.
- Busy policy `:max_elapsed_ms` is now a per-contention budget, reset
  at the start of each busy event instead of anchored at handler
  install — long-lived and pooled connections keep retrying, where
  previously they gave up with zero retries once the connection was
  older than the ceiling.
- Trivial connection-lock readers (`changes/1`, `db_path/1`,
  `transaction_status/1`, and ~17 more) moved to dirty schedulers, so
  a reader on a shared handle can no longer stall a normal scheduler
  behind a concurrent slow query on the same connection. Costs
  ~0.85µs median per call — still sub-microsecond.
- `changeset_apply/2` documentation now states explicitly that
  `:replace` aborts and rolls back the whole apply on a conflict
  SQLite forbids replacing — it never silently skips a change.
- Dependencies refreshed: rusqlite 0.40.2, libsqlite3-sys 0.38.2
  (bundled SQLite unchanged at 3.53.2).

### Fixed

- Returning a TEXT value under allocation failure now yields a
  structured `internal_encoding_error` at every site where a row
  value or column name is encoded — matching the blob path — instead
  of panicking through rustler's string encoder.

## [0.10.0] - 2026-07-20

This release fixes several memory-safety and crash defects present in
0.9.0, and refines the error and streaming contracts. The error-tuple,
streaming, and NUL-handling changes are breaking — see **Changed**.

### Security

- **Memory-safety fixes in resource teardown.** Several defects that
  could crash or corrupt the BEAM were fixed: a use-after-move when an
  incremental-blob resource was dropped, plus use-after-free, leak, and
  panic residuals in the blob, session, and log-hook paths. Raw FFI
  callbacks (progress, WAL, busy) are now guarded so a panic can never
  unwind across the C boundary. Surfaced by an adversarial safety
  review of the code shipped in 0.9.0.

- **`Xqlite.stream/4` could abort the VM on a huge `batch_size`.** A
  validly-typed but pathological `batch_size` (e.g. `10^13`) triggered
  an eager multi-terabyte allocation that aborted the OS process before
  any row was read. The accumulator now grows on demand.

### Added

- **Security guide** documenting the threat model, the per-connection
  thread-safety model, and safe extension loading.
- **Gotchas guide** collecting user-facing footguns (sticky
  `changes/1`, single-writer behavior, busy-policy anchoring, memory
  and binaries, one-connection-per-process, and more).

### Changed

- **BREAKING: error tuples now carry the SQLite extended result code.**
  `:database_busy_or_locked`, `:read_only_database`, `:schema_changed`,
  and `:authorization_denied` are now the 3-tuple
  `{tag, extended_code, message}` (previously `{tag, message}`), so
  callers can tell e.g. `SQLITE_BUSY` from `SQLITE_LOCKED`. Other
  message-classified errors are unchanged.
- **BREAKING: `{:utf8_error, message}` is now
  `{:utf8_error, column, message}`**, carrying the byte column of the
  first invalid sequence.
- **BREAKING: `Xqlite.stream/4` no longer silently truncates on a
  mid-fetch error.** A new `:on_error` option chooses how a mid-stream
  failure (e.g. an invalid-UTF-8 TEXT value) is surfaced, and the
  stream's element shape follows the mode: `:raise` (the new default)
  raises `Xqlite.StreamError` carrying the structured reason; `:halt`
  keeps the previous stop-and-log behavior, now opt-in and documented
  as lossy; `:emit_error` yields a uniformly tagged stream of
  `{:ok, row}` elements followed by a terminal `{:error, reason}`. The
  old default silently dropped the remaining rows with no signal to the
  consumer, so a truncated read could not be told apart from a
  completed one.
- **BREAKING: interior NUL bytes in SQL text are rejected.** SQL passed
  to `query`, `execute`, and `execute_batch` containing an interior NUL
  now returns `{:error, :null_byte_in_string}` instead of being
  silently truncated at the NUL by SQLite's tokenizer. NUL bytes in
  bound parameter values still round-trip unchanged.

### Fixed

- **Non-finite floats no longer raise when read.** A stored or
  computed `±Inf` REAL now reads back as the sentinel atom
  `:positive_infinity` / `:negative_infinity` — and a `NaN`, which
  SQLite already stores as NULL, as `nil` — on every read path
  (`query`, `stream`, prepared `step`). Previously rustler's `f64`
  encoder posted a return-time `ArgumentError`, breaking the
  `{:ok, _}` / `{:error, _}` contract; the row-value encoders now
  guard finiteness the way the schema layer already did.

- **`query_with_changes/3` reports the correct affected-row count.** It
  now returns the true count for `INSERT/UPDATE/DELETE ... RETURNING`
  statements (previously `0`) and no longer leaks a stale prior-DML
  count after a DDL or PRAGMA statement.

- **`backup_with_progress/6` no longer loops forever** when given a
  non-positive `pages_per_step`; it returns
  `{:error, {:invalid_pages_per_step, n}}`.

- **`changeset_apply/3` with `:replace`** no longer fails with
  `SQLITE_MISUSE` on conflict types SQLite forbids replacing
  (`NOTFOUND`, `CONSTRAINT`, `FOREIGN_KEY`); the apply aborts cleanly.

- **Hexdocs stability and navigation.** `Xqlite.Telemetry`'s macro
  docs no longer depend on which compile-time telemetry flag was
  active when the docs were built (the disabled branch carried
  `@doc false`), and the docs sidebar now groups the previously
  ungrouped flagship modules: the type-extension family, the
  telemetry trio, `Xqlite.Result`, and `Xqlite.ExplainAnalyze`.

### Performance

- **Small blob values from `query` use a process-heap binary** instead
  of an off-heap reference-counted binary, cutting per-value overhead
  for reads of many small blobs. Large blobs keep the zero-copy
  reference-counted backing.

- **Slow session, blob, and changeset NIFs run on dirty schedulers**,
  so serializing or copying a large changeset or blob no longer
  occupies a normal BEAM scheduler.

## [0.9.0] - 2026-07-17

### Breaking

- **The busy handler is split into policy and observers.**
  `set_busy_handler/3` (pid + options) is gone; the retry decision
  and the observation are now independent halves of one busy slot:
  `Xqlite.set_busy_policy/2` / `remove_busy_policy/1` own the
  single-slot retry policy (a policy cannot compose), and any number
  of `Xqlite.register_busy_observer/2` subscribers receive
  `{:xqlite_busy, retries, elapsed_ms}` per contention callback —
  with or without a policy installed. `remove_busy_handler/1` is
  replaced by `remove_busy_policy/1` (observers survive it);
  `busy_timeout/2` now clears the policy and documents that the raw
  PRAGMA also silences observers.

### Added

- **Every raw introspection NIF now has an `Xqlite` wrapper.** The
  ergonomic surface gains transaction-state readers
  (`transaction_status/1`, `autocommit/1`, `txn_state/2`), counters
  (`last_insert_rowid/1`, `changes/1`, `total_changes/1`,
  `connection_stats/1`), build info (`compile_options/1`,
  `sqlite_version/0`), and the schema family (`schema_databases/1`,
  `schema_list_objects/2`, `schema_columns/2`,
  `schema_foreign_keys/2`, `schema_indexes/2`,
  `schema_index_columns/2`, `get_create_sql/2`) — all thin,
  telemetry-free delegations. Hooks, sessions, and blob I/O remain
  deliberately raw `XqliteNIF` APIs.

- **`Xqlite.Telemetry.OpenTelemetry`.** A pure, dependency-free
  mapping from xqlite's telemetry events to OpenTelemetry's stable
  database semantic-convention attributes (`db.system.name`,
  `db.query.text`, `db.operation.name`, `db.namespace`,
  `error.type`) plus a `span_name/2` suggestion — the vocabulary
  database-aware observability backends key off. Every mapped name
  is cited to its spec page in the module docs.

- **Two new hexdocs guides.** "Full-text search with FTS5" (virtual
  tables, external-content triggers, bm25 ranking,
  highlight/snippet, adapter usage) and the doc-first "Spatial data
  with SpatiaLite" (per-platform install, gated extension loading,
  geometry columns, spatial index pattern, honest caveats).

- **Busy observation joins the telemetry bridge.**
  `Xqlite.Telemetry.bridge/2` accepts `:busy` (included in the
  default `:all`), re-emitting contention deliveries as
  `[:xqlite, :hook, :busy]` with `retries` and nanosecond `elapsed`
  measurements.

- **`Xqlite.close/1` and `Xqlite.db_path/1`.** Connection close gets
  its ergonomic wrapper (idempotent — `:ok` even when already
  closed) and finally emits the `[:xqlite, :close, :start | :stop]`
  telemetry span the telemetry docs have promised since 0.7.0.
  `db_path/1` returns the main database's file path (`{:ok, nil}`
  for in-memory and temporary databases), with a matching raw
  `XqliteNIF.db_path/1` stub.

- **`Xqlite.open_readonly/1` and `Xqlite.open_temporary/0`.** The
  last two raw-only opens get their ergonomic wrappers, emitting the
  `[:xqlite, :open]` span with modes `:readonly` / `:temp`.

### Fixed

- **Connection open spans actually fire.** The telemetry docs have
  promised `[:xqlite, :open, :start | :stop]` since 0.7.0, but no
  open wrapper ever emitted them. `Xqlite.open/2`,
  `open_in_memory/1`, and `open_in_memory_readonly/1` now emit the
  span with the documented `%{path, mode, result_class,
  error_reason}` metadata.

## [0.8.0] - 2026-07-14

### Added

- **Manual statement lifecycle.** `Xqlite.prepare/2`, `bind/2`
  (positional list or keyword-named), `step/1` (`{:row, values}` /
  `:done`), `multi_step/2` (`{:ok, %{rows: rows, done: bool}}`),
  `reset/1` (bindings preserved), `clear_bindings/1`,
  `column_names/1`, `finalize/1` (idempotent) — plus the raw
  `XqliteNIF.stmt_*` stubs. Prepare once and rebind in a loop to skip
  re-parsing; consume partially without LIMIT rewrites. Exactly one
  statement per prepare: empty SQL and trailing statements are
  structured errors, never silently dropped. Positional bind
  validates the parameter count
  (`{:invalid_parameter_count, %{provided: _, expected: _}}`); using
  a finalized statement returns `{:error, :statement_finalized}`.
  Abandoned statements are finalized by garbage collection; finalize
  before closing the owning connection. Plain steps are not
  cancellable; `multi_step_cancellable/3` provides token-based
  cancellable batch stepping over the connection's progress handler
  (single token or OR-semantics list, like `query_cancellable/4`).
  No telemetry on statement operations (documented).

- **Deny-list authorizer.** `Xqlite.set_authorizer/2` and
  `remove_authorizer/1` (plus the raw `XqliteNIF` stubs) install a
  single-slot authorizer that rejects a chosen set of SQLite action
  kinds at statement-preparation time. Denied statements fail with
  `{:error, {:authorization_denied, message}}`; an unrecognized action
  atom returns `{:error, {:invalid_authorizer_action, atom}}` and
  installs nothing (the list is validated atomically). v1 is
  action-kind granularity only (no table/column filtering) and
  deny-only (no `IGNORE`). Denying `:pragma` also turns off
  `get_pragma`/`set_pragma`.

- **`:type_extensions` on `Xqlite.query/4` and `execute/4`.**
  Previously stream-only: the option now also encodes parameters and
  decodes result rows on the one-shot query/execute paths (same
  first-match chain semantics as `stream/4`; arity-3 calls are
  unchanged).

- **`Instant` and `Duration` type extensions.** Encode-only mirrors
  of the Ecto-layer types: `DateTime` → int64 epoch nanoseconds
  (`Instant` — the integer alternative to the ISO-text `DateTime`
  extension; pick one per chain) and exact-unit `Duration` → int64
  nanosecond spans (calendar units skip; Elixir 1.17+ gated like
  `Decimal`). No decode on either — a stored nanosecond count is
  indistinguishable from any other integer. Timezone-aware datetimes
  and arrays need no new modules: the `DateTime` extension already
  round-trips offsets and `JSON` already handles lists. This
  completes the core-layer type mirroring.

- **Three more built-in type extensions.**
  `Xqlite.TypeExtension.JSON` (plain maps/lists ↔ JSON text via
  `Jason`; structs and unencodable terms skip), `.UUID` (canonical
  hyphenated text ↔ the compact 16-byte value it encodes; decode is a
  16-byte heuristic that cannot tell a BLOB from a same-length TEXT),
  and `.Decimal` (encode-only, `Decimal` → exact TEXT). `Decimal`
  introduces xqlite's first optional dependency — a deliberate policy
  change: the module compiles only when `:decimal` is installed, so the
  core package stays dependency-light. Geo/spatial types remain out of
  scope for core.

### Breaking

- **`ColumnInfo.default_value` is now classified, not raw text.**
  Previously the verbatim `dflt_value` string from
  `PRAGMA table_xinfo` (or `nil`); now a typed classification:
  `:none` (no default — distinct from explicit `DEFAULT NULL`),
  `{:literal, nil | boolean | integer | float | String.t()}` (with
  SQLite's `''` string escaping undone, hex integers as 64-bit
  two's complement, `TRUE`/`FALSE` as booleans),
  `{:blob, binary}` (`x'...'` hex-decoded, may be any bytes),
  `{:current, :time | :date | :timestamp}`, or `{:expr, sql}`
  verbatim for everything else (SQLite strips expression defaults'
  outer parentheses; nothing is constant-folded; integer-shaped
  values beyond 64 bits and non-finite floats land here).
  Parsing happens in Rust at the NIF boundary. Date/time-looking
  strings remain strings — no type divination at the schema layer.

- **`mix precommit` is now `mix verify`.** Same checks, same
  fast-to-slow order, new name. The task module ships in the
  package, so the old task name is gone.

### Fixed

- **Raw statement/stream binding accepts text with interior NUL
  bytes.** The shared FFI binder built a `CString` for TEXT values
  and rejected legitimate NUL-containing payloads with
  `:null_byte_in_string`; it now binds pointer+length, matching the
  one-shot query path (SQLite stores such TEXT fine).

- **Statement column metadata is read live, not snapshotted.**
  `SELECT *` through a prepared statement now re-expands after a
  schema change (SQLite's v2 auto-reprepare); previously the row
  width and `column_names` were frozen at prepare time. Finalized
  statements still answer `column_names` from the prepare-time
  snapshot.

- **Finalizing after a failed step no longer reports a phantom
  error.** `sqlite3_finalize` echoes the statement's most recent
  evaluation error (e.g. `SQLITE_INTERRUPT` after a cancelled step)
  even though the statement is destroyed regardless; `stream_close/1`
  and `Xqlite.finalize/1` treated that echo as a cleanup failure.
  Cleanup now always succeeds — the evaluation error was already
  surfaced at step/fetch time.

### Changed

- Upgraded rusqlite 0.39 → 0.40.1 (bundled SQLite 3.51.3 → 3.53.2)
  and rustler 0.37 → 0.38. No API changes on the xqlite surface.

## [0.7.0] - 2026-06-12

### Breaking

- **Fan-out hooks renamed and made multi-subscriber.** Every hook that
  fans out events to a subscriber pid (update, wal, commit, rollback,
  log) now uses the `register_X_hook` / `unregister_X_hook(handle)`
  verbs and returns an opaque integer handle. Multiple subscribers can
  coexist independently on the same connection (or globally for
  `log_hook`); each registration is independent. Migrations:
  - `set_update_hook(conn, pid)` (returned `:ok`) →
    `register_update_hook(conn, pid)` (returns `{:ok, handle}`)
  - `remove_update_hook(conn)` →
    `unregister_update_hook(conn, handle)` (idempotent on unknown
    handles)
  - Same shape for: `wal_hook`, `commit_hook`, `rollback_hook`,
    `log_hook` (the latter is `register_log_hook(pid)` /
    `unregister_log_hook(handle)` since it's global).
  - `busy_handler` keeps the `set_busy_handler` / `remove_busy_handler`
    verbs because its callback returns a policy decision and
    multi-subscriber composition has no clean rule. A future
    `register_busy_observer/1` will offer fan-out observation
    alongside the single policy slot
    (see `project_busy_handler_observer_split` design notes).
- **Cancellable NIFs now take a list of tokens instead of a single
  token.** `XqliteNIF.query_cancellable/4`,
  `query_with_changes_cancellable/4`, `execute_cancellable/4`,
  `execute_batch_cancellable/3`, and `backup_with_progress/6` now expect
  the trailing argument to be `[reference()]` (possibly empty) rather
  than `reference()`. OR-semantics: any signalled token cancels the
  operation. Single-token callers wrap as `[token]`. The new
  `Xqlite.query_cancellable/4` (and friends) plus
  `Xqlite.backup_with_progress/6` accept either a single token or a list
  and normalise via `List.wrap/1`.
- **`XqliteNIF` is now the raw NIF boundary only.** Every function in
  `XqliteNIF` is a bare NIF stub; all ergonomic wrappers moved to the
  user-facing `Xqlite` module. Migrations:
  - `XqliteNIF.open_in_memory/0` → `Xqlite.open_in_memory/0`
    (or `XqliteNIF.open_in_memory(":memory:")` to stay at the NIF layer)
  - `XqliteNIF.open_in_memory_readonly/0` → `Xqlite.open_in_memory_readonly/0`
  - `XqliteNIF.serialize/1` → `Xqlite.serialize/1`
  - `XqliteNIF.deserialize/2` → `Xqlite.deserialize/2`
  - `XqliteNIF.load_extension/2` → `Xqlite.load_extension/2`
  - `XqliteNIF.backup/2` → `Xqlite.backup/2`
  - `XqliteNIF.restore/2` → `Xqlite.restore/2`
  - `XqliteNIF.set_busy_handler/3` (keyword-opts form) →
    `Xqlite.set_busy_handler/3`; the raw NIF stays as
    `XqliteNIF.set_busy_handler/5`

### Added

- **Opt-in `:telemetry` instrumentation** across the whole API surface.
  Compile-time flag (`config :xqlite, :telemetry_enabled, true` +
  recompile); when disabled (the default) no telemetry call exists in
  the bytecode at all. Span events (`:start`/`:stop` with integer-
  nanosecond `monotonic_time`/`duration`) for query / execute /
  execute_batch / explain_analyze and their cancellable variants,
  transactions and savepoints, streams (open / per-batch fetch /
  close), backup, wal_checkpoint, serialize / deserialize, extension
  loading, and pragma get/set. Cancellation lifecycle events:
  `[:xqlite, :cancel, :token_created | :signalled | :honored]`.
- **`Xqlite.Telemetry.bridge/2` + `bridge_log/1`** — forward the
  multi-subscriber hook fan-outs (update / wal / commit / rollback /
  progress, plus the global log hook) as `[:xqlite, :hook, :*]`
  telemetry events. New "Wiring xqlite telemetry" ExDoc guide covers
  conventions, the full event surface, and sample handlers.
- **Connection observability NIFs** — `Xqlite.wal_checkpoint/3`
  (`:passive` / `:full` / `:restart` / `:truncate`, returns structured
  busy / log-pages / checkpointed-pages), `XqliteNIF.connection_stats/1`,
  `XqliteNIF.autocommit/1`, and `XqliteNIF.txn_state/2`.
- **`Xqlite.busy_timeout/2`** — sets a plain `sqlite3_busy_timeout` while
  cleanly reclaiming any xqlite-installed busy handler first. Prefer this
  over `PRAGMA busy_timeout`, which silently replaces the busy handler at
  the SQLite C level and stops `{:xqlite_busy, …}` delivery without
  removing our internal slot.
- Busy-handler PRAGMA-replacement warning front-and-center in the module
  docs and README.
- **WAL hook**: `XqliteNIF.register_wal_hook/2` +
  `unregister_wal_hook/2`. Sends `{:xqlite_wal, db_name, pages}` to
  each subscriber after each commit in WAL mode. Coexists with
  automatic checkpointing (see the slot-conflict fix below); only
  raw-SQL `PRAGMA wal_autocheckpoint` still steals the hook slot.
- **Commit hook**: `XqliteNIF.register_commit_hook/2` +
  `unregister_commit_hook/2`. Sends `{:xqlite_commit}` to each
  subscriber immediately before each commit. Observation-only — never
  vetoes the commit.
- **Rollback hook**: `XqliteNIF.register_rollback_hook/2` +
  `unregister_rollback_hook/2`. Sends `{:xqlite_rollback}` to each
  subscriber after each rollback.
- **Progress hook (multi-subscriber)**:
  `XqliteNIF.register_progress_hook/4` +
  `XqliteNIF.unregister_progress_hook/2` plus
  `Xqlite.register_progress_hook/3` /
  `Xqlite.unregister_progress_hook/2`. Multiple processes can subscribe
  independently to the same connection; each receives
  `{:xqlite_progress, count, elapsed_ms}` (or
  `{:xqlite_progress, tag, count, elapsed_ms}` if a tag is supplied),
  decimated by the per-subscriber `every_n` knob. Coexists with
  cancellation on the single SQLite progress-handler slot — cancel
  signals interrupt before tick emission.
- **Multi-token cancellation**: cancellable NIFs and
  `backup_with_progress` accept a list of tokens; any signal cancels
  (OR-semantics). The high-level `Xqlite.query_cancellable/4` family
  accepts either a single token or a list.

### Fixed

- **WAL hook ↔ `wal_autocheckpoint` slot conflict.** SQLite implements
  automatic checkpointing *as* a wal_hook, so the two share one C-level
  slot and silently disable each other. Both directions affected the
  in-development hook work: `Xqlite.open/2`'s default
  `wal_autocheckpoint` pragma evicted the master WAL callback (no
  subscriber ever received events), and on raw `XqliteNIF.open`
  connections the master callback itself disabled autocheckpointing
  (unbounded WAL growth). The master callback now owns the slot and
  emulates the autocheckpoint — a passive checkpoint once the WAL
  reaches the configured threshold (default 1000 pages, mirroring
  SQLite) — and the `set_pragma` NIF re-installs the master callback
  and syncs the threshold whenever `wal_autocheckpoint` is set.
  Remaining caveat (documented): issuing `PRAGMA wal_autocheckpoint`
  through raw SQL (`query`, `execute`, `execute_batch`) bypasses the
  repair and still steals the slot.

### Internal

- New `progress_dispatch` Rust module multiplexes the single SQLite
  `sqlite3_progress_handler` slot between cancellation checkers (per
  cancellable-query lifetime) and tick subscribers (per-conn lifetime),
  via two `HookList<T>`s. The C callback is registered eagerly at
  connection open and stays for the lifetime of the connection;
  subscriber install/uninstall is lock-free atomic-swap-and-reclaim.
- New `HookList<T>` primitive in `hook_util`: lock-free copy-on-write
  list of subscribers. Reads (in callbacks) are wait-free atomic loads;
  writes (under the conn Mutex) clone the Vec, mutate the clone, and
  atomic-swap. Vec is the proof-of-concept choice; ring buffer / lock-
  free structures are tracked as a benchmark-gated future optimisation.
- `cancel.rs::ProgressHandlerGuard` no longer touches FFI — it pushes
  one `CancelSubscriber` per token onto the dispatch and unregisters
  them on drop. Holds the owning `Arc<AtomicBool>` for each subscriber
  so the raw pointer stays valid for the registration's lifetime.
- Shared `hook_util` Rust module deduplicates term-construction
  (`make_atom` / `make_binary`) and atomic-slot lifecycle
  (`install_hook` / `uninstall_hook` / `drop_hook`) across the FFI-based
  hooks (busy_handler, wal_hook) and the rusqlite-closure hooks
  (update_hook, commit_hook, rollback_hook).

## [0.6.0] - 2026-04-19

### Breaking

- **Constraint errors are now structured.** `:cannot_fetch_row` has been
  removed as an outcome; constraint-violating statements now raise
  `{:constraint_violation, subtype, details}` with `subtype` as one of
  13 typed atoms (`:constraint_unique`, `:constraint_foreign_key`,
  `:constraint_check`, `:constraint_not_null`, `:constraint_primary_key`,
  `:constraint_trigger`, `:constraint_commit_hook`,
  `:constraint_function`, `:constraint_rowid`, `:constraint_pinned`,
  `:constraint_datatype`, `:constraint_vtab`, and the generic
  `:constraint_violation` fallback) and `details` carrying structured
  `table`, `columns`, `index_name`, `constraint_name` fields where
  applicable. Regex matching on error message strings is no longer
  needed. Callers catching `{:error, {:cannot_fetch_row, _}}` must
  update to match the new structured form.

### Added

- **`Xqlite.explain_analyze/3`** — structured execution report combining
  `EXPLAIN QUERY PLAN`, per-scan runtime counters from
  `sqlite3_stmt_scanstatus_v2` (loops, rows visited, estimated rows,
  name, parent, selectid), statement-level counters from
  `sqlite3_stmt_status` (vm_step, sort, fullscan_step, memused, etc.),
  and wall-clock execution time. SQLite's closest analog to PostgreSQL's
  `EXPLAIN (ANALYZE)`.
- **`Xqlite.open/2` and `Xqlite.open_in_memory/1`** — high-level open
  functions with validated options. Options are type-checked at the
  boundary and produce structured errors on misuse.
- **`Xqlite.enable_strict_table/2`** — converts an existing table to
  STRICT mode via the canonical SQLite rewrite dance.
- **`Xqlite.check_strict_violations/2`** — pre-scans a table for rows
  that would fail STRICT-mode type enforcement, so callers can fix
  data before flipping the switch.
- **Structured STRICT datatype violations.** When a STRICT table
  rejects a write, the error carries `source_type` and `target_type`
  atoms (`:integer`, `:real`, `:text`, `:blob`, `:null`) so callers
  can reason about the mismatch without parsing messages.
- **Structured invalid-option errors** from the option-validation
  layer; no regex on error text.

## [0.5.2] - 2026-03-16

### Added

- **`XqliteNIF.query_with_changes/3`** and **`query_with_changes_cancellable/4`**
  — return rows plus the `sqlite3_changes()` count in one atomic call,
  captured inside the connection Mutex so the count cannot be stolen by
  an intervening statement. Zero for non-DML results (detected by empty
  column list).
- **`Xqlite.query/3`** high-level wrapper that returns an
  `%Xqlite.Result{}` with a populated `changes` field.
- `Xqlite.Result` gained a `changes` field.

## [0.5.1] - 2026-03-16

### Added

- **`XqliteNIF.changes/1`** — returns the row count affected by the most
  recent DML (wraps `sqlite3_changes()`).
- **`XqliteNIF.total_changes/1`** — cumulative row count across the
  connection's lifetime (wraps `sqlite3_total_changes()`).

## [0.5.0] - 2026-03-16

Major feature release. Substantial surface added; several subtle
behavioral changes worth noting on upgrade.

### Added

- **Online backup API.** `XqliteNIF.backup/2` + `restore/2` (one-shot),
  plus `backup_with_progress/6` (page-by-page with progress messages to
  a PID, cancel-token support).
- **Session extension.** `session_new`, `session_attach`, `session_changeset`,
  `session_delete`, `changeset_invert`, `changeset_concat`,
  `changeset_apply` with conflict strategies (`:omit`, `:replace`,
  `:abort`).
- **Incremental blob I/O.** `blob_open`, `blob_read`, `blob_write`,
  `blob_close`. Read and write multi-GB column values without loading
  them into memory.
- **Extension loading.** `enable_load_extension/2` and
  `load_extension/2,3`. Opt-in; disabled by default.
- **Serialize / deserialize.** `serialize/1` captures the entire live
  database as a single binary byte-for-byte identical to its on-disk
  form; `deserialize/2` loads it back.
- **Log hook and update hook** via raw `enif_send`. Per-connection
  update notifications as `{:xqlite_update, action, db, table, rowid}`;
  global log hook as `{:xqlite_log, code, message}`.
- **Type extension behaviour.** `Xqlite.TypeExtension` for bidirectional
  Elixir↔SQLite conversion. Built-ins shipped for `DateTime`, `Date`,
  `Time`, `NaiveDateTime`.
- **`Xqlite.Result`** struct implementing the `Table.Reader` protocol —
  consumable directly by Explorer, Kino, VegaLite.
- **`XqliteNIF.transaction_status/1`** — structured query of the
  current connection's transaction state.
- **Read-only opens.** `open_readonly/1` and `open_in_memory_readonly/1`.
- **Transaction modes.** `deferred`, `immediate`, `exclusive`.
- **Schema-prefixed PRAGMAs.** `:db_name` option for PRAGMAs that accept
  a database name parameter.

### Changed

- **PRAGMA schema reworked** from a keyword list to `Xqlite.PragmaSpec`
  structs. Public shape change for anyone introspecting PRAGMA
  metadata.
- **PRAGMA SET now returns the echoed value** instead of discarding it,
  matching the `{:ok, echoed_value}` shape of the rest of the API.
- **`XqliteNIF.close/1` eagerly releases the underlying SQLite
  connection** rather than waiting for Elixir GC.
- **rusqlite upgraded 0.38 → 0.39.** UTF-8 errors now carry the column
  index of the offending value.

### Fixed

- Stream finalization data race where `sqlite3_finalize` could run
  without the connection Mutex held — a BEAM-segfault-class bug.
- `stream_fetch` now holds the Mutex for the entire fetch loop (was
  dropping it between steps).
- TOCTOU race in the `with_conn` closed-flag check.
- Atom-table exhaustion protection: user input no longer becomes atoms
  unconditionally.
- SQL length overflow guard in `stream_open`.
- Integer-truncation guard for FFI bind calls.
- Identifier quoting: single quotes → double quotes for SQLite spec
  compliance.
- PRAGMA name validation against SQL injection (reject non-identifier
  PRAGMA names).
- PRAGMA validation catch-all for unknown names and corrected numeric
  ranges.
- Interruption detection, cancel ordering, and error-code mapping.

## [0.4.1] - 2026-03-13

### Fixed

- Documentation, README, CI badge, and stale version references
  reconciled across the project.

## [0.4.0] - 2026-03-13

Promotes `v0.4.0-rc.1` to stable. No additional changes since rc.1.

## [0.4.0-rc.1] - 2026-03-13

### Added

- **Precompiled NIFs via `rustler_precompiled`.** No Rust toolchain is
  required to install from Hex. 8 targets covered:
  `aarch64-apple-darwin`, `x86_64-apple-darwin`,
  `aarch64-unknown-linux-gnu`, `x86_64-unknown-linux-gnu`,
  `aarch64-unknown-linux-musl`, `x86_64-unknown-linux-musl`,
  `riscv64gc-unknown-linux-gnu`, `x86_64-pc-windows-msvc`.

### Changed

- Rust edition upgraded 2018 → 2024.

## [0.3.1] - 2025-12-06

### Changed

- Dependencies refreshed.

## [0.3.0] - 2025-11-24

Initial public release. The supported SQLite functionality:

- **Bundled SQLite** — no system install required.
- **Queries, execution, and parameter binding** (positional and named).
- **Transactions** with named savepoints (nested-transaction support).
- **Streaming** row iteration compatible with `Stream.resource/3`.
- **Per-operation cancellation.** Progress-handler-based; any process
  can cancel an in-progress operation without holding the connection
  handle.
- **Typed PRAGMA system** with validated get/set.
- **Schema introspection** via `PRAGMA table_xinfo`, `index_list`,
  `index_xinfo`, `foreign_key_list`, etc. — surfaced as structured
  data, including generated and hidden columns.
- **STRICT table support.**
- **Read-only database opens.**
- **Structured error surface** — constraint violations and failure
  categories mapped to typed atoms (no string parsing needed by
  callers).
- **SQLite introspection** — `compile_options` and `sqlite_version`.

[0.12.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.12.0
[0.11.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.11.0
[0.10.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.10.0
[0.9.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.9.0
[0.8.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.8.0
[0.7.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.7.0
[0.6.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.6.0
[0.5.2]: https://github.com/dimitarvp/xqlite/releases/tag/v0.5.2
[0.5.1]: https://github.com/dimitarvp/xqlite/releases/tag/v0.5.1
[0.5.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.5.0
[0.4.1]: https://github.com/dimitarvp/xqlite/releases/tag/v0.4.1
[0.4.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.4.0
[0.4.0-rc.1]: https://github.com/dimitarvp/xqlite/releases/tag/v0.4.0-rc.1
[0.3.1]: https://github.com/dimitarvp/xqlite/releases/tag/v0.3.1
[0.3.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.3.0
