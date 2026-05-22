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

# Build pi command. In tmux + with jq available + a viable pane geometry,
# run pi in TUI mode so the pane shows the live agent (tool calls, thinking,
# streamed output). A background watcher polls the session JSONL for turn
# completion, extracts the final assistant text into RESULT_FILE, and sends
# "/quit" to the pane so pi exits cleanly. Outside tmux (sequential
# fallback), when jq is missing, OR when the pane isn't viable for the TUI
# (detached session, sub-minimum height), fall back to `pi -p` so the
# existing capture path still works.
#
# Viability gate added 2026-05-18 after odev:4.1: detached `pi-delegate`
# sessions with sub-20-row panes silently break pi's TUI first-render, so
# the watcher never sees a session file and dispatch hangs. The gate trips
# pre-render and routes through headless instead. DELEGATE_MIN_PANE_HEIGHT
# is overridable but the 20-row default reflects observed first-render
# behaviour; lower at your own risk.
#
# tty guard added 2026-05-22 after oracle/odev incident: when an
# orchestrator backgrounds dispatch.sh from within its own attached tmux
# pane (the documented "Headless orchestration" recipe), $TMUX_PANE is
# inherited and the attached/height checks pass — but the pane is the
# *orchestrator's*, not a fresh sub-agent pane. TUI mode then collides on
# the orchestrator's tty (parent pi dies) and the watcher's /quit nudge
# lands in whatever shell takes over that pane (zsh, post-crash). Refuse
# TUI whenever stdout isn't a tty — every documented headless / sequential
# recipe redirects stdout to /dev/null, so this only suppresses TUI in
# exactly the cases that never wanted it. DELEGATE_ASSUME_TTY=1 is a
# test-only seam (tui-gate.test.sh captures stdout to a log) and must not
# be set in production callers; production dispatch always inherits a tty
# from `tmux send-keys` execution.
USE_TUI=false
if { [ -t 1 ] || [ "${DELEGATE_ASSUME_TTY:-0}" = "1" ]; } && [ -n "${TMUX_PANE:-}" ] && command -v jq >/dev/null 2>&1; then
  ATTACHED=$(tmux display -p -t "$TMUX_PANE" '#{session_attached}' 2>/dev/null || echo 0)
  HEIGHT=$(tmux display -p -t "$TMUX_PANE" '#{pane_height}' 2>/dev/null || echo 0)
  MIN_HEIGHT="${DELEGATE_MIN_PANE_HEIGHT:-20}"
  if [ "${ATTACHED:-0}" -gt 0 ] 2>/dev/null && [ "${HEIGHT:-0}" -ge "$MIN_HEIGHT" ] 2>/dev/null; then
    USE_TUI=true
  fi
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

  # Background pi first so we can hand its PID to the watcher. The watcher
  # SIGTERMs this PID on file-timeout / MAX_WAIT and touches a
  # "${RESULT_FILE%.md}.watcher-killed" marker; we re-classify the resulting
  # exit to 124 ("timeout") below so poll.sh sees consistent semantics with
  # pre-fix behaviour (where the outer `timeout` fired and produced the
  # same status).
  #
  # Note on PID semantics: when TIMEOUT_CMD is non-empty (the default), $!
  # is the `timeout` wrapper's PID, not pi's. SIGTERM to `timeout` is
  # forwarded to pi by coreutils — sufficient for the symptom we're fixing.
  # If pi spawns long-lived children that survive their parent, those
  # become orphans; not observed in this skill's workload, document if it
  # appears.
  "${TIMEOUT_CMD[@]}" "${PI_CMD[@]}" &
  PI_PID=$!

  # Background watcher: detects turn completion in the session JSONL,
  # extracts the final assistant text into RESULT_FILE, and sends /quit
  # to this pane so pi exits and returns control to dispatch.sh. Pass
  # MAX_WAIT = TIMEOUT + 30 so the watcher can't outlive an externally
  # killed pi (would otherwise leave dispatch.sh blocked on `wait`).
  WATCHER_MAX_WAIT=$(( TIMEOUT > 0 ? TIMEOUT + 30 : 1800 ))
  "$SCRIPT_DIR/watcher.sh" "$SESSION_DIR" "$RESULT_FILE" "$TMUX_PANE" 2 30 "$WATCHER_MAX_WAIT" "$PI_PID" &
  WATCHER_PID=$!

  EXIT_CODE=0
  wait "$PI_PID" || EXIT_CODE=$?

  # Reap watcher (it should already have exited after sending /quit or
  # killing pi).
  wait "$WATCHER_PID" 2>/dev/null || true

  # If the watcher killed pi (file-timeout or MAX_WAIT), normalise the exit
  # code to 124 so poll.sh classifies this as "timeout" — matches the
  # pre-fix behaviour where the outer `timeout` fired with the same code.
  KILLED_MARKER="${RESULT_FILE%.md}.watcher-killed"
  if [ -f "$KILLED_MARKER" ]; then
    EXIT_CODE=124
  fi
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
