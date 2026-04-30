---
name: session-archaeology
description: >-
  Forensic search across pi and Claude Code session transcripts on this
  machine. Use when the user says "trace the origin of", "what session
  produced", "why did we end up with", "find the prompt that wrote", "which
  reviewers caught", or asks to investigate a past commit, decision, or
  regression by reading prior agent transcripts. Reads historical JSONL —
  for live tmux/worktree state see `session-scan`.
compatibility: Requires Python 3 stdlib and read access to ~/.pi/agent/sessions and ~/.claude/projects on this machine.
allowed-tools: Bash(python3:*) Bash(grep:*) Bash(rg:*) Bash(ls:*) Bash(find:*) Bash(wc:*) Bash(head:*) Bash(tail:*) Read
claude-compatible: false
---

# session-archaeology

Investigate the origin of a commit, decision, or piece of code by reading the
session transcripts that produced it. The skill provides primitives — the
calling agent decides what question to answer.

`scripts/archaeology.py` is the workhorse; it speaks both pi and Claude Code
JSONL formats and emits JSONL on stdout (one record per line) by default,
with `--text` for human-readable output where supported.

```bash
A="$(dirname "$(realpath "$0")")/scripts/archaeology.py"   # if invoked from a bash script
# or just: A=~/.pi/agent/skills/session-archaeology/scripts/archaeology.py
```

## When to use

- "Trace the origin of commit X" / "find the session that produced file Y."
- "Which reviewer caught bug Z?" / "what was the prompt that turned this from approach A to approach B?"
- Investigating a regression: was a decision made deliberately, by which review pass, citing what reasoning?
- Auditing your own agent workflows after the fact.

If the question is *what's running right now* (worktrees, tmux panes, sibling
agents in the current checkout), use `session-scan` instead. This skill reads
**history**.

## Where sessions live

| Harness | Root | Per-cwd dir encoding |
|---|---|---|
| Claude Code | `~/.claude/projects/` | `/path/with.dots` → `-path-with-dots` (slashes **and dots** → dash) |
| pi | `~/.pi/agent/sessions/` | `/path/with.dots` → `--path-with.dots--` (slashes → dash, **dots preserved**, double-dash bookends) |

**Subagent transcripts** (Claude Code only): live under
`~/.claude/projects/<dashed-cwd>/<parent-uuid>/subagents/agent-<hash>.jsonl`.
pi has no equivalent.

## JSONL line shapes (cheat sheet)

Both formats are append-only JSONL with one event per line. Top-level fields
that matter for archaeology: `timestamp` (ISO8601), `cwd`, `sessionId`/`id`.

### Claude Code

```jsonc
// Conversational lines have type "user" or "assistant".
{"type":"user","timestamp":"...","cwd":"...","sessionId":"...","gitBranch":"...",
 "message":{"role":"user","content": "string OR list of blocks"}}

{"type":"assistant","timestamp":"...","message":{
  "role":"assistant",
  "content":[
    {"type":"text","text":"..."},
    {"type":"thinking","thinking":"..."},
    {"type":"tool_use","name":"Bash","input":{...}},
    {"type":"tool_result","content":"..."}   // appears in user lines too
  ]}}
```

Other line types (`attachment`, `system`, `permission-mode`, `last-prompt`,
`ai-title`, `file-history-snapshot`) are session metadata; archaeology
generally ignores them.

### pi

```jsonc
// First line is a session header.
{"type":"session","version":3,"id":"...","timestamp":"...","cwd":"..."}

// All conversational lines have type "message".
{"type":"message","timestamp":"...","message":{
  "role":"user",       // or "assistant" or "toolResult"
  "content":[
    {"type":"text","text":"..."},
    {"type":"thinking","thinking":"..."},
    {"type":"toolCall","name":"bash","arguments":{...},"id":"..."}
  ]}}
```

Note the spelling differences: pi's `toolCall`/`arguments`/`role: "toolResult"`
vs. Claude Code's `tool_use`/`input`/`tool_result` block. The script
normalizes both.

## Workflow

Five primitives, used in this order most of the time.

### 1. Locate sessions

```bash
# All sessions for a directory (prefix-match on realpath; covers worktrees).
python3 "$A" find --cwd /Users/me/code/myrepo --text

# Narrow by time + content.
python3 "$A" find --cwd /Users/me/code/myrepo \
    --since 2026-04-28T13:00:00Z --until 2026-04-28T16:00:00Z \
    --grep "compliance_checklist" --text
```

Output (one row per session): harness, started timestamp, line count, path.
Both pi and Claude Code sessions are returned, sorted by harness then encounter.

### 2. Enumerate user prompts (chronological)

