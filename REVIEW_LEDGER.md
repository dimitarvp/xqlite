# Review ledger — xqlite (append-only)

One entry per fleet run: date, commit, scope, fleet composition,
findings with verdicts + severity + fix commit or backlog ref,
per-axis dryness state. Nothing found is ever silently dropped.

---

## Run 0 — 2026-07-17 — Phase-1 recon (wave 1)

- Commit at scan: `e20707e` (release 0.9.0). Fleet: 4 sonnet
  read-only agents (repo recon ×2, failure-mode mining ×2) +
  orchestrator synthesis. No refuter wave (recon, not findings).
- Raw transcripts + distillates: `~/kod/fleet_review_staging/recon/`.
- Outcomes:
  - erl_crash.dump autopsies (BOTH repos): dev-noise, closed.
    xqlite's (Jul 17) is a boot-time stderr race, xqlitenif absent
    from taints. Re-open only if a dump ever shows xqlitenif tainted.
  - rusqlite UTF-8 panic (the maintainer's upstream find): fixed
    upstream in 0.39.0 (PR#1819); source-verified gone at 0.40.1.
  - **rustler 0.37/0.38 resource destructors/`down`/`dyncall` have
    no catch_unwind** (source-verified) → A1 priority probes seeded
    (Drop census, poisoned-Mutex chain, raw-FFI callback guards).
  - exqlite PR#342 lock-scope audit shape adopted as A2's method.
  - release.sh audited: dirty-tree-gated, no force-push; amend at
    :161, tag -f at :165. Safe with a dirty-tree-on-partial-failure
    wart.
  - Doc drift + docs/CI findings → fixed in `51d1a17` (CLAUDE.md
    sync, hexdocs grouping + flag-stable telemetry docs, CI pins,
    statement_cancel opener comment) or filed in BACKLOG.md.
  - 23 Elixir-ecosystem + 15 Rust/cross-ecosystem failure classes
    harvested → seeded across A1–A14 probes (distillates hold the
    class → axis map).
- Dryness: all axes WET (no adversarial pass has run yet).
