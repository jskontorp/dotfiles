# dotfiles — agent rules

Repo-local addendum for agents working on this dotfiles repo. The global cross-agent contract lives in [`pi/agent/AGENTS.md`](pi/agent/AGENTS.md) and is loaded automatically by both pi (cwd-`AGENTS.md`) and Claude (via `~/.claude/CLAUDE.md`). This file covers only what's specific to editing this repo.

## Trigger matrix

| You touched… | Fast check | Full check | Notes |
|---|---|---|---|
| `install.sh`, `.install-manifest` | `just check` | `just test` | New `_link`/`_linkd` call → also add the destination path to `EXPECTED[]` in `test/validate-manifest.sh`. Scope changes → re-read `install.sh`'s scope-handling block. |
| `justfile` | `just check` | `just test` (if recipe affects linking) | Cross-platform parity (`SHARED_STATUS_TOOLS`, `GLOBAL_PNPM`) is auto-asserted. |
| `pi/agent/skills/**` (edit, add, remove) | `just link && just skills` | `just test`; plus `just test-skill <name>` if the skill ships `tests/run.sh` | The Claude mirror list is derived from `claude-compatible:` frontmatter (in `verify.sh`) — adding a new skill doesn't require touching tests. The Fast check confirms registration; the mirror invariant itself is only validated by `just test`. |
| `pi/skill-lock.json` | `just link && just skills` | `just test` | Add new entries via `just add-skill <url> <name> [subpath] [scope]`. Refresh from upstream via `just update-skill <name>`. Hand-edit only for emergencies. |
| `claude/CLAUDE.md`, `claude/agents/*.md`, `claude/settings.json` | `just link` | `just test` | When widening `claude/settings.json` permissions, document the rationale inline in the JSON. |

`just check` runs the host-side suite (justfile parity, manifest integrity, bash portability) and is wired into `git/hooks/pre-commit`. `just test` runs the full Docker integration suite (~minutes).

## Workflow rules

- Plans, recaps, design notes go under `ideas/`, not repo root.
- Never reach for `npx skills add` — it bypasses `pi/skill-lock.json`. Use `just add-skill` / `just update-skill` / `just new-skill`.
- When reporting verification, state the exact command run and its outcome. Don't generalise from "I edited the file" to "tests pass".

## Known regression classes

- **`set -e` + missing optional tool.** `install.sh` runs under `set -euo pipefail`. New external commands (`bat`, `python3`, …) need a `command -v` guard or must be added to `test/Dockerfile.{mac,vm}`. Evidence: cfc4ba1, 070d150.
- **Skill scope migration leaves orphan symlinks.** When a skill moves between `global` and `project:<name>` scope, prior-scope symlinks must be cleaned up explicitly. `just test` (idempotency check) is the only catch. Evidence: 1d4069d, 356dcc5, 179b206.

(Bash≥4 portability — `mapfile`, `readarray`, `${var,,}` — is now caught automatically by `test/check-bash-portability.sh`.)

## Known gaps

`init.sh` and `machine/*/bootstrap.sh` are only shellchecked; `verify.sh`'s `mac` Docker target uses a `uname` shim, so real macOS-only paths aren't exercised. Don't claim a check exists for these surfaces.
