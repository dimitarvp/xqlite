# Gotchas and sharp edges

This page is a catalogue of xqlite's *surprising-but-defined* behaviors — the
places where the library (or the SQLite engine underneath it) does something
correct that you might not predict from the API alone. None of these is a bug.
Each is stable, deliberate, and written down here so it never catches you out
mid-debugging: "surprising, but here is exactly what happens and what to do."

It is the DX-focused sibling of the [Security](security.md) guide. That page
owns the *threats* — arbitrary code execution through extensions, the
thread-safety and trust model, SQL injection, panic-freedom. This page owns the
*quirks*: value round-trips that change shape, sort orders that read oddly,
handles that leak if torn down in the wrong order. The two cross-reference each
other; when a sharp edge has a security dimension, this page points you there.

## Types and values

### Non-finite floats read back as sentinel atoms

A `REAL` value that is not a finite number does not come back as a float:

- `+Infinity` reads back as the atom `:positive_infinity`
- `-Infinity` reads back as the atom `:negative_infinity`
- `NaN` reads back as `nil`

```elixir
{:ok, conn} = Xqlite.open_in_memory()

{:ok, %{rows: [[value]]}} = XqliteNIF.query(conn, "SELECT 1e308 * 10", [])
value
#=> :positive_infinity
```

Why atoms, and not floats? A BEAM float is an IEEE 754 double, but the runtime
refuses to *construct* a non-finite one — there is no `+Inf`/`-Inf`/`NaN` term,
and the encoder that would build one rejects the value rather than returning it.
Mapping the non-finite cases onto atoms keeps a read on the ordinary `{:ok, _}`
path instead of turning a legitimate query into a raised exception.

You can only ever hit this on the **read** side. There is no way to *bind* a
non-finite float as a parameter — since the BEAM cannot hold one, one can never
reach the bind path — so `±Infinity` appears only as the result of SQL that
overflows the double range: `1e308 * 10`, the literal `9e999`, a `SUM()` that
runs past the maximum. If a column can produce these, match the two atoms
explicitly before treating the value as a number.

`NaN` is the odd one out, and it connects to the next gotcha: you will not see a
sentinel atom for it, because SQLite converts a `NaN` to `NULL` *before* it ever
reaches xqlite's encoder — so a `NaN` reads back as `nil`, straight from the
NULL.

### NaN is stored as NULL

This one is **SQLite's** behavior, not xqlite's, but it surfaces through xqlite
so it belongs here. SQLite has only five storage classes — NULL, INTEGER, REAL,
TEXT, BLOB — and none of them is `NaN`. When a `NaN` would be written to (or
computed into) a column, SQLite stores `NULL` instead:

```elixir
{:ok, conn} = Xqlite.open_in_memory()
:ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t (x REAL);")
{:ok, _} = XqliteNIF.execute(conn, "INSERT INTO t VALUES (9e999 - 9e999)", [])

{:ok, %{rows: [[type, value]]}} = XqliteNIF.query(conn, "SELECT typeof(x), x FROM t", [])
{type, value}
#=> {"null", nil}
```

