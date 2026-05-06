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

**On `permissions.deny` in `settings.json`:** the list is best-effort string matching against the literal command, not a semantic parser. `rm -rf ~` (no slash), `rm -rf "$HOME"`, `rm -rf /Users/<name>`, and `git push origin main --force` (flag after positional args) all bypass the listed patterns. Treat `permissions.deny` as a tripwire for the most-typed forms, not a guarantee. AGENTS.md `# Destructive actions` is the binding rule; the JSON list is decoration.

**On `skipAutoPermissionPrompt: true`:** this disables Claude's prompt-on-unknown-command. Combined with the leaky deny list above, the practical security posture is "AGENTS.md compliance + best-effort string match." Set deliberately because the user runs Claude in auto-accept mode often and visually tracks which mode is active; the prompt would be friction more than signal. If you find yourself relying on the prompt to catch a destructive call, the prompt isn't there — re-read AGENTS.md instead.

@$DOTFILES/pi/agent/AGENTS.md
