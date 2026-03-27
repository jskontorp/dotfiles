#!/usr/bin/env bash
# poll.sh — Poll for sub-agent completion.
# Returns JSON status for each task.
#
# Usage: poll.sh RESULTS_DIR STATUS_FILE TASK_IDS [POLL_INTERVAL] [MAX_WAIT]
#
# Arguments:
#   RESULTS_DIR    — directory containing result and exit files
#   STATUS_FILE    — path to status.json to update
#   TASK_IDS       — comma-separated task IDs to poll
#   POLL_INTERVAL  — seconds between polls (default: 5)
#   MAX_WAIT       — max seconds to wait total (default: 600)

set -euo pipefail

RESULTS_DIR="${1:?Usage: poll.sh RESULTS_DIR STATUS_FILE TASK_IDS [POLL_INTERVAL] [MAX_WAIT]}"
STATUS_FILE="${2:?}"
TASK_IDS="${3:?}"
POLL_INTERVAL="${4:-5}"
MAX_WAIT="${5:-600}"

IFS=',' read -ra TASKS <<< "$TASK_IDS"

ELAPSED=0

while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  ALL_DONE=true

  for TASK_ID in "${TASKS[@]}"; do
    EXIT_FILE="$RESULTS_DIR/${TASK_ID}.exit"
    if [ ! -f "$EXIT_FILE" ]; then
      ALL_DONE=false
    fi
  done

  if $ALL_DONE; then
    break
  fi

  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

# Build status output
echo "["
FIRST=true
for TASK_ID in "${TASKS[@]}"; do
  EXIT_FILE="$RESULTS_DIR/${TASK_ID}.exit"
  START_FILE="$RESULTS_DIR/${TASK_ID}.start"
  RESULT_FILE="$RESULTS_DIR/${TASK_ID}.md"

  $FIRST || echo ","
  FIRST=false

  if [ -f "$EXIT_FILE" ]; then
    EXIT_CODE=$(cat "$EXIT_FILE")
    DURATION="null"
    if [ -f "$START_FILE" ]; then
      START_TS=$(cat "$START_FILE")
      NOW_TS=$(date +%s)
      DURATION=$((NOW_TS - START_TS))
    fi
    if [ "$EXIT_CODE" -eq 0 ]; then
      STATUS="completed"
    elif [ "$EXIT_CODE" -eq 124 ] || [ "$EXIT_CODE" -eq 137 ]; then
      STATUS="timeout"
    else
      STATUS="failed"
    fi
  else
    EXIT_CODE="null"
    DURATION="null"
    STATUS="timeout"
  fi

  HAS_RESULT="false"
  [ -f "$RESULT_FILE" ] && HAS_RESULT="true"

  printf '  {"taskId": "%s", "status": "%s", "exitCode": %s, "duration": %s, "hasResult": %s}' \
    "$TASK_ID" "$STATUS" "$EXIT_CODE" "$DURATION" "$HAS_RESULT"
done
echo ""
echo "]"
