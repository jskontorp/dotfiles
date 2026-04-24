# Volve Assistant — shelved 2026-04-24

A personal assistant DM'd from Slack (or a private web UI) that answers cross-source questions — *"what does my day look like?"*, *"catch me up on Anna before our 10am"*, *"what's open on project X?"* — by querying Linear / Notion / Calendar / Gmail / Slack on demand.

Shelved after narrowing and a four-angle peer review. The review produced findings strong enough that I don't want to build Phase 1 as planned; keeping the work here so future-me can pick up from data, not speculation.

## Files

- `mvp-spec.md` — the original 40-lines-of-Python weekend-hack baseline I wrote.
- `vision-spec.pdf` — the full Phase-1-through-N vision the MVP supersedes-but-doesn't-replace.
- `narrowed-plan.md` — where the narrowing landed before peer review (pi SDK embedded, Node+Fastify+SSE, Tailscale web UI, pi-mcp adapter, five sources, thread-per-session).
- `review/01-stepback.md` — frame-level critique. Argues the plan scope-drifted from weekend-hack to small-product, and that the chat-DM shape was inherited from Slack without re-justification once Slack was dropped.
- `review/02-prior-art.md` — research on OpenClaw, Karpathy's `llm-wiki`, Simon Willison's `llm` CLI, `rhjoh/PiAssistant`, Ronacher's pi philosophy post.
- `review/03-technical.md` — architecture review. Top concerns: MCP OAuth on a headless VM, `@0xkobold/pi-mcp` maturity (2 commits, no OAuth), error-surface UX.
- `review/04-security.md` — security/ops review. Top concern: routing Volve customer/employee data through GitHub Copilot → Anthropic is continuous silent third-party disclosure and isn't bounded to my VM.

## What the review changed

Before touching code again, two things have to happen — in this order — or the project stays shelved:

1. **Ask Volve whether routing company data through Copilot→Anthropic for personal productivity tooling is sanctioned.** One Slack to manager/CTO. If no: project is dead in this shape (need self-hosted model or redact at MCP boundary). If yes: document it and proceed.

2. **Test the premise with a cron + Markdown file, not a UI.** The smallest test of *"would I use a thing that pre-fetches my context"*:

   ```
   */30 6-9 * * 1-5  pi -p "$(cat ~/volve/morning-prompt.md)" >> ~/volve/today.md
   ```

   Linear only, output opened at 07:00 via launchd. Run for a week. If I read `today.md` voluntarily and it tells me something my (separately tuned) Linear/Calendar/Notion saved views don't, the premise holds. If not, no architecture would have saved it.

In parallel, spend ~90 minutes tuning Linear/Calendar/Notion saved views I already pay for. It's genuinely possible the underlying pain is configuration debt, not absence of an assistant.

## What changes in Phase 1, if Phase 0 proves the premise

Not the plan in `narrowed-plan.md`. The revised stack:

- **Single thread, `/new` to reset.** No sidebar, no thread-list UI (convergent finding across three reviewers; cites OpenClaw's per-sender single-session pattern).
- **No SSE.** `POST /prompt` returns JSON. Streaming is Phase 2 polish.
- **Don't use `@0xkobold/pi-mcp` as the spine.** Build on `@fink-andreas/pi-linear-tools` + `@feniix/pi-notion` first. Add Calendar/Gmail as small custom pi extensions or via `mcporter` (OpenClaw's pattern). pi-mcp can come back when it has tests and OAuth.
- **`context/log.md` + `context/MEMORY.md` from day one** (OpenClaw/Karpathy pattern). Append-only chronological log + curated memory file. ~10 lines, gives a grep-able audit trail.
- **MCP auth done locally first**, refresh tokens copied to VM. `GET /mcp/status` endpoint. Visible "🔑 re-auth needed for {source}" inline chat messages — not silent empty answers.
- **Bind to `tailscale0` interface only + static bearer token.** Tailscale alone isn't enough as an auth boundary.
- **30-day retention cron on `sessions/`** (they contain plaintext Gmail/Linear content).
- **`SECRETS.md` + 5-step kill-switch playbook** in the repo README before ship.

## Open questions to settle before unshelving

- Volve's data-handling / AI-processing policy — sanction or not.
- GitHub Copilot data-retention settings on my account (verify: no training, no retention).
- OAuth refresh story per MCP source — particularly Google (Gmail/Cal) on a headless VM.
- Whether `@0xkobold/pi-mcp` or `pi-mcp-adapter` matures into something production-grade by the time I pick this up again.

## Unshelve trigger

Revisit when (a) Phase 0 cron/briefing experiment has run a week with positive signal, AND (b) Volve sanction question is answered, AND (c) I still want an *interactive* surface on top of the briefing (if the briefing alone is enough, this project is done and it's just a cron).
