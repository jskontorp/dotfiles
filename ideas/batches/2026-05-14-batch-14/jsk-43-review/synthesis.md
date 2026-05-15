# JSK-43 double-review synthesis (batch-15)

## Summary

- **Completed:** 2/2 (task-1 guided 113s, task-2 blind 64s, both exit 0)
- **Reviewed:** `.pi-delegate/jsk-43-proposal.md`
- **Implementation status:** Most reviewer findings already incorporated in the current uncommitted diff + the prep commit `1df230c`. Two residual minor gaps remain.

## Reviewer findings, cross-checked against current state

### Already addressed in the implementation

| # | Finding | Source | Where addressed |
|---|---------|--------|-----------------|
| 1 | `just check` recursion inside tmprepo (Case 2 unreachable) | Guided crit 4 | `test/check-hook-chain.sh` writes a stub `justfile` with `check:\n\t@true` before seeding; comment cites "guided reviewer crit 4" |
| 2 | Exact stderr substrings need pinning | Guided + Blind | `SECRET_GATE_SIG` / `SILENCING_GATE_SIG` constants pinned in test |
| 3 | `commit.gpgsign false` + `user.email`/`user.name` config | Guided | Set in tmprepo seed |
| 4 | Capture rc *and* stderr signature (not just rc) | Guided crit 6 | Each case asserts both |
| 5 | Case 3 disambiguator: keep | Guided + Blind | Kept with rationale comment |
| 6 | Near-miss tests for new allowlist regex (JSK-45 precedent) | Guided crit 3 | Landed in prep commit `1df230c`: `test/check-silencing-gate.sh:118-119` adds `.bak` + `prefix/` near-miss rows |
| 7 | Positive test for new allowlist entry | Blind Q4 | The test file itself contains literal `# noqa` and is committed — committing it IS the positive test; `1df230c` also extended self-exemption tests |
| 8 | Acceptance arithmetic resolved (137 unchanged) | Both | Recorded in `ideas/batches/2026-05-14-batch-14/state.md` |
| 9 | `unset GIT_INDEX_FILE …` idiom | Both | Top of test, with explanatory comment |
| 10 | tmprepo cleanup on interrupt | Blind | `trap 'rm -rf "$TMP"' EXIT` |

### Residual gaps — on-path, both trivial

**A. `core.hooksPath` defense in tmprepo (blind Q5).**

If the user has a global `core.hooksPath` set (the repo's own AGENTS.md flags this as a regression class at `AGENTS.md:63`), `git init` in the tmprepo inherits it and silently bypasses the symlinked `.git/hooks/pre-commit`. The test would pass for the wrong reason (or fail mysteriously).

Fix: one line after `git init`:
```bash
git config --local --unset-all core.hooksPath 2>/dev/null || true
```
(Idempotent; harmless if no global setting exists.)

**B. Trigger-matrix row update for the hook chain (guided crit 7).**

`AGENTS.md` trigger matrix has one row for `git/hooks/pre-commit, git/lib/secret-gate.sh, …` but no mention of the chained interaction now covered by `check-hook-chain.sh`. There is also no row for `git/hooks/commit-msg` / silencing-gate.

Lightest fix: append to the existing secret-gate row's Notes column: "`test/check-hook-chain.sh` covers the secret-gate × silencing-gate interaction (JSK-43)." Adding a separate silencing-gate row is out of JSK-43 scope (JSK-36 follow-up).

## Findings deliberately not adopted

- **Blind: "tmprepo per-case vs shared isolation"** — implementation chose shared with explicit precondition checks (`staged="$(git diff --cached --name-only ...)"`) before each case. Defensible; per-case fresh tmprepo is overkill for 3 cases.
- **Blind: `WIP` commit message might trip silencing-gate** — `WIP` is not in `pi/agent/review-patterns.md`; verified by reading the patterns catalogue. (Implementation uses `"add: trigger both gates"` etc. anyway.)
- **Guided: separate silencing-gate trigger-matrix row** — out of JSK-43 scope; the row's absence predates this ticket. Could be filed as a follow-up but the silencing-gate is implicitly covered by the existing pre-commit row's notion that "the three pattern sets must move together"… actually it isn't. File as follow-up if JSK-26's "trigger matrix lies about zsh row" sibling JSK-51 expands.

## Recommended action

Apply both residual fixes (A + B) in the worktree, then verify. Combined diff: ~2 lines code + ~1 line doc. Stays within JSK-43 scope per the ticket-boundary directive in the batch-14 ledger.
