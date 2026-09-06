# Releasing xqlite

A release publishes two things: the Hex package, and eight precompiled
NIF binaries attached to the GitHub release for the tag. Because
`lib/xqlite/xqlitenif.ex` builds its download URL from the project
version, the tag, `mix.exs` and `native/xqlitenif/Cargo.toml` must all
carry the same version, or users who cannot build from source get a 404.

## Before you start

- Working tree clean, `main` up to date, CI green on the commit you are
  about to tag.
- `mix verify` passes: the full local gate (`lib/mix/tasks/verify.ex`) —
  formatting, a warnings-as-errors compile, dependency audit, sobelow,
  clippy, cargo test, dialyzer, `mix test.seq`, and a tree stamp.
- Read `README.md` top to bottom. The installation snippet, the
  compatibility paragraph naming which xqlite series the adapter pins,
  the OTP and Rust floors, and every feature claim must match reality.
- If this release bumps the bundled SQLite, rusqlite or rustler, work
  through `UPGRADE_PLAYBOOK.md` first; it ends by handing back here.
- `CHANGELOG.md`: rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`
  and add a link line at the bottom beside the existing ones:
  `[X.Y.Z]: https://github.com/dimitarvp/xqlite/releases/tag/vX.Y.Z`

## Version bump

Three places, one commit:

| File                          | What changes                         |
| ----------------------------- | ------------------------------------ |
| `mix.exs`                     | `version:` in `project/0`            |
| `native/xqlitenif/Cargo.toml` | `version` under `[package]`          |
| `mix.exs`                     | `source_ref:` in `docs/0` (`vX.Y.Z`) |

`source_ref` is what every source link in the published docs points at; a
stale one sends readers to the previous release's code. Commit
`native/xqlitenif/Cargo.lock` too if the build rewrites it.

Keep the version a plain string literal on the first `version: "…"` line
of `mix.exs`: the release workflow extracts it with `sed`, and a
`@version` attribute used as `version: @version` matches nothing, which
would name every built binary without a version.

## Tag and push

```bash
git add mix.exs native/xqlitenif/Cargo.toml native/xqlitenif/Cargo.lock
git commit -m "bump version to X.Y.Z"
git tag vX.Y.Z
git push origin main
git push origin vX.Y.Z
```

The tag is `v` plus the exact version: `.github/workflows/release.yml`
triggers on tags matching `v*`, and `lib/xqlite/xqlitenif.ex` builds its
download URL from `v#{@version}`.

## The release workflow

