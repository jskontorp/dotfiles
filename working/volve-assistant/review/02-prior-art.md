# Prior-art research — Volve assistant MVP

Sources: all fetched 2026-04-23. None unreachable except `docs.openclaw.ai/guides/personal-assistant` (404; the equivalent guide lives at `openclaw-ai.com/en/docs/start/openclaw` and was used instead).

## Precedents studied

### 1. OpenClaw — embedded pi SDK behind a messaging gateway

Sources: `docs.openclaw.ai`, `docs.openclaw.ai/pi`, `openclaw-ai.com/en/docs/start/openclaw`, `dev.to/jiade/inside-openclaw...`, Ronacher `lucumr.pocoo.org/2026/1/31/pi/`.

- **Shape.** Long-running Node 22+ Gateway process bound to `127.0.0.1:18789`, with channel adapters (WhatsApp/Telegram/Discord/Slack/iMessage/…) feeding messages into a 6-stage pipeline ending in an embedded pi `AgentSession`. There is also a browser Control UI dashboard. So: chat-DM front, dashboard side-car, **plus** a 30-min `heartbeat` cron baked into the default config.
- **Sources wired.** Tools are injected by OpenClaw, not pi: messaging tool, sandboxed bash/read/edit/write, browser, canvas, cron, image, web-fetch, plus channel-specific actions. MCP is not the wiring story — Ronacher: *"The most obvious omission is support for MCP. There is no MCP support in it… you can do what OpenClaw does to support MCP which is to use mcporter."* Memory is two layers of plain markdown: `memory/YYYY-MM-DD.md` daily logs and a curated `MEMORY.md`. Workspace files (`AGENTS.md`, `SOUL.md`, `TOOLS.md`, `IDENTITY.md`, `USER.md`, `HEARTBEAT.md`) are auto-bootstrapped.
- **What keeps it alive.** dev.to teardown attributes the explosion to the architecture, not the chat surface: *"The Lane Queue enforces serial execution by default — one agent turn per session at a time… deterministic logs, no state corruption."* Sessions are JSONL transcripts under `~/.openclaw/agents/<id>/sessions/`, replayable.
- **Pain.** The personal-assistant guide leads with a safety warning: *"Always set channels.whatsapp.allowFrom (never run open-to-the-world on your personal Mac)"* and recommends a **dedicated second phone number** so personal messages don't become "agent input." Heartbeats default OFF in the guide (`every: "0m"`) — *"Heartbeats run full agent turns — shorter intervals burn more tokens."*
- **Lesson for our plan.** OpenClaw is exactly the reference architecture for what's proposed, but two of its hard-won defaults conflict with the plan: (a) it injects tools natively rather than via MCP and explicitly punts MCP to `mcporter`; (b) it treats per-sender allow-listing and channel isolation as non-negotiable. The plan's "Tailscale-as-auth + bind 0.0.0.0:3456" is the analogue and probably fine — but adopt OpenClaw's posture of *one* identified user, hard-coded, not "anyone on my tailnet."

### 2. Karpathy `llm-wiki` gist

Source: `gist.github.com/karpathy/442a6bf555914893e9891c11519de94f`.

- **Shape.** Not a chat product. A *workflow*: agent on one side (Codex / Claude Code / pi), Obsidian on the other, three-layer file tree (raw sources / wiki / schema doc).
- **Sources wired.** None automatically. You drop documents into `raw/` and tell the agent to "ingest." Optional `qmd` for BM25+vector search once the wiki grows.
- **What keeps it alive.** Karpathy frames it as *anti-RAG*: *"the LLM is rediscovering knowledge from scratch on every question. There's no accumulation… the wiki is a persistent, compounding artifact. The cross-references are already there. The contradictions have already been flagged."*
- **Concrete operations.** Three ops only: **Ingest** (one source updates 10–15 pages), **Query** (results filed back as new pages), **Lint** (find contradictions, orphans, stale claims). Two index files: `index.md` (content catalog) and `log.md` (chronological, append-only, prefix-grepable).
- **Lesson for our plan.** This is *not* a drop-in replacement for `VOLVE.md`. `VOLVE.md` is a ~5KB identity/context prompt; the llm-wiki is a knowledge base built from documents you choose to ingest. They solve different problems. The relevant import is the discipline: a `log.md` of what the assistant did per day costs nothing and gives a grep-able audit trail — the same pattern OpenClaw arrived at independently with `memory/YYYY-MM-DD.md`.

### 3. Simon Willison's `llm` CLI ecosystem

Source: `simonwillison.net/2025/May/27/llm-tools/`, `github.com/simonw/llm`.

