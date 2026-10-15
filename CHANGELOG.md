# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`cancel_tokens: nil` means no token**, as `[]` does, on `query/4`,
  `execute/4`, `execute_batch/3`, `multi_step/3`, `stream/4` and
  `backup_with_progress/4`, where it returned `{:error,
  {:invalid_cancel_tokens, _}}`. A list holding `nil` is still rejected,
  and so is `nil` on `cancel_operation/1` and on the raw functions.
- **`Xqlite.optimize/1` and `Xqlite.shrink_memory/1`** run the PRAGMAs of
  those names (see Changed), and the raw `XqliteNIF.optimize/1` is the
  call behind `optimize/1`. In autocommit, on a connection that can write
  and has `query_only` off, `optimize/1` runs `BEGIN IMMEDIATE`,
  `PRAGMA optimize` and `COMMIT` in one call that holds the connection,
  and rolls back on any failure. So it waits for a write lock another
  connection holds as the busy timeout or the busy policy says, and busy
  observers hear the wait, even when there is nothing to analyze; a deny
  of `:transaction` stops it; and it returns
  `{:error, :statement_mid_run}` while a statement, stream or blob of the
  connection is mid-run. Inside a transaction, and on a read-only
  connection or one with `query_only` on, it runs `PRAGMA optimize` alone.
- **`XqliteNIF.strict_rebuild/6`**, the raw call behind
  `Xqlite.enable_strict_table/2`. It runs a list of statements, each
  exactly one, in one `BEGIN IMMEDIATE` transaction while it holds the
  connection, with `foreign_keys` off and `legacy_alter_table` on, and puts
  both back once the transaction has ended. Inside the transaction, before
  any statement runs, it checks that the schema version of the table's
  database and the stored definitions of the table, its indexes and its
  triggers still equal the ones it is given. Any failure, a busy `COMMIT`
  included, rolls the transaction back. A table name holding a NUL byte
  returns `{:error, :null_byte_in_string}` before anything runs.
- **A Known limitations guide.** `guides/known_limitations.md` lists every
  limitation the library documents, with what to do instead, among them
  four ways a read-only connection can still write: through `ATTACH`,
  through `VACUUM INTO`, through `PRAGMA query_only = 0` or a
  journal-mode change, and through a `mode=ro&cache=shared` URI on
  `Xqlite.open/2` or `XqliteNIF.open/1`.
- **`Xqlite.get_limit/2` and `Xqlite.put_limit/3`**, and the raw
  `XqliteNIF.get_limit/2` and `XqliteNIF.put_limit/3`: SQLite's
  per-connection limits (`sqlite3_limit`), thirteen categories.
  `put_limit/3` returns the value now in force, read back under the same
  lock: SQLite lowers a value to its compile-time ceiling for the category
  and raises `:length` to 30. On `Xqlite.put_limit/3` any integer outside
  `0..2_147_483_647` is `{:error, {:invalid_limit_value, %{category: _,
  value: _}}}`, checked before the category; the raw function checks the
  same range and raises `ArgumentError` for an integer outside 64 bits.

### Changed

- **`Xqlite.Pragma.get/2,3,4` returns every row of `integrity_check` and
  `quick_check` as a list, on every form.** Without a number it returned
  SQLite's first row alone, as a string, and with a `:db_name` it raised
  `CaseClauseError` once SQLite reported more than one. A clean database
  now returns `{:ok, ["ok"]}` where it returned `{:ok, "ok"}`.
- **A blob handle closed by `blob_close/1` returns `{:error,
  :blob_closed}`** from `blob_read/3`, `blob_write/3`, `blob_size/1` and
  `blob_reopen/2` while its connection is open, where it returned
  `{:error, :connection_closed}`. Once the connection is closed, every
  blob call still returns `{:error, :connection_closed}`.
- **A batch run outside a transaction returns `{:error,
  :statement_mid_run}` while a statement, stream or blob of the connection
  is mid-run, and runs nothing.** A write such a statement runs would join
  a transaction the batch opens, and could be undone with it. Inside a
  transaction a batch runs as before.
- **The schema readers report a stored column name that is not UTF-8 by
  the column's place in its table.** `schema_columns/2`,
  `schema_foreign_keys/2` and `schema_index_columns/2` returned `{:error,
  {:utf8_error, n, message}}`, `n` naming a column of an internal query;
  they now return `{:error, {:column_name_not_utf8, %{column: place, name:
  bytes}}}`, as the query functions do for such a name in a result. A
  foreign key's parent table and column keep `{:utf8_error, _, _}`.
- **An option argument that is not a list returns an error on every
  function that takes an option list.** `open/2`, `open_in_memory/1`,
  `set_busy_policy/2`, `register_progress_hook/3`,
  `Xqlite.Telemetry.bridge/2` and `Xqlite.Telemetry.bridge_log/1` raised
  `FunctionClauseError` for a map, an atom or `nil` in that place; they
  now return `{:error, {:invalid_option, %{key: nil, value: term, reason:
  :not_a_pair}}}`, as the other functions do, before any file is opened or
  anything starts.
- **The raw `XqliteNIF.set_pragma/3` takes for `busy_timeout` only an
  integer from 0 to 2_147_483_647**, as `Xqlite.put_busy_timeout/2` does.
  Any other value, the name in any case, returns `{:error,
  {:invalid_pragma_value, %{pragma: :busy_timeout, value: value}}}` and
  keeps the wait in force. SQLite read a negative number, `:infinity`, a
  boolean or a string such as `"abc"` as no wait, a string or a float
  holding a number as that number, and an integer above 2_147_483_647 as
  0; an integer past 64 bits returned a conversion error.
- **Handles the garbage collector frees are released by a thread of
  xqlite's own, not by their destructors.** The NIF library starts an OS
  thread when it loads, and fails to load if the thread cannot start. The
  thread releases the statements, streams, blobs and sessions the garbage
  collector frees while their connection is idle, and closes the
  connections dropped without `close/1`; a handle collected while a call
  holds its connection is released by that call before it returns, so
  that call can wait for the commit the release makes. The docs of
  `Xqlite.prepare/2`, `XqliteNIF.stmt_prepare/2` and
  `XqliteNIF.stmt_finalize/1` say so. The thread serves every connection,
  one release after another, so a release that waits in its connection's
  busy handler, or the close of a dropped connection, delays the releases
  of the others. A release is no longer finished when the collection
  returns: another connection that meets the handle's lock right after it,
  with no busy timeout, gets a busy error. Where that matters, finalize,
  close and delete handles yourself, and close connections with
  `close/1`, as the Known limitations guide says. From the first
  connection it opens, the NIF library keeps a resource of its own alive,
  so that the BEAM never unloads the code the thread runs, even after the
  module is purged: the library stays loaded until the node stops.
- **A transaction another process opens while
  `Xqlite.enable_strict_table/2` is starting returns `{:error,
  :transaction_in_progress}`.** The rebuild checked for an open
  transaction before it read the table. A transaction opened between that
  check and the rebuild's own `BEGIN` made the call return
  `{:error, {:sqlite_failure, 1, 1, "cannot start a transaction within a transaction"}}`.
  The rebuild now checks again inside its call, before anything is
  switched, and returns what it returns for the caller's own transaction.
- **`:unknown` in a deny list no longer matches an `ATTACH` or `DETACH`.**
  An `ATTACH` whose file name was a bound parameter or an expression, and
  such a `DETACH`, counted as `:unknown`, so a deny list naming `:unknown`
  stopped them where one naming `:attach` or `:detach` did not. They now
  count as `:attach` and `:detach` (see Fixed), and no action of the
  bundled SQLite counts as `:unknown`.
- **More strings that hold a second statement return `{:error,
  :multiple_statements}`, with nothing changed.** The text after the
  first statement is no longer compiled (see Fixed), so the authorizer is
  no longer asked about a second statement either. These return the new
  error:
  - text after the first statement that holds anything but whitespace,
    comments and semicolons, where it returned its own compile error when
    it was no valid statement or did not compile: `"SELECT 1; garbage"`,
    `"SELECT 1; SELECT * FROM missing"`, or a lone vertical tab or `/*`
    after the first statement;
  - a string holding a second statement the authorizer denies, and, under
    a `:pragma` deny, a string whose first statement is a PRAGMA and that
    holds a second, where it returned `{:error, {:authorization_denied,
    23, _}}`;
  - with a busy policy or observer installed, a string holding a
    `busy_timeout` write and a second statement, where it returned the
    error a `busy_timeout` write gets then, whichever statement held the
    write; a `busy_timeout` write on its own still gets that error;
  - a string whose first statement is a PRAGMA, which is now checked
    before SQLite reads it: one that holds more and is longer than the
    connection's SQL length limit, which returned
    `{:error, {:too_big, 18, _}}`; `"PRAGMA foreign_keys = OFF $a(;x)"`,
    whose semicolon SQLite reads inside a variable, which returned a
    syntax error with foreign-key enforcement turned off; and
    `"EXPLAIN ; PRAGMA foreign_keys = OFF; SELECT 1"`, which returned a
    syntax error.
- **One vocabulary in the docs.** The README, the guides and the module
  docs say "reject" and "rejection" for an input the library turns away,
  where they mixed in other words for it, and use one word, "function",
  for the library's public functions.
- **`changeset_apply/3` names the foreign key in its key error.** A
  changeset SQLite rolls back for a broken foreign key returns
  `{:error, {:constraint_violation, :constraint_foreign_key, details}}`
  under every strategy, the kind an ordinary write's key error carries.
  Under `:replace` and `:abort` it returned the kind
  `:constraint_violation`.
- **`blob_size/1` asks SQLite on every call.** On a handle whose row
  changed, it now ends the handle as a read does and returns
  `{:error, {:sqlite_failure, 4, _, _}}`, and so does a later
  `blob_reopen/2`. It returned the size fixed at the open, and a later
  reopen still moved the handle. A reopen made before any read, write or
  size call still moves it.
- **One `cancel_tokens:` option replaces the `_cancellable` functions.**
  `Xqlite.query/4`, `execute/4`, `execute_batch/3` and `multi_step/3` take
  one token or a list (default `[]`) and keep their return values:
  `query/4` and `execute/4` return `%Xqlite.Result{}` with or without
  tokens, where the removed `query_cancellable/5` and
  `query_with_changes_cancellable/5` returned a plain map and
  `execute_cancellable/5` returned `{:ok, count}`. The raw `XqliteNIF`
  cancellable functions stay. Removed lists the functions this replaces.
- **`Xqlite.Pragma.get` no longer runs the PRAGMAs that act**: `optimize`,
  `shrink_memory`, `wal_checkpoint` and `incremental_vacuum` return
  `{:error, {:unknown_pragma, name}}` there. `Xqlite.optimize/1`,
  `Xqlite.shrink_memory/1` and `Xqlite.wal_checkpoint/3` run them, and
  `Xqlite.query/4` runs `incremental_vacuum`, or `optimize` with a mask.
- **`journal_mode`, `locking_mode` and `encoding` read back as atoms** from
  `Xqlite.Pragma.get` (`:wal`, `:exclusive`, `:utf8`, `:utf16le`,
  `:utf16be`), and a write takes the atom, or the text in any case.
- **`Xqlite.enable_load_extension/1` and `disable_load_extension/1`
  replace `enable_load_extension/2`**, each with its own event:
  `[:xqlite, :extension, :enable]` and the new
  `[:xqlite, :extension, :disable]`, both with metadata `%{conn}` (the
  `:enabled` key is gone).
- **`load_extension/3` and `deserialize/4` take options.** `entry_point:`
  replaces the positional entry point (leave it out to let SQLite find the
  init function), and `read_only:` replaces the boolean of `deserialize/4`,
  whose schema stays positional; options given in the schema's place load
  into `"main"`, as in `deserialize(conn, data, read_only: true)`. A value
  of the wrong kind returns `{:error, {:invalid_option, _}}`, and so does a
  call in the old positional form.
- **`backup_with_progress/6` becomes
  `backup_with_progress(conn, dest_path, pid, opts)`**, the destination
  first as in `backup/3`, with `schema:` (default `"main"`),
  `pages_per_step:` (default 100; a bad value returns
  `{:error, {:invalid_pages_per_step, value}}`) and `cancel_tokens:`.
- **A PRAGMA write through `Xqlite.Pragma.put/3,4` returns `:ok`, or
  `{:error, {:pragma_not_applied, %{pragma: name, asked: value, in_force:
  value}}}` when SQLite reports another value**, with or without
  `db_name:`: `journal_mode: :wal` on an in-memory database,
  `max_page_count` below the page count, a heap limit SQLite will not
  raise. No write returns `{:ok, value}` any more. The error can follow a
  change, since `in_force` is what holds after the write:
  `max_page_count: 1` sets the limit to the page count, so the next insert
  that needs a page fails with "database or disk is full"; a
  `soft_heap_limit` above the hard one is set to the hard one; and in
  memory a `locking_mode: :normal` write returns `in_force: :exclusive`,
  which `get(conn, :locking_mode, db_name: "main")` also reads, while a
  plain `get` returns `:normal`. A write SQLite answers with no row, such
  as `page_size` on a database with content, returns `:ok`;
  `Xqlite.Pragma.get` tells what holds. `Xqlite.Pragma.put/4` rejects
  `db_name:` for `busy_timeout` and `wal_autocheckpoint`, as `get` does, so
  such a write no longer stops the WAL hook messages.
  `enable_foreign_key_enforcement/1` and
  `disable_foreign_key_enforcement/1` return `:ok`.
- **`open/2` and `open_in_memory/1` return `{:error, {:invalid_option,
  %{key: key, value: value, reason: :invalid_value}}}` for an option value
  outside what SQLite stores**, with the value as given: the shape an
  option already returns when its value has the wrong type. They returned
  `{:error, {:invalid_pragma_value, %{pragma: key, value: value}}}`.
  `Xqlite.Pragma.put/3,4` keeps `:invalid_pragma_value`.
- **`backup/3` and `backup_with_progress/4` return
  `{:error, {:cannot_open_database, dest_path, code, message}}` for a
  destination SQLite cannot open**, such as a path in a missing directory,
  as `restore/3` does for its source. They returned
  `{:error, {:sqlite_failure, 14, 14, message}}`.
- **`XqliteNIF.stream_close/1` raises `ArgumentError` for a term that is
  not a stream handle**, like `stream_fetch/2`, `stmt_finalize/1`,
  `blob_close/1` and the other handle functions. It returned
  `{:error, {:invalid_stream_handle, text}}`; that shape is gone from
  `Xqlite.error_reason/0`.
- **SQL text longer than 2 147 483 647 bytes returns
  `{:error, {:too_big, 18, message}}` on every function that compiles one
  statement** (the query, execute, prepare, stream and `explain_analyze`
  functions). `stmt_prepare/2`, `stream_open/3`, `explain_analyze/3` and
  the `Xqlite` functions built on them returned
  `{:error, {:cannot_execute, "SQL string length exceeds c_int range"}}`
  after copying the whole text; they now check the length before any copy
  and return what the others return. SQL over the connection's SQL length
  limit (`:sql_length`, at most 1 000 000 000 bytes) returns the same tag,
  as it did. A text holding a NUL byte returns
  `{:error, :null_byte_in_string}` first, whatever its length.
