---
name: solve-ticket
description: >-
  Implement a Linear ticket end-to-end in a JS webapp repo:
  understand → plan → worktree → implement → verify → peer-review → user-review → deliver.
  Use when the user says "solve TECH-123", "create a solution for TECH-123", "work on TECH-123",
  "implement TECH-123", or any request that starts from a Linear ticket identifier.
compatibility: Requires git, tmux, pi, gh (GitHub CLI), `timeout`/`gtimeout` (coreutils), a JS package manager (bun/npm/pnpm/yarn), and access to the linear + notion tools
allowed-tools: Bash(git:*) Bash(bun:*) Bash(npm:*) Bash(pnpm:*) Bash(yarn:*) Bash(tmux:*) Bash(gh:*) Bash(node:*) Bash(curl:*) Bash(pi:*) Read Write Edit linear notion
---

# Solve Ticket

Implement a Linear ticket in an isolated git worktree with a dedicated dev server.

Deterministic bookkeeping (workspace setup, dev-server readiness polling, peer-review spawn + round cap) is factored into scripts under `scripts/`. Judgement-heavy phases (understand, plan, implement, triage, summarise) remain inline. Tests live under `tests/` — run via `just test-skill solve-ticket`.

## Shell Preamble

Shell state doesn't persist. **Every bash block must start with:**

```bash
TICKET="tech-123"            # lowercase for branch/worktree/tmux
DEV_SESSION="$TICKET-dev"
ROOT=$(git worktree list | awk 'NR==1 {print $1}')
WT="${ROOT}_worktrees/$TICKET"
STATE_DIR="${ROOT}_worktrees/.pi-state"

# Default branch — explicit steps so we don't silently fall through to "".
BASE=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
[ -n "$BASE" ] || BASE=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null)
[ -n "$BASE" ] || BASE=main

# Machine state (PM, WT, BRANCH_EXISTED) — written by workspace-setup.sh in Phase 3.
# Sourcing is safe-if-absent; $PM is unavailable until Phase 3 has run.
# shellcheck disable=SC1090
[ -f "$STATE_DIR/$TICKET.env" ] && . "$STATE_DIR/$TICKET.env"

# Path to this skill's scripts (stable — ~/.pi/agent/skills is a symlink to the dotfiles copy).
SCRIPTS="$HOME/.pi/agent/skills/solve-ticket/scripts"
```

Use **uppercase** (`TECH-123`) for the `linear` tool. Use full `$WT/…` paths for Read/Write/Edit. Never write to the main repo.

## State files

Two files per ticket, both under `$STATE_DIR` (which lives at `${ROOT}_worktrees/.pi-state`, **outside** any worktree so git ignores them entirely):

- **`$TICKET.md`** — human/LLM-authored progress. Title, Plan, Current Phase, Notes, Peer Review log. Edited via the Write tool throughout. Template:

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

- **`$TICKET.env`** — machine state, owned by scripts. Shell-sourceable (`ROOT=`, `WT=`, `STATE_DIR=`, `PM=`, `BRANCH_EXISTED=`). Do **not** hand-edit; the preamble sources it.

## User Context

Text after the ticket ID (e.g. `solve TECH-123 - focus on mobile layout`) is **steering context**. It overrides/refines the ticket. Use it to focus Phase 1 investigation and shape the Phase 2 plan. Persist it in progress file Notes.

## Verification

1. `cd "$WT" && $PM run build` — fix type errors.
2. `cd "$WT" && $PM run lint` — fix lint errors.
3. `tmux capture-pane -p -t "$DEV_SESSION" -S -100` — check for runtime errors.

---

## Phase 1 — Understand

Run from the main worktree before creating any workspace.

1. **Sync default branch** — `git fetch origin "$BASE" && git pull origin "$BASE"` to ensure investigation is against the latest codebase.
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

**Wait for explicit approval.** Then proceed to Phase 3.

## Phase 3 — Workspace

Run `workspace-setup.sh`. It detects the package manager from `$ROOT`'s lockfile (pnpm > bun > yarn > npm, intentionally pnpm-first during multi-lockfile migrations), creates the worktree from `origin/$BASE`, symlinks env files, runs `$PM install`, and writes `$STATE_DIR/$TICKET.env`.

```bash
"$SCRIPTS/workspace-setup.sh" "$TICKET" "$BASE"
```

