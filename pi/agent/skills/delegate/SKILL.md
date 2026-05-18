---
name: delegate
description: >-
  Decompose complex tasks into sub-tasks and dispatch each to an independent pi
  sub-agent. Tasks run in parallel when independent, sequentially when dependent.
  Use when the user says "delegate", "split this up", "run these in parallel",
  "fan out", or when a task naturally decomposes into independent workstreams
  (e.g. "review all five modules", "refactor these three services").
compatibility: Requires pi, tmux (recommended for parallel execution, falls back to sequential), jq (required for live TUI mode — falls back to headless capture without it)
allowed-tools: Bash(pi:*) Bash(tmux:*) Bash(cat:*) Bash(mkdir:*) Bash(timeout:*) Bash(gtimeout:*) Bash(kill:*) Bash(sed:*) Bash(sort:*) Bash(tail:*) Read Write Edit
claude-compatible: false
---

# Delegate

Decompose a task into sub-tasks and dispatch each to an independent pi sub-agent.

All `scripts/` paths resolve relative to this skill's directory. Ensure they're executable:

```bash
chmod +x scripts/dispatch.sh scripts/poll.sh scripts/watcher.sh
```

## Shell Preamble

Shell state doesn't persist. **Every bash block must start with:**

```bash
DELEGATE_DIR=".pi-delegate"
BATCH_DIR="$DELEGATE_DIR/$BATCH"        # set after Phase 2 allocation
RESULTS_DIR="$BATCH_DIR/results"
STATUS_FILE="$BATCH_DIR/status.json"
PLAN_FILE="$BATCH_DIR/plan.md"
SKILL_DIR="$(cd ~/.pi/agent/skills/delegate && pwd)"
```

Orchestration outputs (plan, status, prompts, results, sessions, synthesis)
live under `$BATCH_DIR`. Inputs authored by the user (e.g. `proposal.md` for
`triple-review`) stay at `$DELEGATE_DIR` top-level so they're re-usable across
runs. `$BATCH` is allocated in Phase 2 via the shared atomic-`mkdir` idiom and
is **independent** of the tmux window name (`$TMUX_BATCH`, allocated in Phase
3) — the two namespaces have different lifetimes (tmux session is per-machine,
`.pi-delegate/` is per-cwd) and coupling them produces duplicate tmux window
names cross-cwd.

## Phase 1 — Decompose

Analyse the user's request. Produce a task list. Each task needs:

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Short identifier: `task-1`, `task-2`, etc. |
| `description` | yes | One-line summary |
| `cwd` | no | Working directory (default: current project root) |
| `files` | no | Files to include as context — listed as `@path/to/file` in the prompt |
| `prompt` | yes | Self-contained natural-language prompt for the sub-agent |
| `depends` | no | List of task IDs that must complete first |
| `model` | no | Sub-agent model override |
| `tools` | no | Tool restriction (e.g. `"read,bash"`) |
| `timeout` | no | Seconds (default: 300) |

Present the plan as a table:

```
### Delegation Plan

| ID | Description | Depends | Timeout | Tools |
|----|-------------|---------|---------|-------|
| task-1 | Analyse auth module | — | 300s | read |
| task-2 | Analyse API module | — | 300s | read |
| task-3 | Synthesise findings | task-1, task-2 | 300s | read |

**Sub-agents:** 3 (2 parallel + 1 sequential)
**Model:** (inherited from parent agent)
**Estimated cost:** ~3 sub-agent invocations

Proceed?
```

**Wait for explicit user approval.** Do not spawn anything without it.

### Prompt construction

Each sub-agent prompt must be **self-contained**. Include:
- The specific task objective (one paragraph)
- Relevant file paths to read (as `@file` references embedded in the prompt text)
- Output format expectations
- Any constraints from the user's original request

Do NOT include: the full conversation history, other tasks' descriptions, or the delegation plan itself. The sub-agent knows nothing about the orchestration.

## Phase 2 — Setup

After approval, allocate a fresh batch directory under `.pi-delegate/`. Atomic
`mkdir` (no `-p`) with retry-on-collision is the concurrency primitive — two
racing orchestrators in the same cwd both see e.g. `N=2`, only one of their
`mkdir batch-3` calls succeeds, the loser re-reads and tries `batch-4`.

