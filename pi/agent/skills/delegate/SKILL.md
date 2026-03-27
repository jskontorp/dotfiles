---
name: delegate
description: >-
  Decompose complex tasks into sub-tasks and dispatch each to an independent pi
  sub-agent. Tasks run in parallel when independent, sequentially when dependent.
  Use when the user says "delegate", "split this up", "run these in parallel",
  "fan out", or when a task naturally decomposes into independent workstreams
  (e.g. "review all five modules", "refactor these three services").
compatibility: Requires pi, tmux (recommended for parallel execution, falls back to sequential)
allowed-tools: Bash(pi:*) Bash(tmux:*) Bash(cat:*) Bash(mkdir:*) Bash(timeout:*) Bash(gtimeout:*) Bash(kill:*) Read Write Edit
---

# Delegate

Decompose a task into sub-tasks and dispatch each to an independent pi sub-agent.

All `scripts/` paths resolve relative to this skill's directory. Ensure they're executable:

```bash
chmod +x scripts/dispatch.sh scripts/poll.sh
```

## Shell Preamble

Shell state doesn't persist. **Every bash block must start with:**

```bash
DELEGATE_DIR=".pi-delegate"
RESULTS_DIR="$DELEGATE_DIR/results"
STATUS_FILE="$DELEGATE_DIR/status.json"
PLAN_FILE="$DELEGATE_DIR/plan.md"
SKILL_DIR="$(cd ~/.pi/agent/skills/delegate && pwd)"
```

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
**Model:** claude-sonnet-4-20250514 (inherited)
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

After approval, create the working directory:

```bash
mkdir -p "$RESULTS_DIR"

# Exclude from git (not .gitignore)
GIT_EXCLUDE="$(git rev-parse --git-path info/exclude 2>/dev/null)" || true
if [ -n "$GIT_EXCLUDE" ]; then
  mkdir -p "$(dirname "$GIT_EXCLUDE")"
  grep -Fqx '.pi-delegate/' "$GIT_EXCLUDE" 2>/dev/null || echo '.pi-delegate/' >> "$GIT_EXCLUDE"
fi
```

Write `plan.md` with the approved plan. Initialise `status.json`:

```json
[
  {"taskId": "task-1", "status": "pending", "exitCode": null, "duration": null},
  {"taskId": "task-2", "status": "pending", "exitCode": null, "duration": null}
]
```

### Resume check

If `$DELEGATE_DIR/plan.md` exists with incomplete tasks, **ask the user**: resume or start fresh?

To resume: read `status.json`, skip tasks with `"status": "completed"`, re-run `"failed"` or `"pending"` tasks.

## Phase 3 — Dispatch

Execute tasks in dependency order. Independent tasks (no unmet dependencies) run in parallel.

### Parallel execution (tmux available)

Check for tmux:

```bash
command -v tmux &>/dev/null && echo "tmux available" || echo "tmux unavailable"
```

If tmux is available, create a session for the parallel batch:

```bash
tmux kill-session -t pi-delegate 2>/dev/null || true
tmux new-session -d -s pi-delegate -n batch-1
```

For each task in a parallel batch (max 4 per window):

```bash
# First task gets the existing pane; subsequent tasks split
if [ "$PANE_INDEX" -eq 0 ]; then
  tmux send-keys -t pi-delegate:batch-1 "$SKILL_DIR/scripts/dispatch.sh TASK_ID TASK_DIR TASK_TIMEOUT TASK_PROMPT_FILE RESULTS_DIR TASK_MODEL TASK_TOOLS" Enter
else
  tmux split-window -t pi-delegate:batch-1 "$SKILL_DIR/scripts/dispatch.sh TASK_ID TASK_DIR TASK_TIMEOUT TASK_PROMPT_FILE RESULTS_DIR TASK_MODEL TASK_TOOLS"
  tmux select-layout -t pi-delegate:batch-1 tiled
fi
```

If a batch has >4 tasks, use additional windows (`batch-2`, etc.).

Tell the user: **`Watch live: tmux attach -t pi-delegate`**

### Sequential fallback (no tmux)

```bash
for each task in batch:
  "$SKILL_DIR/scripts/dispatch.sh" "$TASK_ID" "$TASK_DIR" "$TASK_TIMEOUT" "$PROMPT_FILE" "$RESULTS_DIR" "$TASK_MODEL" "$TASK_TOOLS" &
done
wait
```

### Prompt files

Write each task's prompt to a temp file before dispatch (prompts may be multi-line and contain special characters):

```bash
PROMPT_FILE="$DELEGATE_DIR/${TASK_ID}-prompt.txt"
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

Read all result files. Write `$DELEGATE_DIR/synthesis.md`:

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

After the user is done (or on explicit request):

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
