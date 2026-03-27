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
test/             Validation scripts
```

## Setup

```bash
git clone <repo> ~/dotfiles
cd ~/dotfiles
./install.sh        # detects machine, links everything
```

Machine-specific tasks (brew updates, building tools from source):

```bash
just machine <recipe>
```

### Bootstrap (fresh machine)

```bash
# macOS
./machine/mac/bootstrap.sh

# VM
./machine/vm/bootstrap.sh
```

## Project config

Project-specific pi skills and extensions live in `projects/<name>/` and get symlinked into the project repo by `install.sh`. This keeps pi config out of shared project repos.

Currently configured:
- **valuesync_os** — frontend-design, query-database, read-notion, langfuse-analysis, access-s3-data-lake skills + linear/notion extensions

## Skills

Universal skills (commit, create-pr, delegate, gh-cli, etc.) are in `pi/agent/skills/` and loaded globally.

Third-party skills via `npx skills add <package>` install to `.agents/skills/` at the repo root.
