#!/usr/bin/env bash
set -euo pipefail

# sandbox-up.sh — Start a Docker container + tmux session
#
# Usage: sandbox-up.sh [--image IMAGE] [--mount PATH] [--rw] [--name NAME] [--workdir PATH]

IMAGE="ubuntu:latest"
MOUNT_PATH="$(pwd)"
MOUNT_MODE="ro"
NAME="pi-sandbox"
WORKDIR="/workspace"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)   IMAGE="$2";      shift 2 ;;
    --mount)   MOUNT_PATH="$2"; shift 2 ;;
    --rw)      MOUNT_MODE="rw";  shift ;;
    --name)    NAME="$2";       shift 2 ;;
    --workdir) WORKDIR="$2";    shift 2 ;;
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

# Resolve mount path
MOUNT_PATH="$(cd "$MOUNT_PATH" && pwd)"

# If the requested name is already in use, append an incrementing suffix
# rather than destroying the existing session/container.
BASE_NAME="$NAME"
SUFFIX=1
while tmux has-session -t "$NAME" 2>/dev/null || $RUNTIME ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$NAME"; do
  SUFFIX=$((SUFFIX + 1))
  NAME="${BASE_NAME}-${SUFFIX}"
done

# Start container
DOCKER_ARGS=(
  run -d
  --name "$NAME"
  -v "$MOUNT_PATH:$WORKDIR:$MOUNT_MODE"
  -w "$WORKDIR"
)

# Allow extra docker args via env var
if [[ -n "${SANDBOX_DOCKER_ARGS:-}" ]]; then
  read -ra EXTRA <<< "$SANDBOX_DOCKER_ARGS"
  DOCKER_ARGS+=("${EXTRA[@]}")
fi

DOCKER_ARGS+=("$IMAGE" sleep infinity)

$RUNTIME "${DOCKER_ARGS[@]}" >/dev/null

echo "Container '$NAME' started (image: $IMAGE, mount: $MOUNT_PATH → $WORKDIR [$MOUNT_MODE])"

# Create tmux session and attach to container shell
tmux new-session -d -s "$NAME" -x 220 -y 50
tmux send-keys -t "$NAME" "$RUNTIME exec -it $NAME bash" Enter

# Wait for shell to be ready (look for a prompt)
TRIES=0
MAX_TRIES=30
while [[ $TRIES -lt $MAX_TRIES ]]; do
  sleep 0.5
  OUTPUT=$(tmux capture-pane -t "$NAME" -p 2>/dev/null || true)
  # Look for common shell prompt indicators
  if echo "$OUTPUT" | grep -qE '(\$|#|%)[\s]*$'; then
    break
  fi
  TRIES=$((TRIES + 1))
done

if [[ $TRIES -ge $MAX_TRIES ]]; then
  echo "WARNING: Shell prompt not detected after ${MAX_TRIES} attempts. Container may still be starting." >&2
fi

echo "SANDBOX_NAME=$NAME"
echo "tmux session '$NAME' ready."
echo "  Attach: tmux attach -t $NAME"
