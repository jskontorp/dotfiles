#!/usr/bin/env bash
set -euo pipefail

# sandbox-capture.sh — Capture current tmux pane output
#
# Usage: sandbox-capture.sh [--lines N] [--name NAME]

LINES=100
NAME="pi-sandbox"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lines) LINES="$2"; shift 2 ;;
    --name)  NAME="$2";  shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Check session exists
if ! tmux has-session -t "$NAME" 2>/dev/null; then
  echo "ERROR: No tmux session '$NAME'. Run sandbox-up.sh first." >&2
  exit 1
fi

# Capture last N lines from the pane's scrollback
START=$((-LINES))
tmux capture-pane -t "$NAME" -p -S "$START"
