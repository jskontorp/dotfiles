# Claude Code addendum

The imported AGENTS.md is the shared agent-behaviour contract — written to apply to any coding agent that reads it. Read it fully.

Sections tagged `(pi only)` describe pi-specific tooling. When you see them, translate:

- `pi` CLI / `Bash(pi:*)` / "pi sub-agents" → use the `Agent` tool (subagents live at `~/.claude/agents/`).
- `.ts` extensions under `dotfiles/pi/agent/extensions/` → Claude equivalents are MCP servers or built-in tools. `web-search.ts` is already covered by native `WebSearch` / `WebFetch`.
- `just add-skill`, `skill-lock.json`, `dotfiles/pi/agent/skills/` → the dotfiles paths are shared; the `just` workflow manages both agents. Same SKILL.md format works for both.

Skills `delegate`, `solve-ticket`, `linear-issue`, and `notion-write` are intentionally not symlinked into `~/.claude/skills/` — they require pi's runtime.

@/Users/jorgens.kontorp/code/personal/dotfiles/pi/agent/AGENTS.md
