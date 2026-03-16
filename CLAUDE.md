# xqlite

Low-level Elixir NIF library for SQLite3 via Rust (rusqlite 0.38 + Rustler 0.37). Bundled SQLite — no native install required.

## Build & Test

**NON-NEGOTIABLE: Run `mix precommit` before every commit.** This runs all CI checks locally (formatting, compilation warnings, clippy, dialyzer, tests) and stops on the first failure. Never commit without a passing `mix precommit`.

```bash
mix deps.get          # fetches Elixir deps + triggers Rust NIF compilation
mix precommit         # REQUIRED before every commit: all CI checks in one command
mix test.seq          # runs tests sequentially, one file at a time (see Gotchas)
cargo fmt --manifest-path native/xqlitenif/Cargo.toml
cargo clippy --manifest-path native/xqlitenif/Cargo.toml -- -D warnings
mix format
mix compile --warnings-as-errors
mix dialyzer          # PLT cached in priv/plts/
```

Always use `mix test.seq` to run tests — no arguments, always the full suite. It runs everything sequentially (one file per OS process) and takes ~25s. Never use `mix test` directly.
Cache test output in temp files (e.g., `mix test.seq 2>&1 > /tmp/test_output.txt`) to avoid parsing long inline output.

### `async: false` is banned

Never use `async: false` in any test module. Grepping for `async: false` must always yield zero results. All tests must use `async: true`. If a test touches global state (e.g., the log hook), design it to be resilient to concurrent access — don't serialize. The only exception would be empirically proven flaky tests or internal SQLite state corruption, but no such case exists today.

### Test pattern: compile-time `for` over connection openers

NIF tests use a compile-time `for` loop over `connection_openers()` so every test runs against all SQLite connection modes (in-memory, file-backed, etc.). New NIF tests **must** go inside the `for` loop's `describe` block — never as standalone top-level tests with a hardcoded `NIF.open_in_memory()`. The only exception is truly isolated edge cases that test a single narrow behavior unrelated to connection mode.

## Project Structure

- `lib/xqlite.ex` — high-level API (stream, strict mode, FK enforcement)
- `lib/xqlite/xqlitenif.ex` — NIF function declarations (connection, query, execute, pragma, stream, transaction, schema, cancel)
- `lib/xqlite/pragma.ex` — typed PRAGMA schema + getters/setters
- `lib/xqlite/stream_resource_callbacks.ex` — Stream.resource/3 callbacks
- `lib/xqlite/schema/` — struct modules (ColumnInfo, DatabaseInfo, etc.)
- `lib/mix/tasks/test_seq.ex` — sequential test runner task
- `native/xqlitenif/src/` — Rust NIF code:
  - `lib.rs` (atoms, module declarations), `nif.rs` (core NIFs, ~1000 lines),
  - `error.rs` (error classification), `cancel.rs` (progress-handler cancellation),
  - `stream.rs` (AtomicPtr-based streaming), `schema.rs` (PRAGMA introspection), `util.rs` (param conversion, row processing)
- `scripts/release.sh` — semi-manual version bump script (amends commits, force-updates tags)

## Architecture

- Thread safety: `Mutex<Connection>` per connection handle (inside `ResourceArc`, which provides `Arc` semantics). Serialized access is intentional — read concurrency belongs in the Ecto adapter layer (pool of independent handles).
- **CRITICAL — raw handle locking rule:** Every call to a `sqlite3_*` C function — `sqlite3_step`, `sqlite3_finalize`, `sqlite3_column_*`, `sqlite3_bind_*`, `sqlite3_errmsg`, ALL of them — MUST hold the connection `Mutex` for its entire duration. `AtomicPtr` swap gives exclusive *pointer ownership* but NOT exclusive *connection access*. These are two different things. A thread can own a pointer via atomic swap while another thread is mid-`sqlite3_step` on the same connection — that's a data race and a BEAM segfault. We shipped this bug once in `take_and_finalize_atomic_stmt` (called `sqlite3_finalize` without the lock). Never again.
- Streams: `ResourceArc` wraps struct, `AtomicPtr` manages raw `sqlite3_stmt` for lock-free batch iteration. Deliberate unsafe FFI — requires safety audits.
- Cancellation: SQLite progress handler, checked every 8 VM steps (hardcoded, un-tuned). Token is `Arc<AtomicBool>`.
- Error handling: comprehensive Rust→Elixir mapping. Constraint violations get specific atoms. Fallback: `{:sqlite_failure, code, extended_code, message}`.

## Gotchas (hard-won lessons)

