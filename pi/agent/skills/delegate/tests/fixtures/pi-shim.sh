#!/usr/bin/env bash
# pi-shim.sh — Stand-in for `pi` used by delegate-skill tests.
#
# Behaviour is selected by env vars set by the test before prepending this
# script's directory to PATH:
#
#   PI_SHIM_ARGS_FILE   — required. Path to write the argv to (one arg per
#                         line). Used by tests to assert which dispatch.sh
#                         branch was taken (TUI vs headless) and what flags
#                         were forwarded.
#   PI_SHIM_MODE        — one of:
#                           "exit0"  (default) write a session file (TUI
#                                    mode) or print a banner (headless),
#                                    then exit 0.
#                           "sleep"  write the args, then sleep forever.
#                                    Used to exercise watcher kill paths.
#                           "nofile" do NOT write a session file (simulates
#                                    pi hung before first render — the
#                                    odev:4.1 pathology). Combined with
#                                    "sleep" by sleeping after writing args.
#   PI_SHIM_SESSION_DIR — if set and mode is "exit0", write a minimal
#                         terminal-stopReason JSONL into this dir so
#                         watcher.sh sees a happy-path terminal condition.
#                         (Derived by tests from the --session-dir flag.)
#
# The shim is intentionally dumb: it does NOT parse flags. Tests that need
# to assert on flags read PI_SHIM_ARGS_FILE directly.

set -u

ARGS_FILE="${PI_SHIM_ARGS_FILE:-/dev/null}"
MODE="${PI_SHIM_MODE:-exit0}"

# Record argv one-per-line so test asserts can use grep cleanly.
{
  for a in "$@"; do
    printf '%s\n' "$a"
  done
} > "$ARGS_FILE" 2>/dev/null || true

case "$MODE" in
  sleep)
    # Used by file-timeout-kills-pi.test.sh — emulates pi that never writes
    # a session file and never exits on its own.
    while :; do sleep 60; done
    ;;
  nofile)
    # Like sleep, but explicit about not writing anything.
    while :; do sleep 60; done
    ;;
  exit0|*)
    if [ -n "${PI_SHIM_SESSION_DIR:-}" ]; then
      mkdir -p "$PI_SHIM_SESSION_DIR"
      cat > "$PI_SHIM_SESSION_DIR/session.jsonl" <<'EOF'
{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":"shim ok"}],"stopReason":"stop"}}
EOF
    else
      echo "pi-shim: exit0 (headless)"
    fi
    exit 0
    ;;
esac
