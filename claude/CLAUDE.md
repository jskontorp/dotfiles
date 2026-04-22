# Claude Code addendum

The imported AGENTS.md is the shared agent-behaviour contract — written to apply to any coding agent that reads it. Read it fully.

Sections tagged `(pi only)` describe pi-specific tooling. When you see them, translate:

- `pi` CLI / `Bash(pi:*)` / "pi sub-agents" → use the `Agent` tool (subagents live at `~/.claude/agents/`).
- `.ts` extensions under `dotfiles/pi/agent/extensions/` → Claude equivalents are MCP servers or built-in tools. `web-search.ts` is already covered by native `WebSearch` / `WebFetch`.
- `just add-skill`, `skill-lock.json`, `dotfiles/pi/agent/skills/` → the dotfiles paths are shared; the `just` workflow manages both agents. Same SKILL.md format works for both.

Skills opt out of Claude with `claude-compatible: false` in their frontmatter (pi ignores unknown fields). `install.sh` skips those when mirroring to `~/.claude/skills/`.

Several side-effect skills carry `disable-model-invocation: true` — Claude won't auto-pick them on description match; they must be triggered explicitly via slash-command (e.g. `/commit`). Applied to `commit`, `create-pr`, `interactive-rebase`, `sandbox` as belt-and-suspenders against a false-positive description match causing an unwanted commit / push / history rewrite / container spin-up. Pi ignores the field and dispatches by description as usual.

@$DOTFILES/pi/agent/AGENTS.md
