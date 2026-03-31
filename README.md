# dotfiles

Unified dev environment for macOS and Linux.

## Fresh machine

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jskontorp/dotfiles/main/init.sh)
```

Clones the repo to `~/dotfiles` and runs the full bootstrap:
- **macOS** — installs Homebrew, all packages from Brewfile, tmux plugins, symlinks configs, prompts for git identity.
- **Linux** — installs system packages, builds tools from source, sets up swap/SSH/firewall, installs Tailscale, symlinks configs.

After bootstrap, `just` is available for all future management.

## Keeping up to date

```bash
cd ~/dotfiles && git pull
just link      # apply config changes (fast, idempotent)
just update    # upgrade packages + install new additions (hits network)
```

**`just link`** re-symlinks all configs. Run after pulling changes that add or modify config files, pi skills, or AGENTS.md.

**`just update`** upgrades installed packages to latest versions AND installs any new additions (new Brewfile formulas on mac, new apt packages or tools on linux). Run when you want latest versions or after adding packages.

## Commands

| Command | What it does |
| --- | --- |
| `just init` | Full bootstrap (fresh machine, or re-run to fix everything) |
| `just update` | Upgrade packages + install new additions |
| `just link` | Re-symlink all configs |
| `just status` | Show installed tool versions |
| `just test` | Run Docker validation |

**Edit configs:**

| Command | Target |
| --- | --- |
| `just zsh` | `~/.zshrc` (reloads on save) |
| `just tmux` | `~/.tmux.conf` (reloads on save) |
| `just nvim` | `~/.config/nvim/` |
| `just starship` | `~/.config/starship.toml` |
| `just git` | `~/.gitconfig` |
| `just ghostty` | Ghostty config (macOS only) |

## Structure

```
shared/           Cross-platform configs (gitconfig, bat theme)
machine/mac/      macOS (zshrc, starship, tmux, Brewfile, ghostty, ssh, lazygit)
machine/vm/       Linux VM (zshrc, starship, tmux, nvim, lazygit, bootstrap)
pi/               Global pi agent config (AGENTS.md, skills)
projects/         Project-specific pi config (symlinked into project repos)
zsh/              Shell helpers
test/             Docker-based validation
```

## How it works

**Configs** live in this repo and get symlinked by `install.sh` (called via `just link`). Machine-specific variants live under `machine/mac/` or `machine/vm/`.

**Packages** are declared in `machine/mac/Brewfile` (macOS) or built from source in the `just update` recipe (Linux). Adding a package to either means `just update` picks it up on the next run.

**Pi agent config** (AGENTS.md, skills) is symlinked to `~/.pi/agent/`. Project-specific pi config in `projects/<name>/` gets symlinked into the project repo by `install.sh`.
