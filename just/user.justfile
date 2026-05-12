# Global justfile — invoked via `gust <recipe>` from anywhere.
# Symlinked to ~/.config/just/justfile by install.sh.
# Recipes run in $HOME (see `gust` alias in zsh/core.zsh). Use
# {{invocation_directory()}} inside a recipe if it needs the caller's cwd.

set shell := ["bash", "-uc"]

# List available recipes (default).
default:
    @just --justfile {{justfile()}} --list

# Attach to the oracle `odev` tmux session — locally on oracle, via ssh from mac.
odev:
    @if [[ "$(uname -s)" == "Linux" ]]; then tmux a -t odev; else ssh -t oracle tmux attach -t odev; fi

# Attach to the mac `dev` tmux session — only meaningful on mac.
dev:
    @[[ "$(uname -s)" == "Darwin" ]] || { echo "'dev' is the mac session; use 'gust odev' on linux" >&2; exit 1; }
    @tmux a -t dev

# --- Defaults ------------------------------------------------------------

# Re-run dotfiles install (idempotent).
link:
    cd ~/code/personal/dotfiles && ./install.sh

# Run the dotfiles host-side check suite.
check:
    cd ~/code/personal/dotfiles && just check

# Show the unified skills inventory.
skills:
    cd ~/code/personal/dotfiles && just skills

# Update brew + pnpm globals (mac).
update:
    brew update && brew upgrade && brew cleanup
    pnpm self-update
    pnpm -g update

# Show external IP + listening ports — quick "what's this machine doing".
net:
    @echo "External: $(curl -s ifconfig.me)"
    @echo "Listening:"
    @lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR>1 {print "  " $1, $9}' | sort -u

# Fuzzy-pick a git repo/worktree under ~/code and print its path. Use as: cd "$(gust wt)".
wt:
    @find ~/code -maxdepth 4 -name .git \( -type d -o -type f \) 2>/dev/null \
      | sed 's|/\.git$||' \
      | fzf --prompt="worktree> " --preview 'cd {} && git log --oneline -10 2>/dev/null'
