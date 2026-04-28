<!-- generated from dotfiles/claude/CLAUDE.md by install.sh — do not edit ~/.claude/CLAUDE.md directly -->
# Claude Code addendum

The imported AGENTS.md is the shared agent-behaviour contract — written to apply to any coding agent that reads it. Read it fully.

Sections tagged `(pi only)` describe pi-specific tooling. When you see them, translate:

- `pi` CLI / `Bash(pi:*)` — pi-only invocations; ignore.
- "pi sub-agents" (pi's tmux-based delegate skill) → Claude's `Agent` tool (subagents live at `~/.claude/agents/`).
- Pi skill dispatch (description match in pi's runtime) → Claude's auto-invoking `Skill` mechanism. Same SKILL.md format — opt a skill out with `claude-compatible: false`.
- `.ts` extensions under `dotfiles/pi/agent/extensions/` do not apply to Claude. Use native MCP tools (`mcp__claude_ai_Linear__*`, `mcp__claude_ai_Notion__*`), `WebSearch`, `WebFetch`.
- `just add-skill`, `skill-lock.json`, `dotfiles/pi/agent/skills/` — shared layout; the `just` workflow manages both agents.

Skills opt out of Claude with `claude-compatible: false` in their frontmatter (pi ignores unknown fields). `install.sh` skips those when mirroring to `~/.claude/skills/`.

Several side-effect skills carry `disable-model-invocation: true` — Claude won't auto-pick them on description match; they must be triggered explicitly via slash-command (e.g. `/commit`). Applied to `commit`, `create-pr`, `interactive-rebase`, `sandbox` as belt-and-suspenders against a false-positive description match causing an unwanted commit / push / history rewrite / container spin-up. Pi ignores the field and dispatches by description as usual.

## Destructive actions

The shared AGENTS.md `# Destructive actions` section is the policy and applies fully. Claude-specific: the `Bash` tool is the main vector. If a call is blocked by the harness's permission layer, report the denial and stop — do not retry with quoting tricks (`bash -c "…"`), wrapper commands, alternative shells, or by writing a script file and executing it. The deny is the user's standing policy, not a puzzle to route around.

@$DOTFILES/pi/agent/AGENTS.md
