---
slug: jsk-46-precommit-self-check
linear: JSK-46
started: 2026-05-28
closed: 2026-05-28
---

## Standing Directives

- User picked JSK-46 as the next Linear ticket to work.
- Use a worktree (`/Users/jorgens.kontorp/code/personal/dotfiles_worktrees/jsk-46-precommit-self-check`); do not edit canonical.
- Ticket requires a full triple-review flow before implementation.

## Verification invariants

Green for this batch means:

- `bash test/check-pre-commit-self-check.sh` passes once added.
- `just check` passes from the worktree.
- If a full Docker run is skipped, report it explicitly.

## Phase log

- 2026-05-28: Read JSK-46 in Linear, created worktree, inspected current hook/test structure, drafted design proposal for triple review.
- 2026-05-28: Ran triple review. Synthesis: proceed with a narrower final-staged-state guard; add stronger tests for trap status preservation, fixture setup, and path-safe diagnostics; CI workflow wiring requires explicit approval before editing `.github/workflows/test.yml`.
- 2026-05-28: Implemented pre-commit staged-index entry/exit guard, added `test/check-pre-commit-self-check.sh`, wired it into `just check` and CI policy checks, and updated `AGENTS.md` trigger/regression notes.
- 2026-05-28: Verification passed: `bash test/check-pre-commit-self-check.sh`, `just check`, and `just test`.
