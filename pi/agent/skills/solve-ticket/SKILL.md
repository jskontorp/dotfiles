---
name: solve-ticket
description: >-
  Implement a Linear ticket end-to-end: understand → plan → worktree → implement → verify → peer-review → user-review → deliver.
  Use when the user says "solve TECH-123", "create a solution for TECH-123", "work on TECH-123",
  "implement TECH-123", or any request that starts from a Linear ticket identifier.
compatibility: Requires git, pnpm, tmux, pi, gh (GitHub CLI), and access to the linear + notion tools
allowed-tools: Bash(git:*) Bash(pnpm:*) Bash(tmux:*) Bash(gh:*) Bash(node:*) Bash(curl:*) Bash(pi:*) Read Write Edit linear notion
---

# Solve Ticket

Implement a Linear ticket in an isolated git worktree with a dedicated dev server.

## Shell Preamble

Shell state doesn't persist. **Every bash block must start with:**

```bash
TICKET="tech-123"            # lowercase for branch/worktree/tmux
DEV_SESSION="$TICKET-dev"
ROOT=$(git worktree list | awk 'NR==1 {print $1}')
WT="${ROOT}_worktrees/$TICKET"
```

Use **uppercase** (`TECH-123`) for the `linear` tool. Use full `$WT/…` paths for Read/Write/Edit. Never write to the main repo.

## Progress File

Maintain `$WT/.pi-progress.md` (gitignored) for crash recovery. Update after every phase transition and every completed plan step.

```markdown
# TECH-123: <title>

## Plan
1. [x] <completed step>
2. [ ] <pending step>

## Current Phase
Phase 4 — Implement (step 2)

## Notes
- <decisions, blockers, things tried>
```

## User Context

Text after the ticket ID (e.g. `solve TECH-123 - focus on mobile layout`) is **steering context**. It overrides/refines the ticket. Use it to focus Phase 1 investigation and shape the Phase 2 plan. Persist it in progress file Notes.

## Verification

The standard verification procedure, referenced by later phases:

1. `cd "$WT" && pnpm build` — fix type errors.
2. `cd "$WT" && pnpm lint` — fix lint errors.
3. `tmux capture-pane -p -t "$DEV_SESSION" -S -100` — check for runtime errors.

---

## Phase 1 — Understand

Run from the main worktree before creating any workspace.

1. **Sync main** — `git fetch origin main && git pull origin main` to ensure investigation is against the latest codebase.
2. `linear get_issue TECH-123` — read title, description, comments, labels, priority.
3. **Linked context** — Notion URLs → use `notion get_page` for quick lookups, or load the **read-notion** skill if available. Related Linear issues → `linear get_issue` for context only, **do not expand scope**. Note any GitHub refs.
4. **Find affected code** — grep for keywords, entity names, route paths. Read relevant files to understand current state.
5. **Blockers** — if blocked by another issue or unmerged work, stop and tell the user.

If the ticket is vague or missing acceptance criteria, **stop and ask**.

## Phase 2 — Plan

Present a plan **before** creating the worktree:

```
### Plan for TECH-123: <title>
1. <What to change and why>
2. <What to change and why>
**Files:** … **New files:** … **Risk:** …
```

**Wait for explicit approval.** Then create the progress file after Phase 3 setup.

## Phase 3 — Workspace

Create worktree, symlink env, install dependencies:

```bash
if [ ! -d "$WT" ]; then
  mkdir -p "$(dirname "$WT")"
  git fetch origin main
  git worktree add --no-track -b "$TICKET" "$WT" origin/main
fi
[ -f "$ROOT/.env.local" ] && [ ! -e "$WT/.env.local" ] && ln -s "$ROOT/.env.local" "$WT/.env.local"
cd "$WT" && pnpm install
```

Add progress/review files to the worktree-local exclude (not tracked in `.gitignore`):

```bash
GIT_EXCLUDE="$(cd "$WT" && git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$GIT_EXCLUDE")"
for pat in '.pi-progress.md' '.pi-review-*.md'; do
  grep -Fqx "$pat" "$GIT_EXCLUDE" 2>/dev/null || echo "$pat" >> "$GIT_EXCLUDE"
done
```

If the branch already exists but no worktree: ask the user — check it out, or start fresh from main?

Start dev server in a detached tmux session. Wait up to 30s for "Ready in" output. If it doesn't appear, warn and continue.

