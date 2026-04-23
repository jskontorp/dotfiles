---
name: gh-cli
description: >-
  Interact with GitHub using the gh CLI. Use when the user asks to view, create,
  or update GitHub PRs, check CI status, or comment on issues. Not for local git
  operations — see the commit, uncommitted-changes, and interactive-rebase skills for those.
compatibility: Requires gh (GitHub CLI) authenticated with repo access
allowed-tools: Bash(gh:*) Bash(git:*)
disable-model-invocation: true
---

# GitHub CLI

Use `gh` for GitHub interactions on the current repository.

## Allowed Actions

Only these `gh` subcommands are permitted:

| ✅ Allowed | Examples |
|---|---|
| `gh pr list` | List open PRs |
| `gh pr view` | View PR details, body, checks |
| `gh pr create --draft` | Create draft PRs only |
| `gh pr edit` | Update title, body, labels, reviewers |
| `gh pr checks` | View CI status |
| `gh pr diff` | View PR diff |
| `gh pr comment` | Add a comment to a PR |
| `gh issue list` | List issues |
| `gh issue view` | View issue details |
| `gh issue comment` | Comment on an issue |
| `gh run list` | List workflow runs |
| `gh run view` | View run details / logs |

## Restricted Actions

These commands are **only allowed when the user explicitly asks** (e.g., "close the PR", "mark it ready for review"). Never run them proactively.

| ⚠️ Restricted | When allowed |
|---|---|
| `gh pr close` | User explicitly asks to close a PR |
| `gh pr ready` | User explicitly asks to mark PR ready for review |
| `gh pr review --approve` | User explicitly asks to approve |
| `gh issue close` | User explicitly asks to close an issue |

## Forbidden Actions

These are **never allowed** — tell the user to run them manually.

| ❌ Forbidden | Reason |
|---|---|
| `gh pr merge` | Irreversible remote operation |
| `gh pr delete-branch` | Irreversible remote operation |
| `gh release` | Irreversible remote operation |
| `gh repo edit` | Repo-level settings change |
| `git push` | Use `gh pr create` for initial push, otherwise tell the user |

## Recipes

```bash
# List open PRs
gh pr list

# View current branch's PR description
gh pr view --json title,body,state --jq '"# " + .title + "\n\n" + .body'

# View a specific PR
gh pr view 42 --json title,body,state

# Check CI status
gh pr checks 42

# View PR diff
gh pr diff 42

# Create a draft PR
gh pr create --draft --title "feat(scope): description" --body "## Summary
..."

# Update PR description
gh pr edit 42 --body "## Summary
..."

# Add a PR comment
gh pr comment 42 --body "Update: ..."

# Add a comment to an issue
gh issue comment 99 --body "Note: ..."

# Check failed CI logs
gh run list --limit 5 --status failure
gh run view <run-id> --log-failed 2>&1 | tail -60
```

## Rules

- Use `--json` + `--jq` to keep output concise.
- PR titles must follow Conventional Commits: `type(scope): subject`.
- Link issues in PR body with `Closes #N` or `Fixes #N`.
- Always read (`gh pr view`) before writing (`gh pr edit`).
