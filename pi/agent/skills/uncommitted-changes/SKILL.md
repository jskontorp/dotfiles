---
name: uncommitted-changes
description: >-
  Check all uncommitted changes (unstaged, staged, and untracked files) and prepare them
  for production. Use when the user asks for a "review" and there are uncommitted changes,
  or when they explicitly want to clean up local edits before committing — removing debug
  artifacts, simplifying logic, and ensuring production readiness.
  Do NOT use for branch reviews or PR reviews where there are no uncommitted changes.
compatibility: Requires git
allowed-tools: Bash(git:*) Read
---

# Review Uncommitted Changes

Audit every file with **uncommitted** changes and prepare the code for production. **Do not write any code** — analyse first, then propose changes in the chat and wait for approval before proceeding.

> **Scope gate:** This skill applies only when there are uncommitted changes in the working tree. Run the commands in Step 1 — if none of them return files, stop immediately and tell the user. Do not fall through to reviewing committed history or branch-level diffs.

## Steps

### 1. Identify Changed Files

```bash
git diff --name-only                      # unstaged changes
git diff --cached --name-only             # staged changes
git ls-files --others --exclude-standard  # untracked files
```

If all three commands return no files, **stop here** — this skill does not apply. Only files returned by these commands are in scope. Do not review already-committed files.

### 2. Read and Analyse Each File

For every changed file:

1. Read the full file contents.
2. Identify issues in the categories below.
3. Collect all findings before proposing anything.

### 3. Report Findings

Present a structured summary per file **in the chat** before making any edits:

```
### `path/to/file.ts`
- 🧹 **Debug artifact** — `console.log("debug", payload)` on line 42
- 🧹 **Commented-out code** — dead block lines 78-91
- ⚡ **Simplification** — nested ternary on line 30 can be a simple `if`
- 🔤 **Type issue** — `any` used on line 15, should be `MyPayload`
```

Wait for the user to approve or adjust before applying changes.

### 4. Apply Approved Changes

After approval, make surgical edits. Preserve all existing functionality and behavior.

## What to Look For

| Category | Examples |
|----------|----------|
| **Debug artifacts** | `console.log`, `console.debug`, `debugger`, `TODO: remove`, test-only code |
| **Dead code** | Commented-out blocks, unreachable branches, unused imports/variables |
| **Temporary code** | Hardcoded flags, mock data left behind, `// HACK`, `// FIXME` |
| **Readability** | Deeply nested logic, overly clever one-liners, unclear variable names |
| **Type safety** | Use of `any`, missing return types on exported functions, unsafe casts |
| **Consistency** | Deviations from project conventions (check project-level AGENTS.md or skills) |

## Constraints

- **No functional regressions** — behavior must stay identical.
- **No new features** — do not add functionality that wasn't there.
- **No unnecessary abstractions** — don't extract/refactor beyond what clarity requires.
- **Don't delete feature code** — if code looks unused but may belong to another feature, flag it instead of removing it.

## Checklist

- [ ] All uncommitted files identified (unstaged + staged + untracked)
- [ ] Each file read and analysed
- [ ] Findings reported in chat — awaiting approval
- [ ] Debug / dead / temporary code removed
- [ ] Readability and simplicity verified
- [ ] No unsafe types remain
- [ ] No functional regressions introduced
- [ ] Build passes
- [ ] Lint passes
