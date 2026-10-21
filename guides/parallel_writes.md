# Parallel writes on the BEAM

This guide is for an application that writes to one SQLite database from
many processes at once. It says what SQLite allows, what waiting for
SQLite's write lock used to cost the VM and what it costs now, which calls
wait and which answer at once, the settings you choose, how to build a
write queue or a batcher yourself if you need one, what was measured, and
what to expect from a sustained heavy write load.

## What SQLite allows

A SQLite database file takes one write transaction at a time, and any
number of readers. A connection that writes takes the file's write lock
first and keeps it until its transaction ends; a connection that asks for
the lock while another holds it gets the answer `SQLITE_BUSY`, "database is
locked".

In WAL mode, xqlite's default, readers never wait for the writer and the
writer never waits for readers: a reader keeps seeing the database as it
was when its read began. In rollback-journal mode (`journal_mode: :delete`
and the other modes that are not WAL), a commit has to wait until every
reader of the file has finished.

Mainline SQLite never runs two write transactions on one file at once,
whatever the library above it does. So parallel writes here means many
processes writing to one file, each on its own connection, with SQLite
deciding who writes next. It does not mean two writes running at the same
instant.

## What a waiting thread costs the VM

Every xqlite call that touches a connection is a native function (a NIF)
that runs on one of the VM's dirty I/O threads: a pool the VM keeps for
native calls that may block, 10 threads by default. The `+SDio` emulator
flag sets the count, for example `elixir --erl "+SDio 32" -S mix run`, or a
`+SDio 32` line in a release's `vm.args`. The VM's own file operations, such
as `File.read/1`, use the same pool, and so does every other library's
dirty I/O NIF.

Up to xqlite 0.15, a call that met a lock slept inside the native call, on
its dirty I/O thread, until the lock freed or the busy timeout ran out. One
waiting call held one thread. Once ten calls waited at once, every other
connection, on any file, and every file read in the node waited for a free
thread too. So did the lock holder's own `COMMIT`, which is a native call
as well, so the waits ran out their budget and answered busy for writes
that would have gone through a moment later; under a long busy policy the
node did not recover. Giving each process its own connection did not help:
ten connections, none shared, each in its own wait, stalled the node the
same way.

This table measured that old way of waiting, with the default 10 threads
and a WAL file. Connection B holds `BEGIN IMMEDIATE` and commits after
200 ms; connection A's insert waits for B's lock under a 4 000 ms busy
timeout; then N more processes call `Xqlite.autocommit(a)`, which waits for
A; at 100 ms an unrelated connection C runs `SELECT count(*)` and the VM
reads a 5-byte file.

| processes waiting on A | C's query | `File.read/1` | B's commit | A's insert |
|---|---|---|---|---|
| 0 | 104 ms | 103 ms | 221 ms | succeeds at 278 ms |
| 8 | 104 ms | 103 ms | 202 ms | succeeds at 252 ms |
| 9 | 4 209 ms | 4 208 ms | 4 208 ms | busy at 4 208 ms; only B's row on disk |
| 12 | 4 221 ms | 4 220 ms | 4 220 ms | busy at 4 220 ms |
| 12, a busy policy with a long budget | — | — | — | the node hung |

## What xqlite does

No wait for a SQLite lock holds a VM thread. Three steps make that so:

1. **SQLite answers at once.** xqlite installs its own busy callback on
   every connection as it opens. When a call meets a lock that waiting
   could clear, SQLite asks that callback whether to wait; the callback
   notes the question and says no, so SQLite answers `SQLITE_BUSY` to the
   call at once. When waiting could not clear the lock, SQLite answers at
   once without asking.
2. **The answer says what the call left behind.** In the same native call
   xqlite decides what can run again, and answers
   `{:error, {:database_busy, %{code: _, message: _, retry: _, retries: _, elapsed_ms: _}}}`.
   `retry` is `:call`, `:transaction` or `:none`; the next section says
   when each comes.
