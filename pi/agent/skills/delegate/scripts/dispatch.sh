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

# Build pi command
PI_CMD=(pi -p --no-session --no-skills)
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
"${TIMEOUT_CMD[@]}" "${PI_CMD[@]}" >> "$RESULT_FILE" 2>&1
EXIT_CODE=$?

# Record exit code
echo "$EXIT_CODE" > "$EXIT_FILE"

# Append footer
echo "" >> "$RESULT_FILE"
echo "---" >> "$RESULT_FILE"
echo "Exit code: $EXIT_CODE" >> "$RESULT_FILE"
echo "Finished: $(date -Iseconds)" >> "$RESULT_FILE"

exit $EXIT_CODE
