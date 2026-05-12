#!/usr/bin/env bash
# dev-server.sh — Start the project's `$PM run dev` in a detached tmux session
# and poll for readiness. Skips cleanly if no `dev` script is defined.
#
# Usage: dev-server.sh <ticket> <wt> <pm>
#
# Readiness regex (case-insensitive): "ready in|listening on|local:[[:space:]]*http"
# covers Next.js, Vite, Express, Fastify.
#
# Env knobs (for tests):
#   READY_POLL_INTERVAL   seconds between polls (default 1)
#   READY_POLL_MAX        max polls before giving up (default 30)
#
# Exit codes:
#   0   ready, or cleanly skipped (no `dev` script)
#   64  bad args
#   68  readiness timeout (last 30 lines tailed to stderr)
#   69  tmux session died during startup

set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
[ $# -eq 3 ] || { echo "usage: $(basename "$0") <ticket> <wt> <pm>" >&2; exit 64; }
TICKET="$1"
WT="$2"
PM="$3"
[ -n "$TICKET" ] && [ -d "$WT" ] && [ -n "$PM" ] || { echo "invalid args" >&2; exit 64; }

DEV_SESSION="$TICKET-dev"
POLL_INTERVAL="${READY_POLL_INTERVAL:-1}"
POLL_MAX="${READY_POLL_MAX:-30}"

log() { echo "$@" >&2; }

# ----- gate on scripts.dev -----
if ! ( cd "$WT" && node -e 'process.exit(require("./package.json").scripts?.dev?0:1)' 2>/dev/null ); then
  log "no \`$PM run dev\` script — skipping dev server"
  exit 0
fi

# ----- start -----
tmux kill-session -t "$DEV_SESSION" 2>/dev/null || true
tmux new-session -d -s "$DEV_SESSION" -c "$WT" "$PM run dev"

# ----- poll -----
READY=0
for _ in $(seq 1 "$POLL_MAX"); do
  if ! tmux has-session -t "$DEV_SESSION" 2>/dev/null; then
    log "⚠ tmux session $DEV_SESSION died during startup"
    exit 69
  fi
  if tmux capture-pane -p -t "$DEV_SESSION" 2>/dev/null | grep -qEi 'ready in|listening on|local:[[:space:]]*http'; then
    READY=1
    break
  fi
  sleep "$POLL_INTERVAL"
done

if [ "$READY" -eq 0 ]; then
  log "⚠ dev server not ready after $POLL_MAX polls. Last 30 lines:"
  tmux capture-pane -p -t "$DEV_SESSION" 2>/dev/null | tail -30 >&2 || true
  log "attach: tmux attach -t $DEV_SESSION"
  exit 68
fi

log "dev server ready ($DEV_SESSION)"
exit 0