- **`:execute_returned_results` is gone: the execute functions run a
  statement that returns rows to its end, drop the rows and return the
  count.** This holds for `Xqlite.execute/4` and the raw
  `XqliteNIF.execute/3` and `execute_cancellable/4`; `query/4` reads the
  rows. An `INSERT`, `UPDATE` or `DELETE ... RETURNING` through them
  returns its count, where it made the write and then returned that error.
  A `SELECT` returns a count of 0. A PRAGMA that returns a row,
  `journal_mode = WAL` for one, takes effect and returns 0, where it took
  effect and then returned the error. `PRAGMA incremental_vacuum` frees
  every page it is asked to, where it freed one page and returned the
  error. Since a statement that returns rows, through the execute
  functions or a batch, now reads every row, one that never ends never
  returns: a `SELECT` that never ends, such as a recursive CTE without a
  limit, used to return after its first row (the execute functions with
  `:execute_returned_results`, `execute_batch/3` with `:ok`), and now runs
  until a cancel token stops it, given to `execute/4` or `execute_batch/3`
  through `:cancel_tokens`, or to the raw `execute_cancellable/4` or
  `execute_batch_cancellable/3`. Reading a million rows costs about
  100 ms.
- **The SQL length limit (`:sql_length`) applies to each statement of a
  batch, a trailing comment included.** A batch longer than a lowered limit
  used to run nothing even when every statement fit; it now runs, and a
  trailing comment longer than the limit fails after every statement ran.
- **A batch that fails or is cancelled inside a transaction it opened
  itself (`BEGIN` or `SAVEPOINT`) rolls that transaction back, a `COMMIT`
  that failed as busy included**, so the next `commit/1` no longer commits
  the statements that ran before the failure. Run the whole batch again
  rather than retrying the `COMMIT`. A transaction open before the call
  stays open with the batch's earlier statements in it, and so does one the
  batch opens after committing the caller's (`COMMIT; BEGIN; ...`). A
  `ROLLBACK` that fails leaves the transaction open under the batch's own
  error, and `autocommit/1` says so.
- **`commit/1` and `rollback/1` return `{:error, :no_transaction}` when no
  transaction is open**, on `Xqlite` and `XqliteNIF` alike, before any
  statement runs. They returned `{:error, {:sqlite_failure, 1, 1,
  message}}` before. `@type error_reason` gains `:no_transaction`.
- **`commit/1`, `savepoint/2` and `release_savepoint/2` return
  `{:error, :statement_mid_run}` while a write of the same connection is
  mid-run**, on both modules: a write stepped but not yet run to its end or
  reset, or a blob open for writing. SQLite rejects them with `SQLITE_BUSY`
  then, which came back as `{:database_busy_or_locked, 5, _}`, the error a
  lock held by another connection gives, so code that retries on busy
  retried against its own statement. A lock still returns
  `{:database_busy_or_locked, 5, _}`; `rollback/1` and
  `rollback_to_savepoint/2` run whatever is mid-run.
- **The query functions read rows through the code statements and streams
  use.** `XqliteNIF.query/3`, `query_cancellable/4`,
  `query_with_changes/3` and `query_with_changes_cancellable/4` no longer
  read rows through rusqlite: mixed rows read 11-12 % faster. An
  unreadable value or a failed step still returns the error with no rows.
  A BLOB larger than 64 bytes now comes back as a resource binary from
  step, multi_step and stream too, as it did from query; the bytes are
  unchanged.
- **Backup progress messages are
  `{:xqlite_backup_progress, %{remaining: r, total: t, status: :copied | :busy}}`.**
  A `:busy` message sent before any step copied pages carries
  `remaining: nil, total: nil` (was `0` and `0`); a `:busy` after a copied
  step carries that step's counts.
- **A cancel token already signalled comes before an SQL or parameter
  error** on the one-shot calls that take tokens: `query/4`, `execute/4`
  and `execute_batch/3` given `:cancel_tokens`, and the raw
  `XqliteNIF.query_cancellable/4`, `query_with_changes_cancellable/4`,
  `execute_cancellable/4` and `execute_batch_cancellable/3` return
  `{:error, :operation_cancelled}`, since the tokens are read before the
  SQL is prepared. With `:type_extensions` set, a parameter list that is
  not a proper list returns its error first, because the extension check
  runs in Elixir before the native call reads the tokens.
- **`Xqlite.put_busy_timeout/2` replaces `Xqlite.busy_timeout/2`, and it
  no longer removes the retry policy:** while a policy is set it decides
  the wait, and the timeout written applies once `remove_busy_policy/1`
  runs. The new `Xqlite.get_busy_timeout/1` returns the timeout the
  connection keeps; `Xqlite.Pragma.get/2` and `XqliteNIF.get_pragma/2`
  return it too while a busy policy or observer is installed, where they
  returned SQLite's 0. `Xqlite.Pragma.get/3` rejects `:db_name` for
  `busy_timeout` and `wal_autocheckpoint`.
- **One tag for a bad option list everywhere:** `{:invalid_option, %{key,
  value, reason: :unknown_key | :duplicate_key | :invalid_value |
  :not_a_pair}}` (with `allowed` on `:unknown_key`) replaces
  `:invalid_open_option`, `:invalid_hook_option` and the telemetry bridge's
  `{:invalid_hook, _, valid: _}`. `set_busy_policy/2`,
  `register_progress_hook/3`, `stream/4`, the `:type_extensions`
  functions, `Xqlite.Telemetry.bridge/2` (its `:progress` list included)
  and `bridge_log/1` now reject a misspelled key instead of installing the
  default, reject a key given twice instead of using its first value, and
  return an error instead of raising for an out-of-range number or a
  malformed list.
- **`Xqlite.open/2` and `Xqlite.open_readonly/1` reject `""` and
  `":memory:"` with `{:invalid_path, %{path}}`;** use `open_temporary/0`
  and `open_in_memory/1`. `file:` URIs pass as written.
- **`XqliteNIF.open_in_memory/1` opens any name but `":memory:"`, `file:`
  URIs included, with `SQLITE_OPEN_MEMORY` and ATTACHes a plain path in
  memory;** a plain file name no longer creates a file, while an ATTACH by
  a URI naming a `mode=` still reaches the file. `":memory:"`, the name
  `Xqlite.open_in_memory/1` passes, is unchanged.
- **`backup_with_progress/4` returns `{:error, {:database_busy_or_locked,
  code, message}}` for a blocked step,** as `backup/3` does, instead of
  retrying every 100 ms until a token fires.
- **Seven PRAGMAs take and return typed values instead of coded
  numbers:** `cache_size` `{:pages, n}` or `{:kib, n}` (the open default
  is now `{:kib, 64_000}`), `wal_autocheckpoint` and `cache_spill` `:off`
  or a count, `journal_size_limit`, `analysis_limit`, `soft_heap_limit`
  and `hard_heap_limit` `:unlimited` or a count. A bare coded number is
  rejected.
- **`txn_state/2` and `schema_list_objects/2` default to `"main"` and take
  `:all` for every attached database;** `nil` no longer means every
  database. `XqliteNIF.txn_state/2`, `wal_checkpoint/3` and
  `schema_list_objects/2` lose their defaults (see Removed), and
  `session_attach/2` takes `:all` instead of `nil`.
- **A schema name that is not attached returns `{:error, {:no_such_schema,
  name}}`** on every function that takes one, before anything is opened or
  changed; `""` returns `{:error, {:invalid_schema_name, ""}}` (SQLite read
  it as every database, so `wal_checkpoint(conn, mode, "")` checkpointed
  all of them).
- **A table or index name that names nothing returns `{:error,
  {:no_such_table, name}}` or `{:error, {:no_such_index, name}}`** instead
  of `{:ok, []}` on `schema_columns/2`, `schema_foreign_keys/2`,
  `schema_indexes/2`, `schema_index_columns/2` and the Pragma functions
  `table_info`, `table_xinfo`, `index_list`, `index_info`, `index_xinfo`
  and `foreign_key_list`.
- **`get_create_sql/2` returns `{:error, {:no_such_object, name}}`**
  instead of `{:ok, nil}` for a name nothing carries; `{:ok, nil}` now
  means an automatic index.
- **`schema_list_objects(conn, "MAIN")` lists main's objects;** the listing
  compared the name byte for byte and returned `{:ok, []}`.
- **`restore/3` from a path that does not exist, or from a name SQLite
  gives no file for (`""`, `":memory:"`, `"file::memory:"`, a
  `mode=memory` or `vfs=memdb` URI), returns `{:error,
  {:cannot_open_database, path, code, message}}` and changes nothing;** it
  created an empty file and copied it over the schema.
- **SQL holding no statement returns `{:error, :no_statement}`** instead of
  `{:error, {:cannot_execute, "SQL contains no statement"}}`.
- **`wal_checkpoint/3` on a named database not in WAL mode returns
  `{:error, :not_in_wal_mode}`** instead of `-1` page counts, and a
  checkpoint lock another connection holds returns
  `{:error, {:database_busy_or_locked, 5, _}}`.
- **`connection_stats/1` reports the half SQLite defines for each
  counter.** `lookaside_hit`, `lookaside_miss_size` and
  `lookaside_miss_full` report SQLite's running totals (they read 0
  before); `deferred_fks` is now `deferred_fks?`, a boolean; every counter
  is read as 64 bits.
- **Tagged errors carry the rejected term.** `{:invalid_checkpoint_mode,
  mode}`, `{:invalid_schema_name, term}` (`wal_checkpoint/3`,
  `txn_state/2`), `{:invalid_transaction_mode, mode}` and
  `{:invalid_conflict_strategy, strategy}` (were bare atoms),
  `{:blob_write_out_of_bounds, %{offset, byte_size, blob_size}}`,
  `{:invalid_option, _}` from the raw progress-hook NIF, and
  `{:invalid_pragma_value, %{pragma: :busy_timeout, value}}` from
  `put_busy_timeout/2` and the raw setters.
- **`put_busy_timeout/2` returns its error for 2^64 and above instead of
  raising**, and so does `register_progress_hook/3` for `every_n` above
  4_294_967_295.
- **A keyword list binds through a map of the statement's names, and is
  taken only on a statement of at most 2 048 parameters.** Each key was
  resolved by walking the statement's whole list of parameter names, one
  string comparison per name, and the functions going through rusqlite let
  it resolve every name a second time. Both binding paths now read the
  statement's own names once into a map built per call and bind by index,
  so the connection lock is held for less time. Above 2 048 parameters,
  every function that takes a keyword list returns `{:error,
  {:too_many_named_parameters, %{count: n, limit: 2048}}}` before a value
  is read; a positional list binds at any count. The map costs 7.1 ms at
  2 048 parameters on one machine and grows faster than the count:
  reading the name at one index is itself a walk of SQLite's parameter
  list, and its C interface offers no way to read them all in one pass.
  SQLite's own prepare of SQL with that many names costs about twice the
  map, grows the same way, and no parameter list avoids it: 14, 193 and
  3 023 ms at 2 048, 8 192 and 32 766 names. Written with bare `?` the
  same statement prepares in 1.0, 4.7 and 20.7 ms, so a statement with
  thousands of parameters is written with `?` and bound with a positional
  list.
- **A type extension's `decode/1` can reject a stored value, and a callback
  result outside the three shapes returns an error instead of raising.** A
  `decode/1` that claims a value but cannot read it returns
  `{:error, reason}`, and every function that decodes rows returns
  `{:error, {:type_extension_refused, %{column: n, extension: module,
  reason: reason}}}`, `n` being the value's one-based place in its row.
  `stream/4` hands over the rows decoded before it, then returns the error
  under its `:on_error` mode. The query functions decode after the
  statement ran, so its changes stand. An `encode/1` or `decode/1`
  returning anything but `{:ok, value}`, `:skip` or `{:error, reason}`
  raised `CaseClauseError`; it is now the same error with
  `reason: {:bad_return, answer}`.
- **`Xqlite.TypeExtension.decode_value/2` returns `{:ok, decoded}` or
  `{:error, %{extension: module, reason: reason}}`**, as `encode_value/2`
  does, where it returned the bare decoded value: an error can no longer be
  mistaken for a value that decoded to an error tuple.
- **`{:value_too_large, _}` is now returned by every function that
  binds**, where the functions going through rusqlite returned
  `{:sqlite_failure, 18, 18, "string or blob too big"}` and the raw
  functions rejected only values above two gigabytes. The limit in the
  error is the connection's own, which `Xqlite.get_limit/2` reads and
  `Xqlite.put_limit/3` sets.
- **`SQLITE_TOOBIG` is classified as `{:too_big, code, message}`**
  wherever SQLite returns it. It no longer comes from a bind, but it still
  comes from a step: SQLite checks the same limit against the row it
  builds, a concatenation and a column read.
- **`Xqlite.TypeExtension.encode_params/2` and `decode_rows/2` check their
  extension list.** Both are public and are what the raw-statement docs
  recommend for the rows `step/1` and `multi_step/2` return, and both took
  the list as given: a list that was no proper list of extension modules
  raised from the chain, and a module such as `Jason`, which exports both
  callback names without being an extension, silently rewrote values.
  Both now check the list the way every function that takes
  `:type_extensions` does and return
  `{:error, {:invalid_type_extensions, rejection}}` for one that fails; and
  `decode_rows/2` returns `{:ok, rows}` where it returned the bare rows.
  `encode_value/2` and `decode_value/2` still take the list as given: they
  run once per value, and the caller vouches for it.
- **`:type_extensions` is checked before anything else runs.** A term that
  is no proper list of extension modules reached `length/1` or the encode
  chain and raised: `Xqlite.stream(conn, sql, params, type_extensions:
  [JSON | :x])` raised `ArgumentError`, and `query/4`, `execute/4` and
  `bind/3` raised `FunctionClauseError`. Any atom passed, so
  `type_extensions: [Xqlite.TypeExtension.JSON, :nope]` (`:nope` standing
  for a misspelled module name, or for an empty variable holding `nil` or
  `false`) ran until the first value was encoded and then raised
  `UndefinedFunctionError`. Every function that takes the option now
  returns `{:error, {:invalid_type_extensions, rejection}}` before its
  telemetry and before the NIF, `rejection` naming what stopped the check
  (`:not_a_list`, `:improper_tail`, or `:bad_element` with the element's
  one-based position) and the kind of term it was: an element that is no
  extension module is
  `%{reason: :bad_element, position: n, value_type: :atom}`.
  `nil` and an absent option both mean no extensions. An element counts
  as an extension module when three things hold: the atom names a module
  that can be loaded, the module declares `@behaviour Xqlite.TypeExtension`,
  and it exports both `encode/1` and `decode/1`. Two kinds of list that
  worked before now stop. A module that exports `encode/1` and `decode/1`
  without declaring the behaviour: `Jason` and OTP's `:json` both do, and
  `type_extensions: [Jason]` silently stored the integer `1` as the text
  `"1"`. And a module that exports `encode/1` but not `decode/1`, on the
  functions that never decode (`execute/4`, `explain_analyze/4` and
  `bind/3`), which ran it to completion. A module written to the shape the
  `Xqlite.TypeExtension` moduledoc shows is unaffected. Only the behaviour
  declaration is remembered per module: both callbacks are checked on
  every call, and a false there runs the whole check again, so a module
  recompiled without `encode/1` or `decode/1`, or purged, fails the check
  at the next call, and a module merely unloaded is loaded again and
  passes.