3. **Your process sleeps between attempts.** Every `Xqlite` function that
   runs SQL goes through one loop, `Xqlite.retry_busy/3`. On a
   `retry: :call` answer it asks the connection how long to sleep
   (`XqliteNIF.busy_delay/4`, which applies the busy policy or the busy
   timeout's schedule, tells the busy observers, and checks the call's
   cancel tokens), sleeps in your process, and runs the call again.

A sleeping process holds no VM thread and no connection lock, so any
number of waiting processes leave every other connection, every file
operation and every other process running, and the connection is free for
other calls meanwhile. Outside a transaction the sleeping process holds no
SQLite lock either; inside one it keeps what its transaction already held,
as SQLite's own wait did.

The busy timeout and the busy policy keep their meaning: how long a call
on the connection waits for a lock, and how it spaces its attempts. A raw
`XqliteNIF` call never waits: it answers the busy error at once, with
`retries: 0` and `elapsed_ms: 0`. Wrap it in `Xqlite.retry_busy/3` to wait
the same way:

```elixir
Xqlite.retry_busy(conn, fn -> XqliteNIF.execute(conn, sql, params) end)
```

`retry_busy/3` takes the connection, or a prepared statement or a stream
handle of it, and a `:cancel_tokens` option. The raw functions with no
`Xqlite` counterpart (sessions, changesets, blobs) never wait unless you
wrap them.

### What still holds a thread

- A call waiting for the connection itself while another process's call
  on the same connection runs. It holds a dirty I/O thread until the call
  ahead of it ends, though never for a lock wait any more, since no call
  keeps the connection while it waits for a lock. With the default 10
  threads, nine processes waiting for one connection behind a 1.5 s call
  stalled every other connection and file read in the node for 1.4 s, in 20
  of 20 runs; eight stalled nothing. Give each process its own connection,
  or raise the count with `+SDio`.
- A long statement's own work, which is what dirty I/O threads are for:
  ten long statements at once still fill the default pool.
- One short retry inside SQLite that no busy setting governs, described
  under "Sustained heavy writes" below.

## Which calls wait, and which answer at once

What `retry` says:

- **`:call`**: nothing of the call remains, and running the same call
  again means the same thing. The `Xqlite` functions wait and run it again;
  when the busy settings give up they answer this busy error, with
  `retries` and `elapsed_ms` telling how long the call waited.
- **`:transaction`**: the call ran inside a transaction that SQLite will
  not let wait. Your transaction has already read the database and another
  connection holds the write lock, so waiting could deadlock (the other
  writer may be waiting for your read to end), or, in WAL mode, another
  connection committed after your transaction's read began. Roll the
  transaction back and run it again. Answered at once.
- **`:none`**: running the same call again is no remedy. In
  rollback-journal mode SQLite rolled back a write that had already handed
  back rows, or a commit failed inside a reset, a finalize or a close.
  Answered at once.