- **Shape.** CLI-first. `llm "prompt" -T toolname`, plug in tools as Python functions or plugin packages (`llm-tools-simpleeval`, `llm-tools-sqlite`, `llm-tools-datasette`, `llm-tools-quickjs`). No chat surface, no daemon, no scheduler — composes with Unix cron, pipes, and SQLite (Datasette).
- **Sources wired.** Whatever the user pipes in, plus tool plugins. Notably no MCP-first stance — tools are functions, MCP support is a community plugin.
- **What keeps it alive.** It's the *opposite* of an always-on assistant. Simon uses it as an interactive shell tool. The longevity signal is six years of weekly blog posts using it for one-off jobs.
- **Lesson for our plan.** The "answer my day" use cases in the spec ("what does my day look like?", "catch me up on Anna") are *one-shot* prompts. They don't actually need a long-running daemon, sessions, threads, or a UI — a CLI alias `volve "catch me up on Anna"` shelling out to `pi` or `claude -p` with the right MCP config would test the premise just as well, in an afternoon, with no port to expose. The proposed plan has already drifted from MVP toward platform.

### 4. `rhjoh/PiAssistant` — near-twin of the proposed plan

Source: `github.com/rhjoh/PiAssistant` (2 stars, active commits, ~57 commits).

This is the closest public precedent to what's being proposed and worth a hard look.

- **Shape.** Node gateway on localhost owning a single persistent pi RPC session, fan-out to **four** clients: Telegram bot, SwiftUI macOS app, React/Vite Web UI, pi TUI bridge extension. WebSocket on `:3456` (same port the plan picked!), file/status server on `:3457`.
- **Sources wired.** Memory via `memory.md` extracted by a background `memory-watcher` (10-min scan), proactive `heartbeat` (15-min interval), session manager handling `/new` and compaction archival to `sessions/archived/`. Pi runs in **RPC mode**, not embedded — divergence from OpenClaw and from this plan.
- **What keeps it alive / killed it.** Single contributor, 2 stars, no releases — call it a personal project that's running, not a validated product. README warns: *"The gateway binds to localhost only. Telegram is optional at runtime, but the gateway currently expects Telegram config to be present"* — a brittleness signal.
- **Lesson for our plan.** Someone already built this and reached the same shape (gateway + WebSocket + multi-client + heartbeat + memory-watcher) within a few weeks of starting. That's *both* validation that the shape is buildable and a warning that the MVP scope grows to include heartbeats, memory extraction, archival, and multi-client sync almost immediately. It also confirms that **embedded vs RPC** is a real fork in the road — Ronacher and OpenClaw chose embedded; rhjoh chose RPC. The plan picks embedded; that's the better-attested choice.

### 5. Ronacher's pi philosophy post — the "no MCP" position

Source: `lucumr.pocoo.org/2026/1/31/pi/`.

- **Shape.** Personal Telegram bot (mentioned in passing) on top of pi.
- **Position.** *"This is not a lazy omission. This is from the philosophy of how Pi works. Pi's entire idea is that if you want the agent to do something that it doesn't do yet, you don't go and download an extension or a skill or something like this. You ask the agent to extend itself."*
- **Lesson for our plan.** The plan leans hard on `@0xkobold/pi-mcp` as the integration glue. That's pragmatically reasonable — Linear/Notion ship official MCP servers and writing five custom pi extensions on day one is wasteful — but it puts the build in tension with the host agent's design philosophy. The honest fallback path the plan already lists (drop pi-mcp, use `@fink-andreas/pi-linear-tools` + `@feniix/pi-notion` + small custom extensions) is the more pi-native shape and should be the *day-2* target, not the emergency parachute.

### 6. Home Assistant Assist + local-LLM (briefly)

Source: search results pointed to `xda-developers.com/ways-to-use-home-assistant-with-local-llm/` and `community.home-assistant.io` threads. Skimmed only.

- **Shape.** Voice/chat front, structured "exposed entities" as the only thing the LLM sees, deterministic intent matching as a fallback. **Dead end** for this plan: the relevant insight (*tightly scope what the LLM can see*) is already covered by OpenClaw's tool-policy and per-sender allowlists, so no separate citation needed.

## Synthesis

### 1. Does the chat-DM shape work in practice?