`.github/workflows/release.yml` runs on any `v*` tag push and builds one
binary per matrix entry, all at the NIF version its `nif:` key names
(that file's matrix is the truth if this table falls behind):

| Target                        | Runner         | `cross` |
| ----------------------------- | -------------- | ------- |
| `aarch64-apple-darwin`        | `macos-15`     | no      |
| `x86_64-apple-darwin`         | `macos-15`     | no      |
| `x86_64-unknown-linux-gnu`    | `ubuntu-22.04` | no      |
| `x86_64-pc-windows-msvc`      | `windows-2022` | no      |
| `aarch64-unknown-linux-gnu`   | `ubuntu-22.04` | yes     |
| `aarch64-unknown-linux-musl`  | `ubuntu-22.04` | yes     |
| `x86_64-unknown-linux-musl`   | `ubuntu-22.04` | yes     |
| `riscv64gc-unknown-linux-gnu` | `ubuntu-22.04` | yes     |

Each job reads the version out of `mix.exs`, adds its Rust target, builds
through `philss/rustler-precompiled-action` against `native/xqlitenif`,
and attaches the result to the release with `softprops/action-gh-release`
— the first job there creates it. `fail-fast: false`, so one broken
target does not cancel the rest; jobs cap at 30 minutes, and the `cross`
ones are slow because `cross-version: "from-source"` builds `cross` too.

```bash
gh run list --workflow=release.yml --limit 1   # then gh run watch <id>
gh release view vX.Y.Z
```

All eight assets must be present before you go on — one per target, named
`libxqlitenif-vX.Y.Z-nif-<nif>-<target>.so.tar.gz` (`.dll.tar.gz` on
Windows). A missing one locks that target's users out: re-run its job.

## Checksums

`RustlerPrecompiled` verifies every downloaded binary against
`checksum-Elixir.XqliteNIF.exs`, which is git-ignored and ships inside the
Hex package from the working tree (`package/0` lists `checksum-*.exs`).
Regenerate it after the workflow finishes and before `mix hex.publish` —
deleting it first makes a run that wrote nothing visible, instead of
leaving the old file to be published:

```bash
rm -f checksum-Elixir.XqliteNIF.exs
mix clean && mix compile
mix rustler_precompiled.download XqliteNIF --all --print --no-config
```

- `mix clean && mix compile` is not optional (`mix run -e ':ok'` compiles
  too, where a hook redirects a bare compile). Compiling `XqliteNIF` writes
  a metadata file into the user cache — version, base URL, target list —
  and the download task reads that cache, not your source, so a stale one
  fetches the previous release's binaries. That compile needs no checksum
  file: `.envrc` exports `XQLITE_BUILD=true`, which `force_build:` reads.
- `--no-config` stops the task from running `app.config` first, which
  would compile the project through `use RustlerPrecompiled` — and that
  refuses when no checksum file lists the version being built.
- `--all` is the publishing flag. `--only-local` is for development: the
  task rewrites the file from scratch with exactly what it downloaded, so
  `--only-local` leaves one target in it and breaks installation for the
  other seven.

## Publish to Hex

`mix hex.publish` prints the file list and the docs it will build, and
asks for confirmation. What ships is `package/0` in `mix.exs`, with
`lib/mix/tasks/` excluded so `mix verify` and `mix test.seq` stay out of
dependent projects' task lists. `native/xqlitenif/.cargo` is on that list
and load-bearing: it carries the `LIBSQLITE3_FLAGS` that turn on
`SQLITE_ENABLE_STMT_SCANSTATUS`, without which a user's source build has
no working `explain_analyze`. Account setup bites once per machine:

- Hex 2.5 and newer authenticate through `mix hex.user auth`, an OAuth
  device flow. Without TOTP two-factor on the hex.pm account the token
  comes back silently read-only and the publish fails on permissions.
- A toolchain bump reinstalls hex and orphans the stored credential: a
  machine that could publish yesterday reports having none. Re-run
  `mix hex.user auth`.
- There is no CLI key management any more. The fallback is a key from the
  hex.pm web dashboard, exported as `HEX_API_KEY`.

## After the release

- Write the release body: the workflow creates the release only to hold
  the binaries, with no text in it. Every tag gets a curated body from its
  CHANGELOG section — `gh release edit vX.Y.Z --notes-file notes.md`.
- Check that `https://hexdocs.pm/xqlite` renders; `mix hex.publish`
  uploads the docs in the same step.
- Do not bump the local version to a development string afterwards: the
  repository stays at the released version, and the gitignored `.envrc`
  (`export XQLITE_BUILD=true`) builds the Rust from source locally anyway.
- If the adapter has to follow, section B of `UPGRADE_PLAYBOOK.md` is its
  checklist.

## `scripts/release.sh`

`./scripts/release.sh patch|minor|major` automates the mechanical half of
the bump: it checks its tools and the working tree, runs
`mix version --<type>` (which edits `mix.exs` and commits), checks that
the version moved, runs `cargo set-version` on the crate, checks that
through `cargo metadata`, then stages the Cargo files, amends the commit
and force-moves the `vX.Y.Z` tag onto it. It pushes nothing.

Two prerequisites the repository does not provide: `mix version` comes
from the `mix_version` package, which is not in `mix.exs`, and `cargo
set-version` from `cargo install cargo-edit`. Without them the script
aborts — the second during its pre-flight check, the first midway, after
`mix.exs` is already committed.

It leaves you `source_ref:` in `docs/0` (amend again, then `git tag -f
vX.Y.Z`), the CHANGELOG, and everything from "Tag and push" onward. A
moved tag that was already pushed needs `git push --force`, and one that
already triggered the workflow should not be moved at all — cut the next
patch version instead, since users may already hold binaries named after
the old one. The manual path above is three file edits and a commit.

## CI and release workflows: facts and constraints

**Free runners only** — no `-large`, `-xlarge` or any other paid label.
Where a target has no free runner, cross-compile: `x86_64-apple-darwin`
is built on the ARM64 `macos-15` image after a plain `rustup target add`,
and the Linux cross targets go through `cross`. `release.yml` pins
`cross-version: "from-source"` and sets `use-cross` only on the entries
that need it, because the action otherwise unpacks a prebuilt `cross` on
every runner and macOS `tar` has no `--wildcards`.

**NIF version features.** `native/xqlitenif/Cargo.toml` declares one cargo
feature per supported NIF version (`nif_version_<major>_<minor>`); Rustler
needs the feature named explicitly for a precompiled build, and the action
turns its `nif-version` input into that feature. Three places must agree:
the `nif` matrix in `release.yml`, `nif_versions:` in
`lib/xqlite/xqlitenif.ex`, and `[features]` in `Cargo.toml` — and that
module's `targets:` list must match the target matrix likewise.

**Every CI job stands on its own.** Each job in `ci.yml` checks out, sets
up BEAM, restores its caches and runs `mix deps.get` itself. Do not hand a
later job a ready-made `deps/` or `_build/` instead: `mix deps.get` is
what reconciles `mix.lock` with the tree, and a job that skips it cannot
notice a lockfile that no longer matches. Caches are speed, never state.

**Toolchain components.** `dtolnay/rust-toolchain` installs a minimal
toolchain; any job running `cargo fmt` or `cargo clippy` must ask for them
with `components: rustfmt, clippy`.

**Source builds in CI.** `ci.yml` sets `XQLITE_BUILD: "true"` at workflow
level, flipping `force_build:` in `lib/xqlite/xqlitenif.ex`. Without it CI
would download and test the published binaries for whatever version
`mix.exs` names, not the Rust in the branch.

**Windows.** The suite compiles a small SQLite loadable extension before
it runs (`test/test_helper.exs`, which finds `sqlite3ext.h` in the Cargo
registry). On Windows it shells out to `gcc`, on `PATH` through MinGW;
`cl.exe` is not, so a workflow needing MSVC has to add
`ilammy/msvc-dev-cmd` or run `vcvarsall.bat` first — none does today.
SQLite extensions load through a function-pointer table, so MinGW-built
and MSVC-built ones are interchangeable.

## Reference projects for the precompiled-NIF setup

Three published libraries with the same `rustler_precompiled` shape, worth
reading before changing the workflow: `elixir-explorer/explorer` (large
target list, build variants), `elixir-nx/tokenizers` (smaller setup,
RISC-V through `cross`), and `leandrocp/mdex` (reusable workflows). All
three gate `force_build:` on a `<PROJECT>_BUILD` environment variable, the
pattern `lib/xqlite/xqlitenif.ex` follows with `XQLITE_BUILD`.
