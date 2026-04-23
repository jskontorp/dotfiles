#!/usr/bin/env bash
# peer-review-spawn.sh — Spawn an independent pi sub-agent to cold-review
# uncommitted + committed changes on the current branch. Enforces a 2-round
# per-session cap.
#
# Usage: peer-review-spawn.sh <ticket> <wt> <state_dir> <base>
#
# Before the first round of a session, the caller should remove stale review
# files for this ticket (one-liner kept inline in the skill):
#   rm -f "$STATE_DIR/$TICKET"-review-*.md
#
# Behaviour:
#   - Counts $STATE_DIR/$TICKET-review-*.md via nullglob → ROUND = count + 1.
#   - Exits 71 if ROUND > 2 (cap reached).
#   - Atomically reserves $STATE_DIR/$TICKET-review-$ROUND.md via noclobber;
#     writes to .partial and renames on success.
#   - Spawns the reviewer (default `pi -p --no-session --no-skills`, overridable
#     via REVIEW_CMD) under `timeout` or `gtimeout` (hard-fails 69 if neither is
#     installed — otherwise the cap isn't real).
#
# Env knobs:
#   PI_TIMEOUT             seconds (default 300)
#   REVIEW_CMD             reviewer invocation (default "pi -p --no-session --no-skills").
#                          Claude's solve-ticket agent sets REVIEW_CMD="claude -p".
#                          Tokens are whitespace-split into a bash array.
#   REVIEW_TICKET_INSTR    the "fetch the ticket via …" clause spliced into the
#                          prompt. Defaults to pi syntax (`linear get_issue …`).
#                          Claude's agent overrides with the MCP tool name.
#
# Exit codes:
#   0    review completed — triage the output file
#   64   bad args
#   69   neither `timeout` nor `gtimeout` available
#   70   pi exited non-zero (not timeout) — output unreliable
#   71   round cap reached (> 2)
#   72   slot reservation failed (race / pre-existing file)
#   124  pi timed out (preserved)
#   137  pi killed (preserved)

set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
[ $# -eq 4 ] || { echo "usage: $(basename "$0") <ticket> <wt> <state_dir> <base>" >&2; exit 64; }
TICKET="$1"
WT="$2"
STATE_DIR="$3"
BASE="$4"
[ -n "$TICKET" ] && [ -d "$WT" ] && [ -d "$STATE_DIR" ] && [ -n "$BASE" ] || { echo "invalid args" >&2; exit 64; }

PI_TIMEOUT="${PI_TIMEOUT:-300}"

log() { echo "$@" >&2; }

# ----- timeout discovery (hard-fail if absent — the cap must be real) -----
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN=gtimeout
else
  log "error: neither 'timeout' nor 'gtimeout' on PATH — install coreutils"
  exit 69
fi

# ----- round count + cap -----
shopt -s nullglob
REVIEWS=( "$STATE_DIR/$TICKET"-review-*.md )
shopt -u nullglob
ROUND=$(( ${#REVIEWS[@]} + 1 ))
if [ "$ROUND" -gt 2 ]; then
  log "peer-review cap reached (2 rounds). stop."
  exit 71
fi

OUT="$STATE_DIR/$TICKET-review-$ROUND.md"
PARTIAL="$OUT.partial"

# ----- atomic slot reservation via noclobber -----
if ! ( set -C; : > "$OUT" ) 2>/dev/null; then
  log "error: slot $(basename "$OUT") already taken"
  exit 72
fi

# ----- cleanup on non-success (leaves $OUT empty marker + .partial removed) -----
cleanup() {
  local rc=$?
  rm -f "$PARTIAL"
  if [ "$rc" -ne 0 ]; then
    # Leave a short note in the slot so the LLM doesn't parse stale content.
    printf 'peer-review failed (rc=%d)\n' "$rc" > "$OUT"
  fi
}
trap cleanup EXIT

TICKET_UPPER=$(echo "$TICKET" | tr '[:lower:]' '[:upper:]')
: "${REVIEW_TICKET_INSTR:=fetch the ticket via \`linear get_issue $TICKET_UPPER\`}"
PROMPT="Review uncommitted + committed changes on this branch vs origin/$BASE for $TICKET_UPPER. Start with \`git status\` and \`git diff origin/$BASE...HEAD\`, then $REVIEW_TICKET_INSTR for scope. Flag bugs, missed edge cases, and quality issues within ticket scope. Note but do not prioritize scope-expansion ideas."

log "spawning peer review (round $ROUND, timeout ${PI_TIMEOUT}s) ..."
RC=0
# Word-split REVIEW_CMD into an array (bash-array pattern — single-quoting would
# pass the whole string as an executable name and fail).
read -r -a REVIEW_CMD_ARR <<< "${REVIEW_CMD:-pi -p --no-session --no-skills}"
( cd "$WT" && "$TIMEOUT_BIN" "$PI_TIMEOUT" "${REVIEW_CMD_ARR[@]}" "$PROMPT" ) > "$PARTIAL" 2>&1 || RC=$?

case "$RC" in
  0)
    mv "$PARTIAL" "$OUT"
    log "peer review completed → $OUT"
    # Disarm trap — success path owns the file.
    trap - EXIT
    exit 0
    ;;
  124|137)
    # Partial output may still be useful; preserve it.
    mv "$PARTIAL" "$OUT"
    log "peer review timed out (rc=$RC) → $OUT (partial)"
    trap - EXIT
    exit "$RC"
    ;;
  *)
    log "pi failed (rc=$RC) — review output unreliable"
    exit 70
    ;;
esac
