# batch: decom-feniix

Replace `@fink-andreas/pi-linear-tools` + `@feniix/pi-notion` npm stack with in-repo Linear/Notion extensions using direct HTTP APIs and per-workspace auth (keychain on Mac, env file on Linux/VM). Strategic move — no upstream-bug forcing function. Triple-review synthesis at `.pi-delegate/batch-3/triple-review-synthesis.md` in canonical.

## Standing Directives

- User confirmed: strategic motivation, no specific upstream bug. Frame the ticket bodies accordingly ("strategic move toward in-repo-owned tooling").
- Land in two tickets: Linear first, Notion second. Each ticket is one commit, atomic landing.
- "If you see obvious improvements, add them" — hardening scope as judged: fetch timeout + 429 backoff + 401 cache-invalidation + ambiguous-state-name lookup + secret-file cleanup + node-unit-test for inferWorkspace + positive dexec assertions. Skipped: audit logging.
- Notion property-type sugar: option (b) — strings/numbers/bools/arrays auto-converted; relations/formulas/rollups require literal property objects.
- File tickets POST-landing per AGENTS.md § Persistence layers.
- Worktree: `~/code/personal/dotfiles_worktrees/decom-feniix` on branch `decom-feniix`.

## Verification invariants

Green for this batch =
- `just check` clean (host-side, from worktree)
- `just test` clean (Docker integration suite, must run from canonical)
- Node-level unit test for `inferWorkspace` passes (`node --test pi/agent/extensions/shared/workspace.test.mjs` or whatever shape we land on)
- Manual smoke after install: `pi` in personal cwd → `linear list_teams` returns personal teams; `pi` in volve cwd → returns volve teams. Repeat for `notion search` per workspace.
- New trigger-matrix row covers `pi/agent/extensions/{linear,notion,shared/**}.ts` and `pi/agent/settings.json`.

Known deferred / NOT verified end-to-end: actual Notion property writes to real workspaces. The test suite does not exercise live APIs (same as today).

## Phases

1. **Shared helpers** — `pi/agent/extensions/shared/{workspace,preview}.ts`, with node unit test for `inferWorkspace`. No external behaviour change yet.
2. **Linear** — `pi/agent/extensions/linear.ts` with hardening (timeout, 429, 401 cache evict, ambiguous-state-name error). Single commit also removes `@fink-andreas/pi-linear-tools` from settings.json (explicit packages array), deletes `linear-routing.ts`, edits four skills (linear-issue, prepare-merge, review-pr, AGENTS.md trigger-matrix), adds install.sh cleanup line, adds verify.sh positive assertion, updates manifest.
3. **Notion** — `pi/agent/extensions/notion.ts` with property-type sugar (b), same hardening shape. Single commit also removes `@feniix/pi-notion` package, deletes `notion-routing.ts` + `zsh/pi-notion-routing.zsh`, edits `notion-write` skill (drops `update_content`/`replace_content`/`duplicate_page` with explicit "v1 limitation" subsection), adds install.sh cleanup lines (+ approved `rm` of orphan OAuth json files), updates manifest, updates verify.sh.
4. **Post-landing** — file Ticket A (Linear) and Ticket B (Notion) in Linear with closing SHAs in the landing comments. Append `closed: 2026-05-20` to this ledger.

## Status

- 2026-05-20 phase 1: shared/{workspace,preview}.ts + node unit test committed (7c9bebe).
- 2026-05-20 phase 2: Linear extension landed (d6fc3ff). settings.json drops @fink-andreas/pi-linear-tools, linear-routing.ts removed, skills + verify.sh + AGENTS.md updated.
- 2026-05-20 phase 3: in progress.
