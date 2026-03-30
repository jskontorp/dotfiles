# dotfiles

Unified dotfiles for macOS and Linux VM. Replaces the old `dotfiles_mac` + `dotfiles_vm` split.

## Structure

```
shared/           Configs identical across machines (gitconfig, bat theme)
machine/mac/      macOS-specific (zshrc, starship, tmux, Brewfile, ghostty, ssh)
machine/vm/       VM-specific (zshrc, starship, tmux, nvim, bin/sv, bootstrap)
pi/agent/         Global pi agent config (AGENTS.md, skills)
projects/         Project-specific pi config (symlinked into project repos)
zsh/              Shell helpers (git-helpers, sv-proxy, sv-completion, ssh-theme)
test/             Docker-based validation
```

## Setup

```bash
git clone <repo> ~/dotfiles
cd ~/dotfiles
./install.sh
```

### Bootstrap (fresh machine)

```bash
just init     # runs machine/mac/bootstrap.sh or machine/vm/bootstrap.sh
```

## Commands

```
just              List all recipes
just status       Installed tool versions
just update       Upgrade packages + tools (brew on mac, builds from source on vm)
just link         Re-symlink all configs
just save "msg"   Commit and push
just test         Run Docker validation (vm, mac, or both)
just zsh          Edit zshrc (reloads on save)
just ghostty      Edit Ghostty config (mac only)
```

## Project config

Project-specific pi skills and extensions live in `projects/<name>/` and get symlinked into the project repo by `install.sh`. This keeps pi config out of shared project repos.

Currently configured:
- **valuesync_os** — frontend-design, query-database, read-notion, langfuse-analysis, access-s3-data-lake skills + linear/notion extensions

## Skills

Universal skills (commit, create-pr, delegate, gh-cli, etc.) are in `pi/agent/skills/` and loaded globally.

Third-party skills via `npx skills add <package>` install to `.agents/skills/` at the repo root.