So a round-trip through a `REAL` column cannot preserve `NaN`: it comes back
`nil` and `typeof` reports `"null"`. If you need a "not a number" marker that
survives storage, encode it yourself — a sentinel row, a companion boolean
column, or a TEXT tag. See
[SQLite — Datatypes](https://www.sqlite.org/datatype3.html) for the five storage
classes.

### `length()` stops at the first interior NUL

xqlite hands you the *entire* stored TEXT value on read, interior NUL bytes
(`\0`) included — the read paths size every value with `sqlite3_column_bytes`,
so nothing is truncated. SQLite's own `length()` SQL function, however, is
C-string-based: for a text value it counts code points only up to the first NUL.
So `SELECT length(col)` and `byte_size/1` of the value you read back can
disagree:

```elixir
{:ok, conn} = Xqlite.open_in_memory()
:ok = XqliteNIF.execute_batch(conn, "CREATE TABLE t (s TEXT);")
{:ok, _} = XqliteNIF.execute(conn, "INSERT INTO t VALUES (?1)", ["a\0b\0c"])

{:ok, %{rows: [[len, s]]}} = XqliteNIF.query(conn, "SELECT length(s), s FROM t", [])
len            #=> 1   — SQLite counts only up to the first NUL
byte_size(s)   #=> 5   — xqlite returns the whole value
```

This is a SQLite behavior, not an xqlite one, so there is nothing to fix — but
it is worth knowing before you `ORDER BY length(...)`, size-check in SQL, or
trust `length()` as a byte count. (`length()` also counts code points rather
than bytes for multi-byte UTF-8; the interior-NUL rule is the one that surprises
people.) The SQLite docs are explicit: *"For a string value X, the length(X)
function returns the number of Unicode code points (not bytes) in input string X
prior to the first U+0000 character."* See
[SQLite — Core Functions](https://www.sqlite.org/lang_corefunc.html#length).

### Offset-preserving DateTimes sort lexically, not chronologically

`Xqlite.TypeExtension.DateTime` stores a `DateTime` as ISO 8601 TEXT via
`DateTime.to_iso8601/1`, which **preserves the original UTC offset** (`...Z`,
`...+02:00`, and so on). The value round-trips exactly. But when rows carry
*different* offsets, an `ORDER BY` on that column sorts the strings
lexically — and lexical order is not chronological order:

```text
"2024-06-01T23:00:00+00:00"   # 2024-06-01 23:00 UTC
"2024-06-02T00:00:00+02:00"   # 2024-06-01 22:00 UTC — one hour EARLIER
```

`ORDER BY ts ASC` returns the first row before the second, because the date
field `06-01` sorts ahead of `06-02` — yet the second instant is chronologically
*earlier*. Only the sort is affected; reading either value back gives you the
exact `DateTime` you stored.

If you need `ORDER BY` to be chronological, store a sort-stable form:

- **UTC-normalize before storing**, so every value carries the same offset
  (`...Z`). Once all rows share one offset, lexical order *is* chronological.
- **Use `Xqlite.TypeExtension.Instant`**, which stores a `DateTime` as an int64
  nanosecond count since the Unix epoch. Integers sort numerically, which is
  always chronological. (`Instant` is encode-only — it deliberately has no
  decode, because a stored integer is indistinguishable from any other integer,
  so read-side conversion back to a `DateTime` is yours to do.)

## Streaming

### Mid-stream errors surface via `:on_error`

`Xqlite.stream/4` fetches rows lazily, so a failure can land *mid-stream* — an
invalid-UTF-8 TEXT value in row three, the connection lost half-way through.
Because `Stream.resource/3` cannot hand an error back to the consumer as a
return value, xqlite makes you choose how such a failure is surfaced, through
the `:on_error` option. The choice also fixes the stream's **element shape**:

- **`:raise`** (the default) — the happy path yields raw row maps; a mid-fetch
  error raises `Xqlite.StreamError`, whose `:reason` field holds the structured
  error term. A broken read can never masquerade as a completed stream.
- **`:halt`** — the happy path yields raw row maps; a mid-fetch error is logged
  and the stream stops. This mode is **lossy**: the result set is silently
  truncated and the consumer receives no error signal, so `Enum.to_list/1`
  cannot tell a complete run from one that aborted at row three. Reach for it
  only when a partial result is genuinely acceptable.
- **`:emit_error`** — a uniformly tagged stream: every row arrives as
  `{:ok, row}`, and a failure arrives as a single terminal `{:error, reason}`
  before the stream ends.

`:emit_error` is the mode to use when you want to handle failure inside the
pipeline rather than with a `try`:

```elixir
conn
|> Xqlite.stream("SELECT id, name FROM users", [], on_error: :emit_error)
|> Enum.reduce_while([], fn
  {:ok, row}, acc -> {:cont, [row | acc]}
  {:error, reason}, acc -> {:halt, {:error, reason, Enum.reverse(acc)}}
end)
```

An unsupported `:on_error` value returns `{:error, {:invalid_on_error, value}}`
at stream open — before any row is fetched — like any other setup failure.

## Resource lifecycle

### Cancel tokens are single-use

A cancellation token (`Xqlite.create_cancel_token/0`) wraps a flag that is set
**once** and never reset. `Xqlite.cancel_operation/1` flips it to "cancelled,"
and it stays that way for the life of the token — signalling twice is
idempotent, but there is no un-signal. So a token you have already signalled is
*spent*: hand it to another cancellable operation and that operation is
cancelled the moment it starts stepping, before it does any real work.

```elixir
{:ok, token} = Xqlite.create_cancel_token()
:ok = Xqlite.cancel_operation(token)

# Reusing the SAME, already-signalled token cancels the next op at once:
Xqlite.query_cancellable(conn, "SELECT * FROM big_table", [], token)
#=> {:error, :operation_cancelled}
```

The rule is simple: **create a fresh token per cancellable operation.** A token
is cheap; do not cache one and reuse it across calls. (Passing a *list* of
tokens to one cancellable op is a separate, supported feature — OR-semantics
across several live tokens — and unrelated to reuse; each token in the list is
still single-use.)

### Close child handles before the connection

Prepared statements, streams, incremental blobs, and sessions each hold a handle
*into* their connection's SQLite state. Closing the connection while one of them
is still live does not crash and does not corrupt anything — but it **leaks**:

- A live incremental blob keeps an internal statement open, so `Xqlite.close/1`
  cannot free the connection; that connection's `sqlite3` handle stays resident
  until the OS process exits. Prepared statements and streams behave the same
  way.
- A live session leaks the (small) session object, because xqlite will not risk
  tearing it down against a database that has already been freed.

Neither leak grows without bound — it is one leaked object per mis-ordered
teardown, reclaimed when the OS process exits — but in a long-lived system that
churns connections it is a slow drip worth designing out. The fix is ordering:
finalize statements (`Xqlite.finalize/1`), drain or close streams, close blobs
(`XqliteNIF.blob_close/1`), and delete sessions (`XqliteNIF.session_delete/1`)
*before* `Xqlite.close/1`.

This is the DX face of a lifecycle rule the [Security](security.md) guide covers
in full under "Resource lifecycle: close raw handles before the connection" —
see there for the mechanism (why an open blob makes `sqlite3_close` return
`SQLITE_BUSY`, why the session teardown is skipped) and the surrounding trust
model.

## Concurrency and busy handling

### A busy policy's `:max_elapsed_ms` is measured from install, not per event

`Xqlite.set_busy_policy/2` takes two independent give-up ceilings: `:max_retries`
and `:max_elapsed_ms`. They anchor their clocks differently, and the difference
is a footgun:

- **`:max_retries`** counts SQLite's retry count for *the current busy event* —
  it resets to zero every time a fresh contention starts. This is the intuitive
  behavior.
- **`:max_elapsed_ms`** is an *absolute* ceiling measured from **when the busy
  slot was first installed on the connection** — not from when a busy wait
  begins. It never resets for the life of the slot.

The consequence: once a connection has been alive (with a policy installed)
longer than `:max_elapsed_ms`, the elapsed check trips on the *first* callback of
*every* subsequent busy event, so the policy gives up immediately with **zero
retries** — as if no policy were installed at all.

```elixir
# Install a generous-looking policy, then let the connection age past the cap.
:ok = Xqlite.set_busy_policy(conn, max_retries: 1_000, max_elapsed_ms: 400, sleep_ms: 5)
Process.sleep(600)

# A write that hits contention now surrenders instantly (0 retries), even though
# the holder would release well within a 1000×5 ms retry budget:
Xqlite.execute(conn, "INSERT INTO t VALUES (1)", [])
#=> {:error, {:database_busy_or_locked, "database is locked"}}   # gave up in ~0 ms
```

This bites long-lived connections hardest — exactly the pooled, always-open
connections an Ecto-style adapter keeps. With the default `max_elapsed_ms:
5_000`, a policy set at connection open silently stops retrying five seconds
later.

Treat `:max_retries` as the real retry gate: the effective retry budget is
`sleep_ms × max_retries`, and `:max_elapsed_ms` only *lowers* it (never raises
it) once the connection is older than that cap. If you want retries to keep
working on a long-lived connection, set `:max_elapsed_ms` comfortably larger than
the connection's expected lifetime (or very large), and size `:max_retries` /
`:sleep_ms` to bound the per-event wait. To reset the elapsed clock, remove the
policy (`Xqlite.remove_busy_policy/1`, with no observers left on the slot) and
set it again.

### `PRAGMA busy_timeout` silently replaces your busy policy

SQLite has exactly **one** busy-handler slot per connection. xqlite uses it for
both the busy retry policy (`Xqlite.set_busy_policy/2`) and the busy observers
(`Xqlite.register_busy_observer/2`) — both ride that single C callback. Running
`PRAGMA busy_timeout = N`, whether as raw SQL or via
`XqliteNIF.set_pragma(conn, "busy_timeout", ms)`, installs SQLite's *built-in*
sleep-and-retry handler into that same slot, overwriting xqlite's. The effect is
silent: the retry policy stops applying, and every registered observer stops
receiving its `{:xqlite_busy, ...}` messages, with no error and no warning.

Nothing leaks — xqlite reclaims the displaced state on the next slot change or
at connection close — but the behavior change is invisible until you notice the
observers have gone quiet. If you want plain-timeout semantics, switch to them
deliberately with `Xqlite.busy_timeout/2`, which removes the policy first and
keeps xqlite's bookkeeping consistent. Do not interleave a raw
`PRAGMA busy_timeout` with `set_busy_policy/2` on the same connection.

### A busy retry and the WAL autocheckpoint pin the connection

Two by-design operations hold a connection's mutex across a blocking call, so
while they run, *other operations on the same connection wait* (other
connections are never affected):

- A busy retry policy's `:sleep_ms` sleeps on the mutex-holding thread between
  attempts. Budget `sleep_ms × max_retries` as the time the connection can be
  pinned during contention.
- In WAL mode, xqlite's emulated autocheckpoint runs a passive checkpoint — real
  file I/O — inside its WAL hook on the committing thread, with the mutex held.

Neither is a bug; both are simply where SQLite invokes the callback. They are
called out because a long `:sleep_ms` or a large checkpoint can make a *shared*
connection feel stalled to its other callers. The [Security](security.md)
guide's "Thread-safety model" section is the canonical home for this — it
explains the per-connection mutex model that these two cases sit inside.

### Give each process its own connection — sharing one stalls a scheduler

Heavy operations (`query`, `execute`, `stream`, blob read/write, session and
changeset work, `backup`, `serialize`, …) run on the BEAM's *dirty* schedulers,
so they never tie up a normal scheduler no matter how long they take. The cheap
state readers (`changes/1`, `total_changes/1`, `db_path/1`, `autocommit/1`,
`transaction_state/2`, and the like) run on a *normal* scheduler because they are
sub-microsecond in the intended usage.

That intended usage is **one connection per process** — a pool of independent
handles, which is exactly how the Ecto adapter uses xqlite. If you instead
*share a single connection handle across processes*, every call to it is
serialized by that connection's mutex (by design). The sharp edge: if one process
is mid-way through a slow operation on the shared handle, another process calling
even a trivial reader on the same handle **blocks on a normal scheduler for the
slow operation's entire duration** — a multi-second reader call is enough to make
that scheduler unresponsive to unrelated work. Enough of them at once degrades
the whole VM's latency.

The fix is the design: don't share a connection handle between processes for
concurrency. Open one connection per process (or use a pool of independent
handles). If you genuinely must share a handle, treat *every* call on it —
including the cheap readers — as something that can block for as long as the
longest operation currently running on that connection.

## Memory and binaries

### `query` materializes the whole result; `stream` bounds the peak

`Xqlite.query/4` builds the *entire* result set in memory before it returns —
every row, every value, all at once. For a large result that is a large, if
transient, allocation: a 100 000-row result of ~0.5 KB rows is ~50 MB of BEAM
binaries held live until you drop the result. `Xqlite.stream/4` instead fetches
in batches, so if you *consume and discard* rows as they arrive (rather than
`Enum.to_list/1`-ing them back into one list) the peak stays bounded to roughly
one batch, independent of how many rows the query returns — measured at ~68×
smaller peak binary memory for a 100 000-row scan. The rule of thumb is the
usual one, now with a number behind it: **if a result set is large and you don't
need it all at once, stream it and process each batch, don't `query` it.**

There is no memory leak on either path — once you drop the result (or the
consuming process dies), all of it is reclaimed at the next GC.

### BLOB values are backed differently by `query` vs `stream`

A subtlety only worth knowing if you are profiling memory for a blob-heavy
workload. A `BLOB` column value crosses the NIF boundary two different ways:

- through `query` / `query_with_changes` / `execute`, a blob is handed back as a
  *reference-counted resource binary* that wraps SQLite's bytes with no extra
  copy — leanest for large blobs;
- through `stream` / prepared `step` / `blob_read`, a blob is *copied* into a
  fresh binary.

They are byte-for-byte identical values; only the backing differs. The practical
consequence is small and never a correctness issue: reading *many small* blobs
via `query` costs modestly more memory than streaming them (roughly 1.5–3× in
measurements), because every blob — however tiny — becomes an off-heap
reference-counted binary with per-object overhead, whereas the streamed copy of a
≤64-byte blob can live cheaply on the process heap. For a handful of blobs, or
for large blobs, the difference is negligible.

## Deployment and releases

### Hot code upgrades are not supported — restart the node

xqlite is a NIF library, and its native code **cannot be hot-upgraded in place.**
A release that ships a new version of xqlite (or of any library that embeds it)
must **restart the BEAM** to pick it up — a full node restart, not a live
`relup`/`appup` code swap. This is the norm for NIF-heavy deployments, but it is
worth stating plainly because the failure mode is silent-to-the-uninitiated: an
in-place upgrade of the xqlite module simply *does not take*.

Here is exactly what the VM does if you try. Attempting to reload the NIF module
while it is already loaded is **refused, cleanly**:

```elixir
:code.load_file(XqliteNIF)
#=> {:error, :on_load_failure}

# and the VM logs, from the module's on_load:
#   The on_load function for module Elixir.XqliteNIF returned:
#   {:error, {:upgrade, ~c"Upgrade not supported by this NIF library."}}
```

The reason is structural. The BEAM will not load a new NIF library into a module
that already has old code with a loaded NIF library *unless the library provides
an `upgrade` callback* — and the Rustler version xqlite builds against generates a
NIF entry whose `upgrade` (and `reload`, and `unload`) callback is absent (NULL).
So the second load is rejected before it can take effect. There is no back door:
calling `:erlang.load_nif/2` directly from another module is refused too
(`{:error, {:bad_lib, ...}}`) — the only load path is the module's own `on_load`,
which is exactly the path that fails.

The important half is that **it fails safe.** The rejected reload leaves the old
code — and its loaded NIF — running untouched; it does not crash the VM and it
does not corrupt anything. Any connections, prepared statements, streams, blobs,
and sessions you were already holding **keep working normally** across the failed
attempt. Worst case, an accidental hot-upgrade attempt makes your deploy fail
loudly (`{:error, :on_load_failure}`) and you restart the node — you never end up
with two native library instances fighting over the same handles, and you never
lose data to a half-applied swap.

Practical guidance:

- **Deploy xqlite upgrades with a node restart.** Rolling restarts across a
  cluster are fine; in-place BEAM code upgrades are not.
- **Libraries and adapters that wrap xqlite must not assume upgrade-in-place.**
  Treat a new xqlite version as requiring a fresh VM, and document that for your
  own users.
- If your release tooling runs `relup`s, exclude xqlite (and anything statically
  linking it) from the in-place-upgrade set; let it ride the restart instead.
