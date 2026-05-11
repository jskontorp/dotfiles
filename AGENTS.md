# dotfiles — agent rules

Repo-local addendum for agents working on this dotfiles repo. The global cross-agent contract lives in [`pi/agent/AGENTS.md`](pi/agent/AGENTS.md) and is loaded automatically by both pi (cwd-`AGENTS.md`) and Claude (via `~/.claude/CLAUDE.md`). This file covers only what's specific to editing this repo.

## Trigger matrix

| You touched… | Fast check | Full check | Notes |
|---|---|---|---|
| `install.sh`, `.install-manifest` | `just check` | `just test` | New `_link`/`_linkd` call → also add the destination path to `EXPECTED[]` in `test/validate-manifest.sh`. Scope changes → re-read `install.sh`'s scope-handling block. |
| `uninstall.sh` | `just check` (bash-portability scan) | `just test` | Manifest-driven; reverses `install.sh`. The manifest is the contract: a symlink at any manifest-recorded path is removed regardless of where its target points (handles marketplace-skill symlinks under `~/.local/share/pi-skills/` correctly). Skips paths that are no longer symlinks (state drift — user content), warns on stderr, exit code unchanged. Does NOT touch `~/.pi/agent/settings.json`, `~/.claude/CLAUDE.md`, `~/.gitconfig.local`, or any `just update` side effects — see the script's footer. |
| `justfile` | `just check` | `just test` (if recipe affects linking) | Cross-platform parity (`SHARED_STATUS_TOOLS`, `GLOBAL_PNPM`) is auto-asserted. |
| `pi/agent/skills/**` (edit, add, remove) | `just link && just skills` | `just test`; plus `just test-skill <name>` if the skill ships `tests/run.sh` | The Claude mirror list is derived from `claude-compatible:` frontmatter (in `verify.sh`) — adding a new skill doesn't require touching tests. The Fast check confirms registration; the mirror invariant itself is only validated by `just test`. |
| `pi/skill-lock.json` | `just link && just skills` | `just test` | Add new entries via `just add-skill <url> <name> [subpath] [scope]`. Refresh from upstream via `just update-skill <name>`. Hand-edit only for emergencies. |
| `claude/CLAUDE.md`, `claude/agents/*.md`, `claude/settings.json` | `just link` | `just test` | When widening `claude/settings.json` permissions, document the rationale inline in the JSON. |
| `zsh/*.zsh` | `just check` (bash-portability scan) | `just test` | Sourced by every interactive shell on bootstrap; the Docker suite's "zshrc sources cleanly" / re-source-safety checks are the only end-to-end coverage. PATH / env-export logic isn't asserted explicitly — eyeball it. |

`just check` runs the host-side suite (justfile parity, manifest integrity, bash portability) and is wired into `git/hooks/pre-commit`. `just test` runs the full Docker integration suite (~minutes) and requires a Docker runtime on `PATH` — OrbStack is installed by default via `machine/mac/Brewfile` (it also provides the `ssh orb` host); Docker Desktop is the heavier alternative. `verify.sh` prints the install hint if `docker` is missing.

## Workflow rules

- Plans, recaps, design notes go under `ideas/`, not repo root.
- Never reach for `npx skills add` — it bypasses `pi/skill-lock.json`. Use `just add-skill` / `just update-skill` / `just new-skill`.
- When reporting verification, state the exact command run and its outcome. Don't generalise from "I edited the file" to "tests pass".
- Before declaring done: did this work surface a failure mode not in "Known regression classes"? If yes, propose a one-line addition with the SHA. If no, move on.

## Known regression classes

- **`set -e` + missing optional tool.** `install.sh` runs under `set -euo pipefail`. New external commands (`bat`, `python3`, …) need a `command -v` guard or must be added to `test/Dockerfile.{mac,vm}`. Evidence: cfc4ba1, 070d150.
- **Skill scope migration leaves orphan symlinks.** When a skill moves between `global` and `project:<name>` scope, prior-scope symlinks must be cleaned up explicitly. `just test` (idempotency check) is the only catch. Evidence: 1d4069d, 356dcc5, 179b206.
- **Project decommission leaves orphan symlinks.** Removing a project from `projects.conf` / deleting `projects/<name>/` strands every symlink `install.sh` previously created under that project's working tree (and any `~/.pi/agent/extensions/<x>` / `<x>.ts` left from a global → project move — see 0f38b0c, file moves into `extensions/graveyard/`). `install.sh` only links forward; `uninstall.sh` is manifest-driven and these never entered the manifest. `validate-manifest.sh` now buckets them as `ORPHAN` (target missing) distinct from `UNTRACKED` (target exists, real install.sh bug). Remediation: `rm` the symlinks. Evidence: 6afb180, 0f38b0c.
- **Skill-script portability is on the author.** `test/check-bash-portability.sh:14` excludes `pi/agent/skills/**/scripts/` and `SKILL.md` shell examples; BSD `sed`/`grep` and bash-3.2 are not enforced. Evidence: be2f69e.
- **Skills sharing infra must probe-and-extend, not clobber.** The `pi-delegate` tmux session and `.pi-delegate/` paths are shared across the `delegate` and `triple-review` skills (and any future skill that reuses them). Use `tmux has-session` + `batch-N` increment, never `kill-session`. The same applies to filesystem state inside `.pi-delegate/`: skills sharing the dir must allocate `batch-N/` subdirs via atomic `mkdir` (no `-p`) with retry-on-collision, and must keep the FS probe **independent** of the tmux probe — the two namespaces have different lifetimes (tmux session is per-machine, `.pi-delegate/` is per-cwd) and coupling them produces duplicate tmux window names cross-cwd. Evidence: 0d891ab, be2f69e (per-batch FS allocation: TBD post-commit).

(Bash≥4 portability — `mapfile`, `readarray`, `${var,,}` — is now caught automatically by `test/check-bash-portability.sh`.)

## Known gaps

`init.sh` and `machine/*/bootstrap.sh` are only shellchecked; `verify.sh`'s `mac` Docker target uses a `uname` shim, so real macOS-only paths aren't exercised. Don't claim a check exists for these surfaces.