**Behaviour contract:** exit 0 success; 64 bad args; 66 no lockfile (skill doesn't fit); 70 git failure (fetch / worktree add); 73 install failure — recover by `cd "$WT" && $PM install` inline, then continue.

Re-source the env file so `$PM` becomes available in this block:

```bash
# shellcheck disable=SC1090
. "$STATE_DIR/$TICKET.env"
```

**Write the progress markdown** via the Write tool to `$STATE_DIR/$TICKET.md`. Use the template from **State files** above with:
- `# <TICKET_UPPER>: <actual title from Phase 1>`
- Plan section populated from the approved Phase 2 plan
- `## Current Phase` set to `Phase 3 — Workspace`

If the file already exists (resume path), leave it alone — see **Resuming Previous Work**.

**Start the dev server:**

```bash
"$SCRIPTS/dev-server.sh" "$TICKET" "$WT" "$PM"
```

**Behaviour contract:** matches `ready in|listening on|local: http` (Next.js, Vite, Express, Fastify); 30 polls × 1s; tails 30 lines on failure. Exit 0 ready or cleanly skipped (no `scripts.dev`); 64 bad args; 68 timeout; 69 session died.

Tell the user: `Dev server: tmux attach -t <ticket>-dev` (unless skipped).

## Phase 4 — Implement

Write code in the worktree. Follow AGENTS.md conventions.

Work incrementally — one concern at a time. Run the build step from **Verification** after each significant change. Monitor dev server via `tmux capture-pane -p -t "$DEV_SESSION" -S -50` and fix runtime errors immediately. If the dev framework auto-increments the port when taken (Next.js, Vite, etc.), note the actual URL from tmux output. On non-trivial errors, see **Constraints**.

Update progress file after each completed plan step.

## Phase 5 — Verify

Run the **Verification** procedure. Fix all errors before proceeding.

If the ticket involves UI changes, also verify visually using the **webapp-testing** skill. If verification requires risky or destructive operations, use the **sandbox** skill.

## Phase 6 — Peer Review

Spawn an independent `pi` sub-agent to review changes cold. Up to **2 rounds per session** — break early if a round produces no fixes.

**On entry, clear stale review files from prior sessions** (this keeps round counting per-session, not per-lifetime):

```bash
rm -f "$STATE_DIR/$TICKET"-review-*.md
```

**Each round:**

1. Spawn the reviewer:

```bash
"$SCRIPTS/peer-review-spawn.sh" "$TICKET" "$WT" "$STATE_DIR" "$BASE"
RC=$?
```

**Exit-code table:**

| rc    | meaning                                    | action                                          |
|-------|--------------------------------------------|-------------------------------------------------|
| 0     | review completed                           | read the output file, triage findings           |
| 124   | pi timed out (partial output preserved)    | note in progress file, continue to Phase 7      |
| 137   | pi killed (partial output preserved)       | note, continue to Phase 7                       |
| 70    | pi failed (crashed / auth / not on PATH)   | note, continue to Phase 7 — output unreliable   |
| 71    | 2-round cap reached                        | continue to Phase 7                             |
| 69    | `timeout`/`gtimeout` not installed         | stop and tell the user (install coreutils)      |

2. On `rc=0`, read the most recent `$STATE_DIR/$TICKET-review-*.md`. Triage each finding — **accept** (fix now) or **dismiss** with a one-line reason. Dismiss findings that suggest scope expansion, propose unrelated architectural changes, or conflict with ticket requirements.

3. Log in the progress file:

```markdown
## Peer Review — Round {n}
- ✅ <finding> → fixed
- ❌ <finding> — <reason>
```

4. Fix accepted items. If fixes were made, re-run **Verification** and loop to the next round. If no fixes (all dismissed or clean), break.

## Phase 7 — User Review

Present the final state:

```bash
cd "$WT" && git diff --stat && git ls-files --others --exclude-standard
```

Brief summary: what was built (one sentence per plan item), what peer review caught and what was fixed or dismissed.

**Wait for explicit approval before committing.**

## Phase 8 — Deliver

1. **Commit** — run the **commit** skill, stopping after step 3 (commits created). Its step 4 (push prompt + summary) and step 5 (PR description update) don't apply here — `create-pr` handles the push, and there's no PR yet to update.
2. **Draft PR** — follow the **create-pr** skill. Include `Closes TECH-123` in the body.
3. **Kill dev server:** `tmux kill-session -t "$DEV_SESSION" 2>/dev/null || true`
4. **Tell the user** how to clean up (do **not** remove it yourself):
   - Remove worktree only: `git worktree remove <path>`
   - Remove worktree and branch: `git worktree remove <path> && git branch -d tech-123`
   - Remove all state files: `rm -f "$STATE_DIR/$TICKET".md "$STATE_DIR/$TICKET".env "$STATE_DIR/$TICKET"-review-*.md`

After delivering the draft PR, the next invocation with the same ticket should follow **Resuming Previous Work**.

---

## Resuming Previous Work

If the worktree already exists:

1. Read `$STATE_DIR/$TICKET.md` — primary source of truth for plan, phase, notes.
   - If **missing** (state dir wiped, pre-existing worktree from before this skill version, or partial cleanup): tell the user the progress markdown is gone, ask whether to re-derive from git history or start fresh. The preamble's source of `$TICKET.env` still works if it survived; otherwise `$PM` will be unset until Phase 3 runs.
2. Check state: `git status`, `git log --oneline -5`, `tmux has-session -t "$DEV_SESSION"`.
3. Re-fetch ticket: `linear get_issue TECH-123` for new comments/scope changes.
4. **Do NOT re-run `workspace-setup.sh`.** It would re-run `$PM install` (slow, may mutate lockfile). The worktree is already set up. If the dev server isn't running, call `"$SCRIPTS/dev-server.sh" "$TICKET" "$WT" "$PM"` to restart it.
5. **Check for open PR** via `gh pr view`. If one exists → load **prepare-merge** (it has its own gate that decides whether there's anything to do). Otherwise → continue implementation at Phase 4.
6. Present resume summary: what's done, what's next, any notes. Ask: continue, or reset? (`git reset --hard "origin/$BASE"`)

## Constraints

- **Worktree only** — never modify the main repo after Phase 2.
- **Plan first** — no code without user approval.
- **Verify → peer review → user review before commit.**
- **No bare `git push`** — only via `gh pr create --draft`, or when the user explicitly asks. Follow the **gh-cli** skill for all GitHub operations.
- **One ticket, no scope creep** — related issues are noted, not implemented.
- **Non-trivial error → load systematic-debugging immediately.** Don't accumulate guess-and-fix attempts; systematic-debugging's Iron Law says no fixes without root cause. If systematic-debugging stalls, load **step-back** to question the approach. Only then escalate to the user.
- **Ambiguity → ask.**
