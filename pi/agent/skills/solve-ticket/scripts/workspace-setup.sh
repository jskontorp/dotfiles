#!/usr/bin/env bash
# workspace-setup.sh — Detect package manager, create worktree, symlink env
# files, install dependencies. Writes machine state to $STATE_DIR/$TICKET.env.
# Does NOT write the human-readable progress markdown — that's the skill's job
# (needs title + plan from Phase 2).
#
# Usage: workspace-setup.sh <ticket> <base>
#
# Must be invoked with CWD inside the main repo (any worktree is fine; the
# script derives the main worktree from `git worktree list`).
#
# Args:
#   ticket — lowercase ticket id (e.g. tech-123)
#   base   — default branch (e.g. main)
#
# Emits $STATE_DIR/$TICKET.env with:
#   ROOT=<main worktree path>
#   WT=<new worktree path>
#   STATE_DIR=<state dir path>
#   PM=<pnpm|bun|yarn|npm>
#   BRANCH_EXISTED=<0|1>
#
# Human-readable progress is printed to stderr. Stdout is reserved for future
# structured use; nothing is printed there today.
#
# Exit codes:
#   0   success (workspace exists + install succeeded)
#   64  bad args
#   66  no lockfile in root (skill doesn't fit)
#   70  git failure (fetch / worktree add)
#   73  install failure

set -euo pipefail

# ----- arg parsing -----
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
[ $# -eq 2 ] || { echo "usage: $(basename "$0") <ticket> <base>" >&2; exit 64; }
TICKET="$1"
BASE="$2"
[ -n "$TICKET" ] && [ -n "$BASE" ] || { echo "ticket and base must be non-empty" >&2; exit 64; }

# ----- all human output goes to stderr -----
log() { echo "$@" >&2; }

# ----- derive paths from git -----
ROOT=$(git worktree list 2>/dev/null | awk 'NR==1 {print $1}')
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { log "error: could not determine main worktree (run from inside the repo)"; exit 70; }
WT="${ROOT}_worktrees/$TICKET"
STATE_DIR="${ROOT}_worktrees/.pi-state"

# ----- PM detection (prefer persisted state, else lockfile) -----
PM=""
ENV_FILE="$STATE_DIR/$TICKET.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  PM_FROM_STATE=$(awk -F= '$1=="PM"{print $2; exit}' "$ENV_FILE" 2>/dev/null || true)
  [ -n "${PM_FROM_STATE:-}" ] && PM="$PM_FROM_STATE"
fi
if [ -z "$PM" ]; then
  if   [ -f "$ROOT/pnpm-lock.yaml" ];                            then PM=pnpm
  elif [ -f "$ROOT/bun.lock" ] || [ -f "$ROOT/bun.lockb" ];      then PM=bun
  elif [ -f "$ROOT/yarn.lock" ];                                 then PM=yarn
  elif [ -f "$ROOT/package-lock.json" ];                         then PM=npm
  else log "error: no JS lockfile in $ROOT — solve-ticket is JS-only"; exit 66
  fi
fi

# ----- worktree -----
BRANCH_EXISTED=0
mkdir -p "$STATE_DIR"
if [ -d "$WT" ]; then
  log "worktree already exists: $WT"
  BRANCH_EXISTED=1
else
  mkdir -p "$(dirname "$WT")"
  log "fetching origin/$BASE ..."
  git fetch origin "$BASE" >&2 || { log "error: git fetch failed"; exit 70; }
  # Check if branch exists; create or reuse.
  if git show-ref --verify --quiet "refs/heads/$TICKET"; then
    BRANCH_EXISTED=1
    log "branch $TICKET exists; attaching worktree"
    git worktree add "$WT" "$TICKET" >&2 || { log "error: git worktree add (existing branch) failed"; exit 70; }
  else
    log "creating worktree + branch $TICKET from origin/$BASE"
    git worktree add --no-track -b "$TICKET" "$WT" "origin/$BASE" >&2 || { log "error: git worktree add failed"; exit 70; }
  fi
fi

# ----- env symlinks -----
for envfile in .env.local .env.development.local .env.development .env; do
  if [ -f "$ROOT/$envfile" ]; then
    # `ln -sfn` handles dangling symlinks and existing links cleanly.
    ln -sfn "$ROOT/$envfile" "$WT/$envfile"
  fi
done

# ----- install -----
log "running $PM install in $WT ..."
( cd "$WT" && "$PM" install >&2 ) || { log "error: $PM install failed"; exit 73; }

# ----- write env fragment (atomic) -----
TMP_ENV="$(mktemp "$STATE_DIR/$TICKET.env.XXXXXX")"
{
  printf 'ROOT=%q\n'           "$ROOT"
  printf 'WT=%q\n'             "$WT"
  printf 'STATE_DIR=%q\n'      "$STATE_DIR"
  printf 'PM=%q\n'             "$PM"
  printf 'BRANCH_EXISTED=%q\n' "$BRANCH_EXISTED"
} > "$TMP_ENV"
mv "$TMP_ENV" "$ENV_FILE"

log "workspace ready: $WT (PM=$PM)"
exit 0
