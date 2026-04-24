# Volve Assistant — MVP

Minimal build. Slack DM in, Claude Code response out, MCP for everything else. No watchers, no DB, no digests. Ships in a weekend.

Supersedes nothing. The full spec (`volve-assistant-spec.md`) stays the vision. This is the smallest artifact that tests the premise.

---

## What it is

A long-running Python process on the VM that bridges Slack ⇄ Claude Code:

```
You DM the bot  →  Bolt receives  →  shell `claude -p` with MCP  →  reply in Slack
```

That's the whole thing. ~40 lines of Python, three config files, one systemd unit.

Everything clever — which Linear issue is stale, what the email thread says, what's on your calendar — Claude Code figures out live via MCP on each turn. No pre-computation, no state.

## What it does

- Answers "what does my day look like?" by querying Calendar + Linear + Notion + Gmail MCP.
- Answers "I'm meeting Anna at 10, catch me up" by searching across sources for Anna-related context.
- Answers "what's open on [project]?" by reading Linear + Notion.
- Maintains conversation within a Slack thread (reply in the thread, it sees the prior turns).
- Loads `VOLVE.md` as system context every turn — who you are, who the people are, your preferences.

## What it doesn't do (yet)

- Proactively alert (no watchers).
- Scheduled digests (no cron).
- Remember across threads / sessions (thread-local memory only).
- Take actions (read-only MCP usage; no sending emails, no closing issues).

Each of these is a *later* Phase in the full spec. Don't add them until the MVP has run in daily use for a week and you know which one actually matters.

---

## Architecture

```
┌────────────────┐       WebSocket        ┌──────────────────┐
│  Slack (you)   │ ◄──────────────────►   │  Bolt bot        │
└────────────────┘      (Socket Mode)      │  (~40 lines Py)  │
                                           └────────┬─────────┘
                                                    │ subprocess
                                                    ▼
                                           ┌──────────────────┐
                                           │  claude -p       │
                                           │  (headless CC)   │
                                           └────────┬─────────┘
                                                    │ MCP (stdio/http)
                    ┌──────────────┬────────────────┼────────────────┬──────────────┐
                    ▼              ▼                ▼                ▼              ▼
                ┌────────┐   ┌─────────┐    ┌───────────┐    ┌─────────┐    ┌──────────┐
                │ Linear │   │ Notion  │    │ Calendar  │    │  Gmail  │    │  Slack   │
                └────────┘   └─────────┘    └───────────┘    └─────────┘    └──────────┘
```

No DB. No queue. No scheduler. The bot holds no durable state beyond the filesystem files below.

---

## The whole bot

```python
# volve_bot.py
import os
import subprocess
from pathlib import Path
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler

app = App(token=os.environ["SLACK_BOT_TOKEN"])

VOLVE_MD = Path("~/volve/VOLVE.md").expanduser().read_text()
MCP_CONFIG = str(Path("~/.config/claude/mcp.json").expanduser())
TIMEOUT_S = 300

@app.event("message")
def handle_dm(event, say, client):
    # DMs only, ignore self
    if event.get("channel_type") != "im":
        return
    if event.get("bot_id") or event.get("subtype"):
        return

    user_msg = event["text"]
    channel = event["channel"]
    ts = event["ts"]
    thread_ts = event.get("thread_ts", ts)

    # Build prompt — include thread history if this is a reply
    if thread_ts != ts:
        history = client.conversations_replies(channel=channel, ts=thread_ts)
        prior = "\n".join(
            f"{'you' if m.get('bot_id') else 'user'}: {m['text']}"
            for m in history["messages"][:-1]
        )
        prompt = f"Prior thread:\n{prior}\n\nNew message: {user_msg}"
    else:
        prompt = user_msg

    # Visual feedback
    client.reactions_add(channel=channel, timestamp=ts, name="eyes")

    try:
        result = subprocess.run(
            [
                "claude", "-p", prompt,
                "--append-system-prompt", VOLVE_MD,
                "--mcp-config", MCP_CONFIG,
                "--output-format", "text",
            ],
            capture_output=True, text=True, timeout=TIMEOUT_S,
        )
        response = result.stdout.strip() or f"(empty; stderr: {result.stderr[:300]})"
    except subprocess.TimeoutExpired:
        response = f"Timed out after {TIMEOUT_S}s."
    except Exception as e:
        response = f"Error: {e}"

    say(text=response, thread_ts=thread_ts)
    try:
        client.reactions_remove(channel=channel, timestamp=ts, name="eyes")
    except Exception:
        pass

if __name__ == "__main__":
    SocketModeHandler(app, os.environ["SLACK_APP_TOKEN"]).start()
```

That's the bot. Everything else is config.

---

## Files

```
~/volve/
├── VOLVE.md                         # hand-maintained context (git-crypt'd or gitignored)
├── volve_bot.py                     # the script above
├── requirements.txt                 # slack-bolt
└── .env                             # SLACK_BOT_TOKEN, SLACK_APP_TOKEN (mode 600)

~/.config/claude/
└── mcp.json                         # MCP server config for Linear, Notion, Gmail, Cal, Slack

/etc/systemd/system/
└── volve-bot.service                # keeps volve_bot.py alive
```

