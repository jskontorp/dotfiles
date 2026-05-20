---
name: prepare-merge
description: >-
  Two-pass review of a PR branch before merging — line-level quality and architectural coherence.
  Use when the user explicitly says "prepare merge", "prepare for merge", or "ready to merge".
  Do NOT use for general code reviews or uncommitted change reviews.
compatibility: Requires git, gh
allowed-tools: Bash(git:*) Bash(gh:*) Bash(rg:*) Bash(curl:*) linear Read Edit
---

# Prepare Merge

Catch everything an automated reviewer would flag — in one pass, before pushing.

> **Relationship to `review-pr`.** Phases 0–4 of this skill are identical to the read-only peer-review skill `review-pr`. The only divergence is Phase 5 (apply fixes, resolve threads, `gh pr ready`). If you only want a read-only review, use `review-pr` instead.

## Preamble

Every bash block:

```bash
BASE="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo main)"
```

Override with `BASE=<branch>` if the PR targets something other than the repo default (e.g. a long-lived release branch).

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

## Phase 0.7 — Invariant extraction

Before reading the code, extract the contracts the PR *claims* to uphold. LLM reviewers pattern-match on present code and miss issues that live in what isn't there; an explicit contract list anchors the negative-space probe in Phase 2.5 and the architectural review in Phase 3.

Read, in order:

1. **PR description** — `gh pr view --json body --jq '.body'`.
2. **Linked Linear / Jira issue** — if a URL appears in the PR body, best-effort fetch (`linear` tool with `action: "get_issue"`, `gh api`, or `curl`). Skip on failure; don't block the review.
3. **In-repo spec** — glob for the feature name from the PR title: `docs/superpowers/specs/*.md`, `docs/specs/*.md`, `specs/*.md`. Read any match.

From these sources, extract a bulleted list of the **contracts the code claims**. A contract is a falsifiable statement about runtime behaviour. Examples of contract shapes:

- "every persisted item has ≥1 source"
- "audit/notes fields survive persistence"
- "first-run-empty state is distinguishable from never-extracted"
- "endpoint X rejects resources of type Y"
- "items sharing key K must agree on classification field F"
- "field F, declared non-empty in the description, is validated at construction time"

Surface the list under **`### Contracts asserted by this PR`** in the Phase 4 report. If nothing surfaces, state it explicitly:

> Contracts asserted: none surfaced — review proceeds without contract anchor.

Do not fabricate contracts. The list anchors Phase 2.5 and Phase 3 — if it is empty, those phases still run, just without a precomputed checklist.

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

## Phase 2.5 — Negative-space probe

The class of bug that line-level review misses is the bug that is not on the page: a field computed and discarded, an unwritten row, an asymmetric guard, an unenforced invariant. LLM reviewers pattern-match on present code; they don't enumerate absences unless forced.

Each sub-pass below is **enumerate first, judge second**. Write the full list before opining on any item. An empty list is a valid result and should be stated as such.

Use the contracts from Phase 0.7 as priors — if a contract is asserted, the relevant sub-pass must explicitly confirm or refute that the code enforces it.

### (a) Response-field traceability

- Enumerate every field **added or modified** on a public response model in the diff.
- Enumerate every field **added** on internal return types / dataclasses / Pydantic schemas in the diff.
- For each enumerated field, trace where it is **populated** (writers) and where it is **consumed** (readers / serializers / persisters).
- Flag any field that is: declared-but-never-written, written-but-never-read, or computed-but-discarded between the producing function and the persistence / response boundary.

### (b) Persistence input enumeration

For every persistence path touched in this PR (repository write, raw `INSERT`, upsert, archive, soft-delete), enumerate input shapes explicitly:

- **Empty input** — zero items.
- **Single-item input.**
- **Conflicting-key input** — two incoming records share the dedup / primary key but disagree on a non-key field (classification, type, metadata).
- **Retry-after-partial input** — same call shape repeated after a partial earlier write.

For each shape, state the post-state. Is it **representable** (distinct row exists or its absence is itself meaningful)? **Distinguishable** from neighbouring states (e.g. "first-run produced empty result" vs. "never run")? **Correct** (no silent loss, no last-write-wins where the spec requires reconciliation)?

### (c) Endpoint symmetry

For every resource type touched by an endpoint in this PR:

- List **every handler** (GET/POST/PUT/DELETE/PATCH) on that resource across the codebase (`rg` by route prefix or resource name).
- Diff the precondition guards on each: authentication, authorization, resource-type check, ownership / tenant scoping, lifecycle state.
- Flag asymmetries (e.g. POST validates resource type, GET does not; PUT checks ownership, DELETE does not).

### (d) Pydantic / schema contract enforcement

For every `Field(default_factory=list|dict)` (or analogous defaulted collection field) in the diff:

- Read the field's `description=` text.
- If the description claims any constraint — "at least one", "non-empty", "required for persisted items", "must include …" — check that a validator (`@field_validator`, `@model_validator`, repository-side guard) enforces it at the relevant boundary.
- Flag drift between the description (human-readable contract) and runtime enforcement.

### (e) Test-the-test

For each test added or modified in the diff:

- Enumerate scenarios it does **not** cover for the function under test: empty input, conflict / collision, error path, non-default-language / non-default-tenant. Flag gaps that intersect contracts from Phase 0.7.
- If the test patches or mocks N functions in a module, count how many functions of that role exist in the module. Flag if N < total — invisible code is untested code.
- Does any test construct domain objects that bypass validators or invariants (e.g. building a model with `model_construct`, or instantiating a dataclass with values a validator would reject)? Flag — the test is exercising an unrepresentable state.

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

### Contracts asserted by this PR
- every persisted item has ≥1 source (from spec §3)
- audit/notes fields survive persistence (from PR description)
- (or: `Contracts asserted: none surfaced — review proceeds without contract anchor.`)

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

After fixes pass verification, resolve PR comment threads (if a PR exists).

**Confirmation gate.** Before posting any reply or resolving any thread, present the user with:
- Each thread to be replied to (reviewer handle, quoted comment excerpt, classification)
- The exact reply body to be posted
- The list of thread IDs that will be resolved

Wait for explicit approval. On "go ahead" / "yes" / "approve", proceed. Anything else, stop and ask what to change. Mirror the approval pattern used by the Phase 4 report.

Then, for each approved thread:

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
