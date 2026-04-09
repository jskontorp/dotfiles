---
name: prepare-merge
description: >-
  Two-pass review of a PR branch before merging — line-level quality and architectural coherence.
  Use when the user explicitly says "prepare merge", "prepare for merge", or "ready to merge".
  Do NOT use for general code reviews or uncommitted change reviews.
compatibility: Requires git, gh
allowed-tools: Bash(git:*) Bash(gh:*) Bash(rg:*) Read Edit
---

# Prepare Merge

Catch everything an automated reviewer would flag — in one pass, before pushing.

## Preamble

Every bash block:

```bash
BASE="main"
```

## Phase 0 — Gate

```bash
git fetch origin "$BASE" --quiet
```

- No commits ahead of `origin/$BASE` → stop. Nothing to review.

## Phase 0.5 — PR Review Comments

```bash
PR_NUMBER=$(gh pr view --json number --jq '.number' 2>/dev/null)
```

If no PR exists, skip to Phase 1.

Fetch inline review comments and top-level review bodies via `gh api`. Also fetch review thread node IDs and resolution status via GraphQL (`pullRequest.reviewThreads`). Skip threads already marked as resolved. Group comments into threads by `in_reply_to_id`. For each unresolved thread, read the referenced file and line (fall back to `original_line` if outdated), read the full exchange, then classify:

| Status | Action |
|--------|--------|
| **Actionable** | Assign 🔴/🟡/⚪ severity, include in Phase 2/3 findings |
| **Already addressed** (✅) | Verify against current code, note in report |
| **Stale** (🪦) | Note and skip |
| **Subjective** (💬) | List as ⚪ nit unless user promotes |

Actionable comments appear in the Phase 4 report under **PR Review Feedback** before the agent's own findings. If a reviewer comment and a Phase 2/3 finding overlap, keep one entry and attribute both sources.

## Phase 1 — Gather

```bash
git diff --name-status "origin/$BASE...HEAD"
git log --oneline "origin/$BASE..HEAD"
```

Read the **full content** of every changed file. For modified files, also read the diff hunks (`git diff "origin/$BASE...HEAD" -- <file>`). Don't skip files — cross-file issues hide in context.

## Phase 2 — Line-Level Review

Check every changed file for:

| Check | Examples |
|-------|---------|
| **Type safety** | `any`, missing return types on exports, unsafe casts |
| **Dead code & debug artifacts** | Unused imports/vars, commented-out blocks, unreachable branches, `console.log/debug`, `debugger`, `// TODO: remove`, `// HACK` |
| **Error handling** | Empty catch, swallowed errors, API routes without try/catch |
| **Security** | Missing auth checks, unsanitized input |

## Phase 3 — Architectural Review

Zoom out across all changed files.

### Always check

1. **API contracts** — route and caller agree on request/response shapes.
2. **Missing counterparts** — new API route without client hook? Schema change without type update? Component without loading/empty states?
3. **Dead exports & orphans** — exported symbols nobody imports, new files nothing references. Verify with `rg`.
4. **Incomplete renames** — stale references in strings, comments, types.

### Check if relevant to the diff

5. **Type & schema consistency** — new types match existing type definitions and DB schema.
6. **Circular imports** — A imports B imports A.
7. **Migration safety** — additive? Access control policies included?
8. **Pattern consistency** — does the PR introduce a second way to do something that already has an established pattern?
9. **Approach validity** — is the PR layering workarounds, compensating for a deeper problem, or solving the wrong thing entirely? If so, flag as 🔴 and recommend loading the **step-back** skill before proceeding with fixes.

## Phase 4 — Report and wait

Run the project's build and lint commands. Include any errors.

If no findings and both commands pass, report a clean bill and skip Phase 5:

```
## Pre-Merge Review: `branch-name`
X commits, Y files — ✅ No issues found. Ready to merge.
```

Otherwise, present one combined report, then **stop and wait for approval**:

```
## Pre-Merge Review: `branch-name`
X commits, Y files — 🔴 N must-fix · 🟡 M should-fix · ⚪ P nits

### PR Review Feedback  ← only if a PR with comments exists
- 🔴 @reviewer `file.ts` (L42): "missing null check on ..." → **actionable**, not yet addressed
- ✅ @reviewer `file.ts` (L80): "unused import" → **already fixed** in abc1234
- 💬 @reviewer `file.ts` (L15): "consider renaming" → **subjective**, flagged as nit below
- 🪦 @reviewer `old-file.ts` (L10): "..." → **stale**, file deleted

### Must Fix
- 🔴 `file.ts` (L42): `as any` → type as `ApiResponse`

### Should Fix
- 🟡 `file.ts` (L15): unused import `formatDate`

### Nits
- ⚪ `file.ts` (L8): unclear variable name `d`
```

Severity:
- 🔴 **Must fix** — a reviewer would flag this, or it's a bug/security issue
- 🟡 **Should fix** — convention violation or code smell
- ⚪ **Nit** — subjective readability preference

Ask: *"Fix all 🔴 and 🟡? Any nits or subjective reviewer comments you want included or skipped?"*

## Phase 5 — Fix

Apply approved fixes. Re-run build and lint. If fixes introduce new issues, fix those too — cap at **2 re-verify cycles**. If still broken, stop and report.

After fixes pass verification, resolve PR comment threads (if a PR exists):

1. For each unresolved thread that was classified in Phase 0.5 (Actionable and fixed, Already addressed ✅, or Stale 🪦), reply and resolve:
   - **Actionable (fixed)** — reply referencing the fix commit and a short note: `"Fixed in \`abc1234\` — replaced \`as any\` with \`ApiResponse\` type."`
   - **Already addressed ✅** — reply referencing the commit that addressed it: `"Addressed in \`def5678\` — import removed."`
   - **Stale 🪦** — reply with context: `"Stale — file deleted in \`ghi9012\`."`
   - **Subjective 💬 promoted to fix** — reply referencing the fix commit, same as Actionable.
2. Reply via `gh api` (POST comment on the PR review thread).
3. Resolve via GraphQL `resolveReviewThread` mutation using the thread node ID from Phase 0.5.

Do **not** resolve Subjective 💬 threads that were not promoted to a fix — leave those for the reviewer.

Then prompt: *"Fixes applied, verified, and reviewer comments resolved. Run `gh pr ready` to mark ready for review?"*

Wait for explicit user approval before executing `gh pr ready`.

## Constraints

- **Quality fixes only** — no behavior changes. Flag behavioral issues for the user.
- **Branch diff only** — don't refactor code outside the PR.
- **Full file reads** — never review from diff hunks alone.
