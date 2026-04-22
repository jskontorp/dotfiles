---
name: commit
description: >-
  Group uncommitted changes into atomic, logical commits using Conventional Commits,
  push to remote, and update the PR description if one exists.
  Use when the user wants to commit reviewed changes or organise work into clean git history.
compatibility: Requires git and gh (GitHub CLI)
allowed-tools: Bash(git:*) Bash(gh:*)
disable-model-invocation: true
---

# Commit

Stage and commit all uncommitted changes as atomic, logical units using [Conventional Commits](https://www.conventionalcommits.org/), push to remote, and update the PR description if one exists.

## Steps

### 1. Survey Uncommitted Changes

```bash
git status --short
git diff --stat
```

Read each changed file to understand what was modified and why.

### 2. Group into Logical Commits

Organise changes into the smallest meaningful units. Each commit should be independently valid — the build must pass at every point.

**Grouping heuristics:**

| Group by | Example |
|----------|---------|
| Feature/fix scope | All files for a single bug fix together |
| Layer | Schema change + migration in one commit |
| Type of change | Pure refactors separate from behavior changes |
| Independence | Changes that make sense on their own |

### 3. Stage and Commit

For each logical group, stage the relevant files and commit:

```bash
git add path/to/file1 path/to/file2
git commit -m "<type>(<scope>): <subject>"
```

#### Conventional Commit Format

```
<type>(<scope>): <imperative subject, lowercase, no period>
```

**Subject-line only.** No body. If a commit is hard to summarise in one line, split it. The PR description carries context and reasoning.

**Types:** `feat`, `fix`, `refactor`, `style`, `docs`, `chore`, `perf`, `test`
**Scope** — module or area (e.g., `auth`, `api`, `ui`).
**Subject** — imperative mood, lowercase, no trailing period.

```bash
git commit -m "fix(deals): deduplicate stage names before insert"
git commit -m "refactor(ui): replace status badge ternary with lookup map"
git commit -m "chore: remove leftover console.log statements"
```

### 4. Confirm and Push

Check for an existing PR:

```bash
gh pr view --json url --jq '.url' 2>/dev/null || echo "No open PR"
```

Present a summary and **wait for approval**:

- List commits created (one-liner each).
- If a PR exists, show the proposed updated description (see **PR Description Format**).

After approval, tell the user to push:

```
Run: git push
```

If the user confirms they've pushed and a PR exists, continue to step 5. If no PR, done.

### 5. Update PR Description (if PR exists)

Generate an updated description covering the entire branch:

```bash
git log --oneline main..HEAD
```

Use the existing description as a starting point — preserve what's accurate, update what changed.

```bash
gh pr edit --body "<generated description>"
```

## PR Description Format

This format is the canonical reference — used here and by the **create-pr** skill.

````markdown
## Summary

<1-2 sentences — what this PR does and why. Be specific.>

## Changes

- **`<type>(<scope>)`**: <concise what + why>
- ...

## Notes

<migrations, env changes, breaking changes — or "None">
````

**Rules:**

- Cover every commit on the branch, not just the latest session.
- One bullet per logical change — collapse related commits when they serve the same purpose.
- No filler, no preamble. Summary should let a reviewer understand the PR without reading the diff.
- Under ~20 lines of Markdown.

## Constraints

- Each commit must leave the project in a buildable state.
- No unrelated changes bundled together.
- Commit messages are subject-line only.
- **No proactive `git push`** — only via `gh pr create` or when the user explicitly asks.

## Checklist

- [ ] All uncommitted changes surveyed and understood
- [ ] Changes grouped into atomic, logical units
- [ ] Each commit uses Conventional Commits format (subject-line only)
- [ ] Build passes after all commits
- [ ] User approved and pushed to remote
- [ ] PR description updated (if PR exists)
