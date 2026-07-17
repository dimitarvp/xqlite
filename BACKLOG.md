# Backlog — xqlite (review program)

Confirmed-but-not-blocking items + tracked S3s. Severity per the
ratified bar in `REVIEW_AXES.md`. Nothing here is ever silently
dropped; S3s get a committed closer-look pass after the S0–S2
burn-down.

## Open

- [S3] `cargo test` runs only in the Linux lint job — Rust unit
  tests never execute on macOS/Windows. Add lanes or justify.
  (wave-1 recon)
- [S3] Elixir floor: mix.exs claims `~> 1.15`, CI floor is 1.17.
  Add 1.15/1.16 lanes or raise the floor — floor-raise is a Dimi
  values call. Mirrors an identical gap in xqlite_ecto3. (wave-1)
- [probe] Docs-build telemetry-flag state: confirm what config
  hexdocs was built under for 0.9.0 (macro docs were flag-dependent
  until `51d1a17`; fix ships with the next release). (wave-1)
- [probe] Bundled-SQLite-in-artifact check: strings/symbol scan of
  each precompiled tarball proving SQLite 3.53.2 is statically in
  (feature-unification failure class). Cheap mechanical gate before
  the announcement. (wave-1)
- [S3] FTS5 guide is linear-executable — wire it up as an executed
  test so the guide can't rot. (A11 seed)

## Closed

- 2026-07-17 CLAUDE.md drift cluster (intro versions, structure map,
  current state, Hex-2.5 2FA gotcha) → `51d1a17`.
- 2026-07-17 hexdocs grouping + flag-stable telemetry macro docs →
  `51d1a17`.
- 2026-07-17 statement_cancel_test opener-loop rationale comment →
  `51d1a17`.
- 2026-07-17 CI pin alignment (checkout@v6, windows-2022 in
  release.yml) → `51d1a17`.
- 2026-07-17 erl_crash.dump: autopsied, dev-noise, gitignored stays.
