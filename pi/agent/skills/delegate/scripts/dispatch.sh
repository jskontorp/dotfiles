#!/usr/bin/env bash
# dispatch.sh — Spawn a single pi sub-agent for one task.
# Called by the delegate skill orchestrator.
#
# Usage: dispatch.sh TASK_ID TASK_DIR TIMEOUT PROMPT_FILE RESULTS_DIR [MODEL] [TOOLS]
#
# Arguments:
#   TASK_ID      — task identifier (e.g. "task-1")
#   TASK_DIR     — working directory for the sub-agent
#   TIMEOUT      — max seconds (0 = no timeout)
#   PROMPT_FILE  — path to file containing the prompt
#   RESULTS_DIR  — directory for result files
#   MODEL        — (optional) model override
#   TOOLS        — (optional) tool restriction (comma-separated)

set -eo pipefail

TASK_ID="${1:?Usage: dispatch.sh TASK_ID TASK_DIR TIMEOUT PROMPT_FILE RESULTS_DIR [MODEL] [TOOLS]}"
TASK_DIR="${2:?}"
TIMEOUT="${3:-300}"
PROMPT_FILE="${4:?}"
RESULTS_DIR="${5:?}"
TASK_MODEL="${6:-}"
TASK_TOOLS="${7:-}"

RESULT_FILE="$RESULTS_DIR/${TASK_ID}.md"
EXIT_FILE="$RESULTS_DIR/${TASK_ID}.exit"
START_FILE="$RESULTS_DIR/${TASK_ID}.start"
SESSION_DIR="$RESULTS_DIR/../sessions/${TASK_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read prompt from file
if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE" > "$RESULT_FILE"
  echo "1" > "$EXIT_FILE"
  exit 1
fi
TASK_PROMPT="$(cat "$PROMPT_FILE")"

# Record start time
date +%s > "$START_FILE"

# Build timeout command
TIMEOUT_CMD=()
if [ "$TIMEOUT" -gt 0 ] 2>/dev/null; then
  if command -v timeout &>/dev/null; then
    TIMEOUT_CMD=(timeout "$TIMEOUT")
  elif command -v gtimeout &>/dev/null; then
    TIMEOUT_CMD=(gtimeout "$TIMEOUT")
  fi
fi

# Build pi command. In tmux + with jq available, run pi in TUI mode so the
# pane shows the live agent (tool calls, thinking, streamed output). A
# background watcher polls the session JSONL for turn completion, extracts
# the final assistant text into RESULT_FILE, and sends "/quit" to the pane
# so pi exits cleanly. Outside tmux (sequential fallback), or when jq is
# missing, fall back to `pi -p` so the existing capture path still works.
USE_TUI=false
if [ -n "${TMUX_PANE:-}" ] && command -v jq >/dev/null 2>&1; then
  USE_TUI=true
fi

PI_CMD=(pi)
if $USE_TUI; then
  mkdir -p "$SESSION_DIR"
  PI_CMD+=(--session-dir "$SESSION_DIR" --no-skills)
else
  PI_CMD+=(-p --no-session --no-skills)
fi
[ -n "$TASK_MODEL" ] && PI_CMD+=(--model "$TASK_MODEL")
[ -n "$TASK_TOOLS" ] && PI_CMD+=(--tools "$TASK_TOOLS")
PI_CMD+=("$TASK_PROMPT")

# Run
echo "=== Delegate: $TASK_ID ===" > "$RESULT_FILE"
echo "Started: $(date -Iseconds)" >> "$RESULT_FILE"
echo "Directory: $TASK_DIR" >> "$RESULT_FILE"
echo "---" >> "$RESULT_FILE"
echo "" >> "$RESULT_FILE"

cd "$TASK_DIR"

if $USE_TUI; then
  # Label the pane so `tmux attach -t pi-delegate` is self-explanatory.
  PANE_TITLE="$TASK_ID"
  [ -n "$TASK_MODEL" ] && PANE_TITLE="$PANE_TITLE · $TASK_MODEL"
  tmux select-pane -t "$TMUX_PANE" -T "$PANE_TITLE" 2>/dev/null || true

  # Background watcher: detects turn completion in the session JSONL,
  # extracts the final assistant text into RESULT_FILE, and sends /quit
  # to this pane so pi exits and returns control to dispatch.sh. Pass
  # MAX_WAIT = TIMEOUT + 30 so the watcher can't outlive an externally
  # killed pi (would otherwise leave dispatch.sh blocked on `wait`).
  WATCHER_MAX_WAIT=$(( TIMEOUT > 0 ? TIMEOUT + 30 : 1800 ))
  "$SCRIPT_DIR/watcher.sh" "$SESSION_DIR" "$RESULT_FILE" "$TMUX_PANE" 2 30 "$WATCHER_MAX_WAIT" &
  WATCHER_PID=$!

  # Run pi in TUI mode in the foreground (fills the pane).
  EXIT_CODE=0
  "${TIMEOUT_CMD[@]}" "${PI_CMD[@]}" || EXIT_CODE=$?

  # Reap watcher (it should already have exited after sending /quit).
  wait "$WATCHER_PID" 2>/dev/null || true
else
  # Tee output so a `tmux attach -t pi-delegate` pane shows live progress
  # while still capturing everything to the result file. Use PIPESTATUS so
  # pipefail doesn't mask the sub-agent's exit code with tee's, and `|| true`
  # so a non-zero sub-agent exit doesn't trigger `set -e` before we record it.
  # (Sequential fallback callers should redirect dispatch.sh's stdout to avoid
  # interleaving multiple sub-agents into the orchestrator's terminal.)
  "${TIMEOUT_CMD[@]}" "${PI_CMD[@]}" 2>&1 | tee -a "$RESULT_FILE" || true
  EXIT_CODE=${PIPESTATUS[0]}
fi

# Record exit code
echo "$EXIT_CODE" > "$EXIT_FILE"

# Append footer
echo "" >> "$RESULT_FILE"
echo "---" >> "$RESULT_FILE"
echo "Exit code: $EXIT_CODE" >> "$RESULT_FILE"
echo "Finished: $(date -Iseconds)" >> "$RESULT_FILE"

exit $EXIT_CODE
