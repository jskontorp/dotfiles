# Task 3 — Technical architecture review

Reviewed against `volve-assistant-mvp.md` (baseline) and `proposed-plan.md` (current). Verified against the bundled pi SDK docs (`sdk.md`, `session.md`, `compaction.md`) and the `0xKobold/pi-mcp` GitHub repo.

The plan is broadly coherent. Most of the risk is concentrated in two places: (a) MCP OAuth on a headless box, and (b) the maturity of `@0xkobold/pi-mcp`. The rest is largely operational hygiene.

---

## 1. Long-running daemon concerns

**Concern.** Node will hold N pi sessions, M MCP transports, and OAuth tokens for weeks. Concrete failure modes:
- Each `AgentSession` holds the full event log in memory (the JSONL is the persistence mirror). A long thread becomes a permanent live object until you explicitly drop it. Nothing in `createAgentSession()` evicts idle sessions.
- The plan reads "thread list from disk" on demand but doesn't say sessions are evicted from RAM after inactivity. Without an LRU you'll grow until restart.
- pi's `subscribe()` returns an unsubscribe; the SDK explicitly notes "re-subscribe after replacement" for `newSession()` (sdk.md L168-181). An SSE client that disconnects without you calling unsubscribe leaks a listener per reconnect.
- File descriptors: SessionManager writes one JSONL per session. Only the *active* session keeps a write handle open, so 100 archived threads ≠ 100 fds. Sidebar list = `readdir` + read first line of each → cheap up to thousands.
- MCP transports: pi-mcp does have auto-reconnect with exponential backoff (per its README), so the storm risk is bounded, but on simultaneous network blip you'll get N parallel re-handshakes against Linear/Notion/Google/Slack at once.

**Severity: medium.** Memory growth and listener leaks bite within month 1 of daily use, not week 1.

**Action.** Add a session cache with idle-eviction (drop in-memory `AgentSession` after N minutes inactive; reload from JSONL on next prompt) and make sure SSE `req.raw.on('close')` calls the pi `unsubscribe()`. Skip metric collection for MVP, revisit when you observe a `pmap` over 1 GB.

---

## 2. SSE streaming correctness

**Concern.** pi's event stream (`message_update` deltas, tool-call events, `session_update`, etc.) is richer than "token deltas." Mapping it to SSE is fine in principle, but:
- **Reconnect mid-stream**: `EventSource` auto-reconnects and replays from `Last-Event-ID` *only if you set IDs*. The plan doesn't. A phone waking up will reopen the stream and either miss the tail or get nothing because the turn already finished server-side. You need a per-turn buffer keyed by turn id, replayable on reconnect, with a TTL.
- **Backpressure**: Fastify's reply stream will buffer in Node if the TCP socket stalls (sleeping phone). Heap grows per stalled client. Cap the buffer or drop the connection after a timeout.
- **Ordering**: pi events have semantic ordering (tool call → tool result → text continues). SSE preserves order on a single connection but you must serialize events through one writer; if you `await` markdown rendering or DB writes between events, you can interleave.
- **Second prompt while first is streaming**: `session.prompt()` *throws* in this case unless you pass `streamingBehavior: "steer"` or `"followUp"` (sdk.md L224). Your UI must either disable the input during a turn or explicitly pick steer/followUp — silent failure here will look like a dropped message.

**Severity: high** for the second-prompt case (will happen on day one when you tap send twice on mobile); medium for reconnect.

**Action.** (a) Disable the composer while `streaming===true`, surface an obvious "interrupt" button that calls `steer()`. (b) Assign monotonic event IDs per turn, keep last turn's events in a ring buffer, honour `Last-Event-ID` on reconnect. Skip persistent replay for MVP.

---

## 3. pi SDK fit

