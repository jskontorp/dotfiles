---
name: review-pr
description: >-
  Read-only peer review of a PR branch — line-level quality, contract enforcement,
  negative-space probe, architectural coherence. Use when the user says "review the PR".
  Does NOT apply fixes, resolve threads, or mark the PR ready. For the apply-and-land
  flow, use `prepare-merge` instead.
compatibility: Requires git, gh
allowed-tools: Bash(git:*) Bash(gh:*) Bash(rg:*) Bash(curl:*) linear Read
claude-compatible: false
---

# Review PR

Read-only counterpart of [`prepare-merge`](../prepare-merge/SKILL.md). Surfaces findings; does not edit, push, or comment on the PR.

User-facing aliases that should also route here: *"peer review"*, *"review my branch"*, *"review this PR"*. The frontmatter description deliberately advertises only the single trigger phrase `"review the PR"` — per `~/.pi/agent/AGENTS.md` § Pi-side auto-invocation gating, looser descriptions invite incidental dispatch.

## Protocol

Run Phases 0 through 4 of [`prepare-merge/SKILL.md`](../prepare-merge/SKILL.md) exactly as written, in order:

- **Phase 0** — gate on `git fetch` + commits-ahead check.
- **Phase 0.5** — fetch PR review comments and classify (actionable / addressed / stale / subjective).
- **Phase 0.7** — invariant extraction from PR body, linked Linear/Jira issue, in-repo spec. Produce the `Contracts asserted by this PR` bullet list.
- **Phase 1** — gather changed files and read each in full.
- **Phase 2** — line-level review (type safety, dead code, error handling, security).
- **Phase 2.5** — negative-space probe: response-field traceability, persistence input enumeration, endpoint symmetry, Pydantic contract enforcement, test-the-test.
- **Phase 3** — architectural review.
- **Phase 4** — present the structured report (with the `Contracts asserted by this PR` section) and stop.

## Excluded

- **Phase 5** (apply fixes, reply/resolve PR threads, `gh pr ready`) is **not** part of this skill. Report the findings and hand control back to the user.
- No `Edit` tool. No `gh pr review --approve`, no `gh pr ready`, no thread mutations, no commits, no pushes. If the user wants fixes applied after the review, they invoke `prepare-merge` (or fix manually).

## Constraints

- **Read-only.** The `allowed-tools` list omits `Edit` and any write-capable `gh` subcommand intentionally.
- **Full file reads** — never review from diff hunks alone.
- **Branch diff only** — don't comment on code outside the PR.
