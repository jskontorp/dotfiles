---
name: interactive-rebase
description: Perform an interactive git rebase without opening an editor. Use when the user wants to rebase, squash, reorder, edit, fixup, or drop commits interactively. Handles rebase-todo editing programmatically so vim never blocks the coding agent.
compatibility: Requires git
allowed-tools: Bash(git:*) Bash(sed:*) Bash(cat:*)
disable-model-invocation: true
---

# Interactive Rebase

## Preventing Editor Prompts

Always set both env vars to avoid blocking on an editor:

- `GIT_SEQUENCE_EDITOR` — edits the rebase-todo file (use `sed` or a bash script).
- `GIT_EDITOR=true` — suppresses any editor during the rebase (merge messages, squash messages). For rewords, replace with a `sed` script that edits the message file.

```bash
GIT_SEQUENCE_EDITOR="<command>" GIT_EDITOR=true git rebase -i <target>
```

**Never** run a bare `git rebase -i` — it opens vim and blocks the agent.

Use `sed -i ''` on macOS, `sed -i` on Linux.

## Patterns

```bash
# Squash all into first
GIT_SEQUENCE_EDITOR="sed -i '' '2,\$s/^pick/squash/'" GIT_EDITOR=true git rebase -i <target>

# Fixup all into first (discard messages)
GIT_SEQUENCE_EDITOR="sed -i '' '2,\$s/^pick/fixup/'" GIT_EDITOR=true git rebase -i <target>

# Drop a commit
GIT_SEQUENCE_EDITOR="sed -i '' 's/^pick <hash>/drop <hash>/'" GIT_EDITOR=true git rebase -i <target>

# Reword — GIT_EDITOR becomes a sed script instead of `true`
GIT_SEQUENCE_EDITOR="sed -i '' 's/^pick <hash>/reword <hash>/'" \
  GIT_EDITOR="sed -i '' '1s/.*/New commit message/'" \
  git rebase -i <target>

# Multi-action
GIT_SEQUENCE_EDITOR='bash -c "
  sed -i \"\" \
    -e \"s/^pick <hash1>/squash <hash1>/\" \
    -e \"s/^pick <hash2>/drop <hash2>/\" \
    \"\$1\"
"' GIT_EDITOR=true git rebase -i <target>
```

## Workflow

1. `git log --oneline <target>..HEAD` — show the commits, confirm the plan with the user.
2. Build and run the `GIT_SEQUENCE_EDITOR` command.
3. If conflicts arise, resolve them, `git add`, then `GIT_EDITOR=true git rebase --continue`. Abort with `git rebase --abort` if needed.
4. `git log --oneline <target>..HEAD` — show the result.
5. `git diff --stat HEAD..origin/$(git branch --show-current)` — compare with the remote branch. If there's no diff beyond the expected rebase changes, report "✅ No missing changes vs origin." If there are unexpected differences, report a one-liner summarising what's missing or diverged.
6. If a PR exists, update its description following the commit skill. If no PR exists, point the user to **create-pr**.

## Constraints

- **Never force-push.** After the rebase, tell the user the rebase is complete and that they need to force-push manually if the branch was already pushed.
- Always show the commit list and confirm the plan before executing.
- If anything goes wrong, `git rebase --abort`.