- **An integer SQLite has no room for returns a structured error.** A
  number past the signed 64-bit range returned
  `{:cannot_convert_to_sqlite_value, "9223372036854775808", "{error, badarg}"}`,
  a tag carrying two debug strings, which four different causes shared.
  The tag is gone. A parameter outside the range is now
  `{:error, {:integer_out_of_range, %{position: n}}}`, `n` being the
  value's one-based place in the list; `XqliteNIF.set_pragma/3` checks one
  value with no list around it and returns
  `{:error, {:integer_out_of_range, %{}}}`. A TEXT or BLOB parameter longer
  than SQLite's C interface can be told about returns
  `{:error, {:value_too_large, %{byte_size: _, limit: _}}}`.
- **A key named twice in a parameter list is rejected.** `[a: 1, a: 2]`
  bound the second value, where every `Keyword` function reads the first.
  Two keys that name the same parameter (`[{:a, 1}, {:":a", 2}]` included,
  since both name `:a`) now return
  `{:error, {:duplicate_parameter_name, name}}`, with the second key's name
  as it resolved, whatever the values.
- **A rejected batch size reports the caller's own term.** The raw stream
  fetch functions tagged it (`{:integer, 0}`, `{:float, 1.0}`,
  `{:atom, :ten}`) while the statement functions put the bare number, so
  `{:invalid_batch_size, %{provided: _, minimum: 1}}` had two shapes.
  `provided` is now the term as the caller wrote it on both:
  `XqliteNIF.stream_fetch(s, 1.0)` returns `provided: 1.0`. The stream
  fetch functions are the only ones that return an error for a wrong type,
  because they take the term and check it; the statement functions take an
  integer argument, so Rustler raises `ArgumentError` for anything else
  before the function runs, which is what keeps a huge batch size out.
- **`Xqlite.stream/4` checks its batch size at the call.** The option is
  checked beside `:on_error` and `:cancel_tokens`, so a value that is not
  an integer in `1..9223372036854775807` returns
  `{:error, {:invalid_batch_size, %{provided: value, minimum: 1}}}` from
  `stream/4` itself. `batch_size: 0` opened the stream and raised
  `Xqlite.StreamError` on the first element taken out of it, and
  `batch_size: 2 ** 63`, which the native fetch cannot read as a signed
  64-bit integer, opened a stream that died on its first batch; under
  `on_error: :halt` that was an empty stream with no error at all.
  `Xqlite.multi_step/2` keeps its integer guard.
