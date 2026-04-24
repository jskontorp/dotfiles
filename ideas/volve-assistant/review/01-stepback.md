# Frame-level review — Volve assistant MVP

## 1. What is the user actually trying to solve?

The plan never says it cleanly. Reading between the lines: Fink wants less friction reconstructing context that's already scattered across Linear, Notion, Gmail, Calendar, and Slack — specifically the "what's today, who am I about to meet, what's open" lookups that currently cost N tab-switches. The deeper need is probably *cognitive offloading at predictable moments* (start of day, before a meeting), not interactive Q&A. What's fuzzy: whether the pain is **answering arbitrary questions on demand** (which justifies a chat surface) or **not having to ask in the first place** (which justifies a briefing/dashboard and rules out chat as the primary shape). The success criterion — "one exchange a day saves meaningful clicking" — is suspiciously low; if that's the bar, the underlying need may not justify any new system.

## 2. Is a DM-style chat interface the right shape?

Probably not, or at least not first. Chat assumes the user *knows what to ask* and is willing to type a question, wait for a tool-using agent, and read prose back. For "what's my day," a chat round-trip is strictly worse than:

- **Morning briefing, one-shot, pushed.** A 06:30 cron that runs the same prompts and posts the result to a single Slack DM-to-self, an email, or a Markdown file opened by the menubar. Zero UI to build, zero session state, zero auth. Covers the 80% case ("today + Anna at 10 + open on project X") without the user ever typing.
- **Read-only "today" URL.** A static page rendered on demand by hitting one endpoint — same content, no threads, no SSE, no sidebar. If the user wants to refresh, they refresh. Removes 80% of the Node/Fastify/SSE/session-persistence scope.
- **Raycast / Alfred command.** Fink lives in macOS; a single Raycast script command `volve today` invoking `claude -p` against MCP and rendering Markdown is ~20 lines and uses a surface he already opens dozens of times a day. Beats opening a browser tab to a Tailscale URL.
- **Augment existing tools.** Linear saved filter for "stale & mine," Calendar's existing agenda view, Gmail's priority inbox, a Notion homepage. Most of the queries the plan enumerates have native equivalents that the user has presumably not tuned. If the unsexy answer is "configure the tools you already pay for," the assistant doesn't need to exist.
- **CLI in his terminal.** If the user lives in a shell, `volve` printing today's briefing is the lowest-friction surface he could possibly have.

The plan picked chat because the baseline spec picked Slack, and chat persisted through narrowing without being re-justified once Slack was dropped. The argument for chat *with Slack removed* is much weaker — Tailscale-gated localhost web UI is a worse chat surface than Slack on every axis (no mobile push, no native client, no search, no thread UX you didn't write).

## 3. Sunk-cost check

- **pi over Claude Code headless.** Defensible — in-process SDK avoids subprocess spawn — but only matters if you're doing many turns. For a single morning briefing, `claude -p` is fine and the baseline already worked. Switching to pi added "Node project" to the scope. Self-pleasing: medium.
- **`@0xkobold/pi-mcp` adapter.** A young package (flagged in the risks) being placed on the critical path for five sources. The fallback (pi-linear-tools, pi-notion, custom gcalcli/Gmail wrappers) is already messier than `claude -p --mcp-config` was in the baseline. Self-pleasing: high — it's there because pi was chosen, not because the user needs it.
- **Node/Fastify/SSE.** Streaming tokens to a private single-user web UI is theatre. SSE solves "user wants to watch the assistant think"; the actual job is "deliver an answer." A `POST /prompt` returning JSON would be 1/3 the code. Self-pleasing: high.
- **Tailscale web UI.** Solves a problem (mobile access from outside LAN) the user hasn't established he has. If the answer is delivered as a push notification or email, no UI is reachable-from-phone in the first place. Self-pleasing: high.
- **Five MCP sources at MVP.** The baseline correctly says "Linear only, then add one at a time." The plan repeats this but the architecture is sized for all five from day one. The premise can be tested with one source. Self-pleasing: medium.
- **VOLVE.md hand-maintained.** Honest and probably right for now — but listed alongside an "llm-wiki Phase 2" plan that hints at scope drift before Phase 1 has shipped.

Pattern: every commitment except VOLVE.md exists because of a prior commitment, not because of the user's stated need.

## 4. Is the MVP actually an MVP?

No. A Node/TypeScript/Fastify/SSE/session-persistence/Tailscale/systemd build with five MCP sources is a small product, not a premise test. The premise — "would I use a thing that pre-fetches context for me" — can be tested this afternoon with:

```
*/30 6-9 * * 1-5  claude -p "$(cat ~/volve/morning-prompt.md)" --mcp-config ~/.config/claude/mcp.json >> ~/volve/today.md
```

…pointed at Linear only, with the output opened in whatever Markdown viewer Fink already uses. If after a week he's reading `today.md` voluntarily, the premise holds and *then* the question "should this be ambient, chat, or push?" becomes answerable from data instead of speculation. If he's not reading it, no architecture would have saved it.

## 5. Strongest case against building this at all

The five workflows the plan enumerates are all solved, badly, by tools the user already pays for. Linear has saved views; Calendar has agenda; Gmail has priority inbox; Notion has a homepage; Slack has search. The honest read is that the pain is **configuration debt in existing tools**, not absence of an assistant. An LLM that re-queries five APIs every morning to produce a paragraph is a workaround for not having tuned the dashboards he already has. Additional cost: secrets for five services on a VM, plaintext session JSONL containing Gmail/Calendar content (flagged in the plan's own risks), OAuth refresh fragility, and the standing maintenance tax of a personal system that breaks when any upstream MCP or pi-mcp ships a change.

Evidence that would change his mind, gettable without building: spend 90 minutes tuning a Linear "my stale issues" view, a Calendar focused-view, and a Notion homepage. Use them for a week. If he still finds himself doing the cross-source reconstruction by hand, the assistant's premise is real. If not, it isn't.

## 6. Recommendation

Kill the current plan. Today, write the cron-driven shell script: one `claude -p` invocation against Linear MCP only, output appended to `~/volve/today.md`, opened automatically at 07:00 via a launchd `open` action. In parallel, spend one evening tuning Linear/Calendar/Notion saved views. Run both for one week. At end of week ask one question: *did I read `today.md` voluntarily, and did it tell me something the tuned dashboards didn't?* If yes to both, expand to two more sources and keep the format identical — still a Markdown file, still no UI. Only revisit chat/web/Tailscale if a concrete interaction pattern emerges that a static morning artifact cannot serve, and at that point reconsider Slack DM (the original baseline) before building a bespoke web client. The Node/Fastify/SSE/session/Tailscale stack is a solution looking for the problem the premise hasn't yet proven exists.
Written to `/Users/jorgens.kontorp/Downloads/.pi-delegate/results/task-1.md`.

Headline take: the plan drifted from a 40-line weekend Python hack into a Node/Fastify/SSE/Tailscale/web-UI/session-persistence build, and chat-as-shape was never re-justified after Slack was dropped. The premise (would I use pre-fetched cross-source context) is testable this afternoon with one cron job writing to a Markdown file against Linear only — and there's a real chance the actual problem is untuned existing dashboards, not absence of an assistant. Recommendation: kill the current plan, run the shell-script + tuned-views experiment for a week, decide from data.

---
Exit code: 0
Finished: 2026-04-23T17:26:40+02:00