| call | waits for the lock | when it does not succeed |
|---|---|---|
| `begin(conn, :immediate)` or `:exclusive` | yes | `retry: :call`; no transaction is open |
| `begin(conn, :deferred)`, `savepoint/2`, `rollback/1`, `rollback_to_savepoint/2` | never meet a lock | — |
| `commit/1`, and `release_savepoint/2` of the outermost savepoint | yes; only rollback-journal mode makes a commit wait, for the readers | `retry: :call` with the transaction still open; in rollback-journal mode it keeps new readers out until you commit again or roll back |
| one statement in autocommit mode: `query/4`, `execute/4`, `explain_analyze/4`, `prepare/2`, the PRAGMA and schema readers, `optimize/1`, `serialize/2`, `enable_strict_table/2` | yes | `retry: :call`; SQLite rolled back whatever the call did |
| a statement inside a transaction, on a database the transaction has not touched yet (the first statement after `begin(conn, :deferred)`, the first use of an attached file) | yes | `retry: :call`; the transaction is as it was |
| a write inside a transaction that has already read that database | no | `retry: :transaction`, at once |
| `execute_batch/3` | yes, statement by statement | the statements before the busy one stay, unless the batch opened its own transaction, which it rolls back; the answer's `sql` holds the text still to run, and `execute_batch/3` resumes there |
| `stream/4` | at its open, and at a fetch before the stream has read a row | the stream stays open, and its next fetch starts the statement over |
| `step/1`, `multi_step/3` on a statement that has handed back no row in its current run | yes | the statement is reset, its bindings kept |
| `step/1`, `multi_step/3` or a stream fetch, after a write handed back rows (rollback-journal mode only) | no | `retry: :none`: SQLite rolled the write back, and the rows already handed back describe nothing |
| `reset/1`, `finalize/1`, closing a stream or a read-write blob of such a write (rollback-journal mode only) | no | `retry: :none` |
| `backup/3`, `backup_with_progress/4`, `restore/3` outside a transaction | yes | `retry: :call`; the next attempt copies again from the start |
| `backup/3`, `backup_with_progress/4` inside your own transaction, meeting a lock on the destination | no: the destination's connection is the backup's own and asks xqlite nothing | `retry: :transaction`, at once |
| `wal_checkpoint/3` with `:full`, `:restart` or `:truncate` | yes: it runs again while it answers `busy: true` | `{:ok, %{busy: true, …}}`, with what it could copy copied |
| `wal_checkpoint/3` with `:passive` | never | the busy error at once |
| `open/2` (its PRAGMAs, a journal-mode change among them) | yes | the busy error |
| any call that meets `SQLITE_LOCKED`, a table lock of the same connection or of a shared cache | never | `{:error, {:database_locked, %{code: _, message: _}}}` |

One busy answer is no lock at all: SQLite refuses a `COMMIT`, a `RELEASE`
or a `SAVEPOINT` while a write of the same connection is still running,
such as an `INSERT … RETURNING` you have stepped but not finished, or a
blob open for writing. xqlite answers that with
`{:error, :statement_mid_run}`, from `commit/1`, `savepoint/2` and
`release_savepoint/2`, and from the same SQL sent through `query/4`,
`execute/4` or `execute_batch/3`. Run the statement to its end, reset or
finalize it, or close the blob, then try again.

## What you choose

### One connection per process that writes

With raw xqlite, open one connection per process that writes, as many as
you need. With the Ecto adapter, the pool is that set of connections, and
callers beyond the pool size wait in DBConnection's queue, each a process,
holding no thread. Sharing one connection between processes runs their
calls one at a time, and every caller waiting for it holds a dirty I/O
thread (see "What still holds a thread" above).

### WAL mode

WAL mode is xqlite's default on purpose: readers never wait for the writer,
the writer never waits for readers, and a commit never meets a reader's
lock. Rollback-journal mode has two caveats, at the end of this section.

### Transactions that write begin with `begin(conn, :immediate)`

`Xqlite.begin(conn, :immediate)` takes the write lock at once, and waits for
it as the busy settings say, so the transaction never meets the
`retry: :transaction` case. A transaction opened with a plain
`Xqlite.begin/2` (deferred) takes the write lock only at its first write;
when it has read before that write and another connection holds the lock,
the write answers `retry: :transaction`. Roll back and run the transaction
again, a bounded number of times, and keep side effects outside the
database out of the work, since it can run twice:

```elixir
def transact(conn, work, attempts \\ 3) do
  with :ok <- Xqlite.begin(conn),
       {:ok, result} <- work.(conn),
       :ok <- Xqlite.commit(conn) do
    {:ok, result}
  else
    {:error, reason} -> roll_back(conn, work, attempts, reason)
  end
end

defp roll_back(conn, work, attempts, reason) do
  # Answers {:error, :no_transaction} when nothing is open, which is fine here.
  _ = Xqlite.rollback(conn)

  case reason do
    {:database_busy, %{retry: :transaction}} when attempts > 1 ->
      transact(conn, work, attempts - 1)

    _other ->
      {:error, reason}
  end
end
```

A `retry: :call` answer that reaches this code means the busy settings
gave up; whether to try again later is your call.

### The busy timeout or a busy policy