- **Six raw-statement helpers in the native crate are `unsafe fn`.** The
  helpers that take a raw `sqlite3_stmt` pointer (the parameter-count
  check, the check that a keyword list names every parameter, the two
  binders, the value binder and the stream's parameter binding) were
  ordinary safe functions whose contract lived in a comment. Each now
  carries a `# Safety` section naming it (the caller holds the connection
  Mutex; the pointer is a live prepared statement of that connection), and
  every caller says which lock it holds. No behaviour changes.
- **The check that the NIF library unwinds on a panic reads every
  platform's library, and the release workflow runs it.**
  `scripts/panic_strategy.exs` looked for `_Unwind_RaiseException` with
  `nm` whatever the library was. An MSVC-built `.dll` keeps no symbol
  table `nm` can read and unwinds through Windows exceptions instead, so
  the check reported an abort build on every Windows runner. A `.dll` is
  now read with `objdump -p` (or `llvm-objdump`) and passes when its
  import table names `_CxxThrowException` or `__CxxFrameHandler3`; every
  other library is read with `nm -u` (or `llvm-nm`) as before. Both
  families look for their tool on `PATH` and in the rustup sysroot where
  `rustup component add llvm-tools` puts the LLVM ones, and
  `XQLITE_SYMBOL_TOOL` names a tool to use instead. A failed check names
  the tool, the library and every line of the tool's output that mentions
  unwinding, so one CI log is enough to tell a wrong marker from a real
  abort build. The script used to glob for libraries and read the newest
  file it found, which could be the crate's own build under
  `native/xqlitenif/target`, a file nothing loads; it now takes the
  libraries to read as arguments and checks each one, and `mix verify`
  hands it `priv/native/xqlitenif.{so,dll}`. It also fails, instead of
  passing with a notice, when no tool that lists symbols is on the
  machine. Every build job of the release workflow unpacks the library it
  produced and, before the upload, reads it for the same markers with the
  same two tools (`llvm-nm -u` for an ELF or Mach-O library,
  `llvm-objdump -p` for a DLL). A missing marker, or a library the job
  cannot find or read, fails the job, so that target ships no asset; the
  job summary names the library, the tool and the marker lines it found.
- **`{:expected_keyword_tuple, _}` carries the same map as its siblings.**
  An element of a keyword parameter list that is not an `{atom, value}`
  pair came back as the Rust debug text of the caller's own element, which
  put the caller's data, a password in a named parameter included, inside
  an error term, and threw away the position the decoder had in hand. It is
  now `%{reason: :bad_element, position: n, value_type: type}`, the map
  `{:expected_list, _}` and `{:expected_keyword_list, _}` already carry,
  with `n` the one-based position of the element and `type` its kind.
- **`{:invalid_cancel_tokens, _}` holds the same map on every function,
  and a raw cancellable NIF says which of its two lists it rejected.** The
  `Xqlite` functions returned the caller's own value and the raw NIFs
  `%{position: n}`; both now return
  `%{reason: :bad_element, position: n, value_type: type}` for an element
  that is not a live token. The `Xqlite` functions, which take one token
  or a list of them, return position 1 for a single term that is not a
  token and `%{reason: :improper_tail, value_type: type}` for a list whose
  tail is not `[]`. `Xqlite.cancel_operation/1` takes one token and
  rejects a list, an empty one and a list of live tokens included, as the
  one element it was handed. On the raw NIFs a token argument that is not
  a list, or a list with a broken tail, returned
  `{:error, {:expected_list, _}}`, byte for byte what a bad parameter list
  returns, on `execute_batch_cancellable/3` too, which has no parameters.
  Every rejected token argument is now
  `{:error, {:invalid_cancel_tokens, rejection}}` with `:not_a_list`,
  `:improper_tail` or `:bad_element` as the reason, so `{:expected_list,
  _}` on a cancellable call is always about the parameters. The reason
  still differs for a term that is not a list: the raw NIF takes a list
  and nothing else and returns `%{reason: :not_a_list, value_type: type}`,
  while the `Xqlite` function reads a bare term as one token and returns
  `:bad_element` at position 1.
- **`XqliteNIF.stmt_bind/2` reads `nil` as no parameters, like its
  siblings.** `query`, `execute`, `query_with_changes`, `explain_analyze`
  and `stream_open` all took a parameter term of `nil` as "no parameters"
  while `stmt_bind` returned `{:expected_list, _}` for it. One rule now, in
  one place: `stmt_bind(stmt, nil)` means zero parameters, so it returns
  `:ok` on a statement that takes none and `{:invalid_parameter_count, _}`
  on one that takes any (see the parameter-count fix under Fixed).
  `Xqlite.bind/2,3` reads `nil` the same way and returns
  `{:expected_list, %{reason: :not_a_list, value_type: type}}` for any
  other term that is not a list.
- **`Xqlite.Pragma` checks its options.** The options position (the last
  argument of `get/4` and `put/4`, and the third argument of `get/4` when
  it is a keyword list, the two being merged) reached `Keyword.get/3`
  unchecked: a term that is not a list raised `FunctionClauseError`
  several calls deep, and `[1]`, `[:db_name]` and `[foo: 1]` were silently
  ignored. Options are now a keyword list whose only key is `:db_name`,
  whose value is a string, an atom or `nil`; anything else returns
  `{:error, {:invalid_pragma_argument, %{pragma: name, value: value,
  reason: :invalid_options}}}` before a statement is built, `value` being
  the whole term when it is not a keyword list and the `{key, value}` pair
  that could not be read when it is one. The named accessors
  (`table_info/3` and its siblings) reach `get/4` and inherit it.
- **`Xqlite.Pragma.get_result/0` names `:no_value`.** The atom is what
  every read function returns for a PRAGMA the connection has no row for
  (`mmap_size` on a database that is not a file, and `legacy_file_format`
  and `incremental_vacuum` on any database), and it was hidden inside
  `atom()` with nothing saying when it comes. The type names it, the
  `get/3,4` doc says when it comes, and no write function takes it back.
- **A binary that is not UTF-8 where text was meant returns an error
  instead of raising.** Every argument the native side reads as text (the
  SQL of the six query functions and their cancellable counterparts, the
  paths and URIs of the openers, savepoint names, table and index names,
  `get_create_sql/2`'s object name, the schema and path of `serialize`,
  `deserialize`, `load_extension`, `backup` and `restore`,
  `blob_open/6`'s three names, a progress hook's tag and a session's
  table) raised `ArgumentError` for a binary holding bytes that are not
  UTF-8, out of functions whose specs promise `{:ok, _} | {:error, _}`.
  They now return `{:error, :invalid_utf8_in_string}`, beside
  `{:error, :null_byte_in_string}`. A term that is not a binary at all
  still raises, the documented kind for a wrong type on a raw function. On
  the typed PRAGMA functions a `:db_name` or an argument whose bytes are
  not UTF-8 returns `{:error, {:invalid_pragma_argument, %{pragma: name,
  value: value, reason: :invalid_utf8}}}`, and a raw PRAGMA name returns
  `{:error, {:invalid_pragma_name, name}}` with the bytes as they were
  given. `XqliteNIF.set_pragma/3` returns `{:error,
  :invalid_utf8_in_string}` for such a value, where it returned
  `{:error, {:cannot_execute_pragma, name, _}}`; `Xqlite.Pragma.put/3,4`
  returns `{:error, {:invalid_pragma_value, _}}`, a value that PRAGMA
  cannot take.
- **`mmap_size` takes the values this build keeps.** Its domain was the
  shared 32-bit range, while the bundled SQLite is built with
  `MAX_MMAP_SIZE=0x7fff0000`: it stored the maximum for anything above
  that and 0 for anything negative, and both were accepted as written. The
  domain is now `0..0x7FFF0000`, so a negative size and one past the
  ceiling return `{:error, {:invalid_pragma_value, %{pragma: :mmap_size,
  value: value}}}`; `0`, which turns memory mapping off, stays legal.
- **A rejected parameter list reports its own length on every function.**
  The `provided` number of `{:invalid_parameter_count, %{expected: _,
  provided: _}}` differed by function for a list two or more elements too
  long: `Xqlite.query/4`, `Xqlite.execute/4`, `XqliteNIF.query/3`,
  `XqliteNIF.execute/3`, `XqliteNIF.query_with_changes/3` and the raw
  cancellable functions behind them bind through rusqlite, which stops at
  the first index the statement does not have and reports that index, so
  a one-parameter statement handed three values returned `provided: 2`
  while `stream/4`, `bind/3` and `explain_analyze/4` returned
  `provided: 3`. Those functions now count the list before binding
  anything, so `provided` is the list's own length everywhere. The error
  itself, and the `expected` number, are unchanged.

### Removed

- **`Xqlite.query_cancellable/4,5`, `query_with_changes_cancellable/4,5`,
  `execute_cancellable/4,5`, `execute_batch_cancellable/3` and
  `multi_step_cancellable/3`.** Use `query/4`, `execute/4`,
  `execute_batch/3` and `multi_step/3` with the `:cancel_tokens` option
  (see Changed). The raw `XqliteNIF` cancellable functions stay.
- **`Xqlite.transaction_status/1`.** `Xqlite.autocommit/1` answers the
  same question the other way round: `{:ok, true}` while no transaction is
  open.
- **`Xqlite.get_pragma/2` and `Xqlite.set_pragma/3`.** `Xqlite.Pragma.get`
  and `put` are the PRAGMA functions; a PRAGMA that `Xqlite.Pragma` does
  not model is reached with `Xqlite.query/4` or the raw
  `XqliteNIF.get_pragma/2` and `set_pragma/3`. The
  `[:xqlite, :pragma, :get]` and `[:xqlite, :pragma, :set]` events went
  with them.
- **`Xqlite.Pragma.returning_nothing/0`.** It listed the PRAGMAs that
  return nothing, and no PRAGMA left in the typed schema does now that the
  PRAGMAs that act are functions (see Changed).
- **`Xqlite.enable_load_extension/2`.** Use `enable_load_extension/1` and
  `disable_load_extension/1` (see Changed).
- **`Xqlite.backup_with_progress/6`.** Use `backup_with_progress/4`, which
  takes the destination first and the rest as options (see Changed).
- **`Xqlite.busy_timeout/2`.** It is `Xqlite.put_busy_timeout/2` now (see
  Changed).
- **`XqliteNIF.stream_open/4` is `XqliteNIF.stream_open/3`.** The fourth
  argument was reserved for stream options that never arrived, and nothing
  read it: `stream_open(conn, sql, [], :garbage)` opened a stream. A raw
  caller passing four arguments has to drop the last one. `Xqlite.stream/4`
  is unaffected.
- **`XqliteNIF.txn_state/1`, `wal_checkpoint/1,2` and
  `schema_list_objects/1`.** The raw `txn_state/2`, `wal_checkpoint/3` and
  `schema_list_objects/2` lost their defaults, so pass every argument; the
  `Xqlite` functions keep theirs (see Changed).
- **The `[:xqlite, :query_with_changes, :start | :stop | :exception]`
  span.** `[:xqlite, :cancel, :honored]` no longer reports
  `operation: :query_with_changes`: a cancelled `query/4` reports
  `operation: :query`.

### Fixed

- **A busy observer's handle is never issued twice on one connection.**
  Handles started again from 0 each time the last observer left with no
  policy set, so a handle already unregistered could name a later
  observer, and unregistering it again removed that observer and gave the
  wait back to SQLite. Handles now start at 1 and are never reused while
  the connection lives; unregistering an unknown handle still returns
  `:ok`.
- **A busy policy never sleeps past `max_elapsed_ms`.** The policy checked
  the time spent before each sleep and then slept its whole `sleep_ms`, so
  a busy event could run a whole sleep past its ceiling. A sleep that
  would pass the ceiling is now cut to what is left of it, and the event
  gives up there.
- **`backup/3` and `restore/3` finish while another connection writes to
  the source.** Both copied in steps, and SQLite starts a stepped copy
  again from the first page whenever another connection commits to the
  source between two steps, so under a steady writer the copy ended only
  when the writer stopped, or, in rollback-journal mode, `backup/3`
  returned `{:error, {:database_busy_or_locked, 5, _}}` with nothing
  copied. Both now copy in one step, inside one read transaction of the
  source. In rollback-journal mode another connection's commit waits for
  the whole copy and gets a busy error when its own busy timeout ends
  first; in WAL mode the write-ahead log grows until the copy ends.
  `backup_with_progress/4` still copies in steps, and
  `pages_per_step: 2_147_483_647` copies in one.
- **`serialize/2` returns `{:error, :transaction_in_progress}` while the
  connection holds a write transaction on that schema**, one it began or a
  write still running in autocommit mode, and copies nothing. The image
  held that transaction's uncommitted pages, and for a database
  `deserialize/4` loaded it could hold a state no transaction ever had,
  some rows old and some new. A read transaction still copies its
  snapshot.
- **A `:db_name` given twice to an `Xqlite.Pragma` function returns an
  error.** The first pair won and the second was dropped without a word,
  so a call could read or write a database the caller did not mean. A
  second `:db_name`, in one option list or across the argument and the
  options, now returns `{:error, {:invalid_pragma_argument, %{pragma:
  name, value: {:db_name, second}, reason: :duplicate_option}}}`, and
  `put/4` writes nothing.
- **`Xqlite.enable_strict_table/2` keeps a trigger whose `ON` clause
  spells the table's name in another case.** SQLite attaches such a
  trigger to the table, ASCII case folded, while the conversion read the
  table's triggers by the exact name, so the rebuild dropped them and
  still returned `:ok`. It now matches the name as SQLite does.
- **`Xqlite.enable_strict_table/2` converts a table while a TEMP trigger
  sits on a table of the same name in another database.** The conversion
  replayed that trigger, which the rebuild had not dropped, and failed
  with `{:error, {:sql_input_error, _}}`, leaving the table as it was. A
  TEMP object is now replayed only when it no longer exists, so such a
  trigger stays as it was.
- **The log hook sends SQLite's message as the bytes SQLite wrote.** Each
  byte that was not UTF-8 reached every subscriber as U+FFFD, so a name
  stored that way matched nothing in the schema. `message` is now a binary
  holding SQLite's bytes, which need not be UTF-8.
- **A garbage-collected handle no longer stalls a scheduler while its
  connection is busy.** When the garbage collector freed a statement,
  stream, blob or session while another call held its connection, the
  handle's destructor waited for that call on one of the BEAM's normal
  schedulers, and every process queued on that scheduler waited with it.
  A connection waiting for a database lock held by one of those processes
  then returned a busy error at its busy timeout, and under a busy policy
  that kept retrying, the node could hang. Such a handle is now queued on
  its connection, and the call that holds the connection releases it
  before returning (see Changed).
- **A garbage-collected write no longer commits on a scheduler.**
  Releasing a write statement stopped after a step, or a read-write blob,
  commits the write when the connection is in autocommit mode. That commit
  ran inside the destructor on a normal scheduler. In rollback-journal
  mode, while another connection read, it waited there in the busy handler
  and held up every process on that scheduler; when the reader's process
  was one of them, the wait ran to its timeout and the write was rolled
  back. Every release now runs on xqlite's release thread or in the call
  that holds the connection.
- **A connection dropped without `close/1` no longer closes on a
  scheduler.** Its destructor closed the SQLite handle on the normal
  scheduler where the garbage collector freed it. The last connection to a
  WAL database runs a checkpoint as it closes, which takes longer the
  larger the WAL is, and every process on that scheduler waited for it.
  The destructor now hands the connection to xqlite's release thread,
  which closes it there.
- **`Xqlite.enable_strict_table/2` runs the whole rebuild in one call, so
  another process sharing the connection can no longer act inside it.**
  The rebuild sent each of its statements as a call of its own, and
  between two of them a process sharing the connection ran its own
  statements, inside the rebuild's transaction or after ending it. An
  insert it had been told succeeded could vanish, and a child row naming a
  missing parent got in while foreign keys were off. A `commit/1` or
  `rollback/1` it sent left the remaining steps running outside any
  transaction, so a failure could leave the table dropped with all its
  rows. The rebuild, the switch of `foreign_keys` and `legacy_alter_table`
  and their restore now run inside one call that holds the connection
  until it ends. A process sharing the connection waits for the whole
  rebuild, including any wait for another connection's lock up to
  `busy_timeout`, and no cancel token stops it.
- **A rebuild whose `COMMIT` returns busy is rolled back.** With another
  connection reading the database in rollback-journal mode, the `COMMIT`
  returned `{:error, {:database_busy_or_locked, 5, _}}`. It left the
  caller inside the rebuild's transaction with foreign-key enforcement
  off, and enforcement stayed off after the caller rolled back. The
  rebuild now rolls its transaction back on that error, as on any other
  failure, and puts both pragmas back once the transaction has ended.
- **A rebuild no longer erases the rows of a statement still running on
  the connection.** A write another process had started but not finished,
  such as an `INSERT … RETURNING` stepped once, keeps `autocommit/1`
  reading `true`, so the rebuild's transaction took that write over. When
  a later step failed, the rebuild's rollback erased the write's rows,
  while the write still finished without an error; a stream left partly
  read was ended the same way. While a statement, stream or blob handle of
  the connection is running, the rebuild now returns
  `{:error, :statement_mid_run}` and changes nothing.
- **A rebuild notices a schema change made after it read the table.** The
  rebuild builds its statements from the stored definitions of the table,
  its indexes and its triggers, read before its transaction begins. A
  column another process or connection added in that time was dropped with
  its values, and a column dropped or renamed came back holding its own
  name as text in every row. An index or trigger created then was dropped,
  and the call still returned `:ok`. The rebuild now reads those
  definitions and the schema version of the table's database again inside
  its transaction. When one differs or the table is gone, it returns
  `{:error, {:table_changed, %{table: name}}}` with nothing changed. Any
  other schema change in that database in between returns the same; run
  the call again.
- **An authorizer no longer denies statements over names that are not
  UTF-8.** A deny list from `set_authorizer/2`, a busy policy and a busy
  observer each put an authorizer on the connection. With one there, a
  statement that touched a table, column, trigger, view or attached
  database whose stored name is not UTF-8 returned
  `{:error, {:authorization_denied, 23, message}}`, whatever the deny list
  held, and wrote a panic message to standard error. The authorizer now
  decides by the kind of action alone and reads only a PRAGMA's name and
  value, so such a statement returns what it returns with no authorizer: a
  result column whose name is not UTF-8 returns
  `{:error, {:column_name_not_utf8, %{column: index, name: bytes}}}`, and a
  CTE column list renames it. A statement that does an action the deny
  list names is still denied.
- **A deny of `:attach` stops every `ATTACH`, and a deny of `:detach` every
  `DETACH`.** An `ATTACH` whose file name was anything but a string literal
  (a bound parameter, a blob literal, a concatenation, a function call such
  as `printf(...)`, `CAST(...)` or a subquery) got past a deny list naming
  `:attach`, and a `DETACH` whose name was a bound parameter or an
  expression got past one naming `:detach`. The security guide's example
  for SQL from an untrusted source and the Known limitations guide's advice
  for a read-only connection rely on that deny.
- **The update hook reports a write whatever the table's name.** A write to
  a table whose stored name is not UTF-8, or to any table of a database
  attached under such a name, sent no `{:xqlite_update, ...}` message and
  wrote a panic message to standard error. Such a write now reaches every
  subscriber, as a write to any other table does: `db_name` and
  `table_name` are binaries holding the names' bytes as SQLite stores them,
  which need not be UTF-8, and the telemetry bridge passes them on as they
  are.
- **The WAL hook names a database attached under a name that is not
  UTF-8.** Its message, `{:xqlite_wal, db_name, pages}`, carried `""` as
  `db_name` for such a database; it now carries the name's bytes.
- **A connection garbage-collected without `close/1` frees its busy-handler
  state only after SQLite has closed it.** That state was freed first,
  while the connection could still be open. Nothing the library runs
  reached it, but a virtual-table module from a loaded extension that ran
  SQL waiting on a lock while the connection closed could have read freed
  memory. The authorizer's state, now the library's own, is freed the same
  way, after the close.
- **A string rejected for holding a second statement changes nothing.**
  The functions that run one statement return
  `{:error, :multiple_statements}` for such a string, but to find the
  second statement they compiled the text after the first, and
  `XqliteNIF.execute/3`, `XqliteNIF.execute_cancellable/4` and
  `Xqlite.execute/4` compiled every statement in the string. SQLite
  applies many PRAGMAs while it compiles them, `foreign_keys`,
  `query_only`, `defer_foreign_keys`, `temp_store`, `busy_timeout` and
  `wal_autocheckpoint` among them, so a rejected string could turn
  foreign-key enforcement off, let a connection kept read-only write, let a
  row that breaks a foreign key be committed, drop every TEMP table, or
  take the WAL hook from the library. The text after the first statement
  is now read without compiling it, and a string whose first statement is
  a PRAGMA is checked before anything is compiled (see Changed for the
  strings that now return `:multiple_statements`). The docs say again that
  nothing in such a string runs and no setting changes, and the Known
  limitations guide keeps the one case SQLite itself causes: a PRAGMA stays
  applied when a syntax error follows it in the same statement.
- **`execute/3` no longer crashes the VM on a string of many statements.**
  `XqliteNIF.execute/3`, `XqliteNIF.execute_cancellable/4` and
  `Xqlite.execute/4` handed the string to rusqlite, which compiles each
  remaining statement by calling itself once per statement, so a long
  enough run of short statements overflowed its thread's stack and took the
  whole VM down. They now compile the way `query/3` does, reading the first
  statement only, and return `{:error, :multiple_statements}`.
- **`XqliteNIF.set_pragma/3` writes an atom value as a quoted string.** An
  atom other than `true`, `false` and `nil` went into the statement as
  written, so an atom could end the PRAGMA and add a second statement, and
  an atom holding a NUL byte returned `{:ok, nil}` with the value cut at
  the NUL; it now returns `{:error, :null_byte_in_string}`. SQLite strips
  the quotes before it reads the value, so an atom such as `:wal` sets
  what it set before, and an atom such as `:"0 garbage"` is read as that
  text in quotes, where it returned a syntax error.
- **The docs say what the code returns.** `stream/4` states that a stream
  over a `RETURNING` write keeps the whole write when it ends before its
  last row (an early stop, a value that is not UTF-8, a decode rejection),
  that a cancel rolls the write back only when SQLite checks the token
  before the statement finishes, and that a later enumeration halted
  before reading closes the first pass, whose next fetch returns
  `:stream_consumed`. A cancel token already signalled stops a call before
  its statement runs, unless that statement is already mid-run. A
  `CREATE VIRTUAL TABLE` with `rtree` or `fts5` reports one change, and a
  `DROP TABLE` that SQLite precedes with a `DELETE` reports that
  `DELETE`'s rows. `connection_stats/1` reports the current half of
  `:lookaside_used`, and `deferred_fks?` stays `false` with `foreign_keys`
  off. `autocommit/1` and `txn_state/2` take the connection lock and wait
  behind a running statement. `schema_databases/1` reports `""` as the
  file of an in-memory or temporary database. The bundled SQLite starts
  every connection with foreign keys enforced. `busy_timeout: :infinity`
  stores 2_147_483_647 ms, and only the options of `open/2` and
  `open_in_memory/1` take it. `column_names/1` changes only at the step
  that re-prepares the statement. An ATTACH by a URI naming a `mode=`
  reaches the file from `XqliteNIF.open_in_memory/1`. The telemetry guide
  lists every error returned with no event, where it said every operation
  emits events (a `:type_extensions` option that is no proper list of
  extension modules, for one, is rejected before the span opens, so the
  call emits neither a start nor a stop), names `explain_analyze/4` in its
  event table where it said `/3`, and lists the `:conn` key of the bridged
  update and WAL events. Function names in the docs that named no existing
  function now name the right one.
- **The README is rewritten, and its numbers and lists match the code.** It
  counts 53 typed PRAGMAs in both places, four fewer than before now that
  the PRAGMAs that act are functions, lists the precompiled targets per
  platform (RISC-V on glibc only, Windows on x86_64 only), and gives a
  generated column's `default_value` as `:none`.
- **The session capture docs say what a capture holds.**
  `XqliteNIF.session_changeset/1` and `session_patchset/1` hold the net
  change of every row since its table was attached, and a capture clears
  nothing; the docs said a capture held only the changes since the last
  one. They now say what shipping a later capture to a replica that took an
  earlier one loses, how to ship changes in rounds with a new session per
  capture, and that `session_is_empty/1` returns `{:ok, false}` once any
  change was recorded, even when the changes cancel out.
- **`changeset_apply/3` never commits a changeset that leaves a foreign key
  broken.** Under `:omit` such a changeset was committed with `:ok`, and so
  was a key violation the caller's own open transaction held. It is now
  rolled back under every strategy, as `:replace` and `:abort` already did,
  and returns `{:error, {:constraint_violation, :constraint_foreign_key,
  details}}`. To commit such a changeset anyway, turn the target's key
  checks off before the apply, outside a transaction.
- **A blob handle SQLite has ended returns SQLite's error from every read,
  write and size call.** Once a read or write call had met the handle's
  changed row, a reopen had failed, or a transaction or savepoint had
  rolled back while the handle was open (any rollback for a read-write
  handle, even one opened before the `BEGIN` that wrote nothing; a rollback
  that undid a schema change for a read-only one), `blob_size/1` returned a
  size (0, or the old one after a rollback), and reads and writes could
  return an empty binary or a bounds error without asking SQLite; each now
  returns `{:error, {:sqlite_failure, 4, _, _}}` until `blob_close/1`.
- **`load_extension/3` reads the extension switch while it holds the
  connection lock for the load.** A load racing a call that turns extension
  loading on or off could return SQLite's text error instead of
  `{:error, :extension_loading_disabled}`, and a closed connection returned
  `{:error, :extension_loading_disabled}` instead of
  `{:error, :connection_closed}` while loading was off.
- **`schema_foreign_keys/2` reads a foreign key whose REFERENCES clause
  names no parent column.** One such key, `REFERENCES parent` being the
  usual way to point at a parent's primary key, made the call fail for the
  whole table with `{:error, {:invalid_column_type, 4, "to", nil}}`; its
  `to_column` is now `nil`, and the docs say SQLite then uses the parent's
  primary key.
- **`blob_reopen/2` on a blob handle SQLite has ended returns SQLite's
  abort code.** When an earlier statement on the connection had failed on a
  missing or existing table or index, it returned that statement's error,
  such as `{:error, {:no_such_table, _}}`, because SQLite sets no new
  message there. `{:no_such_table, _}`, `{:no_such_index, _}`,
  `{:table_exists, _}` and `{:index_exists, _}` are now returned only for
  SQLite's primary code 1 (`SQLITE_ERROR`), so the reopen returns
  `{:error, {:sqlite_failure, 4, 4, message}}`, the message still the
  earlier statement's text.
- **`open/2` keeps the `auto_vacuum` asked on a new file in WAL mode.** It
  applies `auto_vacuum` before `journal_mode`; a new file under the default
  WAL mode read `:none` whatever was asked.
- **`Xqlite.error_reason/0` lists `{:strict_violations, _}` and
  `{:unexpected_value, _}`**, which `Xqlite.enable_strict_table/2` and
  `Xqlite.Pragma.get/2` already returned, beside the new
  `{:pragma_not_applied, _}`.
- **`backup/3`, `backup_with_progress/4` and `restore/3` no longer wait on
  a lock the caller did not ask to wait on.** A lock another connection
  holds on the file the library opens itself (a backup's destination, the
  file a restore reads) returns `{:error, {:database_busy_or_locked, 5,
  message}}` at once, where it waited rusqlite's 5 000 ms busy timeout
  first. A lock on the caller's own database still waits as the
  connection's `busy_timeout` or busy policy says, except in the two cases
  the gotchas guide describes. `restore/3` no longer sleeps 200 ms on a
  blocked step, and its busy error carries SQLite's own text for the code,
  as the backup functions' does (it read "Error code 5: …").
  `backup_with_progress/4` now also sends its `:busy` message for a lock
  SQLite reports with an extended code, such as 262 when another connection
  of a shared cache uses the destination; it returned the same error with
  no message.
- **`backup/3` and `backup_with_progress/4` reject a destination SQLite
  gives no file for** (`""`, `":memory:"`, `"file::memory:"`, a
  `mode=memory` or `vfs=memdb` URI) with `{:error, {:cannot_open_database,
  dest_path, 14, message}}`; they returned `:ok` and wrote nothing.
- **`backup_with_progress/4` reads its cancel tokens before the
  destination is opened**: a token signalled before the call creates no
  file (it left an empty one).
- **`restore/3` rejects a source with no pages** (a zero-byte file, such as
  the empty file a failed copy to a new path leaves) with
  `{:error, :no_pages}`; it returned `:ok` and emptied the schema.
- **`restore/3` rejects a connection `open_readonly/1` or
  `open_in_memory_readonly/1` opened** with
  `{:error, {:cannot_restore, :read_only_connection}}`, on every schema,
  `temp` included. On a shared cache another connection opened read-write,
  `query_only` does not stop the backup API, so the restore overwrote the
  shared database. `@type error_reason` gains that reason.
- **`open/2` and `open_in_memory/1` check every option value before the
  file is opened.** A value outside what SQLite stores (`busy_timeout`,
  `cache_size`, `wal_autocheckpoint`, `mmap_size`) is rejected with nothing
  opened or created; it was rejected after the file was created and, for an
  existing file, after `journal_mode = WAL` had switched it for good. See
  Changed for the error it returns now.
- **`deserialize/4` rejects the `temp` schema by name.** `"temp"`, in any
  ASCII case, returns `{:error, {:invalid_schema_name, name}}` with the
  name as given, before the image is checked, on `Xqlite.deserialize/4`
  and `XqliteNIF.deserialize/4`. SQLite cannot load an image into the temp
  database, and the call returned its bare
  `{:error, {:sqlite_failure, 1, 1, "SQL logic error"}}`.
- **A table, index or savepoint name holding a NUL byte returns
  `{:error, :null_byte_in_string}`** on `schema_columns/2`,
  `schema_foreign_keys/2`, `schema_indexes/2`, `schema_index_columns/2`,
  `savepoint/2`, `release_savepoint/2` and `rollback_to_savepoint/2`, in
  `Xqlite` and `XqliteNIF` alike, before any SQL is built. They returned a
  `{:sql_input_error, _}` about the library's own statement, because
  SQLite's tokenizer stopped at the NUL.
- **`execute_batch/3`, and the raw `XqliteNIF.execute_batch/2` and
  `execute_batch_cancellable/3`, take time linear in the batch's
  length.** Each statement used to be compiled from a copy of the rest of
  the batch, so the time grew with the square of the length, with the
  connection locked throughout: 80 000 statements took about 10 s, and
  take about 0.1 s now.
- **A batch runs each statement to its end.** A statement that works one
  row at a time, such as `PRAGMA incremental_vacuum`, used to stop after
  its first row, and a `SELECT` whose second row fails returned `:ok` while
  the batch went on. A `SELECT` inside a batch now reads and drops all its
  rows, and a row that fails stops the batch with its error.
- **A cancelled batch stops before its next statement.**
  `execute_batch/3` given `:cancel_tokens`, and the raw
  `XqliteNIF.execute_batch_cancellable/3`, read the tokens between
  statements: a batch of short statements used to run to its end after a
  signal.
- **The query docs say what happens to a `RETURNING` write when one of its
  rows cannot be read.** SQLite makes every change of the write before it
  hands back the first row, so `{:error, {:utf8_error, column, message}}`
  leaves the write in place: committed in autocommit mode, pending inside a
  transaction, where `rollback/1` undoes it.
- **The foreign-key switch inside a transaction returns
  `{:error, :transaction_in_progress}` instead of `{:ok, nil}`.** SQLite
  ignores a `PRAGMA foreign_keys` write while a transaction or a savepoint
  is open, and still reports success. `XqliteNIF.set_pragma/3` now rejects
  that write before it runs, whatever the letter case of the name, so
  `Xqlite.Pragma.put/3,4` (with or without `:db_name`),
  `Xqlite.enable_foreign_key_enforcement/1` and
  `Xqlite.disable_foreign_key_enforcement/1` return the same and never
  report a change SQLite did not make. Every other PRAGMA is written as
  before, and a `PRAGMA foreign_keys` statement sent as SQL still reaches
  SQLite unchanged.
- **The docs say what a failed commit leaves behind.** A `COMMIT` that
  fails on a deferred foreign key, on another connection's lock or on a
  write of the same connection still running keeps the transaction open:
  repair and call `commit/1` again, or call `rollback/1`; `autocommit/1`
  tells whether a transaction is open. A constraint error under the default
  `ABORT` undoes only its own statement. None of these sends
  `{:xqlite_rollback}`, and neither does `close/1` when it rolls an open
  transaction back. The docs of `Xqlite.rollback/1` and
  `XqliteNIF.register_rollback_hook/2` said a constraint error or a failed
  commit was rolled back and sent that message, and the 0.7.0 entry's
  "after each rollback" left `close/1` out. `XqliteNIF.rollback/1`,
  `savepoint/2` and `release_savepoint/2` no longer state wrong rules: a
  rollback discards the whole transaction, a savepoint with no transaction
  open starts one, and releasing the savepoint that started a transaction
  commits it.
- **A result column name that is not UTF-8 returns an error.** A table
  whose stored CREATE text names a column with bytes that are not UTF-8
  made the query functions panic inside rusqlite with the connection lock
  held, so the connection could no longer be used or closed; `prepare/2`,
  `column_names/1` and `stream_open/3` replaced the bad bytes with U+FFFD,
  so two different names could come back equal. Every function that reads
  result column names now returns
  `{:error, {:column_name_not_utf8, %{column: index, name: bytes}}}` for the
  first such column, before anything is bound or run, and leaves nothing
  prepared; a live `column_names/1` returns it on every call and the
  statement stays usable. A CTE column list renames such columns:
  `WITH s(a, b) AS (SELECT * FROM t) SELECT * FROM s`.
- **A schema change between reading the names and the first step returns
  `{:error, {:columns_changed, %{expected: names, live: names}}}`.** When
  another connection changed a table after `stream/4` opened, the rows came
  back under the old names (`DROP COLUMN b` gave `%{"a" => 1, "b" => 3}`);
  the query functions returned `{:invalid_column_index, _}` in the same
  window. The stream's first fetch and the query's first step now return
  the new error; a write in the statement has run by then.
- **A statement prepared before `deserialize/4` no longer crashes the VM.**
  `Xqlite.deserialize/4` and `XqliteNIF.deserialize/4` now expire every
  prepared statement of the connection after a load, so SQLite prepares
  each again at its next step, against the loaded schema. A write prepared
  before loading an image with the same schema cookie used to step into
  freed memory and take the VM down, and a query read whatever table sat at
  its old root page. A statement or stream still running on any schema of
  the connection, or an open blob, now makes the load return
  `{:error, :statement_mid_run}` and replace nothing, where before only one
  on the target stopped it, with `{:error, {:database_busy_or_locked, 5,
  _}}`: the load drops every cached schema, and a running statement may
  read a table definition on every row. The schema re-read the load runs
  afterwards is not subject to the connection's `:sql_length` limit, and
  the statements are marked to be prepared again whatever that re-read
  returns.
- **A TEMP trigger on a loaded table works after `deserialize/4`.** After a
  load, a TEMP trigger on a table of the replaced schema stopped firing,
  and `DROP TRIGGER` on it could take the VM down: SQLite's reload left the
  trigger bound to the freed schema. The connection now re-reads its
  schemas after every load, so the trigger fires on the loaded table; one
  whose table the image lacks stays idle until a load brings the table
  back. A load now turns `PRAGMA writable_schema` off.
- **`restore/3` returns `:statement_mid_run` while a statement runs.**
  SQLite's backup drops every cached schema of the connection when the copy
  finishes, and a statement running on another schema whose program reads
  a table definition on every row (a STRICT table's VIRTUAL generated
  column) took the VM down. `Xqlite.restore/3` and `XqliteNIF.restore/3`
  now return `{:error, :statement_mid_run}` while any statement, stream or
  blob of the connection is mid-run, and copy nothing.
- **`serialize/2` returns what stopped it.** `Xqlite.serialize/2` and
  `XqliteNIF.serialize/2` returned `{:error, {:sqlite_failure, 7, 7, "out
  of memory"}}` for every failure. A lock another connection holds on a
  schema with pages now returns `{:error, {:database_busy_or_locked, 5,
  _}}` after one busy timeout where it waited two, and any other cause
  SQLite records returns its own classified error. An empty schema whose
  first page SQLite cannot write (a zero-byte file opened read-only, a
  `:transaction` deny, a write lock on any attached database) and the
  unused temp schema return `{:error, :no_pages}`; the unused temp schema
  no longer writes anything. A `:pragma` deny no longer stops it.
- **A writable load of a read-only image is rejected.** An image whose
  header byte 18, the write version, is above 2 loaded read-only even with
  `read_only: false`. `deserialize/4` now returns
  `{:error, {:invalid_image, %{reason: :read_only_image, code: 8}}}` and
  replaces nothing; with `read_only: true` it loads.
- **The image docs promise less.** `deserialize/4` no longer offers the
  bytes of a database in use as an image: a database file's bytes are one
  only while no connection has it open and no `-wal` or `-journal` file
  lies beside it, and loading does not catch a torn copy. `serialize/2`
  says that for a schema `deserialize/4` loaded it returns the last
  committed state, whatever transaction is open.
- **`Xqlite.deserialize/4` and `XqliteNIF.deserialize/4` check an image
  before it replaces anything.** A rejected image returns
  `{:error, {:invalid_image, %{reason: reason, code: code}}}` and leaves the
  schema's contents alone. `reason` is `:not_a_database` (code 26) for bytes
  that do not start with SQLite's 16-byte header, the empty binary
  included. It is `:malformed` or `:not_a_database`, with SQLite's own code,
  for an image whose header and schema SQLite cannot read on a scratch
  in-memory connection. It is `:encoding_mismatch` (code 1) for an image in
  a text encoding the target does not take. An attached schema takes only
  the connection's text encoding; `main` takes only a UTF-8 image, and only
  on a UTF-8 connection. To load a UTF-16 database, deserialize it into an
  attached schema of a connection with the same encoding, or open its file
  directly. These images used to load. The next statement then failed with
  code 26, 11, 14 or 1, and into an attached schema that took the whole
  connection down. A UTF-8 image into `main` of a UTF-16 connection
  switched the connection to UTF-8, so later writes put UTF-8 bytes into
  its attached UTF-16 databases, silently. The empty binary used to return
  a false out-of-memory error. The scratch read costs a second copy of the
  image; running out of memory for it still returns the out-of-memory
  error. Deserialize's own encoding read passes a `:pragma` deny list.
- **An image of a WAL database now loads.** `serialize/2` of a WAL
  database, and the file of a closed WAL database, carry header bytes 18
  and 19 set to 2, which SQLite's memory storage cannot open (code 14 on
  every later statement). `deserialize/4` now sets them to 1 in its own
  copy, as SQLite documents.
