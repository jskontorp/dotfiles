#!/usr/bin/env bash
set -euo pipefail

# sandbox-down.sh — Tear down the sandbox container and tmux session
#
# Usage: sandbox-down.sh [--name NAME]

NAME="pi-sandbox"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Detect container runtime
if command -v docker &>/dev/null; then
  RUNTIME=docker
elif command -v podman &>/dev/null; then
  RUNTIME=podman
else
  echo "ERROR: Neither docker nor podman found." >&2
  exit 1
fi

# Stop and remove container
if $RUNTIME ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  $RUNTIME rm -f "$NAME" >/dev/null 2>&1
  echo "Container '$NAME' removed."
else
  echo "No container '$NAME' found."
fi

# Kill tmux session
if tmux has-session -t "$NAME" 2>/dev/null; then
  tmux kill-session -t "$NAME"
  echo "tmux session '$NAME' killed."
else
  echo "No tmux session '$NAME' found."
fi

echo "Sandbox '$NAME' torn down."
