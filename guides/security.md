# Security

This page is xqlite's threat model: what the library guards for you, what
it deliberately leaves in your hands, and the sharp edges worth knowing
before you point untrusted input at a database. It is not a hardening
checklist you tick once — it is a description of where the trust boundary
sits and how xqlite behaves on either side of it.

## The trust boundary

SQLite is an in-process library, not a server. xqlite links it straight
into the BEAM (bundled, statically) and talks to it over a NIF — there is
no socket, no daemon, no listening port of xqlite's own. That removes an
entire class of attack surface: nothing to authenticate to, nothing to
firewall. What replaces it is closer to home. The database *file*, the
*SQL* you hand the engine, and any *extension* you load all run with the
full privileges of your BEAM OS process. Those three inputs are the trust
boundary. The rest of this page is about controlling them.

The upstream project keeps a matching document worth reading alongside
this one: [SQLite — Security](https://www.sqlite.org/security.html).

## Thread-safety model

Every connection handle is a `reference()` backing a `Mutex<Connection>`
on the Rust side (inside a `ResourceArc`, which gives it `Arc` sharing
semantics). The mutex serializes access: a handle may be passed between
BEAM processes freely, and concurrent calls on the same handle take turns
rather than racing. There is no shared mutable SQLite state exposed to
Elixir that the mutex does not cover.

This mutex is not redundant with SQLite's own locking — the two are
complementary. rusqlite opens every connection with
`SQLITE_OPEN_NO_MUTEX`, which disables SQLite's internal per-connection
mutex for speed. That is *safe precisely because* xqlite's
`Mutex<Connection>` is the thing serializing access instead. Removing one
without the other would be a data race. Read concurrency is meant to come
from a pool of independent handles (as the Ecto adapter does), not from
sharing one handle across schedulers.

One rule the mutex cannot enforce for you: **a raw handle must not
outlive the connection it came from.** Prepared statements, streams, and
incremental-blob handles all hold a pointer into their connection's
SQLite state. Closing the connection while one of them is live is a
usage pattern to avoid — not because it will crash (it won't; see the
next section) but because it leaks. Finalize statements, drain or close
streams, close blobs, and delete sessions *before* `Xqlite.close/1`.

## Resource lifecycle: close raw handles before the connection

These are the "hold it wrong" edges. All of them are **safe** — no
crash, no corruption, no undefined behavior — but each leaks a resource
that a small change to your teardown order avoids. Do the first thing,
not the second.

**Close incremental blobs before the connection.** An open blob (from
`XqliteNIF.blob_open/6`) registers an internal statement inside SQLite, so
`sqlite3_close` on a connection with a live blob returns `SQLITE_BUSY` and
SQLite refuses to free the connection. xqlite does not force the issue, so
that connection's `sqlite3` handle stays resident until the OS process
exits. Call `XqliteNIF.blob_close/1` (or let the blob be garbage-collected)
*before* closing the connection, and the handle frees normally. Prepared
statements and streams behave the same way — `Xqlite.close/1` documents
that a connection closed with statements outstanding keeps its handle
alive until the process exits, so `Xqlite.finalize/1` first.

**Delete sessions before the connection.** A session object
(`XqliteNIF.session_new/1`) is torn down under the connection mutex. If
you explicitly close the connection while a session handle is still
referenced, xqlite cannot safely run the session's teardown against a
freed database, so it leaks the (small) session object rather than risk a
use-after-free. Call `XqliteNIF.session_delete/1` before `Xqlite.close/1`.

Neither leak grows without bound during normal use — it is one leaked
object per mis-ordered teardown, reclaimed when the OS process exits. But
in a long-lived system that opens and closes many connections, mis-ordered
teardown is a slow leak worth designing out.

## Loading an extension runs native code in your process

This is the single most consequential capability in the library.

> #### An extension is arbitrary code execution {: .warning}
>
> `Xqlite.load_extension/3` maps a native shared library into your BEAM
> OS process and calls its init function. From that moment the extension
> runs with the full privileges of your application — it can read and
> write any file the process can, open sockets, and corrupt process
> memory. There is no sandbox. **Only load extensions you fully trust**,
> from paths an attacker cannot influence.

Because of that, extension loading is off by default and gated twice: the
SQLite build has the capability compiled in, but it stays disabled until
you explicitly turn it on with `Xqlite.enable_load_extension/2`, and the
recommended pattern is to disable it again immediately after loading:

```elixir
{:ok, conn} = Xqlite.open("app.db")

:ok = Xqlite.enable_load_extension(conn, true)
{:ok, _} = Xqlite.load_extension(conn, "/opt/ext/mod_spatialite")
:ok = Xqlite.enable_load_extension(conn, false)
```

Re-disabling shrinks the window in which a later `load_extension` — yours
or one smuggled in through SQL — can pull in code. Never enable extension
loading on a connection that also runs untrusted SQL. See
[SQLite — Loadable Extensions](https://www.sqlite.org/loadext.html).

## Restricting untrusted SQL: the authorizer

When you must run SQL you did not write — a reporting console, a
user-supplied filter — install a deny-list authorizer. SQLite consults it
while *preparing* every statement, before any row is touched, and xqlite
turns a denied action into a structured `{:error, {:authorization_denied,
message}}`:

```elixir
{:ok, conn} = Xqlite.open_in_memory()

# A read-only console: forbid every mutating and structural action.
:ok =
  Xqlite.set_authorizer(conn, [
    :insert,
    :update,
    :delete,
    :drop_table,
    :alter_table,
    :attach,
    :pragma
  ])

{:error, {:authorization_denied, _}} =
  XqliteNIF.execute(conn, "DELETE FROM audit_log", [])
```

`Xqlite.remove_authorizer/1` clears it. Two limits are worth stating
plainly, because they shape what the authorizer can and cannot promise:

- **Action-kind granularity only.** The decision is made on the action
  *kind* (`:delete`, `:pragma`, `:attach`, …). The table, column, and
  database arguments SQLite passes are ignored, so you cannot yet allow
  `DELETE` on one table while denying it on another.
- **Deny-only.** An action is allowed or denied; SQLite's `IGNORE`
  disposition is not exposed.

One caveat with security relevance: denying `:pragma` also disables
`Xqlite.get_pragma/2`, `Xqlite.set_pragma/3`, and the schema-introspection
helpers, since those run `PRAGMA` statements. Deny it only when you intend
to lock those paths out too. The authorizer restricts *what* untrusted SQL
may do; it is not a substitute for parameterizing *values* — use both. See
[SQLite — Compile-time Authorization](https://www.sqlite.org/c3ref/set_authorizer.html).

## SQL injection: always parameterize

Every query and execute function takes a parameter list. Use it. Never
build SQL by interpolating user input into the statement string —
string interpolation is how a value becomes executable syntax.

```elixir
# WRONG — the value is now part of the SQL grammar.
XqliteNIF.query(conn, "SELECT * FROM users WHERE email = '#{email}'", [])

# RIGHT — the value is bound, never parsed as SQL.
XqliteNIF.query(conn, "SELECT * FROM users WHERE email = ?1", [email])
```

Bound parameters are passed to SQLite out-of-band from the SQL text, so
no contents of `email` — quotes, semicolons, comment markers — can change
what the statement does. This holds everywhere xqlite accepts a parameter
list, including the match term of an FTS5 query and the arguments of an
extension function. Identifiers (table and column *names*) cannot be
parameterized in SQL; when those are dynamic, validate them against an
allow-list you control rather than interpolating raw input.

## Panic-freedom, and where it ends

xqlite's standing guarantee is that a call into the library does not crash
the BEAM. It holds through two layers.

First, every NIF invocation is wrapped so a Rust panic is caught before it
can unwind into C. A panic inside a NIF body — or inside the code that
encodes a return value back to an Elixir term — is turned into a `raise`
of `:nif_panicked` *in the calling process*, which that process can catch
like any other error; the VM stays up. (This is Rustler's documented
behavior, and xqlite relies on it.)

Second, and distinct from panics: xqlite's own *expected* failures are
never raised and never panics. They come back as structured `{:error,
reason}` tuples — `:connection_closed`, `{:utf8_error, column, reason}`,
`{:authorization_denied, message}`, and the rest of the error vocabulary.
A panic means "a bug reached a place it shouldn't"; an `{:error, _}` tuple
means "a thing you asked for could not be done." They are not the same
channel, and you should match on the tuples.

The one place this net does not reach is a **resource destructor** — the
teardown that runs when a connection, statement, stream, blob, or session
handle is garbage-collected. Destructors are invoked by the BEAM's own
memory management, *outside* the per-call panic guard, so a panic there
would unwind into C and take down the VM. That boundary is known and
designed around: every destructor xqlite ships is written to be
panic-proof — teardown runs under the connection mutex, failures are
logged rather than unwrapped, and nothing in the drop path calls an
operation that can panic. It is a guarantee with a named edge, not an
unconditional one.

## Defense in depth: API_ARMOR

xqlite's raw FFI paths — the code in the stream, statement, and blob
resources that calls `sqlite3_step`, `sqlite3_bind_*`, `sqlite3_column_*`,
and `sqlite3_finalize` on raw pointers — are guarded on the Rust side by a
mutex, `Option`, and `AtomicPtr`. Beneath that, the bundled SQLite is
compiled with
[`SQLITE_ENABLE_API_ARMOR`](https://www.sqlite.org/compile.html#enable_api_armor),
which adds NULL-pointer and invalid-argument checks at every SQLite C API
entry point. The effect is a safety net: were a bug ever to reach the C
API with a bad argument, API_ARMOR turns it into a returned
`SQLITE_MISUSE` error instead of undefined behavior. The cost is
negligible and it is always on.

## Data-handling edges

A few smaller behaviors that occasionally surprise, all deliberate:

- **NUL bytes in SQL text are rejected, not truncated.** SQL passed to the
  engine is converted to a C string; a statement string containing an
  interior NUL (`\0`) byte returns `{:error, :null_byte_in_string}` rather
  than being silently cut off at the NUL. Silent truncation is a classic
  way for a crafted value to shorten a statement into something
  unintended; xqlite refuses instead.
- **Invalid UTF-8 in a TEXT column is surfaced, not mangled.** Reading a
  `TEXT` value whose bytes are not valid UTF-8 returns `{:error,
  {:utf8_error, column, reason}}`, naming the column. xqlite does not
  lossily transcode; you learn that the stored bytes are not the text they
  claim to be.
- **Binary parameters dispatch on validity.** An Elixir binary bound as a
  parameter is stored as SQLite `TEXT` when it is valid UTF-8 and as a
  `BLOB` otherwise. Bind explicitly typed values if you need a specific
  column affinity regardless of contents.
- **`:memory:` vs file is a trust and durability choice.** An in-memory
  database (`Xqlite.open_in_memory/1`) has no on-disk footprint and is
  gone when its connection closes — nothing to leak to the filesystem, and
  nothing to persist. A file-backed database is exactly as trustworthy as
  the file: xqlite opens whatever image the path points at, so treat the
  database file itself as an input under your control, and deserialize
  only images you trust (`Xqlite.deserialize/4` replaces a connection's
  contents wholesale with the bytes you hand it).