### `VOLVE.md` (starter template, fill in)

```markdown
# Volve context

## Me
- Name: Fink (Jan Sigurd Kontorp)
- Role: [role at Volve]
- Working hours: 08:00–17:00 Europe/Oslo, Mon–Fri
- Tone: direct, no filler, flag conflicts, state uncertainty plainly

## Company
- Volve is [one paragraph: what it does, stage, headcount]

## People (Volve)
- [Name] — [role] — [how I relate, e.g. "my manager", "co-founder", "eng lead"]
- ...

## Current focus
- [Project] — [my role, state, next milestone]

## Standing commitments
- Weekly 1:1 with [name], [day] [time]

## Don't bother me about
- Automated newsletters, CI notifications, calendar invites from bots
```

### `mcp.json`

Built during setup. Structure (exact servers depend on what's available as official MCP for each source in your Team subscription — verify during build):

```json
{
  "mcpServers": {
    "linear":    { "command": "...", "args": [...] },
    "notion":    { "command": "...", "args": [...] },
    "gmail":     { "command": "...", "args": [...] },
    "calendar":  { "command": "...", "args": [...] },
    "slack":     { "command": "...", "args": [...] }
  }
}
```

### `volve-bot.service`

```ini
[Unit]
Description=Volve Slack bot
After=network-online.target

[Service]
Type=simple
User=jskontorp
WorkingDirectory=/home/jskontorp/volve
EnvironmentFile=/home/jskontorp/volve/.env
ExecStart=/home/jskontorp/volve/.venv/bin/python volve_bot.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

---

## Setup, ordered

1. **Verify headless Claude Code works on the VM.**
   - `claude login` (OAuth flow; may need SSH port-forward for the callback).
   - `claude -p "hello"` → returns a response.
   - If this fails, stop. Nothing downstream matters.

2. **Build `mcp.json` incrementally.**
   - Start with Linear only. Run `claude -p "list my open Linear issues"` — if it queries Linear successfully, move on.
   - Add Notion. Test: `claude -p "find recent Notion pages about [project]"`.
   - Add Calendar, then Gmail, then Slack. Each one: wire, test in isolation, commit.
   - Don't wire all five at once — you won't know which one is broken when something fails.

3. **Create a Slack app in the Volve workspace.**
   - Socket Mode on.
   - Bot scopes: `chat:write`, `im:history`, `im:read`, `im:write`, `reactions:write`, `reactions:read`.
   - Event subscriptions: `message.im`.
   - Install to workspace → bot token (`xoxb-`) and app-level token (`xapp-`) to `.env`.
   - Open a DM with the bot.

4. **Write `VOLVE.md`.** Fill the template honestly. 2–5 KB is plenty. No structure beyond what's above.

5. **Install the bot.**
   ```bash
   cd ~/volve
   python -m venv .venv && source .venv/bin/activate
   pip install slack-bolt
   # drop volve_bot.py in place
   sudo cp volve-bot.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now volve-bot
   journalctl -u volve-bot -f
   ```

6. **Live-test.** DM the bot:
   - "hi" — sanity.
   - "what does my day look like?" — exercises Calendar + Linear.
   - "summarise this week's activity on [project]" — exercises Notion + Linear.
   - "any unread emails I should care about?" — exercises Gmail.

If all four work, ship it. Use it daily for a week before touching anything else.

---

## Open questions (resolve during build)

1. **Headless `claude` auth persistence.** One-time login is easy; whether the token refreshes cleanly in a long-running daemon over weeks is untested. If it breaks, two fallbacks: (a) a cron `claude -p "ping"` once a day to keep things warm, (b) switch to `ANTHROPIC_API_KEY` (pay-per-token, ~$2/day rough estimate at moderate use). Established that Team seat includes Claude Code; *supported* that headless works; *speculative* that it stays healthy unattended.

2. **Which MCP servers for each source.** Official Anthropic connectors vs community servers. Verify at step 2 above, one source at a time.

3. **Subprocess-per-message cost.** Spawning a fresh `claude` process per Slack message is simple but gives no session reuse or prompt caching across turns. If latency or cost bites, the upgrade is the Claude Agent SDK (Python) which keeps an in-process client. Don't do this until you feel the pain.

---

## What this deliberately skips

Every one of these has a clear upgrade path from here. None are needed for the premise test.

- **Watchers + SQLite** — the "don't miss things" guarantee. Not needed if you're opening Slack and asking. Add when you catch yourself missing something the bot could have caught.
- **Scheduled digests** — morning/evening cron-driven briefings. Add as a one-liner cron calling `claude -p` + curl to a Slack webhook once you know what shape you want them to take.
- **Event alerts** — meeting-in-30-min, exec email, P0 assigned. Add after watchers, since they depend on state diffing.
- **Cross-thread memory** — "we discussed X last week". Slack search covers most of this for free.
- **Reaction-to-resolve** — only matters once you have open_loops to resolve.

---

## Success criterion

Five weekdays in a row, at least one DM exchange where the bot saves you meaningful clicking. If yes, move to Phase 2 of the full spec (watchers). If no, the premise is weaker than we think and it's better to know now than after building the tower.