```bash
tmux kill-session -t "$DEV_SESSION" 2>/dev/null || true
tmux new-session -d -s "$DEV_SESSION" -c "$WT" "pnpm dev"
for i in $(seq 1 30); do
  tmux capture-pane -p -t "$DEV_SESSION" | grep -q "Ready in" && echo "Dev server ready." && break
  [ "$i" -eq 30 ] && echo "⚠ Dev server not ready — check: tmux attach -t $DEV_SESSION"
  sleep 1
done
```

Tell the user: `Dev server: tmux attach -t <ticket>-dev`

## Phase 4 — Implement

Write code in the worktree. Follow AGENTS.md conventions.

Work incrementally — one concern at a time. Run `pnpm build` after each significant change. Monitor dev server via `tmux capture-pane -p -t "$DEV_SESSION" -S -50` and fix runtime errors immediately. If the port is taken, Next.js auto-increments — note the actual URL from tmux output.

Update progress file after each completed plan step.

## Phase 5 — Verify

Run the **Verification** procedure. Fix all errors before proceeding.

## Phase 6 — Peer Review

Spawn an independent `pi` sub-agent to review uncommitted changes cold. Up to **2 rounds** — break early if a round produces no fixes.

**Each round:**

1. Spawn the sub-agent (5-minute timeout):

```bash
ROUND=1
TIMEOUT_CMD=()
command -v timeout &>/dev/null && TIMEOUT_CMD=(timeout 300)
command -v gtimeout &>/dev/null && TIMEOUT_CMD=(gtimeout 300)
cd "$WT" && "${TIMEOUT_CMD[@]}" pi -p --no-session "review" > "$WT/.pi-review-${ROUND}.md" 2>&1 || true
```

2. Read `$WT/.pi-review-${ROUND}.md`. If empty, unparseable, or the sub-agent crashed/timed out — treat as no feedback, note in progress file, continue to Phase 7.

3. Triage each finding — **accept** (fix now) or **dismiss** with a one-line reason. Dismiss findings that suggest scope expansion, propose unrelated architectural changes, or conflict with ticket requirements.

4. Log in progress file:

```markdown
## Peer Review — Round {n}
- ✅ <finding> → fixed
- ❌ <finding> — <reason>
```

5. Fix accepted items. If fixes were made, run **Verification** and continue to the next round. If no fixes (all dismissed or clean), break.

## Phase 7 — User Review

Present the final state:

```bash
cd "$WT" && git diff --stat && git ls-files --others --exclude-standard
```

Brief summary: what was built (one sentence per plan item), what peer review caught and what was fixed or dismissed.

**Wait for explicit approval before committing.**

## Phase 8 — Deliver

1. **Commit** — stage and commit per the **commit** skill. Do not push or update PR — the next step handles both.
2. **Draft PR** — follow the **create-pr** skill. Include `Closes TECH-123` in the body.
3. **Kill dev server:** `tmux kill-session -t "$DEV_SESSION" 2>/dev/null || true`
4. **Tell the user** how to clean up (do **not** remove it yourself):
   - Remove worktree only: `git worktree remove <path>`
   - Remove worktree and branch: `git worktree remove <path> && git branch -d tech-123`

After delivering the draft PR, the next invocation with the same ticket should follow **Resuming Previous Work**.

---

## Resuming Previous Work

If the worktree already exists:

1. Read `$WT/.pi-progress.md` — primary source of truth.
2. Check state: `git status`, `git log --oneline -5`, `tmux has-session -t "$DEV_SESSION"`.
3. Re-fetch ticket: `linear get_issue TECH-123` for new comments/scope changes.
4. Restart dev server if not running (Phase 3 tmux steps).
5. Check for open PR:

```bash
PR_STATE=$(cd "$WT" && gh pr view --json state,reviewDecision,reviews --jq '{state, reviewDecision, reviewCount: (.reviews | length)}' 2>/dev/null)
```

Route based on PR state:
- **PR with review activity** (`reviewCount > 0` or `reviewDecision` set) → load **prepare-merge** skill.
- **PR without review activity** + user says "prepare merge" → load **prepare-merge** skill.
- **Otherwise** → continue implementation at Phase 4.

6. Present resume summary: what's done, what's next, any notes. Ask: continue, or reset? (`git reset --hard origin/main`)

## Constraints

- **Worktree only** — never modify the main repo after Phase 2.
- **Plan first** — no code without user approval.
- **Verify → peer review → user review before commit.**
- **No bare `git push`** — only via `gh pr create --draft`, or when the user explicitly asks.
- **One ticket, no scope creep** — related issues are noted, not implemented.
- **3-strike cap** — after 3 failed attempts at the same error, ask the user.
- **Ambiguity → ask.**
