#!/usr/bin/env bash
# watcher.sh — Watch a sub-agent's pi session JSONL until the turn completes,
# then extract the final assistant text into RESULT_FILE and send "/quit" to
# the tmux pane so pi exits cleanly.
#
# Usage: watcher.sh SESSION_DIR RESULT_FILE PANE_TARGET POLL_INTERVAL FILE_TIMEOUT MAX_WAIT
#
# Arguments:
#   SESSION_DIR    — directory pi was launched with --session-dir; watcher
#                    globs *.jsonl inside it.
#   RESULT_FILE    — file to append the extracted assistant text to.
#   PANE_TARGET    — tmux pane id (e.g. %42) or session:window.pane spec.
#                    Empty string disables the /quit nudge.
#   POLL_INTERVAL  — seconds between polls (default: 2).
#   FILE_TIMEOUT   — seconds to wait for the session file to appear before
#                    giving up (default: 30).
#   MAX_WAIT       — seconds to wait for terminal condition before giving up
#                    and sending /quit anyway (default: 1800). Prevents
#                    dispatch.sh's `wait "$WATCHER_PID"` from hanging when pi
#                    is killed externally before reaching a terminal stopReason.

set -uo pipefail

SESSION_DIR="${1:?Usage: watcher.sh SESSION_DIR RESULT_FILE PANE_TARGET [POLL_INTERVAL] [FILE_TIMEOUT] [MAX_WAIT]}"
RESULT_FILE="${2:?}"
PANE_TARGET="${3:-}"
POLL_INTERVAL="${4:-2}"
FILE_TIMEOUT="${5:-30}"
MAX_WAIT="${6:-1800}"

# Wait for a session file to appear under SESSION_DIR.
WAITED=0
SESSION_FILE=""
while [ "$WAITED" -lt "$FILE_TIMEOUT" ]; do
  # shellcheck disable=SC2012
  SESSION_FILE="$(ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -1 || true)"
  [ -n "$SESSION_FILE" ] && break
  sleep "$POLL_INTERVAL"
  WAITED=$((WAITED + POLL_INTERVAL))
done

if [ -z "$SESSION_FILE" ]; then
  echo "[watcher] no session file appeared in $SESSION_DIR within ${FILE_TIMEOUT}s" >> "$RESULT_FILE"
  exit 0
fi

# Wait until the last assistant message has a terminal stopReason and there
# are no orphan tool calls awaiting results. Canonical pi-ai StopReason set
# is "stop" | "length" | "toolUse" | "error" | "aborted". Anything other
# than "toolUse" is terminal for our purposes.
is_terminal() {
  jq -se '
    . as $all
    | ($all | map(select(.type=="message" and .message.role=="assistant")) | last) as $last_a
    | ($all | map(select(.type=="message" and .message.role=="assistant"))
            | map(.message.content // []) | flatten
            | map(select(.type=="toolCall") | .id)) as $calls
    | ($all | map(select(.type=="message" and .message.role=="toolResult"))
            | map(.message.toolCallId // empty)) as $results
    | (($last_a // {}) | .message.stopReason // "") as $r
    | ($r == "stop" or $r == "length" or $r == "error" or $r == "aborted")
      and (($calls - $results | length) == 0)
  ' "$1" 2>/dev/null | grep -q '^true$'
}

WAITED=0
TIMED_OUT=false
while ! is_terminal "$SESSION_FILE"; do
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    TIMED_OUT=true
    break
  fi
  sleep "$POLL_INTERVAL"
  WAITED=$((WAITED + POLL_INTERVAL))
done

if $TIMED_OUT; then
  echo "[watcher] terminal condition not reached within ${MAX_WAIT}s; sending /quit anyway" >> "$RESULT_FILE"
fi

# Extract the text content of the final assistant message and append to RESULT_FILE.
{
  jq -r --slurp '
    map(select(.type == "message" and .message.role == "assistant"))
    | last
    | .message.content // []
    | map(select(.type == "text") | .text)
    | join("\n")
  ' "$SESSION_FILE" 2>/dev/null || echo "[watcher] failed to extract assistant text from $SESSION_FILE"
} >> "$RESULT_FILE"

# Politely ask pi to shut down so dispatch.sh's foreground call returns.
# Retry: pi can be mid-render at terminal condition and drop the keystrokes
# (observed: triple-blind pane ate the first /quit during this skill's own
# self-review run). Bounded loop, exits early once the pane is gone.
if [ -n "$PANE_TARGET" ] && command -v tmux >/dev/null 2>&1; then
  for _ in 1 2 3 4 5 6; do
    tmux send-keys -t "$PANE_TARGET" '/quit' Enter 2>/dev/null || true
    sleep 1
    tmux list-panes -t "$PANE_TARGET" >/dev/null 2>&1 || break
  done
fi
