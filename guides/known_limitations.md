# Known limitations

Every limitation xqlite documents, in one place: what happens, why, and
what to do instead. Where the rule is SQLite's own, the entry says so.
Limitations the [Gotchas](gotchas.md) guide already explains in full are
listed here with a one-line summary and a link.

## A read-only connection can still write

`Xqlite.open_readonly/1` and `Xqlite.open_in_memory_readonly/1` make the
connection's own database read-only. Four paths still write. Until the
library closes them, keep SQL you do not trust away from a read-only
connection's `ATTACH`, `VACUUM INTO` and `PRAGMA` statements with
`Xqlite.set_authorizer(conn, [:attach, :pragma])`. That deny stops some of
the library's own functions too. Denying `:pragma` stops `Xqlite.Pragma`,
`Xqlite.get_busy_timeout/1` and the schema functions that read PRAGMAs, all
but the three reads the [Security](security.md) guide lists:
`Xqlite.Pragma.get(conn, :journal_mode)` and `Xqlite.schema_columns/2`, for
example, answer `{:error, {:authorization_denied, 23, _}}`. Denying
`:attach` stops `Xqlite.deserialize/4` with the same error.

### Through ATTACH

**What happens.** SQL on a read-only connection can attach another
database and write it:

- an `ATTACH` of a shared cache (`cache=shared`) that another connection
  of the same OS process opened read-write joins that connection's copy,
  and writes go into it; for a file, they reach the disk;
- on `Xqlite.open_in_memory_readonly/1`, an `ATTACH` of a file URI with
  `mode=rw` writes that file, and one with `mode=rwc` creates it first.

**Why.** SQLite decides an attached database's access from the `ATTACH`
itself. It compares the URI's `mode=` with the connection's own open flags,
and the flags of the in-memory read-only opener let `rw` and `rwc` through.
A shared cache keeps the access of the connection that opened it first.
xqlite checks only the connection's own database, once, when it opens.

**What to do.** Deny `:attach` with `Xqlite.set_authorizer/2` on a
read-only connection that runs SQL you do not control.

### Through `VACUUM INTO`

**What happens.** `VACUUM INTO` on `Xqlite.open_readonly/1` writes a copy
of the database into a new file. On `Xqlite.open_in_memory_readonly/1` a
plain path stays in memory and creates no file, but a `file:` URI with
`mode=rwc` creates the file, as an `ATTACH` does (above).

**Why.** SQLite writes the copy through an `ATTACH` of its own, and opens
that file for writing even on a read-only connection; the in-memory
opener's memory flag still keeps a plain path in memory.

**What to do.** Deny `:attach` with `Xqlite.set_authorizer/2`. SQLite asks
the authorizer about its own `ATTACH` too, so the statement answers
`{:error, {:authorization_denied, 23, _}}` and writes nothing. Denying
`:pragma` does not stop it.

### Through `PRAGMA query_only = 0` and a journal-mode change

**What happens.** When a read-only open joins a shared cache that another
connection opened read-write, or uses a URI with `mode=memory`, SQLite
reports the database writable, and xqlite keeps the connection read-only
with `PRAGMA query_only = 1`. Two statements get past that: `PRAGMA
query_only = 0`, after which writes succeed, and a `PRAGMA journal_mode`
change, which changes the shared database's journal mode (a WAL file goes
back to a rollback journal). `Xqlite.restore/3` is rejected on such a
connection.

**Why.** `query_only` is a per-connection switch that any SQL on the
connection can turn off, and SQLite checks it only when a statement starts
a write transaction; a journal-mode change starts none.

**What to do.** Deny `:pragma` with `Xqlite.set_authorizer/2` on such a
connection, or give read-only connections a database no read-write
connection shares a cache with.

### Through a `mode=ro` URI on the read-write openers

**What happens.** `Xqlite.open/2` and `XqliteNIF.open/1` hand a `file:` URI
to SQLite as written. A URI with `mode=ro&cache=shared` joins a shared
cache that another connection opened read-write, and writes through it
succeed. The read-only openers set `query_only` in this case; these two do
not.

**Why.** SQLite drops the read-only flag of a connection that joins a
shared cache opened read-write, and `Xqlite.open/2` adds no read-only check
of its own.

**What to do.** Open a read-only connection with `Xqlite.open_readonly/1`,
not with a `mode=ro` URI.

## A rejected second statement can still change a setting

**What happens.** Every function that runs a single statement —
`Xqlite.query/4`, `Xqlite.execute/4`, `Xqlite.prepare/2`, `Xqlite.stream/4`,
`Xqlite.explain_analyze/4` and the `XqliteNIF` functions they call —
rejects a string holding a second statement with
`{:error, :multiple_statements}`, and neither statement runs. A PRAGMA in
the string can take effect all the same:
`"SELECT 1; PRAGMA foreign_keys = OFF"` is rejected and turns foreign-key
enforcement off. On a read-only connection that xqlite keeps read-only
with `query_only` (above), `"SELECT 1; PRAGMA query_only = 0"` is rejected
and the next write succeeds.