```bash
mkdir -p "$DELEGATE_DIR"

# Allocate next free batch dir. The 2>/dev/null on `ls` is load-bearing —
# without nullglob set, no-match would emit a literal `batch-*`.
while true; do
  N=$(ls -1d "$DELEGATE_DIR"/batch-* 2>/dev/null | sed -E 's|.*/batch-||' | sort -n | tail -1)
  BATCH="batch-$(( ${N:-0} + 1 ))"
  mkdir "$DELEGATE_DIR/$BATCH" 2>/dev/null && break
done
BATCH_DIR="$DELEGATE_DIR/$BATCH"
RESULTS_DIR="$BATCH_DIR/results"
STATUS_FILE="$BATCH_DIR/status.json"
PLAN_FILE="$BATCH_DIR/plan.md"
mkdir -p "$RESULTS_DIR"

# Exclude from git (not .gitignore)
GIT_EXCLUDE="$(git rev-parse --git-path info/exclude 2>/dev/null)" || true
if [ -n "$GIT_EXCLUDE" ]; then
  mkdir -p "$(dirname "$GIT_EXCLUDE")"
  grep -Fqx '.pi-delegate/' "$GIT_EXCLUDE" 2>/dev/null || echo '.pi-delegate/' >> "$GIT_EXCLUDE"
fi
```

Write `$PLAN_FILE` with the approved plan. Initialise `$STATUS_FILE`:

```json
[
  {"taskId": "task-1", "status": "pending", "exitCode": null, "duration": null},
  {"taskId": "task-2", "status": "pending", "exitCode": null, "duration": null}
]
```

### Resume check

Before allocating a new batch, scan `$DELEGATE_DIR/batch-*/plan.md` for
incomplete runs and **ask the user**: resume one, or start fresh?

```bash
for d in $(ls -1d "$DELEGATE_DIR"/batch-* 2>/dev/null \
            | sed -E 's|.*/batch-||' | sort -n | sed -E "s|^|$DELEGATE_DIR/batch-|"); do
  [ -f "$d/plan.md" ] || continue
  # Surface $(basename $d) plus any non-completed task IDs from $d/status.json
done
```

To resume: skip the allocation block above, set `BATCH=batch-<chosen>` and
`BATCH_DIR="$DELEGATE_DIR/$BATCH"`, read `$STATUS_FILE`, skip tasks with
`"status": "completed"`, re-run `"failed"` or `"pending"` tasks.

Default to **start a new batch** — resume is opt-in.

### Migration note

If `$DELEGATE_DIR/{plan.md,status.json,results,*-prompt.txt}` exists at the
top level from a pre-batch version of this skill, leave it in place — the new
code path doesn't read it. Ask the user before removing it; don't `rm` it
autonomously.

## Phase 3 — Dispatch

Execute tasks in dependency order. Independent tasks (no unmet dependencies) run in parallel.

### Parallel execution (tmux available)

Check for tmux:

```bash
command -v tmux &>/dev/null && echo "tmux available" || echo "tmux unavailable"
```

If tmux is available, reuse the `pi-delegate` session if one already exists
(another delegate or `triple-review` batch may be in flight) and pick the
next free `batch-N` **window** name so we don't clobber a parallel agent's
panes. Use `sed -E` for BSD/macOS portability — BRE `\+` is not supported
there.

This probe is **independent** of the FS batch ID allocated in Phase 2.
Don't reuse `$BATCH` as the tmux window name — across two different cwds,
the FS side allocates `batch-1` twice (each `.pi-delegate/` is fresh) while
the tmux session must keep window names unique. Allocate them separately.

```bash
if tmux has-session -t pi-delegate 2>/dev/null; then
  N=$(tmux list-windows -t pi-delegate -F '#{window_name}' 2>/dev/null \
      | sed -E -n 's/^batch-([0-9]+).*$/\1/p' | sort -n | tail -1)
  TMUX_BATCH="batch-$(( ${N:-0} + 1 ))"
  tmux new-window -t pi-delegate -n "$TMUX_BATCH"
else
  TMUX_BATCH="batch-1"
  tmux new-session -d -s pi-delegate -n "$TMUX_BATCH"
fi
```

For each task in a parallel batch (max 4 per window):

```bash
# First task gets the existing pane; subsequent tasks split
if [ "$PANE_INDEX" -eq 0 ]; then
  tmux send-keys -t "pi-delegate:$TMUX_BATCH" "$SKILL_DIR/scripts/dispatch.sh TASK_ID TASK_DIR TASK_TIMEOUT TASK_PROMPT_FILE RESULTS_DIR TASK_MODEL TASK_TOOLS" Enter
else
  tmux split-window -t "pi-delegate:$TMUX_BATCH" "$SKILL_DIR/scripts/dispatch.sh TASK_ID TASK_DIR TASK_TIMEOUT TASK_PROMPT_FILE RESULTS_DIR TASK_MODEL TASK_TOOLS"
  tmux select-layout -t "pi-delegate:$TMUX_BATCH" tiled
fi
```

