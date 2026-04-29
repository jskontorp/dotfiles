---
name: session-scan
description: Print a situational brief — worktrees, tmux topology, sibling coding agents, dirty state — for the current repo. Use when starting to edit code, before making changes, when picking up work on a new branch, or to recover awareness of active worktrees and other agents in this checkout.
allowed-tools: Bash
---

# Session scan

Run `pi/agent/skills/session-scan/scan.sh` (or wherever this skill is installed) and read the stdout output before editing code in this repository.

The script prints a one-shot situational brief covering:

- **REPO** — current path, branch, ahead/behind, clean/dirty, in-progress git operations, and `index.lock` presence.
- **WORKTREES** — every linked worktree of this repo, with the current one marked.
- **TMUX TOPOLOGY** — every tmux pane whose `cwd` is at or inside one of this repo's worktrees, grouped by session→window→pane.
- **SIBLINGS** — Claude or pi processes editing this same checkout (warned with `⚠ SAME WORKTREE`) or a sibling worktree (soft note).
- **DIRTY** — counts of unstaged/staged/untracked files plus the most recently modified entries.

Use the output to decide whether another agent is already working in this checkout (in which case **stop and confirm with the user before writing files**), and to orient yourself on the current branch state. The script always exits 0 — it never blocks the caller.
