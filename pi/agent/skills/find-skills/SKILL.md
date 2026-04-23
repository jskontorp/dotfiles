---
name: find-skills
description: Helps users discover and install agent skills when they ask questions like "how do I do X", "find a skill for X", "is there a skill that can...", or express interest in extending capabilities. This skill should be used when the user is looking for functionality that might exist as an installable skill.
---

# Find Skills (dotfiles-overlay version)

Shadows the upstream `vercel-labs/skills/find-skills` skill. Discovery flow is the same — skills.sh leaderboard and the `npx skills find` CLI are still the catalog. Install flow is different: this repo tracks every installed skill in `dotfiles/pi/skill-lock.json` via `just add-skill`, so pi and Claude Code stay in sync across machines.

**Do not run `npx skills add …`** — it bypasses the lock file.

## When to Use

- User asks "how do I do X" where X might be a common task with an existing skill
- "find a skill for X" / "is there a skill for X"
- "can you do X" for a specialised capability
- User expresses interest in extending agent capabilities

## Discovery (unchanged from upstream)

### 1. Check the leaderboard first

https://skills.sh/ ranks skills by install count. For common web-dev domains the top hits are usually `vercel-labs/agent-skills` and `anthropics/skills`.

### 2. Search the CLI

```bash
npx skills find [query]
```

Examples:
- "make my React app faster" → `npx skills find react performance`
- "help with PR reviews" → `npx skills find pr review`
- "need to create a changelog" → `npx skills find changelog`

### 3. Vet before recommending

- **Install count** — prefer 1K+ installs, be cautious under 100.
- **Source reputation** — `vercel-labs`, `anthropics`, `microsoft` are safer than unknown authors.
- **GitHub stars** — check the upstream repo; <100 stars = skepticism.

Present the user: skill name, what it does, install count, source, a link, and the `just add-skill` command (next section) — **not** `npx skills add`.

## Install (dotfiles workflow)

### Translate find-result → `just add-skill` args

The CLI / skills.sh surfaces skills as `<owner>/<repo>@<slug>`. Map that to:

```
just add-skill <url> <name> [subpath] [scope] [rev] [dry-run]
```

- `<url>` = `https://github.com/<owner>/<repo>`
- `<name>` = the slug (also the local identifier)
- `<subpath>` = path to the skill dir inside the upstream repo. **Default is `skills/<name>`, but verify** — some repos nest deeper (e.g. `plugins/javascript-typescript/skills/typescript-advanced-types`). Open the upstream repo or `WebFetch` its tree to confirm before running. A wrong subpath will fail the clone step in `install.sh`.
- `<scope>` = `global` (default) or `project:<name>` for a per-repo skill. `project:*` requires the project to be listed in `dotfiles/projects.conf`.
- `<rev>` = optional commit SHA to pin. Omit to track upstream HEAD.
- Pass `dry-run` as the 6th arg to preview the lock-file diff without writing.

### Concrete examples

```bash
# Global skill, standard layout
just add-skill https://github.com/vercel-labs/agent-skills react-best-practices skills/react-best-practices

# Nested layout — verify subpath from upstream tree first
just add-skill https://github.com/wshobson/agents typescript-advanced-types plugins/javascript-typescript/skills/typescript-advanced-types

# Project-scoped to volve-ai
just add-skill https://github.com/neondatabase/agent-skills neon-postgres skills/neon-postgres project:volve-ai

# Preview before committing
just add-skill https://github.com/x/y my-skill skills/my-skill global '' dry-run
```

### What the command does

Fetches the upstream HEAD SHA (or the pinned `rev`), writes a lock entry to `dotfiles/pi/skill-lock.json`, and runs `install.sh`, which clones into `~/.local/share/pi-skills/<name>/` and symlinks it into `~/.pi/agent/skills/<name>` and `~/.claude/skills/<name>` (unless the skill has `claude-compatible: false`). Both pi and Claude Code pick it up immediately.

### Updating / removing

- Bump a skill's pinned SHA → `just update-skill <name>`
- Remove → delete its entry from `pi/skill-lock.json` and re-run `./install.sh` (the prune step cleans the cache and symlinks).

## When No Skills Match

1. Say so plainly — don't invent a recommendation.
2. Offer to do the task directly.
3. If it's a recurring task, suggest scaffolding a custom skill with `just new-skill <name>` (authored in `dotfiles/pi/agent/skills/`, no marketplace round-trip needed).

## Presenting Options — template

```
Found a candidate: "<name>" — <one-line purpose>.
Source: <owner>/<repo> · <install-count> installs · <leaderboard-url>

To install globally:
  just add-skill https://github.com/<owner>/<repo> <name> <subpath>

I'll verify the subpath against the upstream repo before running. Want me to proceed?
```

Always ask before running `just add-skill` — it mutates the lock file and triggers `install.sh`.
