#!/bin/bash
# Symlink dotfiles into place.
# Detects machine (macOS vs Linux) and links the right configs.
# Usage: ./install.sh
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")" && pwd)"

# --- Detect machine ---
case "$(uname -s)" in
  Darwin) MACHINE="mac" ;;
  Linux)  MACHINE="vm"  ;;
  *)      echo "Unknown OS: $(uname -s)" >&2; exit 1 ;;
esac

echo "Detected machine: $MACHINE"
M="$DOTFILES/machine/$MACHINE"

# --- Shared configs ---
mkdir -p ~/.config ~/.config/zsh ~/.pi/agent

ln -sf "$DOTFILES/shared/gitconfig"      ~/.gitconfig
rm -rf ~/.config/nvim
ln -sfn "$DOTFILES/shared/nvim"          ~/.config/nvim
ln -sf "$DOTFILES/pi/agent/AGENTS.md"    ~/.pi/agent/AGENTS.md
ln -sfn "$DOTFILES/pi/agent/skills"      ~/.pi/agent/skills

# bat theme
mkdir -p "$(bat --config-dir)/themes"
ln -sf "$DOTFILES/shared/bat/themes/Catppuccin Mocha.tmTheme" "$(bat --config-dir)/themes/"
bat cache --build >/dev/null 2>&1

# --- Machine-specific configs ---
ln -sf "$M/zshrc"          ~/.zshrc
ln -sf "$DOTFILES/shared/tmux.conf" ~/.tmux.shared.conf
ln -sf "$M/tmux.conf"      ~/.tmux.conf
ln -sf "$M/starship.toml"  ~/.config/starship.toml

# lazygit (different config dirs per OS)
if [[ "$MACHINE" == "mac" ]]; then
  LAZYGIT_DIR="$HOME/Library/Application Support/lazygit"
else
  LAZYGIT_DIR="$HOME/.config/lazygit"
fi
mkdir -p "$LAZYGIT_DIR"
ln -sf "$DOTFILES/shared/lazygit/config.yml" "$LAZYGIT_DIR/config.yml"

# --- zsh helpers ---
# Remove stale symlinks first
find ~/.config/zsh -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null

# Always linked (core is sourced explicitly by zshrc, helpers via glob)
ln -sf "$DOTFILES/zsh/core.zsh"          ~/.config/zsh/
ln -sf "$DOTFILES/zsh/git-aliases.zsh"   ~/.config/zsh/
ln -sf "$DOTFILES/zsh/git-helpers.zsh"   ~/.config/zsh/
ln -sf "$DOTFILES/zsh/git-worktrees.zsh" ~/.config/zsh/

# Clean up renamed files from previous installs
rm -f ~/.config/zsh/sv.zsh  # renamed to sv-completion.zsh

# Machine-specific zsh helpers
if [[ "$MACHINE" == "mac" ]]; then
  ln -sf "$DOTFILES/zsh/sv-proxy.zsh"   ~/.config/zsh/
  ln -sf "$DOTFILES/zsh/ssh-theme.zsh"  ~/.config/zsh/
else
  ln -sf "$DOTFILES/zsh/sv-completion.zsh" ~/.config/zsh/
fi

# --- Mac-only ---
if [[ "$MACHINE" == "mac" ]]; then
  mkdir -p ~/.ssh
  ln -sf "$M/ssh/config" ~/.ssh/config

  GHOSTTY_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty"
  mkdir -p "$GHOSTTY_DIR"
  ln -sf "$M/ghostty/config" "$GHOSTTY_DIR/config"
fi

# --- VM-only ---
if [[ "$MACHINE" == "vm" ]]; then
  mkdir -p ~/.local/bin
  ln -sf "$M/bin/sv" ~/.local/bin/sv

  # nvim is shared (linked above)
fi

# --- Project-specific pi config ---
# Reads projects.conf for candidate paths, symlinks skills/ and extensions/
# into each project's .pi/ directory. AGENTS.md is NOT managed here — it
# lives in the project repo and follows normal git.
if [[ -f "$DOTFILES/projects.conf" ]]; then
  _project_found=""
  while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue

    read -r name candidate <<< "$line"
    candidate="${candidate/#\~/$HOME}"

    # Skip if we already found this project
    [[ " $_project_found " == *" $name "* ]] && continue

    if [[ -d "$candidate/.git" ]]; then
      _project_found+=" $name"
      echo "Found $name at $candidate"
      local_pi="$candidate/.pi"
      mkdir -p "$local_pi"

      # Symlink each subdirectory present in projects/<name>/
      for sub in "$DOTFILES/projects/$name"/*/; do
        [[ ! -d "$sub" ]] && continue
        sub_name="$(basename "$sub")"
        rm -rf "${local_pi:?}/${sub_name:?}"
        ln -sfn "$sub" "$local_pi/$sub_name"
      done
    fi
  done < "$DOTFILES/projects.conf"

  # Report projects not found
  for dir in "$DOTFILES/projects"/*/; do
    [[ ! -d "$dir" ]] && continue
    pname="$(basename "$dir")"
    [[ " $_project_found " != *" $pname "* ]] && echo "$pname not found, skipping project config"
  done
fi

# --- Git hooks (for the dotfiles repo itself) ---
if [[ -d "$DOTFILES/.git" ]]; then
  mkdir -p "$DOTFILES/.git/hooks"
  ln -sf "$DOTFILES/git/hooks/pre-commit" "$DOTFILES/.git/hooks/pre-commit"
fi

echo "✅ Dotfiles linked ($MACHINE)"