The busy timeout (5 000 ms unless you set another with `open/2`'s
`:busy_timeout` or `Xqlite.put_busy_timeout/2`) waits on SQLite's own
schedule: sleeps of 1, 2, 5, 10, 15, 20, 25, 25, 25, 50 and 50 ms, then
100 ms each, cut at the timeout. Under heavy contention that schedule is
unfair: a call that has waited long sleeps 100 ms between attempts while a
newcomer tries again after 1 or 2 ms, so the longest wait grows with the
number of writers. With 32 processes each writing one row per statement,
the slowest write of a run waited 1.6 s; with 32 processes each writing ten
rows per transaction, the slowest transaction waited 3.4 s, up to 4.5 s,
against the 5 s default.

A busy policy (`Xqlite.set_busy_policy/2`) sets the sleep yourself. Its
`:max_retries` and `:max_elapsed_ms` bound the wait of one call, and a
short `:sleep_ms`, 1 to 5 ms, hands the lock over sooner:

```elixir
:ok = Xqlite.set_busy_policy(conn, max_retries: 5_000, max_elapsed_ms: 5_000, sleep_ms: 2)
```

Each attempt costs one native call and no thread. With 32 processes each
writing one row per statement to one WAL file, a policy with `sleep_ms: 2`
kept the slowest write of a run at 0.2 s against 1.6 s under the busy
timeout, for about 14 % fewer writes per second (25 264 against 29 236);
with 10 processes, 0.1 s against 0.9 s, for 6 % fewer.

### Cancel tokens and timeouts

