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
- [S3] M10/M11 (Run 1): `explain_analyze.rs:380-490` (`map_put().unwrap()`
  ×24) and `nif.rs:2057` (`OwnedBinary::new(0).unwrap()`) use `unwrap`
  where the crate's graceful `map_err`/`ok_or_else` convention applies.
  Latent-only; consistency fix.
- [probe] M5 sub-issue (Run 1): `enif_send(NULL,…)` from a NORMAL
  scheduler (session_changeset/patchset path) vs the repo's dirty-only
  note — the busy_handler comment claims "any thread (OTP 26.1+)".
  Reconcile the comments and confirm against an assertion-enabled ERTS.
- [S3] Cancel token single-use footgun (Run 6, A5): the cancel flag is
  a set-once `Arc<AtomicBool>` with no reset path, so a signalled token
  reused on a later op aborts it immediately (`{:error,
  :operation_cancelled}`). Correct + tested behavior
  (`statement_cancel_test.exs:38`), but the user-facing
  `create_cancel_token/0` / `cancel_operation/1` docs (`lib/xqlite.ex`)
  never say "a signalled token is single-use — create a fresh token per
  operation"; only `XqliteNIF.cancel_operation/1` hints it ("the
  cancellation signal remains active for the token", `xqlitenif.ex:1063`).
  Doc-clarity only; no code change. Well-defined, not a crash/wrong-result.
  NOW documented user-facing in `guides/gotchas.md` ("Cancel tokens are
  single-use" — spells out "create a fresh token per cancellable
  operation"); the only residual is repeating the line in the inline
  `lib/xqlite.ex` docstrings.

## Closed

- 2026-07-19 (Run 7, A9) D1 — offset-preserving `DateTime` (ISO 8601
  TEXT) sorting LEXICALLY, not chronologically, under `ORDER BY` across
  mixed UTC offsets: RULED keep-and-document. The behavior is
  intentional (the value round-trips exactly; only the SQL sort reads
  oddly), and the caveat plus the two sort-stable escape hatches
  (UTC-normalized storage, `Instant` int64 ns) are now documented
  user-facing in `guides/gotchas.md`.
- 2026-07-19 (Run 7, A9) D2 — stored NaN silently becomes NULL (SQLite
  has no NaN storage class): RULED document. Now surfaced in
  `guides/gotchas.md` alongside the non-finite-float read policy
  (±Inf → `:positive_infinity`/`:negative_infinity`, NaN → `nil`).
- 2026-07-19 new `guides/gotchas.md` ("Gotchas and sharp edges")
  catalogues the remaining user-facing DX quirks so they are publicly
  documented, not just ledger findings: non-finite float reads,
  NaN→NULL, `length()` interior-NUL truncation, offset-preserving
  `DateTime` sort, streaming `on_error` modes, cancel-token single-use,
  close-children-before-connection leak (defers to the security guide),
  `PRAGMA busy_timeout` callback replacement, and busy-sleep / WAL
  autocheckpoint connection pinning. Wired into `mix.exs` docs extras;
  cross-links `guides/security.md` both ways.
- 2026-07-19 (Run 7, A9) F1: reading a non-finite (±Inf) REAL raised
  `ArgumentError`; the row-value encoders now map ±Inf to the sentinel
  atoms `:positive_infinity`/`:negative_infinity` and NaN to `nil` at
  both float sites (`encode_val` + `sqlite_row_to_elixir_terms`),
  consistent with the `schema.rs` guard → `16ca65d`.
- 2026-07-19 (Run 7, A9) F2: `Xqlite.stream/4` gained an `on_error`
  option — `:raise` (default, raises `Xqlite.StreamError`), `:halt`
  (opt-in lossy), `:emit_error` (tagged `{:ok, row}` / terminal
  `{:error, reason}`); the old silent-truncate default is gone →
  `16ca65d`.
- 2026-07-19 M6 (Run 1): own `catch_unwind` guard on the three raw-FFI
  callbacks (progress/wal/busy) so a future callback panic degrades to a
  safe fallback instead of unwinding into SQLite and killing the VM →
  `7e575f7`.
- 2026-07-19 M7 (Run 1): documented the busy-sleep + wal-checkpoint
  connection-Mutex pinning in `set_busy_policy/2` and the security
  guide's thread-safety section → `7e575f7`.
- 2026-07-17 CLAUDE.md drift cluster (intro versions, structure map,
  current state, Hex-2.5 2FA gotcha) → `51d1a17`.
- 2026-07-17 hexdocs grouping + flag-stable telemetry macro docs →
  `51d1a17`.
- 2026-07-17 statement_cancel_test opener-loop rationale comment →
  `51d1a17`.
- 2026-07-17 CI pin alignment (checkout@v6, windows-2022 in
  release.yml) → `51d1a17`.
- 2026-07-17 erl_crash.dump: autopsied, dev-noise, gitignored stays.