**Mixed evidence, leaning yes — but not as a daemon-with-UI.** OpenClaw's traction (240k stars, real users) is the strongest signal that messaging-in / agent-out works. But every precedent that *survived* added structure the MVP plan currently omits: persistent memory files (OpenClaw `MEMORY.md` + daily logs, rhjoh `memory.md` watcher, Karpathy wiki), per-sender allowlisting, and a chronological append-only log. None of the precedents I found is a "stop-using" postmortem — but rhjoh/PiAssistant at 2 stars and Simon Willison's deliberately *non*-persistent `llm` CLI together suggest the persistent-chat-with-UI variant has high build cost relative to one-shot CLI invocation. I could not find published "I built this and stopped" postmortems for assistants of this exact shape, despite searching; treat absence as weak evidence (people don't blog about quiet abandonment), not endorsement.

### 2. Embedded pi SDK vs alternatives

**Embedded pi SDK is the right call and well-attested.** OpenClaw's docs explicitly justify it: *"Instead of spawning pi as a subprocess or using RPC mode, OpenClaw directly imports and instantiates pi's AgentSession via createAgentSession(). This embedded approach provides: Full control over session lifecycle and event handling, Custom tool injection, System prompt customization per channel/context."* That's exactly the plan. The visible alternative (rhjoh/PiAssistant's RPC mode) exists but is operated by one person at 2-star scale; OpenClaw operates at 240k-star scale. The baseline `claude -p` subprocess shape from `volve-assistant-mvp.md` is fine for an afternoon test but throws away session reuse, prompt caching, and event streams that the plan needs for the proposed UI. **Stack decision: keep.**

### 3. VOLVE.md vs llm-wiki

**Keep VOLVE.md hand-maintained for MVP. Do *not* adopt llm-wiki yet.** They solve different problems: VOLVE.md is identity/preferences/people (an *injected prompt*), llm-wiki is an *accumulated knowledge base over ingested documents*. There is nothing to ingest on day one — the assistant *queries live MCPs*; it doesn't have a `raw/` corpus. Karpathy himself describes the artifact as compounding *as you add sources*. The directly transferable Karpathy idea, which OpenClaw already implements, is the **`log.md`** — an append-only chronological record of what the assistant did and decided each day, prefix-formatted for `grep`. That's a 5-line addition, gives you an audit trail, and seeds a future llm-wiki migration if the user later wants one.

### 4. Three specific plan changes

1. **Adopt OpenClaw's two-layer memory file pattern from day one.** Add `context/log.md` (append-only, `## [YYYY-MM-DD HH:MM] <kind> | <thread>` prefix) and an empty `context/MEMORY.md`. The system prompt instructs the agent to append to `log.md` after meaningful turns and to read `MEMORY.md` for cross-session knowledge. Source: OpenClaw `personal-assistant` guide (`memory/YYYY-MM-DD.md` + `MEMORY.md`) and Karpathy `log.md` convention. Cost: ~10 lines. Without it, the JSONL session files are the only audit trail, and they're not human-grep-able.

2. **Drop the multi-thread sidebar UI for MVP; ship a single persistent thread + `/new` slash command.** rhjoh/PiAssistant built the multi-client/thread infrastructure and ended up at 2 stars and a brittle gateway. OpenClaw defaults to **per-sender** sessions (`session.scope: "per-sender"`) with `/new` as the reset trigger, not a thread list. For a single-user MVP, "thread list in sidebar + thread autonaming" is platform thinking. Source: OpenClaw personal-assistant guide (`session.scope: "per-sender"`, `resetTriggers: ["/new", "/reset"]`). Saves an estimated 50% of the web UI code.

3. **Replace "Tailscale = auth" with an explicit allowlist, and disable any heartbeat/cron path until the MVP's success criterion is met.** OpenClaw's guide opens with: *"Always set channels.whatsapp.allowFrom (never run open-to-the-world on your personal Mac)"* and ships heartbeats *off* in the personal-assistant config (`every: "0m"`) with the rationale *"shorter intervals burn more tokens."* Translate to this plan: (a) add a hard-coded allowlist check on the `/prompt` endpoint keyed to a long-lived browser cookie or shared secret in addition to Tailscale, so a hostile device on the tailnet can't hit it; (b) explicitly assert in the README that no scheduler exists and none will be added until the success criterion (5 weekdays of useful exchanges) is hit. Source: OpenClaw personal-assistant guide, Safety section.
Written to `/Users/jorgens.kontorp/Downloads/.pi-delegate/results/task-2.md` (~1850 words).

Six precedents studied, with direct quotes from OpenClaw docs, the dev.to teardown, Ronacher's pi post, and the Karpathy gist. One unreachable URL (`docs.openclaw.ai/guides/personal-assistant`, 404) — substituted with the equivalent guide at `openclaw-ai.com`. One near-twin project surfaced that wasn't on the suggested list: `rhjoh/PiAssistant`, which independently arrived at the proposed gateway+WebSocket+:3456 shape, including heartbeats and memory-watcher.

Headline calls:
- Embedded pi SDK: keep (well-attested by OpenClaw at scale).
- llm-wiki: don't adopt; steal only the `log.md` convention.
- Three concrete plan changes, each cited: add two-layer memory files; drop multi-thread sidebar in favor of `per-sender` + `/new`; harden auth beyond "Tailscale = auth" and explicitly forbid heartbeats until premise is validated.

---
Exit code: 0
Finished: 2026-04-23T17:27:57+02:00