1. **SQLite "out of memory" is really VFS contention.** `bundled` feature = statically-linked SQLite = single global VFS/allocator per OS process. Parallel tests corrupt global C state regardless of file isolation. `mix test.seq` enforces OS-level process isolation per test file. This is the permanent solution.
2. **Error code confusion.** `rusqlite::ffi::ErrorCode::DatabaseBusy` enum = 3, but C constant `SQLITE_BUSY` = 5. Error matching in `error.rs` must use `ffi_err.extended_code & 0xFF` against C-level constants.
3. **Rustler zero-arity NIFs.** Rustler doesn't auto-create zero-arity Elixir wrappers for Rust NIFs with default args. Must define explicitly in Elixir (e.g., `open_in_memory/0` calling the 1-arity NIF).
4. **GHA cache split-brain.** Each CI job must: checkout code, download artifacts, run `mix deps.get`. Passing state via artifacts alone breaks lockfile checks.
5. **`dtonlay/rust-toolchain` defaults.** Minimal toolchain — must explicitly request `components: rustfmt, clippy`.
6. **Version string for release tools.** Tools like `versioce` can't parse `@version` module attributes in `mix.exs`. Version must be a string literal in `project/0`.
7. **Triple version bump.** Version must be updated in `mix.exs` (project version), `native/xqlitenif/Cargo.toml`, and `mix.exs` (`source_ref` in `docs/0`) simultaneously. Always commit them together.
8. **No paid GHA runners.** OSS project — never use `-large`, `-xlarge`, or any paid runner labels. Use free-tier runners and cross-compile where needed (e.g., `x86_64-apple-darwin` from ARM64 `macos-15`).
9. **Checksum generation requires `--no-config`.** `mix rustler_precompiled.download XqliteNIF --all --print --no-config` — without `--no-config`, compilation triggers the `use RustlerPrecompiled` macro which fails if the checksum file doesn't exist yet.
10. **Local source builds via `.envrc`.** `.envrc` sets `XQLITE_BUILD=true` so `rustler_precompiled` always compiles from Rust source locally. The `.envrc` is gitignored. Version strings in `mix.exs` and `Cargo.toml` stay at the released version — only bump them on release day (see Release Checklist).
11. **macOS `tar` doesn't support `--wildcards`.** The `philss/rustler-precompiled-action` tries to install `cross` on all runners. Use `cross-version: "from-source"` and omit `use-cross` for non-cross targets to avoid the macOS tar failure.
12. **NIF version features in `Cargo.toml`.** Rustler 0.37 requires explicit cargo features (`nif_version_2_15`/`2_16`/`2_17`) for precompilation. The `rustler-precompiled-action` activates them at build time.
13. **Delete old checksum file before regenerating.** `mix rustler_precompiled.download --all` won't overwrite stale entries from a prior version. Always `rm -f checksum-Elixir.XqliteNIF.exs` first. If `mix hex.publish` still fails with a checksum mismatch, `--only-local` can add just the local platform's entry.
14. **rusqlite upgrade (post-0.38.0).** PR #1819 (fixes our #1817) changes `Error::Utf8Error(err)` → `Error::Utf8Error(col, err)` and replaces `From<ValueRef> for Value` with `TryFrom`. Update the pattern match in `error.rs`; our `row.get::<_, Value>()?` calls need no changes.
15. **Windows paths in Elixir.** `CARGO_HOME` and other env vars on Windows use backslashes. `Path.join` appends with forward slashes, producing mixed-separator paths that `Path.wildcard` cannot match. Always normalize with `String.replace("\\", "/")` before globbing. This bit us in `test_helper.exs`.
16. **C compiler on Windows GHA runners.** `cl.exe` (MSVC) is NOT on PATH — it needs `ilammy/msvc-dev-cmd@v1` or manual `vcvarsall.bat` setup. MinGW `gcc` IS on PATH (gcc 14.2.0 at `C:\mingw64\bin`). Use `gcc -shared` for compiling SQLite extensions on Windows — proven by sqlean project. SQLite extensions use a function-pointer ABI so MinGW vs MSVC is irrelevant.
17. **`mix clean` before checksum download after version bump.** After bumping the version in `mix.exs` and `Cargo.toml`, stale build artifacts retain the old version. `mix rustler_precompiled.download --no-config` reads the version from the compiled beam, not the source. Always run `mix clean && mix compile` before `mix rustler_precompiled.download` on release day.

## Elixir Code Style

- No early returns. Flow control via `case`, `with`, pattern matching.
- `:ok`/`:error` tuples only. No raise/throw. No `rescue`. No implicit crashes either — anonymous function clause patterns (`fn {k, v} -> ...`) MUST have a fallthrough clause or the caller must guarantee the shape. A `MatchError` from a destructuring `fn` is an implicit raise.
- `with <- ` right-hand side: no complex expressions. Extract to private functions.
- Never `elem/1` — always pattern-match. Never `String.to_existing_atom` + `rescue` — use compile-time maps instead.
- Never `func1(func2(a), b)` — use pipes. Minimum 2 pipes (never single `a |> f(b)`, write `f(a, b)` instead).
- Long pipe chains are idiomatic — never shorten them.
- Short functions, low cyclomatic complexity. Split aggressively.
- Minimal git diff is paramount. Don't touch code you weren't asked to change.
- No noise comments ("added", "removed", "now uses"). Code is version-controlled.
- Errors must always carry the most specific, structured information possible. No bare `:error` atoms, no swallowing details into generic wrappers. This is a library — callers need maximum diagnostic information.