- **A read-only open stays read-only on a shared cache and with a
  `mode=memory` URI.** SQLite dropped the read-only flag of an
  `open_readonly/1` or `open_in_memory_readonly/1` connection that joined a
  shared cache another connection opened read-write, and of any URI with
  `mode=memory`, so the connection wrote. Those connections now get
  `PRAGMA query_only = 1` at open; `PRAGMA query_only = 0` and a
  `journal_mode` change still get past it; `restore/3` returns
  `{:error, {:cannot_restore, :read_only_connection}}` (see the openers'
  docs). A private read-only connection still creates TEMP tables. Such an
  open now returns `{:error, {:cannot_open_database, uri, 262, _}}` while
  the shared cache's writer holds an uncommitted schema change, because
  `query_only` cannot be set then; it opens once the writer commits.
- **The execute functions report the statement's own count.**
  `Xqlite.execute/4` and the raw `XqliteNIF.execute/3` and
  `execute_cancellable/4` returned SQLite's sticky `sqlite3_changes()`, so
  CREATE, BEGIN, COMMIT, PRAGMA, VACUUM and DROP reported the previous
  write's count; they now return 0 for a statement that changed no row, as
  `query_with_changes` does, except `CREATE VIRTUAL TABLE` with a module
  that writes rows of its own while it creates them, such as `rtree` and
  `fts5`, which returns 1.
- **A `Stream.zip` cleanup no longer leaves an `Xqlite.stream/4` statement
  open.** A raise on the first pair of a zip holding the stream (from the
  consumer, the other enumerable, or `Enum.zip_reduce`) left the first
  pass's statement open until garbage collection, so writes to its tables
  failed meanwhile. The fresh start the cleanup halts now closes the first
  pass and sends its close event, with that pass's outcome and row count; a
  first pass closed that way returns `:stream_consumed` on its next fetch
  instead of ending early.
- **`Xqlite.unregister_busy_observer/2` and `unregister_progress_hook/2`
  take any non-negative integer**, one past 64 bits too (it raised
  `ArgumentError`); `unregister_progress_hook/2` now raises
  `FunctionClauseError` for a negative handle, as
  `unregister_busy_observer/2` does.
- **`Xqlite.backup_with_progress/4` returns `{:error,
  {:invalid_pages_per_step, value}}` for any `pages_per_step` outside
  `1..2_147_483_647`** (bignums, floats and atoms included) after the
  cancel tokens are checked and before any file is created; it raised
  `ArgumentError`.
- **A call whose cancel token is already signalled now stops before its
  statement runs.** A one-row write through a cancellable call (now
  `query/4`, `execute/4`, `execute_batch/3`, or `multi_step/3` on a
  statement that has not started, given `:cancel_tokens`, and the raw
  `_cancellable` functions) or through a stream's first fetch used to
  commit and still return `{:error, :operation_cancelled}`.
- **A cancel that reaches SQLite's progress check after a statement's last
  step no longer turns a finished write into
  `{:error, :operation_cancelled}`;** the call returns its normal result. A
  cancelled result now always means the run was stopped. A write cancelled
  while it runs rolls back the whole transaction, an explicit one included;
  a token already signalled before a write starts stops it before its first
  step, writes nothing and leaves an open transaction as it was. The gotchas
  guide states what a cancelled result means and when SQLite checks for a
  cancel, replacing "checked every 8 VM instructions".
