# gh-auth-switch-fix — 2026-10-21 — closed: 2026-10-21

## Standing Directives
- User: fix c9e753b if easy; otherwise revert the change so account switching is not blocked.
- User approved a separate worktree; leave canonical shared/gitconfig changes and other sessions untouched.
- User: merge to main when done. No push requested.

## Verification invariants
- Run `zsh -f test/gh-auth-check.zsh`, `zsh -n zsh/core.zsh`, `just check`, and `just test` from this worktree.
- Wrapper tests use a fake gh executable, not real tokens or account changes.
- Do not relink from the worktree or alter credentials / local pins in existing project clones.

## Progress
- Investigation: gh() injects a repo-pinned GH_TOKEN even for auth commands; akerbp-e360 also has a repo-local jskontorp-akerbp Git pin. No credentials read or changed.
- Baseline `just check`: passed before edits.
- Regression reproducer: fails on original wrapper with `FAIL: gh auth switch received an injected token`.
- Fix: pass all `gh auth ...` calls directly to the CLI; preserve normal command pinning.
- Regression suite wired into test/verify.sh for both platforms. `zsh -f test/gh-auth-check.zsh` and `zsh -n zsh/core.zsh`: passed.
- Post-fix `just check`: passed. `just test`: 145 passed, 0 failed (VM + macOS-shim containers). Test containers stopped and removed by the runner.
- `git diff --check`: passed. Canonical shared/gitconfig changes untouched.
- AGENTS.md records the regression class with c9e753b as evidence and test/gh-auth-check.zsh as detection.
- Integration approved: commit this work and fast-forward main. Existing project Git pins and real account settings remain unchanged. Existing shells must re-source core.zsh to load the fix. No relinking needed.