**Why.** To tell a second statement from a trailing comment, the library
compiles the text after the first one, and SQLite applies some PRAGMAs
while it compiles them, `foreign_keys` and `query_only` among them, in
either statement. A PRAGMA that acts when its statement runs, such as
`user_version`, does not take effect.

**What to do.** Pass one statement per call, and keep SQL text from an
untrusted source away from these functions. Where you must run SQL you did
not write, deny `:pragma` with `Xqlite.set_authorizer/2`: SQLite asks the
authorizer before it applies a PRAGMA, so the string answers
`{:error, {:authorization_denied, 23, _}}` and changes nothing.

## Backup and restore

- [A backup or restore right after a busy answer does not wait](gotchas.md#a-backup-or-restore-right-after-a-busy-answer-does-not-wait):
  SQLite restarts its busy handler's count only when a statement runs, so
  run one first; on a shared cache, a lock another connection holds is
  answered at once.

## Sessions and changesets

- [An apply turns `defer_foreign_keys` off](gotchas.md#an-apply-turns-defer_foreign_keys-off):
  SQLite's own rule; after an apply that answers a key error in such a
  transaction, the transaction can only roll back.
- [A session capture holds the net change since the attach](gotchas.md#a-session-capture-holds-the-net-change-since-the-attach):
  a capture clears nothing; ship changes with a new session per capture.
- [Delete sessions before the connection](gotchas.md#delete-sessions-before-the-connection):
  a session still referenced when its connection closes leaks one small
  object.

## Values

- [Non-finite floats read back as sentinel atoms](gotchas.md#non-finite-floats-read-back-as-sentinel-atoms):
  the BEAM has no infinite float, so none can be bound either.
- [NaN is stored as NULL](gotchas.md#nan-is-stored-as-null): SQLite's own
  rule.
- [A non-finite `Decimal` is rejected](gotchas.md#a-non-finite-decimal-is-rejected-not-written-as-a-word),
  and so is a number whose plain form needs more than 6178 digits.
- [DateTimes stored with an offset sort lexically](gotchas.md#datetimes-stored-with-an-offset-sort-lexically-not-chronologically):
  store UTC at one precision, or use `Xqlite.TypeExtension.Instant`.
- [A keyword list stops at 2 048 parameters](gotchas.md#a-keyword-list-stops-at-2-048-parameters-write-for-more):
  above that, write `?` and bind a positional list.

## Streams

- [A stream row is a map](gotchas.md#a-stream-row-is-a-map-alias-columns-that-share-a-name):
  give columns that share a name an alias.
- [A stream needs exactly one statement](gotchas.md#a-stream-needs-exactly-one-statement).

## Transactions, cancellation and contention

- [A write cancelled while it runs rolls back the whole transaction](gotchas.md#a-write-cancelled-while-it-runs-rolls-back-the-whole-transaction):
  SQLite's own rule; a `BEGIN` you issued goes with it.
- [Cancel tokens are single-use](gotchas.md#cancel-tokens-are-single-use):
  create a fresh token per operation.
- [A `busy_timeout` write is rejected while the busy slot is held](gotchas.md#a-busy_timeout-write-is-rejected-while-the-busy-slot-is-held):
  use `Xqlite.put_busy_timeout/2`.
- [A shared handle serializes](gotchas.md#give-each-process-its-own-connection-a-shared-handle-serializes):
  open one connection per process.
- [After a blob call answers code 4, close the handle](gotchas.md#after-a-blob-call-answers-code-4-close-the-handle):
  SQLite has ended it; open a new one.

## Deployment

- [Hot code upgrades are not supported](gotchas.md#hot-code-upgrades-are-not-supported-restart-the-node):
  restart the node to load a new xqlite.

## Elsewhere in these docs

- The README's [Known limitations](../README.md#known-limitations): a
  generated column's `default_value`, user-defined functions, and the
  limits SQLite itself sets (one writer per file, no network access, no
  row-level locks, no schemas).
- A raw `PRAGMA wal_autocheckpoint` statement takes the callback that WAL
  subscribers use; set the value with `Xqlite.Pragma.put/3` instead, as the
  README's [Transaction lifecycle hooks](../README.md#transaction-lifecycle-hooks)
  says.
- The authorizer decides on the action kind alone and can only deny: see
  [Restricting untrusted SQL](security.md#restricting-untrusted-sql-the-authorizer)
  in the Security guide.