A cancel token ends a wait within one sleep. Before each sleep the
connection checks the call's tokens (`busy_delay/4`), and a call that takes
`:cancel_tokens` checks them again before it runs, so a signal ends the
wait with `{:error, :operation_cancelled}` within one sleep (at most 100 ms
on the busy timeout's schedule, `:sleep_ms` under a policy), and nothing
of the call has run. `query/4`, `execute/4`, `execute_batch/3`,
`multi_step/3`, `stream/4`, `backup_with_progress/4` and `retry_busy/3`
take `:cancel_tokens`.

The wait runs in your process, so the process can also stop it by exiting,
for example when a `Task` it runs in is shut down. Outside a transaction
nothing of the call remains then; inside one, the transaction stays open
on the connection, which owns it, until someone commits or rolls it back.

### Observers and telemetry

`Xqlite.register_busy_observer/2` sends `{:xqlite_busy, retries, elapsed_ms}`
to the observer once per retry of a waiting call, from that call's
`busy_delay/4`: `retries` counts the call's busy answers before this one,
and `elapsed_ms` the time since its first. A raw call that answers busy
without waiting sends nothing. `Xqlite.Telemetry.bridge(conn, hooks: [:busy])`
turns those messages into `[:xqlite, :hook, :busy]` events. The telemetry
span of a call that waited includes the wait in its duration, and a busy
answer it finally gave up with is its error reason.

### Rollback-journal mode

Two caveats, both gone in WAL mode:

- A write in autocommit mode whose commit meets readers is rolled back and
  runs again from the start at each attempt, and gives up the lock that
  keeps new readers out each time, so a steady stream of new readers can
  keep it waiting for its whole busy budget. One writer beside 4 steady
  readers made 21 writes per second, against 1 696 when SQLite's wait inside
  the call kept new readers out, and beside 16 readers 1 against 795 (the
  last two rows of the table under "Measured"). Write inside
  `begin(conn, :immediate)` and `commit/1`: a commit that waits keeps its
  transaction and keeps new readers out until it succeeds. Measured with
  this way of waiting reproduced on the old code, the same writer then kept
  4 000 to 5 900 rows per second with waits under 35 ms.
- A write statement you step yourself, a stream of a `RETURNING` write, and
  a read-write blob commit when they end. If another connection reads the
  file at that moment after rows were handed back, SQLite rolls the write
  back and the call answers `{:error, {:database_busy, %{retry: :none}}}` at
  once. Run such writes inside a transaction, or use WAL mode.

## Building a queue or a batcher yourself

xqlite ships no write queue and no batcher. SQLite already decides who
writes: one write transaction at a time per file, under a lock every
connection respects. A queue inside the library would be a second decider
with rules of its own (first come first served, priorities, timeouts of its
own) that every user would inherit whether it fits their load or not, and
it would order only the writers that go through it. What the library owes
you is a wait for SQLite's lock that costs nothing but the waiting
process's time, is bounded by the busy settings, can be cancelled, and can
be seen.

Build one yourself when your load needs it:

- **Fair turns.** When the busy timeout's unfairness hurts, and a short
  `:sleep_ms` is not enough, run one process per database file that hands a
  write turn to its callers in the order they asked, and monitors the
  caller holding the turn, so a caller that dies gives the turn back.
- **Batching.** When many small writes arrive at once, run one process that
  collects writes for a few milliseconds and runs them in one
  `begin(conn, :immediate)` … `commit/1`. Give each caller's part a
  `savepoint/2`: on an error, `rollback_to_savepoint/2` and then
  `release_savepoint/2` undo that caller's part alone, and the others still
  commit. One transaction of a hundred inserts costs little more than one
  insert.

Both stand on the parts above: the structured busy answer, the busy
settings, cancel tokens and the observers. Either takes a few dozen lines.

## Measured

Writer processes, each on its own connection to one database file, write
100-byte rows for 1.5 s while two other jobs run every 10 ms: a
`SELECT 1` on a connection to another file, and a `File.read/1` of a 5-byte
file. The longest pause between two runs of each job is that job's gap;
with nothing else running it is about 12 ms. "autocommit" is one insert per
statement; "txn10" is `begin(conn, :immediate)`, ten inserts and
`commit/1`; both wait under the 5 000 ms default busy timeout, and
"policy" waits under `set_busy_policy(conn, sleep_ms: 2, max_elapsed_ms: 5_000)`
instead. The rollback-journal rows are one writer beside 4 or 16 reader
processes, each on its own connection running `SELECT count(*)` in a loop.
"Longest wait" is the slowest single writer call of a run, one insert or
one whole transaction. Each run is its own OS process; the old code (its
wait inside the native call) and the new code ran alternately, run by run,
10 runs per row, on one machine on one day. Numbers are medians over the
runs, the worst run in brackets; every other setting is xqlite's default.

Machine: macOS 15.8.1 on an Intel Xeon W-2150B (10 cores, 20 hardware
threads) with 64 GB, Erlang/OTP 29, Elixir 1.20.4, the bundled SQLite
3.53.2, the default 10 dirty I/O threads, and other work on the machine (a
load average of 2 to 8.5 during the runs).

| journal | writers | shape | writes/s before → after | longest wait ms before → after | `SELECT 1` gap ms before → after | `File.read/1` gap ms before → after | busy errors per run before → after |
|---|---|---|---|---|---|---|---|
| wal | 1 | autocommit | 30 960 → 30 896 | 2.3 [2.7] → 2.2 [35.2] | 11.5 [11.9] → 11.5 [12.4] | 11.4 [11.8] → 11.4 [12.4] | 0 → 0 |
| wal | 4 | autocommit | 30 615 → 30 181 | 475 [797] → 643 [1 148] | 11.9 [12.3] → 11.7 [12.8] | 11.6 [12.3] → 11.7 [12.8] | 0 → 0 |
| wal | 9 | autocommit | 30 619 → 28 997 | 923 [1 317] → 946 [1 554] | 11.9 [12.6] → 12.2 [12.8] | 11.9 [12.5] → 12.1 [12.8] | 0 → 0 |
| wal | 10 | autocommit | 28 787 → 30 315 | 794 [1 248] → 947 [1 451] | 12.6 [39.7] → 12.1 [12.6] | 12.4 [39.7] → 12.1 [12.5] | 0 → 0 |
| wal | 11 | autocommit | 25 855 → 29 991 | 890 [1 123] → 997 [1 451] | 13.1 [24.7] → 12.1 [12.6] | 12.6 [24.7] → 12.0 [12.6] | 0 → 0 |
| wal | 16 | autocommit | 25 960 → 29 870 | 1 007 [1 535] → 1 249 [1 653] | 13.0 [41.9] → 11.9 [12.5] | 13.1 [41.9] → 12.0 [12.5] | 0 → 0 |
| wal | 32 | autocommit | 25 495 → 29 236 | 1 045 [1 530] → 1 552 [1 656] | 14.9 [89.8] → 12.1 [14.6] | 14.1 [90.7] → 12.1 [14.8] | 0 → 0 |
| wal | 64 | autocommit | 25 002 → 28 132 | 1 156 [1 415] → 1 654 [2 070] | 19.6 [20.8] → 12.1 [32.9] | 15.3 [16.1] → 12.0 [33.7] | 0 → 0 |
| wal | 10 | txn10 | 74 350 → 78 283 | 1 546 [1 992] → 2 160 [2 361] | 14.9 [15.6] → 12.4 [18.2] | 14.9 [15.4] → 12.4 [18.9] | 0 → 0 |
| wal | 11 | txn10 | 50 → **80 970** | 5 367 [5 402] → 2 362 [2 463] | **5 296** [5 316] → **12.5** [12.8] | 5 295 [5 316] → 12.4 [12.8] | 3 [7] → 0 |
| wal | 32 | txn10 | 60 → 79 290 | 16 040 [16 126] → 3 370 [4 485] | 15 969 [16 081] → 12.5 [16.8] | 15 968 [16 080] → 12.5 [18.1] | 23 [25] → 0 |
| wal | 10 | autocommit, policy | 28 669 → 28 398 | 98.4 [152] → 98.8 [111] | 12.4 [31.1] → 11.5 [11.6] | 12.7 [31.1] → 11.5 [11.7] | 0 → 0 |
| wal | 32 | autocommit, policy | 23 872 → 25 264 | 121 [160] → 201 [249] | 15.5 [16.9] → 11.6 [12.2] | 14.0 [14.4] → 11.9 [14.4] | 0 → 0 |
| delete, 4 readers | 1 | autocommit | 1 696 → **21** | 2.3 [3.0] → 748 [1 250] | 11.7 [12.1] → 12.1 [12.4] | 11.8 [12.2] → 12.1 [12.6] | 0 → 0 |
| delete, 16 readers | 1 | autocommit | 795 → **1** | 3.2 [3.9] → 1 556 [1 560] | 13.4 [13.7] → 11.7 [12.2] | 13.4 [13.7] → 11.6 [12.2] | 0 → 0 |

In words, the row of 11 processes writing in transactions to one WAL
file: before, 50 rows per second, every other connection and file read in
the node paused for 5.3 s, and 3 writes a run (up to 7) answered busy;
after, 80 970 rows per second, pauses of 12.5 ms, and no busy answer.

The stall needs a lock holder that makes another native call while it
holds the lock, such as a transaction's next insert or its `COMMIT`, and
more waiting connections than dirty I/O threads: ten transaction writers
did not stall even before, since the holder still found a free thread.
Writers in autocommit mode on a WAL file never stalled the node: an
autocommit write takes and frees the lock inside one native call, so the
threads turn over every few milliseconds. There the new code keeps the
pauses at their idle size and writes about as many rows per second up to
10 writers and 12 to 16 % more from 11 on, at the price of a longer worst
single wait, which the busy timeout's schedule explains (see "The busy
timeout or a busy policy" above). The last two rows are the
rollback-journal caveat above.

## Sustained heavy writes

SQLite is not a good fit for a sustained heavy write load, and nothing in
xqlite changes that. If you try, this is what to expect and what helps.

SQLite runs one write transaction at a time per database file, whatever
library sits above it. xqlite makes waiting for that turn cheap, a sleeping
process, and visible, through the busy answer, the observers and
telemetry; it cannot make two writes run at once. So the number of writes a
file can take per second is the number one connection can commit, which
the table above shows for one machine. More writer processes do not raise
it: they share it, each waiting its turn. When your sustained write rate
comes near that number, put more rows into each transaction, since one
transaction of a hundred inserts costs little more than one insert, or
spread the data over several database files that are written
independently. Measure your peak against one writer's commit rate before
you depend on it.

A WAL reader that meets a change of the shared WAL index retries inside
SQLite with short sleeps, usually microseconds and under 10 seconds in all;
no xqlite setting governs that retry.