- **A second enumeration of an `Xqlite.stream/4` stream read on where the
  first stopped, or looked like an empty table.** The statement opens at
  the call, so a second `Enum.to_list/1`, the rest after an `Enum.take/2`,
  or a retry after a rescued `Xqlite.StreamError` returned `[]`, and a pass
  started while the first still ran (`Stream.zip(s, Stream.drop(s, 1))`, a
  nested `Enum.take/2`, a pass after the first consumer was killed) handed
  out rows from the wrong batches with no error. The stream now runs once:
  every enumeration after the first gets `:stream_consumed` through
  `:on_error` (`:raise` raises `Xqlite.StreamError` with it, `:emit_error`
  emits `{:error, :stream_consumed}` as its only element, `:halt` logs it
  and emits nothing) without fetching, closing or sending a telemetry event
  of its own. Call `stream/4` again for a second pass.
- **A bind on a statement that had already stepped returned SQLite's bare
  misuse error.** Mid-run, `bind/3` returned
  `{:error, {:sqlite_failure, 21, 21, _}}` after walking the whole
  parameter list under the connection lock, while `clear_bindings/1`
  returned `{:error, :statement_mid_run}`. A bind on a statement that takes
  parameters and is mid-run now returns `{:error, :statement_mid_run}`
  before it reads the list, and keeps the values bound before. After the
  run has ended (`:done` or a failed step) the bind resets the statement
  itself, so the next step reruns with the new values; `reset/1` is no
  longer needed first.
- **Docs: a step rejected as busy keeps its run, and what a closed
  connection leaves behind.** A step SQLite rejected as busy while taking
  or committing its lock keeps its run for a retry (the statement stays
  mid-run and the retry writes once), where the docs said every failed step
  ended the run. After the connection is closed, every step, bind, reset,
  clear and fetch returns `{:error, :connection_closed}`, finalize and
  `stream_close/1` return `:ok`, and the column-name calls return the names
  captured at prepare or open; `XqliteNIF.stmt_finalize/1` said the SQLite
  handle stayed alive and `XqliteNIF.stream_fetch/2` said the error
  repeated until `stream_close/1`.
- **`Xqlite.clear_bindings/1` mid-run nulled the rest of the read.**
  `sqlite3_clear_bindings` has no mid-run check where every
  `sqlite3_bind_*` returns `SQLITE_MISUSE`, so a clear between two rows
  released the values in place and every row left in the run read NULL:
  `SELECT rowid, ? FROM t` handed back `[1, "P"]`, then `[2, nil]`. A
  statement that takes parameters and has been stepped without a `reset/1`
  since now returns `{:error, :statement_mid_run}` and keeps its values. A
  statement that takes none has nothing to release and still returns `:ok`,
  and so does a clear once the run is over, as a bind does: a finished run
  has no rows left to change.
- **`Xqlite.TypeExtension.encode_params/2` skipped its own check when there
  were no extensions.** With `[]` or `nil` extensions the call handed the
  term straight back, returning `{:ok, term}` for every list its own
  documentation says it rejects: a term that is no list, and a list whose
  tail is not `[]`. It now walks the list's spine whatever the extension
  list, and returns the same `{:expected_list, _}` and
  `{:expected_keyword_list, _}` errors it returns with an extension on. A
  keyword element that is not a `{key, value}` pair still travels on to the
  NIF, which rejects it, and a key of any kind is still a key.
- **`Xqlite.TypeExtension.decode_rows/2` raised where its encoding
  counterpart returned an error.** A rows term that is no list of lists
  (`:done`, `{:row, values}`, `nil`, a list whose tail is not `[]`, a row
  that is no list) raised `Protocol.UndefinedError` or
  `FunctionClauseError` from inside the chain, and this is the function
  four `Xqlite` doc blocks recommend for the rows `step/1` and
  `multi_step/2` hand back. It now returns the encoding side's errors:
  `{:error, {:expected_list, %{reason: :not_a_list, value_type: kind}}}`,
  the same tag with `:improper_tail` for a tail that is not `[]`, and with
  `:bad_element` and the row's one-based position for a row that is no
  list. A row whose own tail is not `[]` is rejected where a walk reads it,
  which is when an extension is on. A map row, which used to be turned
  silently into a list of its pairs, is rejected as a row that is no list.
- **`SAVEPOINT`, `RELEASE`, `ROLLBACK TO` and a read-only statement with a
  long comment read as "SQL contains no statement" under a lowered
  `:length`.** The check that tells an empty text from a statement now
  reads SQLite's own null statement, which no length limit hides, so the
  check is exact at any limit.
- **`XqliteNIF.get_create_sql/2` checks its name against the length
  limit** like every function that binds a value, returning
  `{:error, {:value_too_large, %{byte_size: _, limit: _}}}` where it
  returned `{:too_big, code, message}`.
- **A bind SQLite rejected part-way through the list left a half-written
  row.** A value longer than the connection's length limit was rejected
  only once SQLite met it, with the values before it already bound and the
  failing parameter left NULL, and the statement still runnable, so a step
  after the error wrote a half-updated row. Every function that binds now
  checks every TEXT and BLOB parameter against that limit before it binds
  anything, and returns
  `{:error, {:value_too_large, %{byte_size: _, limit: _}}}` with nothing
  bound; a bind SQLite rejects for any other reason after taking a value
  leaves the statement unrunnable until a bind succeeds or
  `clear_bindings/1` runs.
- **A bind the library rejected left the statement runnable.** None of the
  six errors the library returns for a parameter list binds anything, and
  SQLite reads a parameter nothing was bound to as NULL, so
  `Xqlite.bind(stmt, [1, 2, {:no}])` followed by `Xqlite.step(stmt)` ran
  the statement with NULL in every parameter and returned success: an
  `UPDATE` written that way wrote NULL over its columns. A statement that
  takes parameters now rejects `step/1` and `multi_step/2,3` with
  `{:error, {:parameters_unbound, %{expected: n}}}` until a bind succeeds,
  and the same error covers a statement stepped straight after
  `prepare/2`. An earlier successful bind stays in force, `reset/1` keeps
  it, and `clear_bindings/1` is how a caller asks for a run with NULL in
  every parameter. A bind SQLite rejects before taking any value leaves
  the statement as it was. This check comes after the checks for a
  finalized statement and a closed connection, so a finalized statement
  still returns `:statement_finalized` and one on a closed connection
  `:connection_closed`.
- **A keyword list that left a name out wrote NULL over that column.** A
  named parameter nothing was bound to reads as NULL, so
  `Xqlite.query(conn, "UPDATE t SET a = :a, b = :b WHERE id = 1", a: "new_a")`
  wrote NULL over `b` and returned `changes: 1`; the raw functions
  (`XqliteNIF.stmt_bind/2`, `stream_open/3`, `explain_analyze/3`) lost the
  column the same way. A keyword list must now name every parameter of the
  statement, each exactly once, on every function that takes parameters,
  and the whole list is checked before a single value is bound: a
  parameter no key named is `{:error, {:missing_parameter, %{index: i,
  name: name}}}` for the lowest such index, `name` being SQLite's own
  spelling of it (`":b"`, `"@b"`, `"$c"`, `"?3"`) and `nil` for a bare `?`,
  which no keyword list can name; use a positional list for such a
  statement. A key the statement does not have is still
  `{:error, {:invalid_parameter_name, key}}`, and it is still the error when
  the list both names something unknown and leaves something out: every
  key is resolved first. A name used twice in the SQL is one parameter with
  one value and passes, as before.
  **Two partial keyword binds in a row no longer add up.**
  `Xqlite.bind(stmt, a: 1)` followed by `Xqlite.bind(stmt, b: 2)` worked
  because SQLite keeps a binding until it is overwritten; each call now has
  to hand over a complete list. Where that pattern was in use, call
  `reset/1` and bind the whole list once.
- **A keyword list can now name an `@` or `$` parameter.** Every key used to
  get a `:` prefix, so `SELECT @b` was unreachable by name: `[b: 1]` and
  `[{:"@b", 1}]` both returned `{:invalid_parameter_name, _}`. A key whose
  own text starts with `:`, `@` or `$` is now used as written
  (`[{:"@b", 1}]` binds `@b`, `[{:"$c", 1}]` binds `$c`) and every other key
  still gets the `:` prefix, so `[a: 1]` binds `:a` as before.
- **An improper parameter list no longer raises in `Xqlite.query/4`,
  `execute/4` and `explain_analyze/4`.** They counted the list for their
  telemetry metadata before the NIF ran, with `length/1`, which raises
  `ArgumentError` on a list whose tail is not a list. They now count the
  list's proper prefix by hand and let the NIF return its error, so
  `[1 | :tail]` is `{:error, {:expected_list, %{reason: :improper_tail,
  value_type: :atom}}}` there too, the same as at every other function.
  `nil` and a term that is no list are unchanged.
- **`secure_delete` rejected the words SQLite takes.** Its spec maps `0`,
  `1` and `2` to `false`, `true` and `:fast`, and the mapped path looked a
  word up in those three alone, so `:on`, `"off"`, `:yes` and `"NO"` were
  `{:error, {:invalid_pragma_value, _}}` while SQLite itself stores 1, 0, 1
  and 0 for them. A PRAGMA whose mapping gives both booleans a word of
  their own now takes the whole boolean vocabulary and writes the mapping's
  own word (`:on` writes `TRUE`), in any case, as an atom or a string. A
  mapping of three modes, such as `auto_vacuum`'s, gives a boolean no
  meaning and still rejects the words; `secure_delete = 2` stays rejected,
  because SQLite reads the integer as the boolean true and would store 1.
- **A parameter list one element short wrote NULL through `stream/4`.** The
  three functions that bind through SQLite's C API directly (`stream/4`
  and `XqliteNIF.stream_open/3`, `explain_analyze/4`, and `bind/3`) never
  counted the list they were handed, and SQLite reads a parameter nothing
  was bound to as NULL.
  `Xqlite.stream(conn, "UPDATE t SET v = ?2 WHERE id = ?1", [1])` therefore
  wrote NULL over the stored text and reported success, where `query/4`
  rejects the same call; `[]` and `nil` did it to every row of the table.
  All three now return
  `{:error, {:invalid_parameter_count, %{expected: _, provided: _}}}` before
  a value is bound, the too-long list included, which used to leak SQLite's
  own "column index out of range". `[]` and `nil` count as zero parameters,
  so they pass only on a statement that takes none:
  `XqliteNIF.stmt_bind(stmt, nil)` on a statement with a parameter is now
  rejected instead of leaving it NULL. A keyword list is checked by the
  keyword-list rule above.
- **`multi_step/2` no longer throws away the rows it had already read.** A
  value SQLite hands back that cannot be read, such as a TEXT column holding
  bytes that are not valid UTF-8, used to lose every row the same batch had
  read before it: four rows with the unreadable one second returned the
  error and row one never reached the caller. `multi_step/2` now does what
  a stream fetch has done for a while: it hands back the rows it read, with
  `done: false`, holds the error, and returns it on the next call that
  reads a row, `step/1` included; the statement then carries on at the row
  after the bad one. `reset/1` starts the statement over and drops a
  held-back error. A cancellation still discards the rows of the batch it
  lands in, and `multi_step/3` given `:cancel_tokens` shares all of it. A
  `sqlite3_step` that fails outright (a locked database, an I/O error, a
  runtime error in the SQL such as `abs(-9223372036854775808)`, a trigger's
  `RAISE`) is returned at once instead of being held back: no row was
  stepped past, so there is nothing to continue at. Such a failure discards
  the batch's rows, as a cancellation does, so a result set that fails
  part-way hands back no rows through `multi_step/2` (`step/1` and
  `stream/4` still deliver the rows before the failure). After such a
  failure the statement is left where SQLite left it: the next step is
  SQLite's own rerun from the top, which meets the same failure, and
  `reset/1` changes nothing.
- **`Xqlite.stream/4` silently dropped every column whose name repeated.** A
  stream row is a map keyed by column name, and a map cannot hold two
  entries under one key, so a join of two tables sharing a column
  (`SELECT ta.v, tb.v FROM ta, tb`) came back as `%{"v" => 2}`, the first
  value gone with nothing said about it, where `Xqlite.query/4` over the
  same SQL keeps both. SQLite also names a column that has no name of its
  own after the text that produced it, so `SELECT 1, 1` and `SELECT ?, ?`
  lost values the same way, in every `:on_error` mode. Such a statement is
  now rejected at stream open with `{:error, {:duplicate_column_name,
  name}}`, `name` being the first name that repeats in SQLite's order;
  alias the columns (`SELECT ta.v AS x, tb.v AS y`) to stream it. `query/4`
  and the raw stream functions return lists and are unchanged.
- **An improper parameter list raised once a type extension was on.** With
  no extension the list travelled untouched to the native check, which
  rejects a tail that is not a list with
  `{:error, {:expected_list, %{reason: :improper_tail, value_type: _}}}`;
  with one, the encode chain walked the list itself and `[1 | :tail]`
  raised `FunctionClauseError` on every `Xqlite` function that takes
  parameters and on the public `Xqlite.TypeExtension.encode_params/2`. The
  chain now returns what the native check returns for the same term: both
  improper-tail shapes, and
  `{:error, {:expected_list, %{reason: :not_a_list, value_type: _}}}` for a
  parameter term that is no list and not `nil`, which raised too.
  `Xqlite.bind/2,3` lost its own `is_list` guard with it, so
  `Xqlite.bind(stmt, :foo)` returns that error instead of raising and
  `Xqlite.bind(stmt, nil)` means no parameters, as it does at every other
  function that takes parameters.
- **Documentation.** The seven `:type_extensions` paragraphs say
  "extension modules" rather than "module names"; the four places that
  recommend `Xqlite.TypeExtension.decode_rows/2` say it returns
  `{:ok, rows}`; the `:too_big` docs write its code as `code` rather than
  the literal 18, SQLite defining no extended code for that result today;
  the telemetry guide names the limit functions beside
  `backup_with_progress/4` as the functions that emit nothing; the gotchas
  guide, this changelog and ARCHITECTURE.md carry the one measured figure
  for a named bind; and ARCHITECTURE.md names the functions the stream
  data flow really goes through and all of the checks the open makes.

### Internal

- **Every public function is fuzzed in a second VM.**
  `test/fuzz_law_test.exs` calls each public function of `Xqlite`,
  `XqliteNIF`, `Xqlite.Pragma` and `Xqlite.TypeExtension` 2000 times with
  values of its `@spec` types and hostile terms, in a child VM, so a crash
  in native code cannot take the suite down. The test fails on a crash, on
  a call that never returns, or on a result outside the documented shapes,
  and names the call that caused it.

## [0.15.0] - 2026-09-18

### Fixed

- **An improper list no longer takes the VM down.** A list whose tail is not a
  list (`[1 | 2]`) handed to any of the nineteen functions that read a list —
  the parameter lists of `Xqlite.stream/4`, `Xqlite.bind/2,3`, `query`,
  `execute`, `query_with_changes`, `explain_analyze`, `stmt_bind` and
  `stream_open`, the cancel-token lists of the seven cancellable functions and
  `backup_with_progress/6`, and `set_authorizer/2`'s action list — used to
  reach a decoder that panics: on a build that aborts on a panic, the whole
  operating-system process died. Every one of those lists is now walked by
  hand and a broken tail is `{:error, {:expected_list, %{reason:
  :improper_tail, value_type: type}}}`.
