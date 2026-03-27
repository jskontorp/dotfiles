---
name: create-pr
description: >-
  Create a draft PR for the current branch with a generated description.
  Use when the user says "create pr", "open pr", "draft pr", or wants to push and open a pull request.
compatibility: Requires git, gh (GitHub CLI)
allowed-tools: Bash(git:*) Bash(gh:*)
---

# Create PR

Push the current branch and open a draft PR with a generated description.

## Phase 0 — Gate

```bash
BRANCH=$(git branch --show-current)
```

- On `main` → stop.
- PR already exists for this branch (`gh pr view --json url 2>/dev/null`) → stop, show the URL. Suggest using the commit skill with "update the PR" if they want to refresh the description.

## Phase 1 — Generate description

```bash
git log --oneline main..HEAD
```

Read the commit log and any changed files needed to understand the PR's purpose.

**Title** — Conventional Commits format. If the branch name contains a Linear ticket identifier (a short alphabetic project key + hyphen + number, like `tech-123` or `TECH-456`), extract it and prepend it uppercased: `TECH-123: type(scope): subject`. Common patterns: branch IS the ticket (`tech-123`), or ticket is embedded after a slash (`feat/TECH-456-fix-bug`). Do not match incidental fragments like `fix-2` in `fix-2-bugs`. If no ticket is found: `type(scope): subject`.

**Body** — use the **PR Description Format** from the **commit** skill.

## Phase 2 — Confirm

Present the title and body in chat. Ask: *"Create this draft PR?"*

Do **not** proceed without explicit approval.

## Phase 3 — Create

```bash
gh pr create --draft --title "<title>" --body "<body>"
```

Report the PR URL.

## Constraints

- **Draft only** — always `--draft`. Never create a ready-for-review PR.
- **Never push force** — if the branch hasn't been pushed, `gh pr create` handles the push. If it fails, tell the user.
- **One PR per invocation** — don't batch.
