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

Always run `mix format` and `cargo fmt --manifest-path native/xqlitenif/Cargo.toml` before committing.
Prefer to cache test results in temporary text files (e.g., `mix test.seq 2>&1 > /tmp/test_output.txt`) and then inspect them, rather than parsing long output inline.
Run targeted tests first (`mix test test/path/to/file.exs`), then run the full suite (`mix test.seq`) only after those pass.
`mix test.seq` is for the full suite only — it does not support subsets or individual files. For individual files use `mix test` with one file at a time.

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
10. **`-dev` suffix auto-enables `force_build`.** During development keep version as `X.Y.Z-dev` — `rustler_precompiled` detects it and compiles from Rust source. No env var or checksum file needed locally.
11. **macOS `tar` doesn't support `--wildcards`.** The `philss/rustler-precompiled-action` tries to install `cross` on all runners. Use `cross-version: "from-source"` and omit `use-cross` for non-cross targets to avoid the macOS tar failure.
12. **NIF version features in `Cargo.toml`.** Rustler 0.37 requires explicit cargo features (`nif_version_2_15`/`2_16`/`2_17`) for precompilation. The `rustler-precompiled-action` activates them at build time.
13. **Delete old checksum file before regenerating.** `mix rustler_precompiled.download --all` won't overwrite stale entries from a prior version. Always `rm -f checksum-Elixir.XqliteNIF.exs` first. If `mix hex.publish` still fails with a checksum mismatch, `--only-local` can add just the local platform's entry.

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

## Rust Code Style

- All Rustler atoms must be referenced via the `atoms::` module prefix (e.g., `atoms::columns()`, `atoms::error()`). Never import atoms into local scope with bare `use crate::{columns, ...}`.
- Every `unsafe` block must have a `// SAFETY:` comment explaining the invariant that makes it safe.
- Use `#[inline]` on hot-path helpers called per-row or per-NIF-invocation.

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
7. Locally bump to `X.Y+1.0-dev` in `mix.exs` and `Cargo.toml` (do NOT commit — local-only so `-dev` suffix triggers source builds).

## Current State (March 2026)

- v0.4.1 released on Hex. Elixir `~> 1.15`, OTP 26/27/28.
- Rust edition 2024. Rustler 0.37, rusqlite 0.37.
- `rustler_precompiled` done. 8 targets, NIF 2.17, `cross` for Linux ARM/musl/RISC-V.
- GHA release workflow (`.github/workflows/release.yml`) builds precompiled NIFs on tag push (`v*`).
- CI: `.github/workflows/ci.yml` — format+lint, dialyzer, test matrix (Ubuntu/macOS/Windows × Elixir 1.16–1.19 × OTP 26–28). Uses `XQLITE_BUILD=true` to force source compilation.
- Windows support: best-effort, untested locally, relies on community reports.
