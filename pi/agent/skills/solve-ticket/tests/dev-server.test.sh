#!/usr/bin/env bash
# Tests for dev-server.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/../scripts"
# shellcheck source=lib/helpers.sh
. "$SCRIPT_DIR/lib/helpers.sh"

SCRIPT="$SCRIPTS_DIR/dev-server.sh"

# Make tests fast.
export READY_POLL_INTERVAL=0
export READY_POLL_MAX=5

# ----- per-test helpers -----

# Make a worktree dir with a package.json. `with_dev=1` includes a dev script.
make_wt() {
  local wt="$1" with_dev="$2"
  mkdir -p "$wt"
  if [ "$with_dev" = "1" ]; then
    cat > "$wt/package.json" <<'EOF'
{ "name": "x", "scripts": { "dev": "node -e 'setInterval(()=>{},1000)'" } }
EOF
  else
    cat > "$wt/package.json" <<'EOF'
{ "name": "x", "scripts": {} }
EOF
  fi
}

# Tmux stub with argv-based dispatch. Controlled by files in $STUB_STATE_DIR:
#   tmux.alive         — if present, has-session succeeds
#   tmux.capture.N     — text printed by capture-pane on the Nth call
#   tmux.capture.default — fallback text (default: empty)
install_tmux_stub() {
  local body='
case "$1" in
  kill-session) exit 0 ;;
  new-session)  : > "$STUB_STATE_DIR/tmux.alive"; exit 0 ;;
  has-session)  [ -f "$STUB_STATE_DIR/tmux.alive" ] && exit 0 || exit 1 ;;
  capture-pane)
    cc="$STUB_STATE_DIR/tmux.capture_count"
    k=$(( $(cat "$cc" 2>/dev/null || echo 0) + 1 ))
    echo "$k" > "$cc"
    for f in "$STUB_STATE_DIR/tmux.capture.$k" "$STUB_STATE_DIR/tmux.capture.default"; do
      if [ -f "$f" ]; then cat "$f"; exit 0; fi
    done
    exit 0 ;;
  *) exit 0 ;;
esac
'
  make_stub tmux "$body"
}

# ----- tests -----

test_bad_args() {
  local rc
  "$SCRIPT" 2>/dev/null; rc=$?
  assert_exit 64 "$rc" "zero args → exit 64"
  "$SCRIPT" a b 2>/dev/null; rc=$?
  assert_exit 64 "$rc" "two args → exit 64"
  "$SCRIPT" a /nonexistent-dir c 2>/dev/null; rc=$?
  assert_exit 64 "$rc" "bad wt → exit 64"
}

test_help() {
  local out
  out=$("$SCRIPT" --help)
  assert_contains "$out" "Usage:" "--help prints usage"
}

test_no_dev_script_skips() {
  local wt="$TMP/wt"
  make_wt "$wt" 0
  install_tmux_stub
  local rc
  "$SCRIPT" tech-1 "$wt" pnpm >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "no scripts.dev → exit 0"
  assert_eq "0" "$(stub_count tmux)" "tmux NOT called when no dev script"
}

test_ready_on_first_poll() {
  local wt="$TMP/wt"
  make_wt "$wt" 1
  install_tmux_stub
  printf 'Ready in 1.2s\n' > "$STUB_STATE_DIR/tmux.capture.default"
  local rc
  "$SCRIPT" tech-2 "$wt" pnpm >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "ready on poll 1 → exit 0"
}

test_ready_on_third_poll() {
  local wt="$TMP/wt"
  make_wt "$wt" 1
  install_tmux_stub
  # Polls 1+2 empty; poll 3 has readiness signal.
  : > "$STUB_STATE_DIR/tmux.capture.1"
  : > "$STUB_STATE_DIR/tmux.capture.2"
  printf 'Local:   http://localhost:3000\n' > "$STUB_STATE_DIR/tmux.capture.3"
  local rc
  "$SCRIPT" tech-3 "$wt" pnpm >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "ready on poll 3 (Vite signal) → exit 0"
}

test_session_dies_mid_poll() {
  local wt="$TMP/wt"
  make_wt "$wt" 1
  install_tmux_stub
  # Session starts alive (new-session creates the marker), but we remove it
  # after the first has-session to simulate death.
  install_tmux_stub_dying() {
    local body='
case "$1" in
  kill-session) exit 0 ;;
  new-session)  : > "$STUB_STATE_DIR/tmux.alive"; exit 0 ;;
  has-session)
    hc="$STUB_STATE_DIR/tmux.has_count"
    k=$(( $(cat "$hc" 2>/dev/null || echo 0) + 1 ))
    echo "$k" > "$hc"
    if [ "$k" -ge 2 ]; then exit 1; fi
    [ -f "$STUB_STATE_DIR/tmux.alive" ] && exit 0 || exit 1 ;;
  capture-pane) exit 0 ;;  # always empty while alive
  *) exit 0 ;;
esac
'
    make_stub tmux "$body"
  }
  install_tmux_stub_dying
  local rc
  "$SCRIPT" tech-4 "$wt" pnpm >/dev/null 2>&1; rc=$?
  assert_exit 69 "$rc" "session dies mid-poll → exit 69"
}

test_timeout() {
  local wt="$TMP/wt"
  make_wt "$wt" 1
  install_tmux_stub
  # capture-pane always empty → never ready → timeout.
  : > "$STUB_STATE_DIR/tmux.capture.default"
  local rc
  "$SCRIPT" tech-5 "$wt" pnpm >/dev/null 2>&1; rc=$?
  assert_exit 68 "$rc" "never ready → exit 68"
}

test_readiness_regex_next() {
  local wt="$TMP/wt"
  make_wt "$wt" 1
  install_tmux_stub
  printf '  ✓ Ready in 342ms\n' > "$STUB_STATE_DIR/tmux.capture.default"
  local rc
  "$SCRIPT" tech-6 "$wt" pnpm >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "Next.js 'Ready in …ms' matches"
}

test_readiness_regex_express() {
  local wt="$TMP/wt"
  make_wt "$wt" 1
  install_tmux_stub
  printf 'Express listening on port 3000\n' > "$STUB_STATE_DIR/tmux.capture.default"
  local rc
  "$SCRIPT" tech-7 "$wt" pnpm >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "Express 'listening on' matches"
}

# ----- runner -----

run_test "bad args"                         test_bad_args
run_test "--help"                           test_help
run_test "no scripts.dev → skip cleanly"    test_no_dev_script_skips
run_test "ready on first poll"              test_ready_on_first_poll
run_test "ready on third poll"              test_ready_on_third_poll
run_test "session dies mid-poll"            test_session_dies_mid_poll
run_test "never ready → timeout"            test_timeout
run_test "Next.js regex"                    test_readiness_regex_next
run_test "Express regex"                    test_readiness_regex_express

summary
