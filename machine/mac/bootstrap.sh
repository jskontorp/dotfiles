#!/bin/bash
# Bootstrap a fresh macOS dev environment from scratch.
# Usage: git clone ... ~/code/personal/dotfiles && cd ~/code/personal/dotfiles && ./machine/mac/bootstrap.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "🚀 Bootstrapping macOS dev environment..."

# --- Homebrew ---
if ! command -v brew &>/dev/null; then
  echo "📦 Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# --- Brewfile ---
echo "📦 Installing packages from Brewfile..."
brew bundle --file="$SCRIPT_DIR/Brewfile"

# --- Symlink dotfiles (before TPM so ~/.tmux.conf exists) ---
source "$DOTFILES/install.sh"

# --- TPM (must exist before `just update` runs tmux plugin install) ---
echo "📦 Installing tmux plugin manager..."
[[ -d "$HOME/.tmux/plugins/tpm" ]] || \
  git clone --depth=1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

# --- Install remaining tools via `just update` (single source of truth) ---
# Installs the global pnpm packages — pi, claude-code, pyright, typescript —
# materialises Claude Code's native binary, and installs tmux plugins. Brewfile
# already ran above so `just`/`pnpm`/`node`/`bat` are present; the redundant
# brew bundle inside `just update` is a fast no-op on a freshly bootstrapped
# host.
just -f "$DOTFILES/justfile" update

# --- Git identity (stored in ~/.gitconfig.local, not in the repo) ---
if [[ ! -f "$HOME/.gitconfig.local" ]]; then
  echo ""
  read -rp "👤 Git name: " git_name
  read -rp "📧 Git email: " git_email
  cat > "$HOME/.gitconfig.local" <<EOF
[user]
	name = $git_name
	email = $git_email
EOF
fi

echo ""
echo "✅ Bootstrap complete!"
echo ""
echo "Remaining manual steps:"
echo "  1. gh auth login"
echo "  2. Restart your terminal"
echo ""
echo "Optional: set a custom editor (default is nvim):"
echo "  Add to ~/.zshrc.local: export EDITOR=\"cursor --wait\""
