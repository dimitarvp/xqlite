# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`Xqlite.get_limit/2` and `Xqlite.put_limit/3`**, and the raw
  `XqliteNIF.get_limit/2` and `XqliteNIF.put_limit/3` — SQLite's
  per-connection limits (`sqlite3_limit`), thirteen categories.
  `put_limit/3` answers the value now in force, read back under the same
  lock: SQLite lowers a value to its compile-time ceiling for the category
  and raises `:length` to 30. On `Xqlite.put_limit/3` any integer outside
  `0..2_147_483_647` is `{:error, {:invalid_limit_value, %{category: _,
  value: _}}}`, judged before the category; the raw stub judges the same
  range and raises `ArgumentError` for an integer outside 64 bits.

### Fixed

- **A second enumeration of an `Xqlite.stream/4` stream read on where the
  first stopped, or looked like an empty table.** The statement opens at the
  call, so a second `Enum.to_list/1`, the rest after an `Enum.take/2`, or a
  retry after a rescued `Xqlite.StreamError` answered `[]`, and a pass started
  while the first still ran — `Stream.zip(s, Stream.drop(s, 1))`, a nested
  `Enum.take/2`, a pass after the first consumer was killed — handed out rows
  from the wrong batches with no error. The stream now runs once: every
  enumeration after the first answers `:stream_consumed` through `:on_error` —
  `:raise` raises `Xqlite.StreamError` with it, `:emit_error` yields
  `{:error, :stream_consumed}` alone, `:halt` logs it and yields nothing —
  without fetching, closing or sending a telemetry event of its own. Call
  `stream/4` again for a second pass.
- **A bind on a statement that had already stepped answered SQLite's bare
  misuse tuple.** Mid-run, `bind/3` answered
  `{:error, {:sqlite_failure, 21, 21, _}}` after walking the whole parameter
  list under the connection lock, while `clear_bindings/1` answered
  `{:error, :statement_mid_run}`. A bind on a statement that takes parameters
  and is mid-run now answers `{:error, :statement_mid_run}` before it reads the
  list, and keeps the values bound before. After the run has ended — `:done`
  or a failed step — the bind resets the statement itself, so the next step
  reruns with the new values; `reset/1` is no longer needed first.
- **Docs: a step refused as busy keeps its run, and what a closed connection
  leaves behind.** A step SQLite refused as busy while taking or committing its
  lock keeps its run for a retry — the statement stays mid-run and the retry
  writes once — where the docs said every failed step ended the run. After the
  connection is closed, every step, bind, reset, clear and fetch answers
  `{:error, :connection_closed}`, finalize and `stream_close/1` answer `:ok`,
  and the column-name calls answer the names captured at prepare or open;
  `XqliteNIF.stmt_finalize/1` said the SQLite handle stayed alive and
  `XqliteNIF.stream_fetch/2` said the error repeated until `stream_close/1`.

- **`Xqlite.clear_bindings/1` mid-run nulled the rest of the read.**
  `sqlite3_clear_bindings` has no mid-run check where every `sqlite3_bind_*`
  answers `SQLITE_MISUSE`, so a clear between two rows released the values in
  place and every row left in the run read NULL: `SELECT rowid, ? FROM t`
  handed back `[1, "P"]`, then `[2, nil]`. A statement that takes parameters
  and has been stepped without a `reset/1` since now answers
  `{:error, :statement_mid_run}` and keeps its values. A statement that takes
  none has nothing to release and still answers `:ok`, and so does a clear
  after `:done`, where a bind is refused instead — a finished run has no rows
  left to change.
- **`Xqlite.TypeExtension.encode_params/2` skipped its own walk when there
  were no extensions.** With `[]` or `nil` extensions the call handed the term
  straight back, answering `{:ok, term}` for every list its own documentation
  says it refuses: a term that is no list, and a list whose tail is not `[]`.
  It walks the list's spine whatever the extension list now, and answers the
  same `{:expected_list, _}` and `{:expected_keyword_list, _}` refusals it
  answers with an extension on. A keyword element that is no `{key, value}`
  pair still travels on to the NIF, which refuses it, and a key of any kind is
  still a key.
- **`Xqlite.TypeExtension.decode_rows/2` raised where its write-side twin
  refused.** A rows term that is no list of lists — `:done`, `{:row, values}`,
  `nil`, a list whose tail is not `[]`, a row that is no list — raised
  `Protocol.UndefinedError` or `FunctionClauseError` from inside the chain,
  and this is the function four `Xqlite` doc blocks recommend for the rows
  `step/1` and `multi_step/2` hand back. It now answers the write side's
  refusals: `{:error, {:expected_list, %{reason: :not_a_list, value_type:
  kind}}}`, the same tag with `:improper_tail` for a tail that is not `[]`,
  and with `:bad_element` and the row's one-based position for a row that is
  no list. A row whose own tail is not `[]` is refused where a walk reads it,
  which is when an extension is on. A map row, which used to be turned
  silently into a list of its pairs, is refused as a row that is no list.
