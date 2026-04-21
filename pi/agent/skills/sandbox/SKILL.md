---
name: sandbox
description: >-
  Spin up an isolated Docker container for testing.
  Run test suites, dev servers, integration tests, or destructive operations
  without blocking the agent or polluting the host.
  Use when the user wants to test something in a clean environment,
  run long-running processes, or execute risky commands safely.
compatibility: Requires docker (or podman). tmux strongly recommended.
allowed-tools: Bash(docker:*) Bash(podman:*) Bash(tmux:*) Bash(cat:*) Read
---

# Sandbox

Run anything in a disposable container. Prefer tmux as the control layer — the user can `tmux attach -t pi-sandbox` to watch live.

All `scripts/` paths resolve relative to this skill's directory. Ensure they're executable:

```bash
chmod +x scripts/sandbox-up.sh scripts/sandbox-exec.sh scripts/sandbox-capture.sh scripts/sandbox-down.sh
```

## Workflow (tmux — preferred)

### 1. Choose an Image

| Project signal | Image |
|----------------|-------|
| `Dockerfile` in root | Build: `docker build -t pi-sandbox-img .` |
| `docker-compose.yml` / `compose.yml` | Use `docker compose run` (see Rules) |
| `package.json` | `node:lts` |
| `go.mod` | `golang:latest` |
| `Cargo.toml` | `rust:latest` |
| `requirements.txt` / `pyproject.toml` | `python:3` |
| Nothing obvious | `ubuntu:latest` |

Ask the user if ambiguous.

### 2. Start

```bash
./scripts/sandbox-up.sh [--image <image>] [--mount <host-path>] [--rw] [--name <name>] [--workdir <container-path>]
```

| Flag | Default | Purpose |
|------|---------|---------|
| `--image` | `ubuntu:latest` | Container image |
| `--mount` | cwd | Host dir to mount |
| `--rw` | off | Mount read-write |
| `--name` | `pi-sandbox` | Container + tmux session name |
| `--workdir` | `/workspace` | Mount point + working dir inside container (override for images that expect `/app`, `/src`, etc.) |

On name collision, the script appends a suffix (`pi-sandbox-2`, …) and prints `SANDBOX_NAME=<actual>`. **Parse and use the actual name for all subsequent calls.**

### 3. Run Commands

**Blocking** (tests, builds):

```bash
./scripts/sandbox-exec.sh "<command>" [--timeout <secs>] [--name <name>]
```

Default timeout: 120s. Returns stdout/stderr + exit code.

**Fire-and-forget** (servers, watchers):

```bash
./scripts/sandbox-exec.sh "<command>" --timeout 0
```

Returns immediately. Use capture to poll output.

### 4. Capture Output

```bash
./scripts/sandbox-capture.sh [--lines <n>] [--name <name>]
```

Last `n` lines from the tmux pane (default: 100). Use to poll servers or read scrolled-past output.

### 5. Tear Down

```bash
./scripts/sandbox-down.sh [--name <name>]
```

## Direct Fallback

When tmux is unavailable. The user loses live observability.

```bash
# Start (override the container path if the image expects something other than /workspace)
docker run -d --name pi-sandbox -v "$(pwd):/workspace:ro" -w /workspace <image> sleep infinity

# Run
docker exec pi-sandbox <command>

# Tear down
docker rm -f pi-sandbox
```

## Rules

- **Always sandbox.** Keep the host clean. Don't install globally — do it inside the container.
- **Prefer tmux.** Fall back to `docker exec` only when tmux is genuinely unavailable.
- **Read-only mounts by default.** Use `--rw` only when the test must write. Confirm with the user first.
- **Always tear down.** Every start needs a matching teardown, even on failure.
- **Report results.** Summarise what passed, what failed, and the exit code. Don't dump raw output.
- **docker-compose**: `docker compose up -d` on the host first, then sandbox into the app container. The scripts target single containers.
- **Host networking**: Pass `--network host` via `SANDBOX_DOCKER_ARGS` env var.
- **Podman**: Auto-detected if `docker` isn't available.
