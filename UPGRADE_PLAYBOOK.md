# Upgrade playbook: bundled SQLite / rusqlite / rustler

The checklist to run when bumping the bundled SQLite version (which
arrives via rusqlite's `bundled` feature), rusqlite itself, or
rustler — plus the follow-up steps in the xqlite_ecto3 adapter repo.
Every step is either a command to run or a claim to re-check; nothing
here is optional on a bump that changes the bundled SQLite version.

## A. In this repo (xqlite)

1. **Bump the crate deps** in `native/xqlitenif/Cargo.toml`
   (rusqlite, and libsqlite3-sys if pinned). Note which SQLite
   version the new rusqlite bundles — the release notes of
   rusqlite/libsqlite3-sys say it.
2. **Expect `error.rs` to break first.** rusqlite's error enum is the
   historical breakage point (e.g. `Error::Utf8Error` gaining a
   field, `From<ValueRef>` becoming `TryFrom`). Fix the
   `From<RusqliteError>` match; `row.get::<_, Value>()` call sites
   usually survive untouched.
3. **Re-check the compile-option contract.** Tests and docs depend on
   exact build flags; run a connection and read
   `PRAGMA compile_options`, then confirm:
   - `ENABLE_STMT_SCANSTATUS` present (explain_analyze needs it; set
     via the cargo `[env]` section, and cargo must run from the crate
     directory, not via `--manifest-path`).
   - `ENABLE_API_ARMOR` present (the safety net under the raw FFI
     paths — never remove).
   - `THREADSAFE=1` present (the shared-globals contention story in
     CLAUDE.md depends on it).
   - `LIKE_DOESNT_MATCH_BLOBS` ABSENT (the adapter's
     `:like_match_blob` tests pass because LIKE matches blobs; if a
     bump flips this, those tests and their rationale must flip too).
4. **Read the SQLite release notes for the surfaces we pin.** The
   library asserts specific SQLite behaviors; a bump can move them
   legitimately, and the fix is updating our pins knowingly, not
   suppressing failures. The load-bearing surfaces:
   - constraint-violation message grammar (`constraint_parse.rs`
     splits on `", "` and the first `"."`; the adapter re-anchors 10
     parse shapes against it),
   - column-affinity determination rules (the adapter's REAL→NUMERIC
     rewrite mirrors SQLite's rule order),
   - `ALTER TABLE RENAME` reference-rewriting behavior (the
     adapter's rebuild dance and its dependent-object refusals),
   - pragma semantics for everything `Xqlite.Pragma` types,
   - JSON function behavior (json_extract/json_each — the adapter's
     array type and path translation),
   - `sqlite3_changes`/`total_changes` stickiness (the
     `query_with_changes` contract).
5. **`cargo fmt` + `cargo clippy -- -D warnings`** from the crate
   directory.
6. **`mix verify`** — the full local CI gate. The test suite includes
   the property/law suites at ≥2000 runs each (type round-trips,
   session changeset algebra); these are the fuzz layer that catches
   behavioral drift a unit test misses. A red law suite after a bump
   means SQLite behavior moved — investigate before touching the law.
7. **Update the version claims**: README's bundled-SQLite badge and
   prose, CHANGELOG entry naming old → new SQLite and rusqlite
   versions, and any doc line citing the version number.
8. **Release day only** (see CLAUDE.md's Release Checklist for the
   full mechanics): triple version bump, tag, precompiled-NIF
   workflow, `rm -f checksum-*.exs`, `mix clean && mix compile`
   before the checksum download, `mix hex.publish`.

## B. In the adapter repo (xqlite_ecto3), after the xqlite release

1. **Bump the dep** in `mix.exs` (the bound is patch-level,
   `~> 0.X.0` — each adapter release pins one xqlite minor).
2. **Run the full suite in hex mode**: `mix xqlite_ecto3.test.seq`
   with `XQLITE_PATH` UNSET. A path override masks dep breakage —
   never trust a green suite that ran against the local checkout.
3. **Re-anchor the error surface**: the constraint parse shapes (the
   suite's structured-error tests cover them; if the message grammar
   moved in step A4, these go red first) and a byte-compare of
   `constraint_parse.rs`/`error.rs` against the previous release when
   nothing red shows — silence plus an unchanged surface is the
   passing grade, silence plus a changed surface needs a look.
4. **Run the vendored integration census** and compare against the
   recorded anchor (currently 440 passed / 26 excluded, exit 0). Any
   delta means either a behavior moved or an exclusion rationale went
   stale — `ECTO_INTEGRATION_TAGS.md` and `test/test_helper.exs`
   must be re-trued against reality, not patched to green.
5. **Re-check the compile-option-dependent rationales**:
   `:like_match_blob` (step A3's flag), the `:concat`/`:right_join`
   version-feature rows, and the tags-doc header's SQLite version
   string.
6. **Update version claims**: README's SQLite version mentions, the
   tags-doc header, CHANGELOG.

## C. On an ecto/ecto_sql bump (different trigger, same discipline)

1. Re-run the vendored census; expect the counts to move only by
   upstream test additions/removals — account for every delta.
2. Sweep every `{:location, {file, line}}` exclusion tuple against
   the new test lines (each tuple must name the `test` line itself;
   the trace-run census in the B2 probes is the instrument).
3. Re-read each excluded test's body: an upstream rewrite can change
   what an exclusion's rationale claims.
4. The migration-conditional tags (`:bitstring_type`,
   `:duration_type`) cannot be checked by include-runs — drive the
   shared migration directly with the tag lifted (the adapter-owned
   probe pattern in the review ledger, Run 38).