- **A bind SQLite refused before taking a value marked the statement
  unrunnable.** A bind on a statement mid-run is refused by SQLite with
  `SQLITE_MISUSE` before it touches the first parameter, but the bind path
  tagged it as partly bound and cleared the flag that lets a statement step,
  so `reset/1` then `step/1` answered `{:error, {:parameters_unbound, _}}`
  with the earlier bind still in place. Only a failure after at least one
  value was taken clears the flag now; a refusal that took nothing leaves
  the statement as it was.
- **`SAVEPOINT`, `RELEASE`, `ROLLBACK TO` and a read-only statement with a
  long comment read as "SQL contains no statement" under a lowered
  `:length`.** The check that tells an empty text from a statement reads
  SQLite's expansion of the statement, which SQLite withholds above the
  connection's length limit; the read now lifts the limit and puts it back,
  so the check is exact at any limit.
- **`XqliteNIF.get_create_sql/2` judges its name against the length limit**
  like every door that binds a value, answering
  `{:error, {:value_too_large, %{byte_size: _, limit: _}}}` where it used to
  answer `{:too_big, code, message}`.
- **The telemetry guide names the one refusal answered without an event.**
  A `:type_extensions` option that is no proper list of extension modules is
  refused before the span opens, so the call emits neither a start nor a
  stop; the guide said every operation emits events. Its event table also
  named `query_cancellable/4`, `query_with_changes_cancellable/4` and
  `explain_analyze/3` where the doors are `/5`, `/5` and `/4`.
- **A bind SQLite refused part-way through the list left a half-written row.**
  A value longer than the connection's length limit was refused only once
  SQLite met it, with the values before it already bound and the failing
  parameter left NULL — and the statement still runnable, so a step after the
  error wrote a half-updated row. Every door now judges every TEXT and BLOB
  parameter against that limit before it binds anything, and answers
  `{:error, {:value_too_large, %{byte_size: _, limit: _}}}` with nothing
  bound; a bind SQLite refuses for any other reason leaves the statement
  unrunnable until a bind succeeds or `clear_bindings/1` runs.
- **A keyword list of many names bound more slowly than it had to.** Each key
  was resolved by walking the statement's whole list of parameter names, one
  string comparison per name. Both binding paths now read the statement's own
  names once into a map and bind by index, and the doors going through
  rusqlite no longer let it resolve every name a second time. On one machine a
  bind of 32 766 names went from 3.48 to 1.46 seconds, and the connection lock
  is held for that much less. The cost still grows faster than the number of
  names: reading the name at one index is itself a walk of SQLite's parameter
  list, and its C interface offers no way to read them all in one pass.

- **A bind the library refused left the statement runnable.** Every one of
  the six refusals binds nothing at all, and SQLite reads a parameter nothing
  was bound to as NULL, so `Xqlite.bind(stmt, [1, 2, {:no}])` followed by
  `Xqlite.step(stmt)` ran the statement with NULL in every parameter and
  answered success — an `UPDATE` written that way wrote NULL over its
  columns. A statement that takes parameters now refuses `step/1`,
  `multi_step/2` and `multi_step_cancellable/3` with
  `{:error, {:parameters_unbound, %{expected: n}}}` until a bind succeeds,
  and the same refusal covers a statement stepped straight after `prepare/2`.
  An earlier successful bind stays in force, `reset/1` keeps it, and
  `clear_bindings/1` is how a caller asks for a run with NULL in every
  parameter. The refusal sits behind the lifecycle checks, so a finalized
  statement still answers `:statement_finalized` and one on a closed
  connection `:connection_closed`.
- **`Xqlite.stream/4` took a batch size the fetch door cannot read.** The gate
  accepted any integer at or above 1, while the fetch door reads the number as
  a signed 64-bit integer, so `batch_size: 2 ** 63` opened a stream that died
  on its first batch — and under `on_error: :halt` that was an empty stream
  with no error at all. The gate now bounds the number to
  `1..9223372036854775807` and answers
  `{:error, {:invalid_batch_size, %{provided: _, minimum: 1}}}` at the call,
  as it already did for `0` and for a term that is no integer.

