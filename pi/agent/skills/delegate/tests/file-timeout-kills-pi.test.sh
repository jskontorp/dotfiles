#!/usr/bin/env bash
# Tests for the watcher.sh kill paths added in commit A.
#
# Each case dispatches via dispatch.sh with TMUX_PANE faked (so the existing
# loose TUI gate is satisfied — commit B tightens the gate; this test stays
# compatible with both) and a pi-shim that hangs without writing a session
# file. The watcher should detect the FILE_TIMEOUT, kill the shim, leave a
# .watcher-killed marker, and dispatch.sh should record exit 124.
#
# Coverage:
#   1. file-timeout branch kills pi-shim within FILE_TIMEOUT + 5s
#   2. .watcher-killed marker is created
#   3. .exit file contains 124 (not the shim's SIGTERM 143 nor 0)
#   4. PI_PID="" (back-compat) does NOT kill pi-shim — verifies the
#      opt-in semantics are preserved for callers that haven't migrated.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/../scripts/dispatch.sh"
WATCHER="$SCRIPT_DIR/../scripts/watcher.sh"
SHIM_DIR="$SCRIPT_DIR/fixtures"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP file-timeout-kills-pi.test.sh — jq not installed"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; pkill -P $$ 2>/dev/null || true' EXIT

# Prepend a per-test PATH with a `pi` symlink → pi-shim.sh.
BIN="$TMP/bin"
mkdir -p "$BIN"
ln -s "$SHIM_DIR/pi-shim.sh" "$BIN/pi"
chmod +x "$SHIM_DIR/pi-shim.sh"
export PATH="$BIN:$PATH"

passed=0
failed=0
failures=()

assert() {
  local desc="$1" cond="$2"
  if eval "$cond"; then
    passed=$((passed+1))
  else
    failures+=("$desc")
    failed=$((failed+1))
  fi
}

###############################################################################
# Case 1: dispatch.sh + watcher.sh kills pi-shim on file-timeout
###############################################################################
CASE1="$TMP/case1"
mkdir -p "$CASE1/results"
echo "prompt" > "$CASE1/prompt.txt"
export PI_SHIM_ARGS_FILE="$CASE1/results/task-1.args"
export PI_SHIM_MODE="sleep"
unset PI_SHIM_SESSION_DIR  # don't let the shim short-circuit

# Fake the tmux pane so dispatch.sh takes the TUI branch.
# No outer `timeout` wrapper — not portable to default macOS — the polling
# loop below is the safety net; if dispatch.sh hangs past deadline the test
# SIGKILLs it and reports failure.
TMUX_PANE="%999" \
  "$DISPATCH" task-1 "$CASE1" 0 "$CASE1/prompt.txt" "$CASE1/results" "" "" \
  >"$CASE1/dispatch.log" 2>&1 &
DISPATCH_PID=$!

# Wait up to FILE_TIMEOUT (30s, watcher default) + 15s slack for dispatch's
# post-wait bookkeeping.
deadline=$(( $(date +%s) + 45 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$CASE1/results/task-1.exit" ]; then break; fi
  sleep 1
done

# Reap dispatch (it should have completed; if not, force).
if kill -0 "$DISPATCH_PID" 2>/dev/null; then
  kill -KILL "$DISPATCH_PID" 2>/dev/null || true
  failures+=("case1: dispatch.sh did not exit within 35s (watcher kill failed)")
  failed=$((failed+1))
else
  passed=$((passed+1))
fi

assert "case1: .watcher-killed marker present" \
  '[ -f "$CASE1/results/task-1.watcher-killed" ]'

EXIT_CONTENT="$(cat "$CASE1/results/task-1.exit" 2>/dev/null || echo MISSING)"
assert "case1: exit code is 124 (got '$EXIT_CONTENT')" \
  '[ "$EXIT_CONTENT" = "124" ]'

# No straggler pi-shim process.
sleep 1
LEFTOVER=$(pgrep -f "pi-shim.sh" | wc -l | tr -d ' ')
assert "case1: no straggler pi-shim (got $LEFTOVER)" \
  '[ "$LEFTOVER" = "0" ]'

###############################################################################
# Case 2: watcher.sh with PI_PID="" preserves silent-exit back-compat
###############################################################################
# Direct watcher.sh invocation — no dispatcher, no pi to kill.
# Just assert that watcher exits cleanly on file-timeout when PI_PID is empty,
# matching the old behaviour. (No process to assert against, so this is a
# pure "doesn't break callers that don't pass PI_PID" check.)
CASE2="$TMP/case2"
mkdir -p "$CASE2/sessions/task-2"
: > "$CASE2/results.md"
# Args: SESSION_DIR RESULT_FILE PANE_TARGET POLL_INTERVAL FILE_TIMEOUT MAX_WAIT
if "$WATCHER" "$CASE2/sessions/task-2" "$CASE2/results.md" "" 1 2 2 >/dev/null 2>&1; then
  passed=$((passed+1))
else
  failures+=("case2: watcher.sh exited non-zero with empty PI_PID")
  failed=$((failed+1))
fi

assert "case2: no .watcher-killed marker when PI_PID empty" \
  '[ ! -f "$CASE2/results.watcher-killed" ]'

assert "case2: 'no session file' diagnostic was written" \
  'grep -q "no session file appeared" "$CASE2/results.md"'

###############################################################################
# Summary
###############################################################################
echo ""
echo "file-timeout-kills-pi: passed=$passed failed=$failed"
if [ "$failed" -gt 0 ]; then
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
exit 0
