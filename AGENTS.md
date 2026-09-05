# xqlite

A low-level Elixir library over SQLite. `lib/` is Elixir;
`native/xqlitenif/` is a Rust crate Rustler compiles into a NIF library;
SQLite itself comes bundled through rusqlite, never from the system. The
sibling repository `xqlite_ecto3` is the Ecto adapter on top: each
release pins one xqlite minor series at patch level (`~> X.Y.0`); xqlite
is pre-1.0, so its minor carries the breaking changes. Versions live in
`mix.exs` and `Cargo.toml`, the shipped binaries in `release.yml`.

## Build and test

```bash
mix verify     # the whole gate; run it before every commit
mix test.seq   # the whole suite, one OS process per test file
mix format     # Quokka-enforced: rewrites style, not only layout
```

`mix verify` (`lib/mix/tasks/verify.ex`) stops at the first failure and
runs Elixir and Rust formatting, a warnings-as-errors compile,
`mix deps.audit`, sobelow, clippy, `cargo test`, dialyzer, `mix test.seq`
and the verify stamp; its cargo steps run from `native/xqlitenif`, where
cargo finds `.cargo/config.toml`.

**Verify, then commit, with nothing in between.** The stamp step writes
`_build/verify.stamp`, a fingerprint over every file git tracks or does
not ignore (`scripts/tree_fingerprint.exs`), and `git commit` is denied
unless the tree still matches it: any edit afterwards, Markdown included,
means verifying again. Verify is slow, so run it in a background shell
writing its exit code to a file; the committing script's first statement
is `[ "$(cat "$EXIT")" = 0 ] || exit 1`. Never pipe a gate through `tail`
or `rg` — a pipeline reports only the last exit code, hiding a failure.

Run tests only as `mix test.seq`: no arguments, the whole suite, output
to a file. Every compiler warning is an error — `mix.exs` sets
`elixirc_options: [warnings_as_errors: true]` for `lib/` and a `test`
alias adding `--warnings-as-errors`, inherited by each child run; the
compiler always wins. `async: false` is banned (a test touching global
state survives concurrent access instead) and no test is skipped on a
supported platform. NIF tests go inside the compile-time `for` over
`connection_openers()` in `test/support/`.

## Property tests: laws, not pins

Every invariant gets a StreamData property, not a handful of examples:
text forms and encodings, name derivations, parsers, affinity and type
rules, error-shape unions, schedules, value-preserving rewrites. An
example asserts one input, a law asserts the rule over a whole generated
domain. `max_runs` is at least 2000, and a property runs in seconds — if
it takes minutes, shrink the domain, never the meaning. Cap size-driven
generators with `StreamData.scale/2`: `float/0` costs time quadratic in
the size parameter and size grows by one per run, so an uncapped one
spends its budget inside the generator.

Build hostile domains on purpose — NUL bytes, invalid UTF-8, quotes,
empty and oversized values, boundary integers — and use SQLite itself as
the oracle where a round trip can be compared. Keep one example test
beside each law as the anchor that fails first; golden SQL strings
accompany a law, never replace it. No environment-specific assertions:
wide timing windows, structured shapes over POSIX atoms, a reason on any
exclusion.

## Elixir rules

- `XqliteNIF` holds raw NIF stub declarations only, every body `err()`;
  helpers, defaults and wrappers live in `Xqlite`. A stub's name equals
  the Rust function's; a convenience wrapper is its own `Xqlite` function.
- No early returns: `case`, `with`, pattern matching, and a `with`
  clause's right-hand side stays simple — extract anything complex.
- `:ok` / `:error` tuples only: no raise, throw or rescue, and no
  implicit crash either — an anonymous function that destructures
  (`fn {k, v} -> ... end`) needs a fallthrough clause.
- Never `elem/1` — pattern-match. Never `String.to_existing_atom` with a
  rescue — use a compile-time map. Never `f(g(a), b)` — pipe, in chains
  of two or more steps (`f(a, b)`, not `a |> f(b)`); long chains stay.
- Short functions, low branching, split aggressively; and the smallest
  diff that does the job — do not touch code you were not asked to.
- Never assert on error message text, only on structured atoms and
  fields; nothing structured to match on means the error struct needs
  fixing. Parameter dispatch (keyword list versus positional) mirrors
  `native/xqlitenif/src/util.rs:is_keyword`, never re-checked in Elixir.

## Structured errors

Every error carries the most specific structured information available: a
tagged tuple or a struct with typed fields, never a bare `:error`, never
details swallowed into a generic wrapper. Out-of-range or invalid input
from Elixir is rejected with a structured error, never clamped or
silently defaulted.

Classification never parses message text. Two exceptions: the
constraint-message parser `native/xqlitenif/src/constraint_parse.rs`, and
four name-prefix arms in `error.rs:classify_sqlite_error` (`no such
table`, `no such index`, `table … already exists`, `index … already
exists`). Both are listed in the error-text exceptions index (see
Pointers), updated whenever an arm is added or removed.

## Rust rules

- Every `#[rustler::nif]` function lives in `nif.rs`; resource structs
  and per-topic logic live in their own module. Reach atoms through the
  `atoms::` prefix, never imported locally; `#[inline]` on per-row helpers.
- **Every `sqlite3_*` C call holds the connection `Mutex` for its whole
  duration.** An `AtomicPtr` swap gives ownership of the pointer, not
  access to the connection: another thread can be inside `sqlite3_step`
  on it, a data race that crashes the VM. `nif.rs:stream_fetch` keeps its
  lock across the whole batch loop.
- Crashless Rust: no `unwrap`, `expect`, `panic!`, out-of-bounds
  indexing, or `unwrap_or*` on a caller's number — return a structured
  error. The crate has none today; a new one is justified in review.