- **A keyword list that left a name out wrote NULL over that column.** A
  named parameter nothing was bound to reads as NULL, so
  `Xqlite.query(conn, "UPDATE t SET a = :a, b = :b WHERE id = 1", a: "new_a")`
  wrote NULL over `b` and answered `changes: 1`; the raw doors
  (`XqliteNIF.stmt_bind/2`, `stream_open/3`, `explain_analyze/3`) lost the
  column the same way. A keyword list must now name every parameter of the
  statement, each exactly once, on every door that takes parameters, and the
  whole list is judged before a single value is bound: a parameter no key
  named is `{:error, {:missing_parameter, %{index: i, name: name}}}` for the
  lowest such index, `name` being SQLite's own spelling of it (`":b"`, `"@b"`,
  `"$c"`, `"?3"`) and `nil` for a bare `?`, which no keyword list can name —
  use a positional list for such a statement. A key the statement does not
  have is still `{:error, {:invalid_parameter_name, key}}`, and it is still
  the answer when the list both names something unknown and leaves something
  out: every key is resolved first. A name used twice in the SQL is one
  parameter with one value and passes, as before.
  **Two partial keyword binds in a row no longer add up.**
  `Xqlite.bind(stmt, a: 1)` followed by `Xqlite.bind(stmt, b: 2)` worked
  because SQLite keeps a binding until it is overwritten; each call now has
  to hand over a complete list. Where that pattern was in use, call
  `reset/1` and bind the whole list once.
- **A keyword list can now name an `@` or `$` parameter.** Every key used to
  get a `:` prefix, so `SELECT @b` was unreachable by name — `[b: 1]` and
  `[{:"@b", 1}]` both answered `{:invalid_parameter_name, _}`. A key whose
  own text starts with `:`, `@` or `$` is now used as written
  (`[{:"@b", 1}]` binds `@b`, `[{:"$c", 1}]` binds `$c`) and every other key
  still gets the `:` prefix, so `[a: 1]` binds `:a` as before.
- **An improper parameter list raised at six doors.** `Xqlite.query/4`,
  `execute/4`, `explain_analyze/4` and the three `*_cancellable` doors count
  the list for their telemetry metadata before the NIF runs, with `length/1`,
  which raises `ArgumentError` on a list whose tail is not a list. They now
  count the list's proper prefix by hand and let the NIF answer, so
  `[1 | :tail]` is `{:error, {:expected_list, %{reason: :improper_tail,
  value_type: :atom}}}` there too, the same as at every other door. `nil` and
  a term that is no list are unchanged.
- **`secure_delete` refused the words SQLite takes.** Its spec maps `0`, `1`
  and `2` to `false`, `true` and `:fast`, and the mapped path looked a word up
  in those three alone, so `:on`, `"off"`, `:yes` and `"NO"` were
  `{:error, {:invalid_pragma_value, _}}` while SQLite itself stores 1, 0, 1
  and 0 for them. A PRAGMA whose mapping gives both booleans a word of their
  own now takes the whole boolean vocabulary and writes the mapping's own word
  (`:on` writes `TRUE`), in any case, as an atom or a string. A mapping of
  three modes, such as `auto_vacuum`'s, gives a boolean no meaning and keeps
  refusing the words; `secure_delete = 2` stays refused, because SQLite reads
  the integer as the boolean true and would store 1.
- **A parameter list one element short wrote NULL through `stream/4`.** The
  three doors that bind through SQLite's C API directly — `stream/4` and
  `XqliteNIF.stream_open/3`, `explain_analyze/4`, and `bind/3` — never
  counted the list they were handed, and SQLite reads a parameter nothing
  was bound to as NULL. `Xqlite.stream(conn, "UPDATE t SET v = ?2 WHERE id
  = ?1", [1])` therefore wrote NULL over the stored text and reported
  success, where `query/4` refuses the same call; `[]` and `nil` did it to
  every row of the table. All three now answer
  `{:error, {:invalid_parameter_count, %{expected: _, provided: _}}}` before
  a value is bound, the too-long list included — that one used to leak
  SQLite's own "column index out of range". `[]` and `nil` count as zero
  parameters, so they pass only on a statement that takes none:
  `XqliteNIF.stmt_bind(stmt, nil)` on a statement with a parameter is now
  refused instead of leaving it NULL. A keyword list is judged by the
  coverage rule above.