If a batch has >4 tasks, use additional windows — the same `has-session` +
`batch-N` increment naturally produces them.

Each pane runs `dispatch.sh`, which (when tmux **and** `jq` are present,
**and** the tmux session has an attached client, **and** the pane is at
least `DELEGATE_MIN_PANE_HEIGHT` rows tall — default 20) launches the
sub-agent in **pi TUI mode** — full live view of tool calls, thinking, and
streamed output. A background watcher polls the session JSONL; when the
assistant's last message reaches a terminal `stopReason`
(`stop`/`length`/`error`/`aborted`) and no tool calls are pending, it
extracts the final assistant text into `$RESULTS_DIR/${TASK_ID}.md` and
sends `/quit` to the pane so pi shuts down cleanly. Sub-agent sessions
persist under `$DELEGATE_DIR/sessions/${TASK_ID}/` for post-hoc inspection
(`pi --resume` or `--export`).

If any TUI precondition fails, dispatch falls through to the headless
`pi -p` path (see "Headless orchestration" below). This gating was added
after the odev:4.1 (2026-05-18) failure mode — a detached `pi-delegate`
session with sub-20-row panes silently breaks pi's first-render, leaves
the watcher with no JSONL to read, and hangs dispatch until the outer
`timeout` fires. The gate trips pre-render and routes through headless
instead. **Interactive caveat:** a user who runs delegate from a detached
session and `tmux attach`es a few seconds later will still get headless
for the whole run, because the gate is evaluated once at dispatch time.
Attach **first**, then dispatch, for live TUI viewing.

**RESULT_FILE shape differs by branch.** Headless (`pi -p | tee`) captures
everything pi prints; TUI mode captures only the final assistant message's
text content (tool calls, thinking blocks, intermediate messages live in
the session JSONL, not in `$RESULTS_DIR/${TASK_ID}.md`). For consumers
that need the full transcript, read `$DELEGATE_DIR/sessions/${TASK_ID}/`.
The watcher caps its wait at `TIMEOUT + 30s` so dispatch.sh's `wait` never
hangs on an externally killed pi. If the watcher gives up (no session
file within 30s, or no terminal stopReason within `TIMEOUT + 30s`), it
SIGTERMs the pi process and touches a `.watcher-killed` marker that
dispatch.sh translates into exit code `124` — the same code poll.sh would
have seen had the outer `timeout` fired, so the status classification
(`"timeout"`) is consistent across both paths.

Tell the user, printing both names explicitly (no claim of equality):

```
Watch live: tmux attach -t pi-delegate \; select-window -t pi-delegate:$TMUX_BATCH
FS outputs: $BATCH_DIR/
```

### Sequential fallback (no tmux)

```bash
for each task in batch:
  # Redirect stdout/stderr so backgrounded dispatch.sh processes don't
  # interleave their tee output into the orchestrator's terminal — the
  # full transcript is already captured in $RESULTS_DIR/${TASK_ID}.md.
  "$SKILL_DIR/scripts/dispatch.sh" "$TASK_ID" "$TASK_DIR" "$TASK_TIMEOUT" "$PROMPT_FILE" "$RESULTS_DIR" "$TASK_MODEL" "$TASK_TOOLS" >/dev/null 2>&1 &
done
wait
```

### Headless orchestration (CI / VM / no human attaching)

When the orchestrator is running somewhere no human will attach to the
`pi-delegate` tmux session — CI, a VM driven over SSH, a batch job, the
parent agent's own non-interactive shell — skip the tmux session entirely
and background dispatch directly:

```bash
for i in $(seq 1 N); do
  TASK_ID="task-$i"
  PROMPT_FILE="$BATCH_DIR/${TASK_ID}-prompt.txt"
  "$SKILL_DIR/scripts/dispatch.sh" "$TASK_ID" "$TASK_DIR" "$TIMEOUT" "$PROMPT_FILE" "$RESULTS_DIR" "" "" >/dev/null 2>&1 &
done
# (poll.sh below)
```

If `TMUX_PANE` is set in the parent shell (e.g. you're inside a tmux
pane but want headless mode anyway), the TUI gate will refuse TUI mode
automatically when the pane geometry or attached-client check fails —
you don't need to `unset TMUX_PANE`. The gate is the contract; explicit
`unset` is no longer necessary.

Align `poll.sh`'s `MAX_WAIT` with the per-task timeout instead of using a
flat budget. The per-task `TIMEOUT` is the longest a single task can
run; tasks run in parallel, so `MAX_WAIT = TIMEOUT + 60s` slack covers
the slowest task plus dispatch.sh's post-wait bookkeeping:

