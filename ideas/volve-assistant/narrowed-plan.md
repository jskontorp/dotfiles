# Volve Assistant MVP — proposed plan (as of 2026-04-23)

This document captures the decisions reached in conversation between the user (Fink / Jan Sigurd Kontorp) and the orchestrating agent. The baseline spec this is narrowing down from is `volve-assistant-mvp.md` (sibling file). The full vision lives in `volve-assistant-spec.md.pdf` (not included here).

## Premise test

A personal assistant that answers DM-style questions like "what does my day look like?", "catch me up on Anna before our 10am", "what's open on [project]?" — by querying Linear / Notion / Calendar / Gmail / Slack on demand. Read-only. No watchers, no digests, no proactive alerts. Thread-local memory only. Phase 0.

Success criterion: five weekdays in a row where at least one exchange saves meaningful clicking.

## Decisions already made

### Runtime / agent

- **Use pi (`@mariozechner/pi-coding-agent`) SDK, not Claude Code headless.**
  - Reason: user already operates pi daily; OpenClaw uses the same embedded-SDK pattern in a messaging gateway; avoids per-message subprocess spawn cost; free credits via GitHub Copilot subscription (billed via Azure) cover model usage.
- **Model: `github-copilot` / `claude-opus-4.7`.** Same provider serving the orchestrator right now; proven. No override.
- **Architecture shape: Node process, pi SDK embedded in-process via `createAgentSession`.** Not subprocess-per-message, not RPC.

### Sources

- **MCP bridged via `@0xkobold/pi-mcp` extension.** Turns any MCP server into pi tools. Supports stdio/HTTP/SSE/WS. Env-variable interpolation for headers.
- **Start with Linear only** (`https://mcp.linear.app/mcp`, remote HTTP, OAuth on first connect). Verify roundtrip. Then layer Notion, Calendar, Gmail, Slack one at a time.
- Remote HTTP MCPs (Linear, Notion, Figma, Sentry, GitHub, etc.) are the default; no local processes to spawn.

### Frontend

- **Not Slack for MVP.** User wants to avoid workspace-admin friction and keep the assistant private/unseen by the Volve team. Slack DM remains the eventual target but not day one.
- **Local web UI served by the same Node process, reachable via Tailscale** (phone + laptop). No third parties. Bound to 0.0.0.0 on a Tailscale-only port; Tailscale is the auth layer.
- UI: single static HTML page, vanilla JS, SSE for streaming assistant tokens, left sidebar with threads, main chat pane. ~150 lines. `marked` for markdown rendering.
- **Port: 3456** (tentative).

### Sessions / memory

- One pi session per "thread." Persist via `SessionManager.create(cwd)` to disk under `sessions/`. Thread list reads from disk.
- No DB, no queue, no scheduler.
- `VOLVE.md` injected as context every session via `agentsFilesOverride` on `DefaultResourceLoader`.
- Thread auto-naming (timestamp). Rename later.

### Deployment

- **Build locally on the user's Mac first, then deploy to the always-on Linux VM** (already has pi + claude installed and daily-used).
- systemd unit at `deploy/volve-assistant.service` for later.

### Proposed repo layout

```
~/code/personal/assistant/
├── package.json              # Node 20+, ESM, TypeScript
├── tsconfig.json
├── .env.example              # PORT only; pi auth + MCP tokens live in their own stores
├── .gitignore                # .env, context/VOLVE.md, sessions/, node_modules, dist
├── README.md
├── src/
│   ├── index.ts              # entry: loads VOLVE.md, boots server
│   ├── server.ts             # Fastify + SSE /stream + POST /prompt + GET /threads
│   ├── agent.ts              # createAgentSession wrapper, pi-mcp extension wired in
│   └── web/
│       ├── index.html        # single page, threads sidebar + chat pane
│       └── app.js            # vanilla JS, fetch + EventSource
├── context/
│   └── VOLVE.md              # starter template, gitignored content, tracked file
├── mcp/
│   └── servers.json          # pi-mcp config, start with Linear only
└── deploy/
    └── volve-assistant.service   # systemd unit for later VM deploy
```

## Explicitly out of scope for MVP

- Watchers / proactive alerts.
- Scheduled digests (morning/evening briefings).
- Event alerts (meeting-in-30, exec-email, P0 assigned).
- Cross-thread / long-term memory beyond raw session JSONL files.
- Reaction-to-resolve flows (no open_loops concept yet).
- Write actions in any MCP (no sending mail, no creating Linear issues from the assistant).
- Auth on the web endpoint (Tailscale-as-auth only for MVP).
- Multi-user support.

## Known open questions / risks (flagged but not yet resolved)

1. **MCP OAuth refresh on a long-running headless daemon.** First-time OAuth opens a browser; whether tokens refresh cleanly over weeks without human intervention is untested for each remote MCP.
2. **pi/GH-Copilot provider rate limits** under heavy morning-briefing load.
3. **Privacy of sessions on disk** — will contain Gmail/Calendar/Linear content in plaintext JSONL under `sessions/`.
4. **`@0xkobold/pi-mcp` is young** (recent publish). If it's flaky we fall back to the two existing pi-native packages (`@fink-andreas/pi-linear-tools`, `@feniix/pi-notion`) + custom extensions wrapping `gcalcli` / Gmail API for the rest.
5. **VOLVE.md hand-maintenance burden.** Karpathy's `llm-wiki` pattern (LLM-maintained linked markdown wiki) is a candidate Phase-2 replacement.

## What the user wants reviewed

Four independent angles, each as a separate sub-agent:

1. **Step-back / unframed take** — question whether this is the right shape at all.
2. **Prior-art research** — minimal personal-assistant precedents, OpenClaw-adjacent projects.
3. **Technical architecture review** — sharp edges in the proposed stack.
4. **Security / operational review** — Tailscale-as-auth, disk persistence of sensitive content, OAuth refresh, blast radius.