- **`multi_step/2` no longer throws away the rows it had already read.** A
  value SQLite hands back that cannot be read — a TEXT column holding bytes
  that are not valid UTF-8 — used to lose every row the same batch had read
  before it: four rows with the unreadable one second answered the error and
  row one never reached the caller. The statement door now does what the
  stream door has done for a while: it hands back the rows it read, with
  `done: false`, holds the error, and answers it on the next call; the
  statement then carries on at the row after the bad one. `reset/1` starts
  the statement over and drops a held-back error. A cancellation still
  discards the rows of the batch it lands in. `multi_step_cancellable/3`
  shares all of it. Two corrections since: the error a batch holds back is
  answered by the next call that reads a row, whichever door makes it —
  `step/1` used to walk straight past it, so the bad row vanished with no
  error at all and, when it was the last row, `finalize/1` swallowed the
  error for good. And a `sqlite3_step` that fails outright — a locked
  database, an I/O error, a runtime error in the SQL such as
  `abs(-9223372036854775808)`, a trigger's `RAISE` — is answered at once
  instead of being held back: no row was stepped past, so there is nothing
  to continue at. Such a failure discards the batch's rows, exactly as a
  cancellation does, so a result set that fails part-way now hands back no
  rows at all through `multi_step/2` (`step/1` and `stream/4` still deliver
  the rows before the failure). It used to hold the error back and then
  alternate for ever between the rows from the top and the error, never
  reaching `done: true`. After such a failure the statement is left where
  SQLite left it: the next step is SQLite's own rerun from the top, which
  meets the same failure, and `reset/1` changes nothing.
- **`Xqlite.stream/4` silently dropped every column whose name repeated.** A
  stream row is a map keyed by column name, and a map cannot hold two entries
  under one key, so a join of two tables sharing a column —
  `SELECT ta.v, tb.v FROM ta, tb` — came back as `%{"v" => 2}`, the first
  value gone with nothing said about it, where `Xqlite.query/4` over the same
  SQL keeps both. SQLite also names a column that has no name of its own
  after the text that produced it, so `SELECT 1, 1` and `SELECT ?, ?` lost
  values the same way, in every `:on_error` mode. Such a statement is now
  refused at stream open with
  `{:error, {:duplicate_column_name, name}}`, `name` being the first name
  that repeats in SQLite's order; alias the columns
  (`SELECT ta.v AS x, tb.v AS y`) to stream it. `query/4` and the raw stream
  doors answer lists and are unchanged.
- **An improper parameter list raised once a type extension was on.** With no
  extension the list travelled untouched to the native walk, which refuses a
  tail that is not a list with
  `{:error, {:expected_list, %{reason: :improper_tail, value_type: _}}}`;
  with one, the encode chain walked the list itself and `[1 | :tail]` raised
  `FunctionClauseError` on all eight parameter doors and on the public
  `Xqlite.TypeExtension.encode_params/2`. The chain now answers what the
  native walk answers for the same term: both improper-tail shapes, and
  `{:error, {:expected_list, %{reason: :not_a_list, value_type: _}}}` for a
  parameter term that is no list and not `nil`, which raised too.
  `Xqlite.bind/2,3` lost its own `is_list` guard with it, so
  `Xqlite.bind(stmt, :foo)` answers that refusal instead of raising and
  `Xqlite.bind(stmt, nil)` means no parameters, as it does at every other
  parameter door.
- **Documentation.** The seven `:type_extensions` paragraphs say "extension
  modules" rather than "module names"; the four places that recommend
  `Xqlite.TypeExtension.decode_rows/2` say it answers `{:ok, rows}`; the
  `:too_big` docs write its code as `code` rather than the literal 18, SQLite
  defining no extended code for that result today; the telemetry guide names
  the limit functions beside `backup_with_progress/6` as the doors that emit
  nothing; the gotchas guide, this file and the architecture map carry the
  one measured figure for the named bind; the architecture map names the
  functions the stream data flow really goes through and all of the checks
  the open makes; and this file's Unreleased section has one `### Changed`
  heading again, so the entries under it that are fixes read as fixes.

### Changed

- **SQL holding no statement answers `{:error, :no_statement}`** instead of
  `{:error, {:cannot_execute, "SQL contains no statement"}}`.
- **`wal_checkpoint/3` on a named database not in WAL mode answers
  `{:error, :not_in_wal_mode}`** instead of `-1` page counts, and a checkpoint
  lock another connection holds answers
  `{:error, {:database_busy_or_locked, 5, _}}`.
- **Backup progress messages are
  `{:xqlite_backup_progress, %{remaining: r, total: t, status: :copied | :busy}}`.**
- **`connection_stats/1` reports the half SQLite defines for each counter.**
  `lookaside_hit`, `lookaside_miss_size` and `lookaside_miss_full` report
  SQLite's running totals (they read 0 before); `deferred_fks` is now
  `deferred_fks?`, a boolean; every counter is read as 64 bits.
