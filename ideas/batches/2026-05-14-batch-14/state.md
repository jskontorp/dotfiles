# batch-14: state-awareness + parallel-work safety (post-batch-13)

machine: Mac (canonical: `~/code/personal/dotfiles`)
session: 2026-05-14 (multi-phase, spans /compact)
umbrella: [JSK-52](https://linear.app/jskontorp-dev/issue/JSK-52/)
closed: <pending>

Ledger written retroactively mid-batch, between JSK-43 commit 1 and commit 2, after JSK-52 was filed and the "first real session-ledger use" was identified as item #5 in its concrete follow-ups. Going forward this file is the working memory; chat and `.pi-delegate/batch-N/` are scratch.

## Standing Directives (this session)

Out-of-band user guidance accumulated through this session. Append, don't auto-delete.

- **Per-call approval for destructive ops.** push, branch delete, worktree remove, Linear state changes — each is its own approval call. Bundling rejected by the harness once already; user has been consistent about per-call gating throughout. AGENTS.md `Destructive actions` is the canonical rule; this is its in-session reinforcement.
- **Push-then-verify-rc-then-cleanup, in separate calls.** Hit the cleanup-before-verify mistake on the JSK-44 push (push rejected, worktree+branch already deleted, recovery via cherry-pick succeeded). Subsequent pushes split into per-step approvals. Item #3 in JSK-52's "concrete follow-ups not yet broken out."
- **Single-thread tickets.** No parallel implementation across tickets in this session. JSK-44 → JSK-45 → JSK-43 → JSK-46 (deferred to fresh session). Decision driven by context-budget concern.
- **Reviewer dispatch differentiated per ticket.** JSK-44 (lint, mechanical): solo with self-review. JSK-45 (tiny): solo. JSK-43 (one integration test, but design surface non-trivial): double plan-review (guided + blind via `.pi-delegate/batch-15/`). JSK-46 (architectural): full triple-review deferred to fresh session. The "full delegate flow for everything" default was rejected as overkill after JSK-43 split into JSK-44+JSK-46 made the complexity profile more granular.
- **Linear comments invite exploration, don't dictate.** User framing on JSK-52 pickup: "Don't dictate, but invite exploration." Comments are observations + questions, not action items. Tested on JSK-44 and JSK-46 comments (May 14).
- **Ticket-boundary discipline.** JSK-37 retro called out as the negative example (bundled worktree-refuse guard with auto-link recipe). Persistence-layers section in `pi/agent/AGENTS.md` cites this verbatim. Pattern reinforced in JSK-44/46 split decision and JSK-49/50/51 sibling-filing during the `ee7095c` review.
- **JSK-52 is the umbrella, not a sprint.** Continuous policy track. Comments accrue, status stays Triage, first review 2026-08-01. Don't try to close it.

## Verification invariants

What "green" means for any commit in this batch:

- `just check` from the worktree returns rc=0. New checks added in-batch (JSK-44 `check-git-env-isolation.sh`, JSK-43 `check-hook-chain.sh`) are wired in via the recipe.
- `just test` (Docker, full suite): 137/137 passes. Baseline since `b198fcb`; JSK-43 doesn't change the count (the new check passes inside its own bash script, but `just test`'s Results section reflects the Docker harness's headline accept/reject per checks-script, not per-case).
- Post-commit verification: `git show HEAD --stat` confirms expected file changes, working tree clean (`git status --short` empty).
- Post-push verification: `origin/main` resolves to the expected SHA before any cleanup is approved.
- Provenance check: any new entry in `AGENTS.md` Known regression classes must cite a 7-hex-char SHA (`test/check-regression-provenance.sh`, wired into `just check`).

## Closed phases

| Ticket | SHA | Summary |
|---|---|---|
| Step 0 — reviewer-prompt update | `11071fd` | Added criterion #10 (ticket-boundary) to `triple-review/prompts/guided.md`. Push-race recovered (rebased onto `998929d`). |
| JSK-44 | `b198fcb` | `test/check-git-env-isolation.sh` lint — static guard against GIT_INDEX_FILE inheritance. Eat-own-dogfood + test-the-test fixture. |
| JSK-45 | `8f210d6` | Silencing-gate self-exemption unit + integration tests. JSK-45 first impl cascaded 3 failures because the pass-case fixture overwrote the lib the hook sources — fixed by using `test/check-silencing-gate.sh` as the fixture target (also exempt, but not loaded by the hook at runtime). |
| JSK-43 commit 1 | `1df230c` | Silencing-gate allowlist + JSK-45 test arrays extended for new exempt path `test/check-hook-chain.sh`. Split from JSK-43 because of bootstrap chicken-and-egg (commit 2 needs this allowlist visible to the hook before it can land). |

## In flight

- **JSK-43 commit 2** (next): `test/check-hook-chain.sh` + hook headers + `justfile` entry. Staged in worktree, pending push approval after this ledger lands.
- **JSK-46** (deferred): pre-commit hook self-check (runtime guard). Full triple-review treatment scheduled for fresh session. Comment on JSK-46 (May 14) flags three concrete observations from this batch.

## Carry-forward observations (for the next session or for JSK-52)

1. **Worktree-cleanup-after-push-rc race.** JSK-44 push mistake. Procedural rule earned: never bundle cleanup with push in a single bash block; verify push rc=0 before deletion verbs. Filed as JSK-52 follow-up candidate #3.
2. **`SKIP_*` env-var leak through subprocess git invocations.** JSK-43 commit 1 first attempt: `SKIP_SILENCING_GATE=1 git commit ...` propagated through `pre-commit → just check → check-silencing-gate.sh → tmprepo commits`, silently regressing six existing test cases. Comment on JSK-46 (May 14) flags this as a design consideration. Open question whether `check-*.sh` unset lists should extend beyond `GIT_*` to `SKIP_*`.
3. **Bootstrap chicken-and-egg with hook-reads-canonical.** A commit that both extends a canonical-side config (e.g. an allowlist regex) and uses the new behavior trips the *old* behavior because the hook reads canonical's working tree pre-commit. Resolution: split into two commits. Comment on JSK-44 (May 14) flags this as adjacent. Candidate AGENTS.md regression-class entry if seen 2-3 more times.
4. **Push-race recovery proven twice.** `79e4924`→rebased→`11071fd` (Step 0), `8f210d6`→`b198fcb`→onwards (JSK-44). Non-FF rejection + `pull --rebase` + re-push. No conflicts encountered. The "another session pushed" event happened twice in ~2h — frequency high enough that the pattern is load-bearing.
5. **Double-review converged on same root cause from different angles.** Guided found the `just check`-inside-tmprepo bug via file:line tracing (criterion 4); blind found "hook installation method not specified" from the spec ambiguity end. Same underlying issue, two reviewers, complementary framings. Argument for keeping both reviewer types in any multi-pass review.

## Resume hints

If `/compact` happens and a follow-up session reads this:
- Origin state: `origin/main` is at whatever `git fetch && git rev-parse origin/main` returns. Last known SHA in this ledger: `1df230c`. Update on resume.
- Worktree: `~/code/personal/dotfiles_worktrees/jsk-43-hook-chain` should exist on branch `jsk-43-hook-chain` with JSK-43 commit 2's files staged but not committed. If gone, re-spawn via `./dev jsk-43-hook-chain` from canonical and re-stage from this batch's last commit.
- Linear: JSK-44 + JSK-45 Done. JSK-43 in Triage with commit 1 already landed (work is partial-Done; ticket state will move when commit 2 lands).
- Verification: re-run `just check` first; if rc=0, confirm origin sync via `git fetch && git rev-list --left-right --count origin/main...HEAD`.

## Cross-references

- Umbrella: JSK-52 (continuous policy track).
- Related-open: JSK-46 (paired with JSK-44 on regression-class closure), JSK-43 (this batch's terminal ticket), JSK-49 (multi-machine ledger collision — passive sentinel only).
- Related-closed-this-batch: JSK-44, JSK-45.
- Reviewer artefacts: `.pi-delegate/batch-15/` (JSK-43 plan double review — guided + blind, both completed 113s, results retained for forensics).