```bash
python3 "$A" prompts <session.jsonl> --text
```

Strips synthetic wrappers (`<command>…`, `<local>…`, `<bash>…`, `<task>…`,
`<system>…`). Emits `timestamp + first ~300 chars` per real user prompt.
This is the highest-signal first pass on any session.

### 3. Sample assistant tool calls

```bash
# All Bash calls touching 'compliance_checklist' in the inputs.
python3 "$A" tools <session.jsonl> --name bash --file compliance_checklist --text

# All Edit/Write tool uses in a time window.
python3 "$A" tools <session.jsonl> --name Edit --name Write \
    --since 2026-04-28T13:00:00Z --until 2026-04-28T16:00:00Z --text
```

Pairs with step 2: a user prompt at time T, followed by tool calls at T+ε, is
the artefact of a decision being made. Quote both.

### 4. Walk subagent transcripts (Claude Code)

```bash
# Argument can be the parent session JSONL path, dir, or just the UUID.
python3 "$A" subagents <parent-uuid> --text
```

Output: timestamp, line count, filename, first non-synthetic user prompt
(the subagent's task brief). This is how you discover review fan-outs and
detective dispatches you didn't know were there.

### 5. Detect cross-harness shuttle

```bash
# Long user messages (default >1500 chars) — often pastes from another agent.
python3 "$A" shuttle <session.jsonl> --text --threshold 1500
```

Heuristic only: the calling agent decides whether each match is a real shuttle
(pasted-from-another-agent text) versus the user genuinely typing a long
message. Common true positives: review reports pasted between Claude Code and
pi, full ticket bodies, plan documents fed in for execution.

## Decision attribution pattern

The single most useful pattern, and what makes archaeology produce evidence
rather than anecdotes:

> **Quote the user prompt + cite the next assistant turn that produced an artefact.**

```
[2026-04-28T08:46:18Z] user: "why not make it deterministic where it should be?"
[2026-04-28T08:48:52Z] assistant tool_use Edit:
    file_path = "app/agents/compliance_checklist/schemas.py"
    new_string = "@field_validator('item_key', mode='before')..."
```

Pair via `prompts` + `tools --since <prompt-ts>` to surface these. Quote both
in any synthesis.

## Cross-harness shuttle — what to look for

Shuttle traces appear as **normal user messages** in the receiving harness
because the user pastes them as input. There is no special record type. Tells:

- Length over ~1500 characters (use `shuttle`).
- Markdown structure with headers (`#`, `##`) at the start.
- Phrases like "Detective", "Reviewer", "Phase N", "Findings", or fenced JSON.
- Timestamps where the receiving session goes silent for a few minutes (user
  was in the other harness) and then a long message lands.

## Fanning out

If the investigation has ≥3 distinct session clusters (e.g. planning sessions,
implementation sessions, review subagents), prefer the `delegate` skill:
one detective per question cluster, three personas where the work warrants it
(guided / blind / step-back), each writing a structured report you synthesize.

## Privacy guidance (for the calling agent)

Transcripts contain pasted production data, API keys in error messages, and
unfiltered comments about people. The skill cannot enforce anything; the
discipline lives in you:

- Quote summaries, not raw transcript blobs, when sharing across harnesses
  or with remote review/automation tools.
- Don't paste extracted content into Linear, Notion, web fetches, or remote
  Claude sessions without the user's explicit say-so for that specific call.
- Don't cache extracted content outside agent working memory.

## Output formats (machine vs. human)

- Default: **JSONL on stdout** (one record per line). Pipe to `jq`, feed
  to another tool, or read structurally.
- `--text` flag: tab/space-aligned single-line records, suitable for direct
  reading. Use for ad-hoc queries; use JSONL for further processing.

## Failure modes to know about

- **Format drift.** If Claude Code or pi change their JSONL schema, this
  script may silently misparse new fields. Sanity-check by running the
  examples in this file against a known recent session before trusting the
  output for an investigation.
- **Empty subagents/ dir.** Some Claude Code parent sessions never spawned
  subagents — `subagents` will print a message to stderr and exit 0.
- **Truncated/corrupt lines.** All subcommands skip lines that don't parse
  as JSON; they don't abort the read. Counts in `find --text` are total
  lines, including unparseable ones.
- **Live sessions.** A session being written to during your read may yield a
  partial last line. Same handling as truncated lines.

## Anti-patterns

- Trusting `archaeology.py prompts` output verbatim without sampling the
  raw JSONL once. Cross-check at least one quote against the source line.
- Asking it questions it doesn't answer. The script doesn't synthesize, doesn't
  rank by relevance, doesn't classify — those are your job.
- Using it for live state. That's `session-scan`.