- **Tagged errors carry the rejected term.** `{:invalid_checkpoint_mode, mode}`,
  `{:invalid_schema_name, term}` (`wal_checkpoint/3`, `txn_state/2`),
  `{:invalid_transaction_mode, mode}` and `{:invalid_conflict_strategy,
  strategy}` (were bare atoms), `{:blob_write_out_of_bounds, %{offset,
  byte_size, blob_size}}`, `{:invalid_hook_option, _}` from the raw
  progress-hook NIF, and `{:invalid_pragma_value, %{pragma: :busy_timeout,
  value}}` from `busy_timeout/2` and the raw setters.
- **`XqliteNIF.set_pragma(conn, "busy_timeout", n)` rejects an integer above
  2_147_483_647** instead of storing 0.
- **`busy_timeout/2` answers the rejection for 2^64 and above instead of
  raising**; `register_progress_hook/3` does for `every_n` above
  4_294_967_295.

- **A keyword list is taken only on a statement of at most 2 048
  parameters.** Above that, every door that takes a keyword list answers
  `{:error, {:too_many_named_parameters, %{count: n, limit: 2048}}}` before a
  value is read; a positional list binds at any count. The names of an
  accepted list resolve through one map built per call, which costs 7.1 ms at
  2 048 parameters on one machine and grows faster than the count. SQLite's
  own prepare of SQL with that many names costs about twice the map, grows
  the same way, and no parameter list avoids it: 14, 193 and 3 023 ms at
  2 048, 8 192 and 32 766 names. Written with bare `?` the same statement
  prepares in 1.0, 4.7 and 20.7 ms, so a statement with thousands of
  parameters is written with `?` and bound with a positional list.
- **A type extension's `decode/1` can refuse a stored value, and a callback
  answer outside the three shapes is refused, not raised.** A `decode/1`
  that claims a value but cannot read it answers `{:error, reason}`, and
  every function that decodes rows answers `{:error,
  {:type_extension_refused, %{column: n, extension: module, reason:
  reason}}}`, `n` being the value's one-based place in its row. `stream/4`
  hands over the rows decoded before it, then answers the error under its
  `:on_error` mode. The query functions decode after the statement ran, so
  its changes stand. An `encode/1` or `decode/1` answering anything but
  `{:ok, value}`, `:skip` or `{:error, reason}` raised `CaseClauseError`; it
  is now the same refusal with `reason: {:bad_return, answer}`.
- **`Xqlite.TypeExtension.decode_value/2` answers `{:ok, decoded}` or
  `{:error, %{extension: module, reason: reason}}`**, as `encode_value/2`
  does, where it answered the bare decoded value: a refusal can no longer be
  mistaken for a value that decoded to an error tuple.
- **`{:value_too_large, _}` is now answered by every door that binds**, where
  the doors going through rusqlite used to answer
  `{:sqlite_failure, 18, 18, "string or blob too big"}` and the raw doors only
  refused values above two gigabytes. The limit in the error is the
  connection's own, which `Xqlite.get_limit/2` reads and
  `Xqlite.put_limit/3` sets.
- **`SQLITE_TOOBIG` is classified as `{:too_big, code, message}`** wherever
  SQLite answers it. It no longer comes from a bind, but it still comes from a
  step: SQLite checks the same limit against the row it builds, a
  concatenation and a column read.
- **`Xqlite.TypeExtension.encode_params/2` and `decode_rows/2` judge their
  extension list.** Both are public and are what the raw-statement docs
  recommend for the rows `step/1` and `multi_step/2` return, and both took
  the list as given: a list that was no proper list of extension modules
  raised from the chain, and a module such as `Jason`, which exports both
  callback names without being an extension, silently rewrote values. Both
  now walk the list the way every door does and answer
  `{:error, {:invalid_type_extensions, refusal}}` for one that fails; and
  `decode_rows/2` answers `{:ok, rows}` where it used to answer the bare
  rows. `encode_value/2` and `decode_value/2` still take the list as given:
  they run once per value, and the caller vouches for it.
- **A module that passed the extension check is asked for its callbacks on
  every call.** The check remembered a module for the life of the node, so
  one recompiled without `encode/1` or `decode/1`, or purged, kept passing
  and every door raised `UndefinedFunctionError`. Both callbacks are checked
  on every call now — a false there runs the whole check again, so a module
  merely unloaded is reloaded and passes — and only the behaviour
  declaration is remembered.
- **`:type_extensions` is judged before anything else runs.** A term that is
  no proper list of module names reached `length/1` or the encode chain and
  raised: `Xqlite.stream(conn, sql, params, type_extensions: [JSON | :x])`
  raised `ArgumentError`, and `query/4`, `execute/4`, `bind/3` and the
  cancellable doors raised `FunctionClauseError`. Every door that takes the
  option now answers `{:error, {:invalid_type_extensions, refusal}}` before
  its telemetry and before the NIF, the refusal naming what stopped the walk
  (`:not_a_list`, `:improper_tail`, or `:bad_element` with the element's
  one-based position) and the kind of term it was. `nil` and an absent option
  both mean no extensions.