**Concern.** `createAgentSession()` is the supported embedded pattern (sdk.md L19-38; OpenClaw uses it). No fundamental mismatch. Specifics worth pinning:
- `prompt()` returns `Promise<void>` — your HTTP handler should *not* await it before responding; respond `202 Accepted` with a turn id, push events over the SSE channel.
- `bindExtensions()` must be re-called when sessions are recreated (sdk.md L169). If you use `createAgentSessionRuntime()` for `newSession()`, don't forget to rebind pi-mcp on the new session or tools silently disappear.
- `steer`/`followUp` are real and useful; expose `steer` as the "interrupt" button. `followUp` is rarely what a chat user wants — skip in MVP UI.
- pi's `DefaultResourceLoader` `agentsFilesOverride` injects `VOLVE.md` as an `AGENTS.md`-equivalent — confirmed valid path; just be aware it's resolved once at session creation, so editing `VOLVE.md` mid-thread won't take effect until next session.

**Severity: low.** The fit is real; only failure mode is forgetting `bindExtensions` on new sessions.

**Action.** Centralise session creation in one helper that also wires extensions and re-subscribes. Skip runtime-replacement complexity for MVP — one session per thread, no `newSession()` mid-thread.

---

## 4. MCP OAuth in a headless daemon

**Concern.** This is the single most under-specified piece of the plan. The pi-mcp README shows OAuth nowhere — its auth model is `Authorization: Bearer ${API_TOKEN}` headers via env interpolation. Looking at each source:
- **Linear** (`mcp.linear.app/mcp`) uses MCP's standard OAuth (Dynamic Client Registration + browser callback). pi-mcp does not appear to implement the OAuth client; you'd need either a pre-obtained access token (Linear's OAuth tokens expire — refresh required) or to do the dance out-of-band.
- **Notion**: integration-token model works headlessly (paste token in env). Easiest of the bunch.
- **Google Calendar / Gmail** (official MCP via Google or community): OAuth, callback URL must be reachable. From a Tailscale-only VM, Google's redirect URI to a non-public host is awkward — usually solved by running the OAuth dance once on your laptop (with `localhost` redirect), then transferring the refresh token to the VM env.
- **Slack** (if used as a source MCP): bot token works headlessly.

`pi-mcp` does not (per README) handle OAuth refresh. If a token expires, the server-side MCP returns 401, pi-mcp will reconnect-storm and surface as tool failure with no helpful message.

**Severity: high.** Linear-via-OAuth and Google-via-OAuth will both bite in week 1 — Linear immediately, Google within 7 days when the access token expires.

**Action.** Before writing UI code: do the OAuth dance for each remote MCP on your Mac, capture access+refresh tokens, paste into VM env. For Linear specifically, either (a) skip the official MCP and use `@fink-andreas/pi-linear-tools` with a personal API key, or (b) write a tiny refresh-token cron. Plan an explicit "MCP auth health" endpoint (`GET /mcp/status`) that pings each server and shows last error — without it you'll debug blind.

---

## 5. Session persistence and thread model

**Concern.**
- pi's session schema is versioned and *auto-migrates on load* (session.md L19-27, currently v3, v1→v2→v3 already shipped). Across pi minor versions you're safe; across a major you may need to pin pi or accept a one-time migration. Low risk.
- Sessions live under `~/.pi/agent/sessions/--<path>--/<ts>_<uuid>.jsonl`. The plan says `sessions/` under the project — that's the cwd-derived path, fine.
- Sidebar list: reading first JSONL line for 100 files is microseconds. No issue at MVP scale.
- Delete/archive: not in the plan at all. You'll want at minimum a "delete thread" button — without it the sidebar grows without bound and contains old experiments. Just `rm` the JSONL.
- Privacy: JSONLs contain plaintext Gmail/Linear/Calendar payloads. Filesystem permission is your only barrier. (Covered in security review.)

**Severity: low** (technically) / **medium** (UX — no delete = sidebar rot).

**Action.** Add `DELETE /threads/:id` that deletes the JSONL. Skip rename/archive for MVP, revisit when sidebar exceeds ~50 threads.

---

## 6. `@0xkobold/pi-mcp` maturity

**Concern.** Repo state (verified): **2 commits, 0 stars, 0 forks**, single author, no visible tests beyond a `test/` dir. Bun-locked (`bun.lock`) — interop with your pnpm/npm workflow is unverified. Features look reasonable on paper (four transports, allow/denylist, auto-reconnect, env interpolation) but there is *no production track record* and no OAuth story (see §4).

This is the highest-leverage single dependency in the stack and it is essentially pre-alpha.

**Severity: high.** Anything from a missing reconnect edge case to a transport bug will land in your week-1 use.

**Action.** Vendor it. Either (a) fork into the repo and pin to a SHA, or (b) skip it and stand up MCP via the two pi-native packages already in the plan's open-questions (`@fink-andreas/pi-linear-tools`, `@feniix/pi-notion`) plus thin custom extensions for Calendar/Gmail. Treat pi-mcp as a "if it works, great" path, not the spine.

---

## 7. Thread-local memory sufficiency

**Concern.** "No cross-thread memory" is fine on day 1 but breaks within a week the moment you say "follow up on what I asked yesterday about Anna" in a new thread. The MVP spec already calls this out and accepts it. The real question is the smallest retrofit:
- **Cheapest**: one paragraph appended to `VOLVE.md` after each session, hand-edited or LLM-summarised. Karpathy's `llm-wiki` is the same idea; defer.
- **Better**: nightly job that compacts each new JSONL into a one-paragraph summary file under `context/recall/`, all loaded into the agents file. Trivial to add later.
- **Avoid for MVP**: vector retrieval. Not justified at this scale.

**Severity: medium.** You'll feel it in week 2.

**Action.** Skip for MVP. Revisit when you catch yourself opening an old thread to copy-paste context into a new one twice in one week.

---

## 8. Model / provider specifics

**Concern.**
- `github-copilot/claude-opus-4.7` via pi works (you use it daily). Rate limits on Copilot's Anthropic passthrough are not publicly documented; expect occasional 429s under a "morning briefing" burst. pi will surface these as model errors — make sure they hit the chat UI, not just stderr.
- Long context: pi's auto-compaction triggers on token threshold (compaction.md L29-37) and is purely session-internal — it works identically in embedded mode. No action needed.
- Opus is expensive (in tokens, even on Copilot's flat-fee). For "what's on my calendar" questions, Sonnet would be plenty; Opus is wasted. Consider `claude-sonnet-4.x` as default, Opus as opt-in per thread.

**Severity: low.**

**Action.** Use Sonnet by default; expose a per-thread model switch later. Skip until you actually feel cost or latency.

---

## 9. Build/deploy gap

**Concern.**
- Mac → Linux: pi itself has no native deps in `pi-coding-agent`'s direct closure (pure TS/JS), but `better-sqlite3` and similar can sneak in via transitive deps. If you `pnpm install` on Mac and `rsync` the `node_modules`, native binaries will be wrong-arch. Always `pnpm install` on the VM, or use `pnpm deploy --prod` to a clean tree there.
- Node version: the plan says 20+. pi-coding-agent's `engines` field — confirm both machines on the same major (ideally pin via `.nvmrc` / `volta`).
- ESM + Fastify + tsx/tsc: trivial, no traps.
- pi auth on the VM: pi reads creds from `~/.pi/`. Already present (you use it daily). The systemd unit must run as your user, not `root` or a service user, otherwise pi has no auth (`User=jskontorp`, as the spec already shows for the Python version — replicate).
- systemd: `Restart=on-failure` will hide a session-construction crash loop. Add `StartLimitIntervalSec` / `StartLimitBurst` so you actually notice.
- Bun lockfile in pi-mcp: if you import pi-mcp directly from the npm tarball you get the built JS, no Bun needed at install time. If you fork (recommended in §6), watch the build step.

**Severity: medium.**

**Action.** `nvmrc` pinned, `pnpm install` on the VM (never copy `node_modules`), `User=` set in systemd, `StartLimitBurst=3 StartLimitIntervalSec=60`. Skip Docker for MVP.

---

## 10. Error surfaces

**Concern.** The plan has no mention of error UX. pi's events include `error` payloads on tool failures and model errors, but they need to be explicitly mapped into chat-visible messages. Default failure modes today:
- MCP server 401 (token expired) → tool returns error → model may retry or apologise vaguely → user sees "I couldn't find that" with no clue why.
- pi-mcp reconnect storm → tools simply absent from the manifest → model says "I don't have access to Linear" instead of "Linear is disconnected."
- Model rate limit → SSE stream ends without an assistant message → spinner forever.
- Network drop mid-tool-call → pi may hang waiting for the MCP response; no client-visible error.

**Minimum shippable error UX**:
1. Every pi `error` event renders as a red inline chat block with the raw message.
2. SSE stream always ends with either a `done` or `error` frame; client has a 60s no-event timeout that surfaces "stream stalled, retry?".
3. A `/health` page (or a status pill in the sidebar) showing per-MCP connection state, last error, last successful tool call timestamp.
4. Tool-call failures surface as a collapsed "🔧 linear.search_issues failed: 401 Unauthorized" line in the message thread, not just in logs.

**Severity: high.** Without (1)–(3) you will spend MVP week debugging via `journalctl` instead of using the assistant.

**Action.** Build (1) and (2) before first end-to-end test. (3) and (4) within first week of dogfooding.

---

## Top three changes I'd insist on before shipping

1. **Solve MCP auth concretely, per source, before any UI work.** Document the OAuth dance for Linear and Google (laptop-side, transfer refresh token to VM env), or swap Linear for `@fink-andreas/pi-linear-tools` with a personal API key. Add a `GET /mcp/status` endpoint that pings each server. *Without this the MVP simply does not function past day one.*

2. **Don't depend on `@0xkobold/pi-mcp` as the spine.** It's a 2-commit repo with no OAuth and no track record. Either vendor it (fork + pin SHA, accept maintenance burden) or build the Linear+Notion path on the existing pi-native packages and add Calendar/Gmail as small custom extensions. pi-mcp can come back when it has tests and OAuth.

3. **Wire error events and the second-prompt-during-stream case in the UI from day one.** Disable composer (or use `steer()`) while streaming, render pi `error` events as red inline messages, end every SSE stream with an explicit `done` or `error` frame, and add a 60s client-side stall timeout. Without these, every real failure looks like "spinner forever" and you'll abandon the tool inside a week.

Everything else (session eviction, sidebar delete, Sonnet-by-default, systemd hardening) is month-1 polish — useful, not blocking.
Review written to `/Users/jorgens.kontorp/Downloads/.pi-delegate/results/task-3.md` (~1850 words).

Headline findings:

- **Highest-leverage risk is MCP auth, not the daemon shape.** `@0xkobold/pi-mcp`'s README shows no OAuth client — only `Bearer ${API_TOKEN}` env interpolation. Linear's hosted MCP and Google's OAuth-based MCPs need a real OAuth dance + refresh, which on a Tailscale-only VM means doing it on the Mac and transferring tokens. This is unsolved in the plan.
- **`@0xkobold/pi-mcp` is 2 commits, 0 stars, single author, Bun-locked.** Pre-alpha, and it's the spine of the proposed integration. Fork-and-pin or fall back to the pi-native Linear/Notion packages already mentioned in the plan's open questions.
- **Two SSE/SDK gotchas the plan glosses:** `session.prompt()` *throws* if called during streaming unless you pass `streamingBehavior` (sdk.md L224) — UI must disable composer or wire `steer()`. And `EventSource` reconnect needs per-event IDs + a turn-buffer or wake-from-sleep loses the tail.
- pi SDK fit itself is fine; embedded `createAgentSession` is supported and OpenClaw-like. Session schema is versioned with auto-migration. Compaction works in embedded mode.
- Error UX is essentially undesigned in the plan; minimum viable bar specified in §10.

Top three insists are at the bottom of the file.

---
Exit code: 0
Finished: 2026-04-23T17:28:07+02:00