- **A stream open that refuses a parameter frees its statement.**
  `Xqlite.stream/4` prepares the SQL before it reads the parameters, and a
  parameter it could not read used to leave that prepared statement behind
  with nothing referencing it. SQLite then refused to close the connection —
  `{:error, {:database_busy_or_locked, 5, _}}` — for the life of the process,
  one statement leaked per refused open.
- **Three PRAGMA domains SQLite accepts but the gate refused.**
  `max_page_count` takes `1..4294967294` (its own default is 4294967294, which
  a fresh connection could not write back), `soft_heap_limit` and
  `hard_heap_limit` take `0..(2^63 - 1)`, and `threads` is capped at 8, which
  is where SQLite caps it. `journal_size_limit` takes -1 for "no limit".
- **A PRAGMA that names its values takes those names.** `auto_vacuum` and
  `secure_delete` accept `:none`, `:full`, `:incremental`, `true`, `false` and
  `:fast`, as atoms or strings in any case, the way `synchronous` and
  `temp_store` already did — so reading one and writing it back works.
  `secure_delete`'s integer domain is `0..1`: SQLite reads any other non-zero
  integer as "true", so `2` used to mean `true` while asking for `:fast`,
  which is reachable by its word alone.
- **Every door hands SQLite the same PRAGMA name.** `Xqlite.get_pragma/2` and
  `Xqlite.set_pragma/3` resolve a known name to the spelling the typed schema
  uses before the native call, so an error payload names `"function_list"`
  whatever case the caller wrote.

### Changed

- **`{:expected_list, _}` and `{:expected_keyword_list, _}` carry a map, not
  text.** Both used to carry a Rust debug rendering of the term; they now
  carry `%{reason: :not_a_list | :improper_tail | :bad_element, value_type:
  atom()}`, with a one-based `:position` when a single element is at fault.
  `@type Xqlite.list_refusal` names the shape.
- **A raw cancellable function refuses a bad token itself.** An element of a
  cancel-token list that is not a token used to raise `ArgumentError` from the
  native call; it now answers `{:error, {:invalid_cancel_tokens, %{position:
  n}}}`, and a `set_authorizer/2` action that is not an atom answers
  `{:error, {:expected_list, %{reason: :bad_element, position: n, value_type:
  type}}}`.
- **The crate pins its panic strategy.** `native/xqlitenif/.cargo/config.toml`
  sets `panic = "unwind"` for the release and dev profiles, where it outranks
  a machine-wide cargo setting. Rustler's guard turns a panic into a catchable
  `:nif_panicked` only while panics unwind; a build that aborts instead kills
  the VM. `mix verify` gained a step that reads the built library's symbols
  and fails when the pin did not hold.

- **A PRAGMA argument is a scalar, and the PRAGMA's own read forms decide the
  rest.** `Xqlite.Pragma.get/3,4` and the named accessors
  (`Xqlite.Pragma.table_info/2,3` and its siblings) resolve the name first and
  then judge the argument position: a string, an atom or an integer is the
  argument, a keyword list is the options, and anything else answers
  `{:error, {:invalid_pragma_argument, %{pragma: name, value: value, reason:
  reason}}}` before a statement is built. Three calls that used to answer
  `{:ok, []}` now answer that error: a plain list in the argument position
  (`get(conn, :table_info, ["people"])`, `reason: :not_a_scalar`); one of the
  six PRAGMAs that read only with an argument, called without one
  (`get(conn, :table_info)`, `reason: :missing`); and an argument to a PRAGMA
  with no one-argument read form (`get(conn, :user_version, 42)`,
  `reason: :takes_no_argument`) — SQLite reads `PRAGMA user_version("42")` as
  a write, so that getter used to write. A fourth call changes the other way:
  `get(conn, :table_info, ["people"], db_name: "main")` worked by accident,
  because the list was turned into a string, and now answers the same error.
  `@type error_reason` gains the shape.
- **`close/1` answers what `sqlite3_close` said.** The connection is closed
  through rusqlite's own `close`, whose result used to be discarded inside
  `Drop`, so a refusal is now `{:error, {:database_busy_or_locked, code,
  message}}` instead of a silent `:ok`. The statements, streams and blobs are
  finalized before the handle is freed, so that answer still leaves none
  behind, and the connection stays open and can be closed again. No state this
  library can reach makes SQLite refuse today.
- **A PRAGMA value that is not text is refused by what it is.**
  `XqliteNIF.set_pragma/3` (and `Xqlite.set_pragma/3` for a name the typed
  schema does not model) used to answer
  `{:cannot_convert_to_sqlite_value, "<<1:7>>", "Failed to decode binary as
  string for PRAGMA: {error, badarg}"}`, two strings written for a human, for
  every binary it could not read as text. Now a bit size that is no whole
  number of bytes answers `{:unsupported_data_type, :bitstring}`, bytes that
  are no UTF-8 answer `{:cannot_execute_pragma, name, reason}`, and a value
  holding a NUL byte answers `:null_byte_in_string` instead of being written
  into the statement, where SQLite's tokenizer would stop at the NUL.
- **`register_progress_hook/3` refuses a bad option instead of raising.** A
  `:tag` that is not an atom used to raise `CaseClauseError`, an `:every_n`
  that is not an integer or is negative raised `ArgumentError` from the NIF,
  and `0` answered a sentence. All four answer
  `{:error, {:invalid_hook_option, %{key: key, value: value, reason:
  :invalid_value}}}` now, checked before the connection is touched.
  `@type error_reason` gains the shape.

- **Two value types, one per direction.** `Xqlite.sqlite_value/0` now says
  what a result row holds: an integer, a float, a binary, `nil`, and the two
  atoms a REAL that is not finite reads back as, `:positive_infinity` and
  `:negative_infinity`. `%Xqlite.Blob{}` left it — no result row ever carries
  the wrapper — and moved to the new `Xqlite.param_value/0`, which says what
  the binder takes: the same scalars plus `true`, `false` and the wrapper.
  `Xqlite.TypeExtension`'s `encode/1` callback answers a `param_value`, its
  `decode/1` callback takes a `sqlite_value`. No function changed; the types
  now describe the direction they are used in.
- **A PRAGMA name resolves the same way through every door.**
  `Xqlite.Pragma.get/3,4`, `Xqlite.Pragma.put/4`, `Xqlite.get_pragma/2` and
  `Xqlite.set_pragma/3` fold the name's case before anything else, so
  `:foreign_keys`, `:FOREIGN_KEYS`, `"foreign_keys"` and `"FOREIGN_KEYS"` all
  reach the same PRAGMA. A string naming a PRAGMA the typed schema does not
  know is now rejected with `{:unknown_pragma, name}`, where
  `Xqlite.Pragma.put/4` used to answer `{:invalid_pragma_name, name}`;
  `{:invalid_pragma_name, key}` is left for a key that is neither an atom nor
  a string, which used to raise. `@type error_reason` follows:
  `{:unknown_pragma, atom() | String.t()}` and
  `{:invalid_pragma_name, term()}`.
- **A bitstring parameter is refused by its kind, not by Rust's debug text.**
  A value whose bit size is not a whole number of bytes — `<<1::7>>` — used to
  answer `{:cannot_convert_to_sqlite_value, "<<1:7>>", "{error, badarg}"}`,
  two strings the Rust side wrote for a human. It now answers
  `{:unsupported_data_type, :bitstring}`, the shape every other term the
  binder cannot store already uses. A whole number of bytes is untouched: it
  still binds as TEXT or BLOB by its UTF-8 validity.
- **`%Xqlite.Blob{}` needs its bytes.** `bytes` is an enforced key, so the
  wrapper literal without it no longer compiles and `struct!(Xqlite.Blob, [])`
  raises. `struct/2` with no bytes and `struct!(Xqlite.Blob, bytes: nil)` still
  build a wrapper holding `nil`, which the binder refuses as before. A pattern
  is unaffected.
- **`Xqlite.close/1` and `XqliteNIF.close/1` say they can fail.** Both specs
  are `:ok | error()` now. What they do did not change: the one error is
  `{:lock_error, message}`, after a panic inside the NIF broke a lock the close
  needs, which this library's own Rust cannot produce. Both docs now say which
  two locks those are and what each one leaves behind.

### Fixed

- **A PRAGMA key that is no name is an answer at every door.**
  `Xqlite.get_pragma/2` and `Xqlite.set_pragma/3` handed the key to
  `to_string/1` before anything judged it, which raised
  `Protocol.UndefinedError` for a tuple, a map, a pid or a reference and
  `ArgumentError` for a list of atoms. Both answer
  `{:error, {:invalid_pragma_name, key}}` now, with the key unchanged, the
  way `Xqlite.Pragma.get/2,3,4` and `Xqlite.Pragma.put/3,4` always did. A
  charlist changes with them: `Xqlite.set_pragma(conn, ~c"user_version", 77)`
  used to write, because `to_string/1` turns a charlist into the text of its
  characters, and is refused now — write the name as a string or an atom.
- **The openers judge their options list.** `Xqlite.open/2` and
  `Xqlite.open_in_memory/1` raised `Protocol.UndefinedError` from
  `Enum.find/2` for options that are not a list. Both carry
  `when is_list(opts)` now, so the raise is the `FunctionClauseError` the
  `Xqlite` moduledoc names, and it happens before the telemetry span opens:
  `[:xqlite, :open, :start]` and `[:xqlite, :open, :exception]` no longer
  fire for options the guard refuses. An element of the list that is not a
  `{key, value}` pair raised `FunctionClauseError` from inside `Enum.find/2`
  and answers `{:error, {:invalid_open_option, %{key: nil,
  reason: :not_a_pair, value: element}}}` now. `@type error_reason` gains
  the shape.
- **A cancel-token list that ends in something other than `[]` is an answer.**
  `[token | :bogus]` passes the `is_list/1` test, and the seven doors that
  take cancel tokens — both query forms, `execute`, `execute_batch`,
  `stream`, `multi_step` and `backup` — raised `FunctionClauseError` from
  inside `Enum.all?/2` on it, while `Xqlite.cancel_operation/1` answered for
  the same value. They walk the list themselves now and all answer
  `{:error, {:invalid_cancel_tokens, value}}`, carrying the value unchanged.
- **An options list that ends in something other than `[]` is an answer.**
  A list built by hand as `[{:foreign_keys, true} | :busy_timeout]` passes
  the `is_list/1` guard, and `Xqlite.open/2` and `Xqlite.open_in_memory/1`
  raised `FunctionClauseError` from inside `Enum.find_value/2` on it. They
  walk the list themselves now and answer `{:error, {:invalid_open_option,
  %{key: nil, reason: :not_a_pair, value: tail}}}`, carrying whatever the
  list ended in.
- **A number in the PRAGMA argument position reaches SQLite as a number.**
  `Xqlite.Pragma.get/3,4` quoted every argument into a name, so
  `get(conn, :integrity_check, 1)` built `PRAGMA integrity_check("1")` and
  answered `{:error, {:no_such_table, "1"}}` where SQLite answers `["ok"]`,
  and `:optimize` and `:incremental_vacuum` lost the bitmask and the page
  count they were handed. An integer is written as a number now, a string or
  an atom as a quoted name.
- **`nil` is no PRAGMA argument.** `nil` is an atom, so
  `Xqlite.Pragma.get/3,4` and the named accessors read it as one and built
  the statement with no argument at all: `get(conn, :table_info, nil)`
  answered `{:ok, []}`, the same as a table no database holds. It answers
  `{:error, {:invalid_pragma_argument, %{pragma: name, value: nil,
  reason: :not_a_scalar}}}` now, like any other term that is no scalar.
- **`{:cannot_execute_pragma, name, reason}` carries the name, never the
  statement.** Two of the three places that build it passed the whole
  statement text as the first element — `XqliteNIF.get_pragma(conn, "42")`
  answered `{:cannot_execute_pragma, "PRAGMA 42;", _}` — while the third
  passed the bare name. All three pass the name now. A shape's payload
  changes, which is a break; xqlite is pre-1.0 and takes it.
- **A PRAGMA name folds by ASCII letters, the way SQLite folds it.**
  `Xqlite.Pragma` matched a name with `String.downcase/1`, a Unicode fold,
  so a name spelled with the Kelvin sign (U+212A) where a `k` belongs
  resolved to the PRAGMA it folds onto. Only ASCII letters fold now, and
  such a name answers `{:error, {:unknown_pragma, key}}`.
- **A cancel token that is not one is refused, not raised.** Every door that
  takes tokens — `Xqlite.query_cancellable/5`, `execute_cancellable/5`,
  `execute_batch_cancellable/3`, `query_with_changes_cancellable/5`,
  `multi_step_cancellable/3`, `backup_with_progress/6`, `stream/4` and
  `cancel_operation/1` — now answers `{:error, {:invalid_cancel_tokens,
  value}}`, carrying the value you passed unchanged. They used to raise
  `ArgumentError` (`FunctionClauseError` for `cancel_operation/1`) on anything
  that was not a live token, `:bogus` and a plain `make_ref()` alike. The new
  NIF `XqliteNIF.is_cancel_token/1` answers whether a term is a token; the raw
  `XqliteNIF` functions still raise, as every raw NIF does on a wrong-typed
  argument. `cancel_tokens: nil` used to mean "no tokens" and is refused now —
  pass `[]`.
- **The telemetry guide names the metadata each event really carries.** Its two
  tables named a few keys per event where the `Xqlite.Telemetry` moduledoc
  names all of them; the stream-open row named one key of five. Every row now
  names every start-metadata key except `conn` and `sql`, and a test keeps the
  guide and the moduledoc in step.
- **A blob wrapper holding a bitstring says so.**
  `%Xqlite.Blob{bytes: <<1::7>>}` is rejected with `type: :bitstring` instead
  of `type: :binary`: the BEAM has one term type for binaries and bitstrings
  alike, and a bitstring whose bit size is not a whole number of bytes is the
  only value that can produce that error. `Xqlite.Blob` now lists every atom
  `type` can hold.
- **The PRAGMA getters accept every spelling the setters accept.**
  `Xqlite.Pragma.get(conn, :FOREIGN_KEYS)` and
  `Xqlite.Pragma.get(conn, "foreign_keys")` answered
  `{:error, {:unknown_pragma, _}}` while the same spellings worked for
  writing.
- **`wal_autocheckpoint` is read and written under any spelling.**
  `Xqlite.get_pragma(conn, :WAL_AUTOCHECKPOINT)` reported `0` while the
  lower-case spelling reported the threshold in force. xqlite's own WAL
  callback holds the slot SQLite would report that number from, so the NIF
  substitutes the value it is emulating — and it matched the PRAGMA's name
  byte for byte when deciding to.
- **The STRICT helpers match a table name the way SQLite does.**
  `Xqlite.check_strict_violations/2` and `Xqlite.enable_strict_table/2` fold
  ASCII case when they look the table up — and only ASCII, which is all
  SQLite folds — so `"PEOPLE"` finds a table stored as `people` again. They
  also read the columns from the table that was found, schema qualified: with
  a temporary table and a main table whose names differ only in case, the
  check used to pair one table's columns with the other table's definition.
- **`Xqlite.busy_timeout/2` rejects a bad argument.** `-1`, `"5"` and
  `:infinity` answer `{:error, {:cannot_execute, reason}}` instead of raising
  `FunctionClauseError`.