- **An element of `:type_extensions` that is no extension module is refused.**
  Any atom used to pass the walk, so
  `type_extensions: [Xqlite.TypeExtension.JSON, :nope]` — a misspelled module
  name, or an empty variable holding `nil` or `false` — ran until the first
  value was encoded and then raised `UndefinedFunctionError`. Every door that
  takes the option now answers
  `{:error, {:invalid_type_extensions, %{reason: :bad_element, position: n,
  value_type: :atom}}}` before anything runs. An element counts as an
  extension module when three things hold: the atom names a module that can
  be loaded, the module declares `@behaviour Xqlite.TypeExtension`, and it
  exports both `encode/1` and `decode/1`. Two kinds of list that worked
  before now stop. A module that exports `encode/1` and `decode/1` without
  declaring the behaviour: `Jason` and OTP's `:json` both do, and
  `type_extensions: [Jason]` silently stored the integer `1` as the text
  `"1"`. And a module that exports `encode/1` but not `decode/1`, on the four
  doors that never decode — `execute/4`, `explain_analyze/4`, `bind/3` and
  `execute_cancellable/5` — which ran it to completion. A module written to
  the shape the `Xqlite.TypeExtension` moduledoc shows is unaffected. The
  check runs once per module for the life of the node: a module that passed
  is remembered, one that was refused is asked again on the next call.
- **An integer SQLite has no room for answers a structured error.** A number
  past the signed 64-bit range used to answer
  `{:cannot_convert_to_sqlite_value, "9223372036854775808", "{error, badarg}"}`
  — a tag carrying two debug strings, which four different causes shared. The
  tag is gone. A parameter outside the range is now
  `{:error, {:integer_out_of_range, %{position: n}}}`, `n` being the value's
  one-based place in the list; `XqliteNIF.set_pragma/3` judges one value with
  no list around it and answers `{:error, {:integer_out_of_range, %{}}}`. A
  TEXT or BLOB parameter longer than SQLite's C interface can be told about
  answers `{:error, {:value_too_large, %{byte_size: _, limit: _}}}`.
- **A key named twice in a parameter list is refused.** `[a: 1, a: 2]` used to
  bind the second value, where every `Keyword` function reads the first. Two
  keys that name the same parameter — `[{:a, 1}, {:":a", 2}]` included, since
  both name `:a` — are now
  `{:error, {:duplicate_parameter_name, name}}`, with the second key's name as
  it resolved, whatever the values.
- **A refused batch size reports the caller's own term.** The stream fetch
  doors used to tag it — `{:integer, 0}`, `{:float, 1.0}`, `{:atom, :ten}` —
  while the statement doors put the bare number, so
  `{:invalid_batch_size, %{provided: _, minimum: 1}}` had two shapes.
  `provided` is now the term as the caller wrote it on both:
  `XqliteNIF.stream_fetch(s, 1.0)` answers `provided: 1.0`. The stream fetch
  doors are the ones that answer for a wrong type at all, because they take
  the term and judge it; the statement doors take an integer argument, so
  rustler refuses anything else with `ArgumentError` before the function runs
  — that is their protection against a huge batch size.
- **`Xqlite.stream/4` refuses a bad batch size at the call.** `batch_size: 0`
  used to open the stream and raise `Xqlite.StreamError` on the first element
  taken out of it. The option is now judged beside `:on_error` and
  `:cancel_tokens`, so a value that is not a positive integer answers
  `{:error, {:invalid_batch_size, %{provided: value, minimum: 1}}}` from
  `stream/4` itself. `Xqlite.multi_step/2` keeps its integer guard.
- **Six raw-statement helpers in the native crate are `unsafe fn`.** The
  helpers that take a raw `sqlite3_stmt` pointer — the parameter-count check,
  the coverage check, the two binders, the value binder and the stream's
  parameter binding — were ordinary safe functions whose contract lived in a
  comment. Each now carries a `# Safety` section naming it (the caller holds
  the connection Mutex; the pointer is a live prepared statement of that
  connection) and every caller says which lock it holds. No behaviour changes.