- Every `unsafe` block carries a `// SAFETY:` comment stating what makes
  it sound (`lib.rs` warns on undocumented ones), and `clippy.toml` sets
  `check-private-items = true`: a private `unsafe fn` needs `# Safety`.
- Never add `sqlite3_interrupt`: cancellation runs through the progress
  handler, so it is per operation and needs no connection handle.
- Keep the bundled SQLite, never a system library: libsqlite3-sys's
  bundled build always passes `-DSQLITE_ENABLE_API_ARMOR`, turning C-API
  misuse into `SQLITE_MISUSE` instead of a crash beneath our raw
  pointers, and a system build may lack it. Never add a flag disabling
  it; `.cargo/config.toml` adds one flag, `SQLITE_ENABLE_STMT_SCANSTATUS`.
- The Rust `Mutex<Connection>` and rusqlite's `SQLITE_OPEN_NO_MUTEX` are
  complementary: `Connection` is `!Sync` so the Mutex is required anyway,
  and dropping SQLite's own mutex is safe because it serializes calls.

## Comments, commits, pull requests

A code comment survives only if it explains what the code cannot: a
non-obvious why, or cryptic mechanics. Never name a backlog item, task
id, run number or severity grade in one; a bare commit hash is fine.
Generous `@doc` and `@moduledoc` are good, inline comments are on thin
ice, and the comment count trends down — measure it with `tokei`.

Commits: 50-character subject, body wrapped at 72, lowercase except
identifiers like `SQLite` or `NIF`; what changed and sometimes why, never
how; no trailers. Pull requests: a short lowercase title and a checklist
of `- [x] did a thing`, nothing else — the reader is a dev skimming.

## Gotchas while coding

- **One OS process per test file.** The bundled SQLite is one statically
  linked copy per loaded NIF library, so parallel test processes contend
  on its process-global C structures even with separate databases and
  report a spurious "out of memory" — exhaustion, not corruption, since
  the build is thread-safe. `mix test.seq` gives each file its own process.
- **Mask the extended code.** rusqlite's `ErrorCode::DatabaseBusy` is 3
  while C's `SQLITE_BUSY` is 5, so `error.rs` compares
  `extended_code & 0xFF` against SQLite's C constants.
- **`sqlite3_changes()` is sticky**: SELECT, DDL and PRAGMA leave it
  alone, so use `query_with_changes`, which reads it in the same Mutex
  hold and reports it only when `sqlite3_total_changes()` moved.
- **Zero-arity NIFs.** Rustler generates no Elixir wrapper for a Rust
  default argument, so `Xqlite.open_in_memory/0` is written by hand as
  `open_in_memory(opts \\ [])`; `XqliteNIF` declares zero-arity stubs
  only for Rust functions that really take none — `open_temporary/0`,
  `create_cancel_token/0`, `sqlite_version/0`.
- **Cancellation** is checked every 8 SQLite VM operations
  (`PROGRESS_NUM_OPS` in `progress_dispatch.rs`); quote it from there only.
- **rusqlite upgrades break `error.rs` first**, its error enum being the
  recurring breakage point; `UPGRADE_PLAYBOOK.md` is the checklist for a
  bundled SQLite, rusqlite or rustler bump.
- **Windows path separators.** `CARGO_HOME` holds backslashes there while
  `Path.join` appends forward slashes, so normalize with
  `String.replace("\\", "/")` before globbing (`test/test_helper.exs`).
- **Local builds are source builds:** the gitignored `.envrc` exports
  `XQLITE_BUILD=true`, so the crate is compiled, never downloaded.

## Project structure

- `lib/xqlite.ex` — the public API: connections, query, execute, stream,
  statements, transactions, PRAGMAs, introspection, busy policy, backup.
- `lib/xqlite/` — `xqlitenif.ex` (raw stubs), `pragma{.ex,_spec.ex}`
  (typed PRAGMAs), `type_extension{.ex,/}` (`encode/1` / `decode/1` and
  its built-ins), `telemetry{.ex,/}` (gated macros, the hook-to-telemetry
  GenServer, OpenTelemetry names), `result.ex`, `explain_analyze.ex`,
  `schema/`, and the two stream modules.
- `lib/mix/tasks/` — `verify.ex` (the gate), `test_seq.ex` (the runner);
  `scripts/` — `release.sh` (version bump), `tree_fingerprint.exs`.
- `native/xqlitenif/src/` — `nif.rs` holds every `#[rustler::nif]`
  function and `lib.rs` the atoms and module list; the rest is one module
  per topic: the resources (`connection.rs`, `statement.rs`, `stream.rs`,
  `blob.rs`, `session.rs`, `cancel.rs`), the hooks and callbacks
  (`hook_util.rs`, the per-hook modules, `progress_dispatch.rs`,
  `busy_handler.rs`, `authorizer.rs`), `error.rs` with
  `constraint_parse.rs`, and `query.rs`, `util.rs`, `schema.rs`,
  `pragma.rs`, `transaction.rs`, `explain_analyze.rs`.

## Pointers

- `ARCHITECTURE.md` — the map of the current code: module by module, the
  data flows, the state machines, the facts several places depend on.
- `RELEASING.md` — the release procedure, CI and precompiled binary
  constraints. `UPGRADE_PLAYBOOK.md` — bumping bundled SQLite, rusqlite
  or rustler. `guides/` — gotchas, security, telemetry wiring, full-text
  search, SpatiaLite.
- The review program's records — ledger, backlog, probe scripts and
  `ERROR_TEXT_EXCEPTIONS.csv`, the index of sanctioned message-text
  parses — live outside this repository in
  `~/kod/xqlite-review-ledgers/xqlite/`; that vocabulary never enters
  code, commits or public docs. `CLAUDE.md` stays a one-line pointer to
  this file and is never edited.