## Rust Code Style

- **All `#[rustler::nif]` functions live in `nif.rs`.** Resource structs, helpers, and module-specific logic go in their own modules (e.g., `session.rs`, `stream.rs`, `connection.rs`). Never put NIF functions outside `nif.rs`.
- All Rustler atoms must be referenced via the `atoms::` module prefix (e.g., `atoms::columns()`, `atoms::error()`). Never import atoms into local scope with bare `use crate::{columns, ...}`.
- Every `unsafe` block must have a `// SAFETY:` comment explaining the invariant that makes it safe.
- Use `#[inline]` on hot-path helpers called per-row or per-NIF-invocation.
- Elixir-side parameter dispatch (keyword vs positional) must mirror the Rust NIF's head-check routing in `util.rs`. Do not add redundant O(N) validation in Elixir when Rust already validates structure at the NIF boundary.

## Commit Style

- 50-char subject line, 72-char body wrap.
- All lowercase except technical identifiers (e.g., `SQLite`, `NIF`, `OTP`).
- Explain the *what*, occasionally the *why*. Never the *how* — that's the code's job.
- Never include `Co-Authored-By` or any signature/trailer lines.

## PR Descriptions

- Brief lowercase title summarizing the change.
- Checklist format: `- [x] done a thing` for each item.
- No "tests passing", no internal TODOs, no fluff.
- Audience: tired devs who skim.

## Reference Projects for `rustler_precompiled` Patterns

- **Explorer** (`elixir-explorer/explorer`) — large-scale usage, variants, `macos-15` runners, NIF 2.15.
- **Tokenizers** (`elixir-nx/tokenizers`) — simpler setup, `-dev` suffix for force-build, RISC-V target via `cross`.
- **MDEx** (`leandrocp/mdex`) — similar to Explorer, uses reusable GHA workflows.

All three use `<PROJECT>_BUILD` env var pattern for `force_build:`.

## Release Checklist

1. Audit `README.md` top to bottom. Installation instructions, version numbers, feature claims, and roadmap must reflect reality.
2. Bump version in all three places: `mix.exs` (project version), `Cargo.toml`, `mix.exs` (`source_ref` in `docs/0`).
3. Commit, push, tag `vX.Y.Z`, push tag. Wait for release workflow to finish.
4. `rm -f checksum-Elixir.XqliteNIF.exs` — stale entries from prior versions won't be overwritten.
5. `mix rustler_precompiled.download XqliteNIF --all --print --no-config`
6. `mix hex.publish`
7. No post-release local version bump needed — `.envrc` handles source builds via `XQLITE_BUILD=true`.

## Design Tradeoffs

- **Cancellation over interrupt.** xqlite uses progress-handler cancellation (`Arc<AtomicBool>` checked every 8 VM instructions) instead of `sqlite3_interrupt()`. Interrupt is fire-and-forget, per-connection, and known to let slow operations run to completion before being noticed (reported on ElixirForum and in exqlite issues). Our approach is per-operation, fine-grained, and any process can cancel without needing the conn handle — strictly better for DBConnection/Ecto timeout wiring. Never add `sqlite3_interrupt()`.
- **Our Mutex vs NOMUTEX.** rusqlite defaults to `SQLITE_OPEN_NO_MUTEX` (disables SQLite's internal mutex). Our `Mutex<Connection>` is still required by Rust's type system (`Connection` is `!Sync`). The two are complementary, not redundant: NOMUTEX is safe *because* our Mutex serializes access.
- **API_ARMOR as defense-in-depth.** `ENABLE_API_ARMOR` adds NULL-pointer and invalid-argument checks at every SQLite C API entry point. Our Rust layer (Mutex, Option, AtomicPtr) already guards against most misuse, but API_ARMOR is the safety net beneath our raw FFI paths in `stream.rs` and `util.rs` — where we call `sqlite3_step`, `sqlite3_column_*`, `sqlite3_bind_*`, and `sqlite3_finalize` on raw pointers. Without it, a bug in our unsafe code would segfault; with it, we get `SQLITE_MISUSE`. Negligible performance cost. Never remove it.

## Current State (March 2026)

- v0.5.0 released on Hex. Elixir `~> 1.15`, OTP 26/27/28.
- Rust edition 2024. Rustler 0.37, rusqlite 0.39.
- `rustler_precompiled` done. 8 targets, NIF 2.17, `cross` for Linux ARM/musl/RISC-V.
- GHA release workflow (`.github/workflows/release.yml`) builds precompiled NIFs on tag push (`v*`).
- CI: `.github/workflows/ci.yml` — format+lint, dialyzer, test matrix (Ubuntu/macOS/Windows × Elixir 1.16–1.19 × OTP 26–28). Uses `XQLITE_BUILD=true` to force source compilation.
- Windows support: best-effort, untested locally, relies on community reports.
