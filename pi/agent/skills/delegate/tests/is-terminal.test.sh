#!/usr/bin/env bash
# Tests for watcher.sh — exercises the is_terminal jq query and the final-text
# extraction over hand-crafted session JSONL fixtures.
#
# Each fixture lives in fixtures/ and is staged into a temp SESSION_DIR
# named after the fixture; watcher.sh is invoked with PANE_TARGET="" so the
# tmux send-keys path is skipped (no tmux dependency required for tests).
# Short MAX_WAIT (3s) and FILE_TIMEOUT (3s) keep the test under ~10s total
# for the non-terminal cases, which deliberately exercise the timeout branch.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER="$SCRIPT_DIR/../scripts/watcher.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP is-terminal.test.sh — jq not installed"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

passed=0
failed=0
failures=()

# run_case <fixture-basename> <expect: terminal|timeout|nofile> <expected-substring-in-result>
run_case() {
  local name="$1" expect="$2" needle="$3"
  local sdir="$TMP/$name" rfile="$TMP/$name.result"
  mkdir -p "$sdir"
  if [ "$expect" != "nofile" ]; then
    cp "$FIXTURES/$name.jsonl" "$sdir/session.jsonl"
  fi

  # Args: SESSION_DIR RESULT_FILE PANE_TARGET POLL_INTERVAL FILE_TIMEOUT MAX_WAIT
  : > "$rfile"
  if ! "$WATCHER" "$sdir" "$rfile" "" 1 3 3 >/dev/null 2>&1; then
    failures+=("$name: watcher exited non-zero")
    failed=$((failed+1))
    return
  fi

  local body
  body="$(cat "$rfile")"

  case "$expect" in
    terminal)
      if grep -q "terminal condition not reached" "$rfile"; then
        failures+=("$name: expected terminal, got timeout marker")
        failed=$((failed+1)); return
      fi
      ;;
    timeout)
      if ! grep -q "terminal condition not reached within 3s" "$rfile"; then
        failures+=("$name: expected timeout marker, got: $body")
        failed=$((failed+1)); return
      fi
      ;;
    nofile)
      if ! grep -q "no session file appeared" "$rfile"; then
        failures+=("$name: expected nofile message, got: $body")
        failed=$((failed+1)); return
      fi
      passed=$((passed+1)); return
      ;;
  esac

  if [ -n "$needle" ] && ! grep -qF "$needle" "$rfile"; then
    failures+=("$name: result missing expected substring '$needle'; got: $body")
    failed=$((failed+1)); return
  fi
  passed=$((passed+1))
}

# Terminal cases — should extract final assistant text, no timeout marker.
run_case stop-clean           terminal "hello from clean stop"
run_case toolcall-result-stop terminal "finished after toolcall"
run_case error-stop           terminal "errored out"

# Non-terminal cases — must hit MAX_WAIT and write timeout marker.
run_case orphan-toolcall      timeout  ""
run_case in-progress          timeout  ""

# No session file — watcher must report and exit cleanly.
run_case stop-clean-nofile    nofile   "" 2>/dev/null
# (the helper uses the fixture name to find the file; for nofile we don't
# stage one, so any name works — pass a unique one to avoid collisions.)

echo ""
echo "---- is-terminal.test.sh ----"
echo "passed: $passed"
echo "failed: $failed"
if [ "$failed" -gt 0 ]; then
  printf '  ✗ %s\n' "${failures[@]}"
  exit 1
fi
exit 0
