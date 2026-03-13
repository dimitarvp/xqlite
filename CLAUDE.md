# xqlite

Low-level Elixir NIF library for SQLite3 via Rust (rusqlite 0.37 + Rustler 0.37). Bundled SQLite — no native install required.

## Build & Test

```bash
mix deps.get          # fetches Elixir deps + triggers Rust NIF compilation
mix test.seq          # REQUIRED: runs tests sequentially, one file at a time (see Gotchas)
cargo fmt --manifest-path native/xqlitenif/Cargo.toml
cargo clippy --manifest-path native/xqlitenif/Cargo.toml -- -D warnings
mix format
mix dialyzer          # PLT cached in priv/plts/
```

Never use `mix test` directly — always `mix test.seq`.

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

- Thread safety: `Arc<Mutex<Connection>>` per connection handle. Serialized access is intentional — read concurrency belongs in the Ecto adapter layer (pool of independent handles).
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

## Elixir Code Style

- No early returns. Flow control via `case`, `with`, pattern matching.
- `:ok`/`:error` tuples only. No raise/throw.
- `with <- ` right-hand side: no complex expressions. Extract to private functions.
- Never `elem/1` — always pattern-match.
- Never `func1(func2(a), b)` — use pipes. Minimum 2 pipes (never single `a |> f(b)`, write `f(a, b)` instead).
- Long pipe chains are idiomatic — never shorten them.
- Short functions, low cyclomatic complexity. Split aggressively.
- Minimal git diff is paramount. Don't touch code you weren't asked to change.
- No noise comments ("added", "removed", "now uses"). Code is version-controlled.

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

## Current State (March 2026)

- v0.3.1 released on Hex. Elixir `~> 1.15`, OTP 26/27/28.
- Rust edition 2024.
- `rustler_precompiled` is greenfield. Plan: GHA-native runners, NIF 2.17 only, 7 targets (RISC-V dropped — no GHA runner). No Docker/cross.
- CI: `.github/workflows/ci.yml` — format+lint, dialyzer, test matrix (Ubuntu/macOS/Windows × Elixir 1.16–1.19 × OTP 26–28).
- Windows support: best-effort, untested locally, relies on community reports.