```bash
"$SKILL_DIR/scripts/poll.sh" "$RESULTS_DIR" "$STATUS_FILE" "$TASK_IDS" 5 $(( TIMEOUT + 60 ))
```

This is the pattern used as the recovery path on the odev:4.1 failure —
it's now the documented mode, not a workaround.

### Prompt files

Write each task's prompt to a temp file under `$BATCH_DIR` before dispatch
(prompts may be multi-line and contain special characters):

```bash
PROMPT_FILE="$BATCH_DIR/${TASK_ID}-prompt.txt"
# Write prompt via the Write tool, then pass path to dispatch.sh
```

### Dependency chains

After each batch completes, check which pending tasks now have all dependencies met. Form the next batch from those. Repeat until all tasks are dispatched or have failed dependencies.

If a task's dependency failed, mark the dependent task as `"status": "dep-failed"` and skip it.

## Phase 4 — Collect

Poll for completion after dispatching each batch:

```bash
"$SKILL_DIR/scripts/poll.sh" "$RESULTS_DIR" "$STATUS_FILE" "task-1,task-2,task-3"
```

The poll script checks for result files and exit code markers. Default poll interval: 5s. Default timeout: per-task timeout from the plan.

After polling confirms completion (or timeout), update `status.json` for each task.

Read each result file:

```bash
cat "$RESULTS_DIR/task-1.md"
```

If a task timed out, `status.json` shows `"status": "timeout"`. The result file may be partial — read it anyway.

## Phase 5 — Synthesise

Read all result files. Write `$BATCH_DIR/synthesis.md`:

```markdown
# Delegation Results

## Summary
- **Completed:** 4/5 tasks
- **Failed:** 1 (task-3: timeout after 300s)

## task-1: Analyse auth module
**Status:** ✅ completed (42s)
[key findings from result file]

## task-2: Analyse API module
**Status:** ✅ completed (38s)
[key findings from result file]

## task-3: Run integration tests
**Status:** ❌ timeout (300s)
[partial output if available]

## Conflicts / Issues
- [any contradictions between sub-agent findings]

## Recommended next steps
- [based on the combined results]
```

Present the synthesis to the user. Include:
- Which tasks succeeded, which failed
- Key findings from each task (don't just dump raw output — extract the substance)
- Conflicts between findings
- Recommended actions

## Phase 6 — Act

After the user reviews the synthesis, they may:

1. **Apply** — implement approved changes from the results
2. **Re-run** — re-dispatch failed tasks with adjusted prompts (loop back to Phase 3 for those tasks only)
3. **Discard** — drop everything

### Clean up

Default cleanup acts on **this batch only** so concurrent runs aren't
clobbered:

```bash
tmux kill-window -t "pi-delegate:$TMUX_BATCH" 2>/dev/null || true
rm -rf "$BATCH_DIR"
# If $BATCH_DIR was the last one and the user wants the dir gone:
# rmdir "$DELEGATE_DIR" 2>/dev/null || true
```

"Clean everything" (whole `.pi-delegate/` + whole tmux session) is opt-in
and only on explicit request:

```bash
tmux kill-session -t pi-delegate 2>/dev/null || true
rm -rf "$DELEGATE_DIR"
```

Only clean up when the user says so or approves it. Don't auto-delete.

## Constraints

- **Plan first, spawn never.** No sub-agents without user approval.
- **Isolation.** Sub-agents don't share sessions or state. Each gets `--no-session`. Communication is only through result files.
- **No recursive delegation.** Sub-agents must not use the delegate skill. Always pass `--no-skills` to sub-agents.
- **Timeout is mandatory.** Every sub-agent gets a timeout. Default 300s. Kill and report, never hang.
- **Fail gracefully.** A failed sub-agent doesn't abort the batch. Collect what succeeded, report what failed.
- **Minimal context.** Each prompt is self-contained. Don't dump conversation history.
- **Cost awareness.** Before dispatching, state the count and model. Get approval.
- **Clean up.** Offer to remove `.pi-delegate/` and kill tmux when done.

## Examples

**Parallel code review:** "Review each of these 5 modules for security issues" → 5 sub-agents, each scoped to one module, tools restricted to `read`.

**Research fan-out:** "Investigate three approaches to caching" → 3 sub-agents each researching one approach, synthesis merges into a comparison table.

**Sequential pipeline:** "Extract API schema, then generate types, then write tests" → 3 tasks with `depends` chains, executed in order.

**Mixed:** "Refactor auth and update docs" → 2 independent tasks in parallel, then a dependent "verify consistency" task.