- **The panic-strategy check reads a Windows DLL the right way.**
  `scripts/panic_strategy.exs` looked for `_Unwind_RaiseException` with `nm`
  whatever the library was. An MSVC-built `.dll` keeps no symbol table `nm`
  can read and unwinds through Windows exceptions instead, so the check
  reported an abort build on every Windows runner. A `.dll` is now read with
  `objdump -p` (or `llvm-objdump`) and passes when its import table names
  `_CxxThrowException` or `__CxxFrameHandler3`; every other library is read
  with `nm -u` (or `llvm-nm`) as before. Both families look for their tool on
  `PATH` and in the rustup sysroot where `rustup component add llvm-tools`
  puts the LLVM ones, `XQLITE_SYMBOL_TOOL` still names a tool to use instead,
  and a failed verdict now names the tool, the library and every readout line
  mentioning unwinding, so one CI log is enough to tell a wrong marker from a
  real abort build. The release workflow reads the same markers with the
  same two tools.
- **`XqliteNIF.stream_open/4` is `XqliteNIF.stream_open/3`.** The fourth
  argument was reserved for stream options that never arrived, and nothing
  read it — `stream_open(conn, sql, [], :garbage)` opened a stream. It is
  gone, so a raw caller passing four arguments has to drop the last one.
  `Xqlite.stream/4` is unaffected.
- **`{:expected_keyword_tuple, _}` carries the same map as its siblings.** An
  element of a keyword parameter list that is not an `{atom, value}` pair used
  to come back as the Rust debug text of the caller's own element — which put
  the caller's data, a password in a named parameter included, inside an error
  term, and threw away the position the decoder had in hand. It is now
  `%{reason: :bad_element, position: n, value_type: type}`, the map
  `{:expected_list, _}` and `{:expected_keyword_list, _}` already carry, with
  `n` the one-based position of the element and `type` its kind.
- **`{:invalid_cancel_tokens, _}` holds the same map on every door.** The
  Elixir doors used to answer with the caller's own value and the raw NIFs
  with `%{position: n}`. Both now answer
  `%{reason: :bad_element, position: n, value_type: type}` for an element that
  is no live token; the Elixir doors, which take one token or a list of them,
  answer position 1 for a single term that is no token and
  `%{reason: :improper_tail, value_type: type}` for a list whose tail is not
  `[]`. `Xqlite.cancel_operation/1` takes one token and refuses a list, an
  empty one and a list of live tokens included, as the one element it was
  handed. The raw NIFs keep `{:expected_list, _}` for a term that is no list.
- **`XqliteNIF.stmt_bind/2` reads `nil` as no parameters, like its siblings.**
  `query`, `execute`, `query_with_changes`, `explain_analyze` and
  `stream_open` all took a parameter term of `nil` as "no parameters" while
  `stmt_bind` answered `{:expected_list, _}` for it. One rule now, in one
  place: `stmt_bind(stmt, nil)` means zero parameters, so it answers `:ok` on
  a statement that takes none and `{:invalid_parameter_count, _}` on one that
  takes any (see the parameter-count fix above). `Xqlite.bind/2,3` still
  guards `is_list/1`, so `nil` raises at the typed door as before.
- **`Xqlite.Pragma` judges its options.** The options position — the last
  argument of `get/4` and `put/4`, and the third argument of `get/4` when it
  is a keyword list, the two being merged — used to reach `Keyword.get/3`
  unjudged: a term that is no list raised `FunctionClauseError` several calls
  deep, and `[1]`, `[:db_name]` and `[foo: 1]` were silently ignored. Options
  are now a keyword list whose only key is `:db_name`, whose value is a
  string, an atom or `nil`; anything else answers
  `{:error, {:invalid_pragma_argument, %{pragma: name, value: value, reason:
  :invalid_options}}}` before a statement is built, `value` being the whole
  term when it is no keyword list and the `{key, value}` pair that could not
  be read when it is one. The named accessors (`table_info/3` and its
  siblings) reach `get/4` and inherit it.
- **`nil` is not a PRAGMA name.** `Xqlite.get_pragma/2` and
  `Xqlite.set_pragma/3` turned it into the empty string on their way to
  SQLite and answered `{:error, {:invalid_pragma_name, ""}}`, replacing the
  caller's key with a string it never wrote. They now answer
  `{:error, {:invalid_pragma_name, nil}}`. `true` and `false` stay names of
  PRAGMAs SQLite parses and ignores.
- **`Xqlite.Pragma.get_result/0` names `:no_value`.** The atom is what every
  read door answers for a PRAGMA the connection has no row for — `mmap_size`
  on a database that is not a file, and `legacy_file_format` and
  `incremental_vacuum` on any database — and it was hidden inside `atom()`
  with nothing saying when it comes. The type names it, the `get/3,4` doc says
  when it comes, and no write door takes it back.
