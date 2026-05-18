#!/usr/bin/env bash
# Regression test for the odev:4.1 (2026-05-18) failure mode.
#
# Scenario: a detached pi-delegate tmux session is created with 4 panes
# (sub-20-row geometry), and dispatch.sh is invoked in each. Pre-fix, pi's
# TUI would never first-render and the watcher's silent-exit would leave
# dispatch hanging until the outer `timeout 900` fired. Post-fix:
#   - the TUI gate (commit B) sees session_attached=0 and falls through to
#     headless `pi -p` before pi is launched, so the geometry never matters.
#
# This test exercises the realistic orchestrator pattern (`tmux new-session
# -d` → 3× split-window → 4× dispatch.sh in panes) and asserts all four
# tasks complete with .exit=0 within 30s, no straggler shims.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/../scripts/dispatch.sh"
SHIM_DIR="$SCRIPT_DIR/fixtures"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP regression-odev-4-1.test.sh — jq not installed"
  exit 0
fi
if ! command -v tmux >/dev/null 2>&1; then
  echo "SKIP regression-odev-4-1.test.sh — tmux not installed"
  exit 0
fi

TMP="$(mktemp -d)"
SESSION="delegate-test-$$"
cleanup() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  rm -rf "$TMP"
  pkill -P $$ 2>/dev/null || true
}
trap cleanup EXIT

BIN="$TMP/bin"
mkdir -p "$BIN"
ln -s "$SHIM_DIR/pi-shim.sh" "$BIN/pi"
chmod +x "$SHIM_DIR/pi-shim.sh"

RESULTS="$TMP/results"
mkdir -p "$RESULTS"
echo "prompt" > "$TMP/prompt.txt"

# Per-task argv files; pi-shim writes one each.
export PI_SHIM_MODE="exit0"

# Sanity: tmux new-session must inherit PATH so panes find the `pi` shim.
PATH_FOR_PANES="$BIN:$PATH"

# Detached session, sub-20-row geometry — the exact odev:4.1 conditions.
tmux new-session -d -s "$SESSION" -x 80 -y 24 -n batch
# Layout will be tiled 4-way (~80×6 panes), reproducing the original failure
# geometry. Split 3 times.
for _ in 1 2 3; do
  tmux split-window -t "$SESSION:batch"
  tmux select-layout -t "$SESSION:batch" tiled
done

# Give each pane's shell a moment to finish init (zshrc / bashrc can be slow
# enough that send-keys races prompt-readiness and the keystrokes get
# eaten). Empirically 2s suffices on this skill's reference hosts.
sleep 2

# Dispatch 4 tasks, one per pane.
for i in 0 1 2 3; do
  TASK_ID="task-$((i+1))"
  ARGS_FILE="$RESULTS/$TASK_ID.args"
  CMD="PATH=$PATH_FOR_PANES PI_SHIM_ARGS_FILE=$ARGS_FILE PI_SHIM_MODE=exit0 $DISPATCH $TASK_ID $TMP 0 $TMP/prompt.txt $RESULTS '' ''"
  tmux send-keys -t "$SESSION:batch.$i" "$CMD" Enter
done

# Wait up to 45s for all 4 .exit files (pre-fix this would have hung
# indefinitely; post-fix the headless fallback returns near-immediately
# from the pi-shim).
deadline=$(( $(date +%s) + 45 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  done_count=$(ls "$RESULTS"/*.exit 2>/dev/null | wc -l | tr -d ' ')
  [ "$done_count" -ge 4 ] && break
  sleep 1
done

passed=0
failed=0
failures=()

done_count=$(ls "$RESULTS"/*.exit 2>/dev/null | wc -l | tr -d ' ')
if [ "$done_count" -ge 4 ]; then
  passed=$((passed+1))
else
  failures+=("only $done_count/4 tasks produced .exit files within 45s")
  failed=$((failed+1))
fi

# Each task: exit=0 AND argv contains --no-session (headless path taken).
for i in 1 2 3 4; do
  EXIT_CONTENT="$(cat "$RESULTS/task-$i.exit" 2>/dev/null || echo MISSING)"
  if [ "$EXIT_CONTENT" = "0" ]; then
    passed=$((passed+1))
  else
    failures+=("task-$i exit was '$EXIT_CONTENT' (expected 0)")
    failed=$((failed+1))
  fi
  if grep -q '^--no-session$' "$RESULTS/task-$i.args" 2>/dev/null; then
    passed=$((passed+1))
  else
    failures+=("task-$i did not take headless path (no --no-session in argv)")
    failed=$((failed+1))
  fi
done

# No straggler shims.
sleep 1
LEFTOVER=$(pgrep -f "pi-shim.sh" | wc -l | tr -d ' ')
if [ "$LEFTOVER" = "0" ]; then
  passed=$((passed+1))
else
  failures+=("$LEFTOVER straggler pi-shim processes")
  failed=$((failed+1))
fi

echo ""
echo "regression-odev-4-1: passed=$passed failed=$failed"
if [ "$failed" -gt 0 ]; then
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
exit 0
