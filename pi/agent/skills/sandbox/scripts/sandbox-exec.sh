#!/usr/bin/env bash
set -euo pipefail

# sandbox-exec.sh — Run a command inside the sandbox, capture output
#
# Usage: sandbox-exec.sh "<command>" [--timeout SECONDS] [--name NAME]
#
# Uses a marker protocol: appends a unique marker + exit code after the command.
# Polls tmux capture-pane until the marker appears, then extracts output + exit code.
#
# --timeout 0  → fire and forget (returns immediately, use sandbox-capture.sh to poll)

COMMAND="${1:?Usage: sandbox-exec.sh \"<command>\" [--timeout SECONDS] [--name NAME]}"
shift

TIMEOUT=120
NAME="agent-sandbox"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --name)    NAME="$2";    shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

MARKER="__SANDBOX_DONE_$(date +%s%N)_$$__"

# Send command + marker to the tmux pane
# The marker echoes: __SANDBOX_DONE_xxx:EXIT_CODE__
tmux send-keys -t "$NAME" "$COMMAND; echo \"${MARKER}:\$?\"" Enter

# Fire and forget mode
if [[ "$TIMEOUT" == "0" ]]; then
  echo "(command sent, not waiting for completion)"
  exit 0
fi

# Poll for marker
ELAPSED=0
POLL_INTERVAL=0.5
OUTPUT=""

while true; do
  OUTPUT=$(tmux capture-pane -t "$NAME" -p -S -500 2>/dev/null || true)

  if echo "$OUTPUT" | grep -qF "$MARKER"; then
    break
  fi

  sleep "$POLL_INTERVAL"
  ELAPSED=$(echo "$ELAPSED + $POLL_INTERVAL" | bc)

  if (( $(echo "$ELAPSED >= $TIMEOUT" | bc -l) )); then
    echo "TIMEOUT after ${TIMEOUT}s. Command may still be running." >&2
    echo "Use sandbox-capture.sh to check output." >&2
    # Dump what we have so far
    echo "$OUTPUT"
    exit 124
  fi
done

# Extract output between the command and the marker
# Find the marker line and extract exit code
MARKER_LINE=$(echo "$OUTPUT" | grep -F "$MARKER" | tail -1)
EXIT_CODE=$(echo "$MARKER_LINE" | sed "s/.*${MARKER}:\([0-9]*\).*/\1/")

# Get everything between when we sent the command and the marker
# Strategy: find the line with our command, take everything after it until the marker
RESULT=$(echo "$OUTPUT" | sed -n "/$(echo "$COMMAND" | head -c 40 | sed 's/[[\.*^$()+?{|]/\\&/g')/,/${MARKER}/p" | head -n -1 | tail -n +2)

if [[ -n "$RESULT" ]]; then
  echo "$RESULT"
fi

echo "--- exit code: ${EXIT_CODE:-unknown} ---"
exit "${EXIT_CODE:-1}"