- **`mix verify`'s panic step checks the library the VM loads, by path.**
  `scripts/panic_strategy.exs` used to glob for libraries and read the newest
  file it found, which could be the crate's own build under
  `native/xqlitenif/target` — a file nothing loads. It now takes the
  libraries to read as arguments and checks each one, and `mix verify` hands
  it `priv/native/xqlitenif.{so,dll}`. It also fails, instead of passing with
  a notice, when no tool that lists symbols is on the machine; name one in
  `XQLITE_SYMBOL_TOOL` to override the search for `nm` and `llvm-nm`.
- **The release workflow fails a target whose library does not unwind.**
  Every build job unpacks the library it produced and, before the upload,
  reads it for the marker `scripts/panic_strategy.exs` reads:
  `_Unwind_RaiseException` among an ELF or Mach-O library's undefined symbols
  (`llvm-nm -u`), `_CxxThrowException` or `__CxxFrameHandler3` in a DLL's
  import table (`llvm-objdump -p`). A missing marker, or a library the job
  cannot find or read, fails the job, so that target ships no asset; the job
  summary names the library, the tool and the marker lines it found.
- **A binary that is not UTF-8 where text was meant is an answer, not a
  raise.** Every argument the native side reads as text — the SQL of the six
  query doors and their cancellable twins, the paths and URIs of the openers,
  savepoint names, table and index names, `get_create_sql/2`'s object name,
  the schema and path of `serialize`, `deserialize`, `load_extension`,
  `backup` and `restore`, `blob_open/6`'s three names, a progress hook's tag
  and a session's table — used to raise `ArgumentError` for a binary holding
  bytes that are no UTF-8, out of functions whose specs promise
  `{:ok, _} | {:error, _}`. They now answer
  `{:error, :invalid_utf8_in_string}`, the neighbour of
  `{:error, :null_byte_in_string}` one byte away. A term that is no binary at
  all still raises, the documented kind for a wrong type on a raw stub. At the
  typed PRAGMA doors a `:db_name` or an argument whose bytes are not UTF-8
  answers `{:error, {:invalid_pragma_argument, %{pragma: name, value: value,
  reason: :invalid_utf8}}}`, and a raw PRAGMA name answers
  `{:error, {:invalid_pragma_name, name}}` with the bytes as they were given.
  `XqliteNIF.set_pragma/3` answers `{:error, :invalid_utf8_in_string}` for
  such a value, where it used to answer
  `{:error, {:cannot_execute_pragma, name, _}}`; `Xqlite.set_pragma/3` keeps
  `{:error, {:invalid_pragma_value, _}}`, a value that PRAGMA cannot take.
- **A raw cancellable NIF says which of its two lists it refused.** A token
  argument that is no list, or a list with a broken tail, answered
  `{:error, {:expected_list, _}}` on the raw NIFs — byte for byte what a bad
  PARAMETER list answers, on `execute_batch_cancellable/3` too, which has no
  parameters. Every refusal of a token argument is now
  `{:error, {:invalid_cancel_tokens, refusal}}` with `:not_a_list`,
  `:improper_tail` or `:bad_element` as the reason, so `{:expected_list, _}`
  on a cancellable call is always about the parameters. The reason still
  differs across the door for a term that is no list: the raw NIF takes a list
  and nothing else and answers `:not_a_list`, while the `Xqlite` function
  reads a bare term as one token and answers `:bad_element` at position 1.
- **`mmap_size` takes the values this build keeps.** Its domain was the shared
  32-bit range, while the bundled SQLite is built with
  `MAX_MMAP_SIZE=0x7fff0000`: it stored the maximum for anything above that
  and 0 for anything negative, and both were accepted as written. The domain
  is now `0..0x7FFF0000`, so a negative size and one past the ceiling answer
  `{:error, {:invalid_pragma_value, %{pragma: :mmap_size, value: value}}}`;
  `0`, which turns memory mapping off, stays legal.
- **A refused parameter list reports its own length on every door.** The
  `provided` number of `{:invalid_parameter_count, %{expected: _, provided:
  _}}` used to differ by door for a list two or more elements too long:
  `Xqlite.query/4`, `Xqlite.execute/4`, `XqliteNIF.query/3`,
  `XqliteNIF.execute/3`, `XqliteNIF.query_with_changes/3` and the cancellable
  twins of all of them (`Xqlite.query_cancellable/5`,
  `Xqlite.execute_cancellable/5`, `Xqlite.query_with_changes_cancellable/5`
  and the `XqliteNIF` stubs behind them) bind through rusqlite, which stops
  at the first index the statement does not have and reports that index, so a
  one-parameter statement handed three values answered `provided: 2` while
  `stream/4`, `bind/3` and `explain_analyze/4` answered `provided: 3`. Those
  doors now count the list before binding anything, so `provided` is the
  list's own length everywhere. The refusal itself, and the `expected`
  number, are unchanged.

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
