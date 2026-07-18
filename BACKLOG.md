# Backlog — xqlite (review program)

Confirmed-but-not-blocking items + tracked S3s. Severity per the
ratified bar in `REVIEW_AXES.md`. Nothing here is ever silently
dropped; S3s get a committed closer-look pass after the S0–S2
burn-down.

## Open

- [S1 — needs Dimi ruling] (Run 7, A9) Reading a non-finite (±Inf)
  REAL raises `ArgumentError "argument error"` on EVERY read path
  (`query`/`stream`/`step`; computed `SELECT 9e999` AND stored). Root:
  rustler `f64::encode` → `enif_make_double` has no finiteness guard
  (`primitive.rs:61`), called at `util.rs:26` (`encode_val`) and in
  `sqlite_row_to_elixir_terms`'s `SQLITE_FLOAT` arm. Not `{:ok|:error}`,
  not a value; conn stays usable (recoverable, no wedge). Inconsistent
  with `schema.rs:302` which DOES guard non-finite. Announcement-blocker
  pending a semantics decision: raise vs `{:error, :non_finite_float}`
  vs sentinel atom vs lossless float. Repro: `bash type_edges/run.sh`
  (F1 pins). Not fixed speculatively (design choice).
- [S1 — needs Dimi ruling] (Run 7, A9) The stream path swallows a
  mid-stream fetch error into `Logger.error` and silently truncates
  the result (`stream_resource_callbacks.ex:89-102` — deliberate per
  its own comment). A 4-row table with invalid-UTF-8 in row 3, streamed
  `batch_size:1`, yields only rows 1-2 with no error to the consumer;
  `query`/`step` return `{:error, {:utf8_error,…}}`. Success-on-failed-
  read / silent truncation, user-undocumented. Decide: propagate (raise
  / terminal error element / `on_error:` opt) vs keep + document. Repro:
  `bash type_edges/run.sh` (F2 pins). Not fixed speculatively.
- [decision-debt — needs Dimi ruling] (Run 7, A9) Offset-preserving
  `DateTime` stored as ISO 8601 TEXT sorts LEXICALLY, not
  chronologically, under `ORDER BY` when rows carry different UTC
  offsets (demonstrated: a `+02:00` row that is chronologically earlier
  sorts AFTER a `Z` row). Value round-trips exactly; only the SQL sort
  is wrong. Keep + document the caveat, or store a sort-stable form
  (UTC-normalized ISO 8601 / `Instant` int64)?
- [S3 doc] (Run 7, A9) Stored NaN silently becomes NULL
  (`INSERT … VALUES(9e999-9e999)` → `typeof`=null). Documented SQLite
  behavior, not surfaced in xqlite's value docs — document alongside the
  F1 Inf policy.
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

## Closed

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