- **`Xqlite.multi_step_cancellable/3` documents its rows.** Like `step/1` and
  `multi_step/2` it hands back what SQLite stored, with no type extension run
  on the rows.

## [0.14.0] - 2026-09-17

### Added

- **`:type_extensions` reaches every function that takes parameters.**
  `Xqlite.bind/3`, `Xqlite.explain_analyze/4`,
  `Xqlite.query_cancellable/5`, `Xqlite.execute_cancellable/5` and
  `Xqlite.query_with_changes_cancellable/5` each gained a trailing
  options list carrying `:type_extensions`, so the same chain
  `query/4` runs applies to them. The two cancellable query forms also
  decode their result rows, in place on the plain map they already
  return. Callers passing the old number of arguments are unaffected;
  an empty extension list leaves all five exactly as they were.

### Changed

- **A type extension can refuse a value.** `Xqlite.TypeExtension`'s
  `encode/1` callback gained a third answer, `{:error, reason}`, meaning
  "this value is mine and it cannot be stored". `:skip` still means "not
  mine, ask the next extension". A refusal ends the call with
  `{:error, {:type_extension_refused, %{position: n, extension: module,
  reason: reason}}}`, where `n` is the parameter's 1-based place in the
  list, before any SQL runs, and inside the call's telemetry span. To
  make that unambiguous, `Xqlite.TypeExtension.encode_value/2` now
  answers `{:ok, value}` or `{:error, %{extension: _, reason: _}}` and
  `Xqlite.TypeExtension.encode_params/2` answers `{:ok, params}` or the
  refusal tuple, where both used to return the encoded value directly.
  Code that calls either of them by hand needs the tuple unwrapped.
  `decode/1` is unchanged: a value no extension converts still comes
  back as SQLite stored it.
- **PRAGMA values are checked once, in one place.**
  `Xqlite.Pragma.check_value/2` is the single rule
  `Xqlite.set_pragma/3`, `Xqlite.Pragma.put/4` and the connection
  options of `Xqlite.open/2` all apply. A true/false PRAGMA takes
  `true`, `false`, `1`, `0` and the words `on`, `off`, `yes`, `no`,
  `true`, `false` as atoms or strings in any case; a numeric PRAGMA
  takes an integer inside its range and refuses a boolean; a mode
  PRAGMA takes its words as atoms or strings in any case, and the
  integers its spec lists. `nil` is refused everywhere, which changes
  its error from `{:cannot_execute_pragma, _, _}` to
  `{:invalid_pragma_value, _}`. A PRAGMA `Xqlite.Pragma` does not model
  keeps the raw path through `Xqlite.set_pragma/3`.

### Fixed

- **A stream no longer drops the rows it had already read.** When a
  fetch failed part-way through its batch — an invalid-UTF-8 TEXT
  value, an integer overflow in the SELECT — every row read before the
  failing one was thrown away with the error. At the default batch size
  of 500 a stream over fifteen rows whose last one was bad yielded no
  rows at all, in every `:on_error` mode. The batch now ends early: the
  rows already read come back as an ordinary batch and the error
  follows on the next fetch, so `:emit_error` yields them as
  `{:ok, row}` and then the terminal `{:error, reason}`, `:halt` stops
  after them and `:raise` raises after them. No row is delivered twice
  and no row from the failing one on is read. A cancellation keeps its
  documented behaviour and still discards the batch it lands in.
- **A `Decimal` that is not a number is refused instead of stored as a
  word.** `Xqlite.TypeExtension.Decimal` wrote `NaN`, `-NaN`,
  `Infinity` and `-Infinity` as those words into a TEXT column, where
  nothing could tell them from data. Each now answers
  `{:error, {:non_finite, kind}}` with `kind` one of `:nan`,
  `:negative_nan`, `:infinity`, `:negative_infinity`.
- **A very long `Decimal` is refused instead of raising.** A value whose
  plain form needs more than 6178 digit characters used to escape
  `query/4`, `execute/4` and `stream/4` as an `ArgumentError` from the
  `:decimal` library, against their `@spec`. It now answers
  `{:error, {:too_many_digits, %{digits: n, maximum: 6178}}}`, counted
  the way the library counts and without calling the raising function.
  Everything within the ceiling is written exactly as before.
- **The JSON extension says why it declined.** A map or list
  `Jason.encode/1` could not encode — one holding bytes that are not
  valid UTF-8, or a tuple, pid, reference or function — used to fall
  through to the NIF and produce the same `{:unsupported_data_type,
  :map}` as a map with no extension loaded. It now answers
  `{:error, {:json_encode_failed, %{reason: reason}}}` carrying Jason's
  own error, and the caller hears which parameter it was.
- **`Xqlite.set_pragma/3` no longer reports success for a value SQLite
  ignored.** `set_pragma(conn, "foreign_keys", :maybe)` answered
  `{:ok, nil}` while foreign keys stayed off, and
  `set_pragma(conn, "user_version", :garbage)` answered `{:ok, nil}`
  while the version became 0. Both are now
  `{:error, {:invalid_pragma_value, %{pragma: name, value: value}}}`
  and the setting is untouched. The lower-case and atom spellings that
  only the unchecked path used to accept — `:wal`, `"wal"`, `:memory`,
  `:normal`, `:on`, `:off` — now work through `Xqlite.Pragma.put/4` too.
- **A boolean on a numeric PRAGMA is refused.**
  `Xqlite.Pragma.put(db, :user_version, true)` answered `{:ok, nil}`
  and wrote 0, because the check accepted the boolean and then handed
  SQLite the word `ON`.
- **A PRAGMA that can only be read is refused.**
  `Xqlite.Pragma.put(db, :page_count, 5)` and
  `Xqlite.Pragma.put(db, :integrity_check, 5)` answered `{:ok, _}` and
  changed nothing; both now answer
  `{:error, {:read_only_pragma, name}}`.
- **A connection option past what SQLite stores is refused at open.**
  `Xqlite.open_in_memory(busy_timeout: 3_000_000_000)` opened and read
  the timeout back as 0 — no wait at all — and `cache_size:
  -10_000_000_000` and `wal_autocheckpoint: 3_000_000_000` did the
  same. All three now fail the open with
  `{:error, {:invalid_pragma_value, _}}`.

## [0.13.0] - 2026-09-17

### Changed

- **A `busy_timeout` write is rejected while the busy slot is held.** While
  a busy retry policy (`Xqlite.set_busy_policy/2`) or at least one busy
  observer (`Xqlite.register_busy_observer/2`) is installed, a statement
  that writes `busy_timeout` now fails as it is prepared with `{:error,
  {:busy_timeout_write_refused, %{policy: boolean, observers: count}}}`.
  It used to be accepted and to silently replace xqlite's busy callback
  with SQLite's built-in one: the policy stopped applying and every
  observer stopped receiving `{:xqlite_busy, ...}` messages, with no
  error. Every spelling is covered — a quoted name, a `main.` or `temp.`
  prefix, `PRAGMA busy_timeout(N)`, a leading comment, and a value of `0`
  or less — on every path that prepares SQL: `query/4`, `execute/4`,
  `execute_batch/2`, `prepare/2`, `stream/4`, and the typed
  `Xqlite.set_pragma(conn, :busy_timeout, ms)` / `XqliteNIF.set_pragma/3`.
  Reading `PRAGMA busy_timeout` is still allowed and still reads `0` while
  the slot is held, `Xqlite.busy_timeout/2` still changes the wait, and
  with the slot empty the write is accepted as before.
- **The connection carries one authorizer for both jobs.** While the busy
  slot is held, `Xqlite.set_authorizer/2`'s denied kinds and xqlite's own
  two rules share the single authorizer SQLite gives a connection. Your
  rules are unchanged for every action other than a `busy_timeout` write,
  and removing your list while the slot is held keeps xqlite's rules.
  Taking or emptying the slot now installs or clears an authorizer, which
  expires the connection's prepared statements; SQLite re-prepares them at
  their next step with no change of outcome.

### Fixed

- **An authorizer denying `:pragma` no longer costs the connection its
  wait.** Taking the busy slot reads `PRAGMA busy_timeout` to remember the
  wait it displaces. That read used to be denied by the caller's own
  authorizer and silently treated as "nothing to remember", so the
  connection stopped waiting on contention for good and emptying the slot
  put nothing back — losing the 5000 ms every connection starts with.
  xqlite's own read now passes the caller's authorizer, and a read that
  fails for any other reason takes nothing and answers the read's own
  error instead of remembering zero.
- **`XqliteNIF.set_busy_policy/4`'s doc stated the wrong ceiling.**
  `max_elapsed_ms` is the wall-time budget for a single busy event, reset
  at the first callback of each fresh contention, as `Xqlite.set_busy_policy/2`
  and the gotchas guide already said — not an absolute ceiling from the
  slot's first installation.

## [0.12.2] - 2026-09-17

### Added

- **`%Xqlite.Blob{}`, a parameter that is always stored as a `BLOB`.** A
  plain Elixir binary is stored as `TEXT` when its bytes are valid UTF-8
  and as a `BLOB` otherwise — right for strings, and a coin toss for raw
  bytes: about one in fourteen thousand random 16-byte values (a UUID, a
  key, a piece of ciphertext) happens to decode as UTF-8 and lands as
  `TEXT`. The two classes sort apart and compare unequal, so a `UNIQUE`
  column accepts the same bytes twice and a STRICT table with a `BLOB`
  column rejects the `TEXT` one outright. Binding
  `%Xqlite.Blob{bytes: bytes}` stores a `BLOB` whatever the bytes are, as a
  positional element or as a keyword pair's value, on `Xqlite.query/4`,
  `Xqlite.execute/4`, their cancellable forms, `Xqlite.stream/4`,
  `Xqlite.bind/2`, `Xqlite.explain_analyze/3` and the matching `XqliteNIF`
  functions. Values read back are plain binaries, never wrapped, so a
  read-and-write-back loop moves them to `TEXT` unless it wraps them again.
  A `bytes` field that is not a binary is refused with
  `{:error, {:invalid_blob_bytes, %{position: position, type: type}}}`,
  naming the parameter's one-based position in the list and the type found
  there.

### Changed

- Dependencies refreshed: rustler_precompiled 0.9.0 (the precompiled
  NIF download now verifies TLS through the certificate store that
  Erlang/OTP 25+ ships, so `castore` leaves the dependency tree, and
  `NO_PROXY` and `RUSTLER_PRECOMPILED_IPFAMILY` are honoured),
  telemetry 1.4.2, and the crate's transitive dependencies (rusqlite,
  rustler and the bundled SQLite unchanged at 3.53.2).

### Fixed

- **`Xqlite.TypeExtension.UUID` no longer spreads UUIDs over two storage
  classes.** It emitted the bare sixteen bytes, so the storage class
  followed their contents: the nil UUID and roughly one in fourteen
  thousand others were stored as `TEXT` while every other UUID in the same
  column was a `BLOB`. Decoding hid the split — both read back as the same
  hyphenated string — while `ORDER BY`, `UNIQUE` and STRICT tables saw it.
  The extension now emits `%Xqlite.Blob{}`.
- **`Xqlite.TypeExtension.encode_params/2` encodes every element of a
  keyword list.** Positional or keyword is decided once, from the list's
  first element, exactly as the NIF decides it; the keyword branch then
  re-decided per element and encoded only those that were a pair with an
  atom key, passing every other one through untouched.

## [0.12.1] - 2026-09-06

### Fixed

- **`Xqlite.enable_strict_table/2` no longer deletes the rows of child
  tables.** With `PRAGMA foreign_keys` on — the default `Xqlite.open/2`
  sets — the rebuild's `DROP TABLE` performed the implicit delete SQLite
  does there, and that delete ran every child's `ON DELETE` action: a
  child declaring `CASCADE` lost every row that pointed at the converted
  table, and the helper still answered `:ok`; a child declaring
  `RESTRICT` or nothing at all failed the drop with a bare constraint
  violation instead. The rebuild now reads `foreign_keys`, switches it
  off before its transaction opens (SQLite ignores the pragma inside
  one) and puts it back afterwards on every path, so the drop runs no
  action and every child keeps its rows.
- **Triggers survive the rebuild.** `DROP TABLE` drops the table's
  triggers, and only index statements were saved and replayed, so every
  trigger on the table was gone after a successful conversion. Triggers
  are now saved and replayed beside the indexes — including a
  `TEMP` trigger, which lives in the `temp` schema with the table's bare
  name and which the drop deletes there without a word. Each statement
  is replayed into the schema it came from, with the same bytes SQLite
  stored.
- **A table that a view reads converts.** The rename at the end of the
  rebuild re-parses every view and trigger in the schema to carry the
  new name into them, and one still naming the dropped original made it
  fail with `{:sqlite_failure, 1, 1, "error in view ..."}`. The rename
  now runs with `PRAGMA legacy_alter_table` on, which renames the table
  and nothing else; the views keep their text, which already names the
  final name. That pragma is read first and put back too.
- **A table in an attached database keeps its indexes.** SQLite stores
  `CREATE INDEX` without the schema qualifier it was written with, so
  the replayed statement resolved the bare table name through `temp`
  and `main` first and answered `{:no_such_table, "main.t"}` — an
  attached table with any index could not be converted at all. Every
  replayed statement now carries the schema it came from.
- **The rowids survive.** The copy was `INSERT INTO tmp SELECT * FROM t`,
  which let SQLite hand out fresh rowids, so a table without an
  `INTEGER PRIMARY KEY` alias came back renumbered 1..n and any gap was
  gone. The copy now names the rowid on both sides. A table declaring
  all three of `rowid`, `_rowid_` and `oid` as columns, none of them the
  alias, has no spelling left to name it with and is refused with the
  new `{:rowid_shadowed, table}`.
- **A call made inside the caller's own transaction is refused.** The
  helper's `BEGIN` failed and its error path then ran `ROLLBACK`, which
  threw away the caller's transaction and every row it had not
  committed. It now answers the new bare `:transaction_in_progress`
  before touching anything, and rolls back only a transaction it opened
  itself.
- **Generated columns and self-referencing foreign keys convert.**
  `SELECT *` supplied a value for every generated column, which SQLite
  refused with a column-count mismatch; the copy's column list now comes
  from `PRAGMA table_info`, which leaves them out. A table whose foreign
  key points at itself failed the drop for the same reason the child
  tables did, and converts now.
- **The temporary-table collision names the table plainly.** An existing
  `<table>_xqlite_strict_rebuild` reached SQLite's own `CREATE TABLE`
  error, whose payload echoed the quoted token
  (`{:table_exists, "\"t_xqlite_strict_rebuild\""}`). It is now refused
  before the transaction with the bare name.

`:transaction_in_progress` and `{:rowid_shadowed, String.t()}` join
`Xqlite.error_reason/0`.

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

[0.15.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.15.0
[0.14.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.14.0
[0.13.0]: https://github.com/dimitarvp/xqlite/releases/tag/v0.13.0
[0.12.2]: https://github.com/dimitarvp/xqlite/releases/tag/v0.12.2
[0.12.1]: https://github.com/dimitarvp/xqlite/releases/tag/v0.12.1
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
