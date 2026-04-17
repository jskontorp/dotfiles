#!/bin/bash
# Symlink dotfiles into place.
# Detects machine (macOS vs Linux) and links the right configs.
# Writes a manifest of created symlinks to .install-manifest for testing.
# Usage: ./install.sh
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_MANIFEST="$DOTFILES/.install-manifest"
: > "$INSTALL_MANIFEST"

# --- Symlink helpers (record every link to manifest for test verification) ---

# _link <target> <dest>  — symlink a file (if dest is a dir, link inside it)
_link() {
  ln -sf "$1" "$2"
  if [[ -d "$2" && ! -L "$2" ]]; then
    echo "${2%/}/$(basename "$1")" >> "$INSTALL_MANIFEST"
  else
    echo "$2" >> "$INSTALL_MANIFEST"
  fi
}

# _linkd <target> <dest> — symlink a directory (replaces existing)
_linkd() {
  rm -rf "$2"
  ln -sfn "$1" "$2"
  echo "$2" >> "$INSTALL_MANIFEST"
}

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

_link "$DOTFILES/shared/gitconfig"      ~/.gitconfig
_linkd "$DOTFILES/shared/nvim"          ~/.config/nvim
_link "$DOTFILES/pi/agent/AGENTS.md"    ~/.pi/agent/AGENTS.md
# Replace old whole-directory symlink with a real directory
[[ -L ~/.pi/agent/skills ]] && rm ~/.pi/agent/skills
mkdir -p ~/.pi/agent/skills
for skill in "$DOTFILES/pi/agent/skills"/*/; do
  [[ ! -d "$skill" ]] && continue
  _linkd "$skill" ~/.pi/agent/skills/"$(basename "$skill")"
done

# pi extensions: symlink each .ts file into ~/.pi/agent/extensions/
if [[ -d "$DOTFILES/pi/agent/extensions" ]]; then
  mkdir -p ~/.pi/agent/extensions
  for ext in "$DOTFILES/pi/agent/extensions"/*.ts; do
    [[ ! -f "$ext" ]] && continue
    _link "$ext" ~/.pi/agent/extensions/"$(basename "$ext")"
  done
fi

# --- Marketplace pi skills (from lock file) ---
SKILL_LOCK="$DOTFILES/pi/skill-lock.json"
if [[ -f "$SKILL_LOCK" ]]; then
  mkdir -p ~/.agents/skills
  cp "$SKILL_LOCK" ~/.agents/.skill-lock.json

  python3 -c "
import json, os, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for name, info in data.get('skills', {}).items():
    skill_dir = os.path.dirname(info['skillPath'])
    print(f'{name}\\t{info[\"sourceUrl\"]}\\t{skill_dir}')
" "$SKILL_LOCK" | while IFS=$'\t' read -r name url skill_dir; do
    [[ -d "$HOME/.agents/skills/$name" ]] && continue
    echo "Installing pi skill: $name"
    tmp=$(mktemp -d)
    if git clone --depth 1 --filter=blob:none --sparse "$url" "$tmp/repo" 2>/dev/null &&
       (cd "$tmp/repo" && git sparse-checkout set "$skill_dir" 2>/dev/null); then
      cp -r "$tmp/repo/$skill_dir" "$HOME/.agents/skills/$name"
    else
      echo "  ⚠ Failed to install $name" >&2
    fi
    rm -rf "$tmp"
  done

  # Symlink marketplace skills into ~/.pi/agent/skills/
  for skill in ~/.agents/skills/*/; do
    [[ ! -d "$skill" ]] && continue
    name=$(basename "$skill")
    # Custom skills (already linked above) take precedence
    [[ -e ~/.pi/agent/skills/"$name" ]] && continue
    _linkd "$HOME/.agents/skills/$name" ~/.pi/agent/skills/"$name"
  done
fi

# bat theme
mkdir -p "$(bat --config-dir)/themes"
_link "$DOTFILES/shared/bat/themes/Catppuccin Mocha.tmTheme" "$(bat --config-dir)/themes/"
bat cache --build >/dev/null 2>&1

# --- Machine-specific configs ---
_link "$M/zshrc"          ~/.zshrc
_link "$DOTFILES/shared/tmux.conf" ~/.tmux.shared.conf
_link "$M/tmux.conf"      ~/.tmux.conf
_link "$M/starship.toml"  ~/.config/starship.toml

# lazygit (different config dirs per OS)
if [[ "$MACHINE" == "mac" ]]; then
  LAZYGIT_DIR="$HOME/Library/Application Support/lazygit"
else
  LAZYGIT_DIR="$HOME/.config/lazygit"
fi
mkdir -p "$LAZYGIT_DIR"
_link "$DOTFILES/shared/lazygit/config.yml" "$LAZYGIT_DIR/config.yml"

# --- zsh helpers ---
# Remove stale symlinks first
find ~/.config/zsh -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null

# Always linked (core is sourced explicitly by zshrc, helpers via glob)
_link "$DOTFILES/zsh/core.zsh"          ~/.config/zsh/
_link "$DOTFILES/zsh/git-aliases.zsh"   ~/.config/zsh/
_link "$DOTFILES/zsh/git-helpers.zsh"   ~/.config/zsh/
_link "$DOTFILES/zsh/git-worktrees.zsh" ~/.config/zsh/

# Clean up renamed files from previous installs
rm -f ~/.config/zsh/sv.zsh  # renamed to sv-completion.zsh

# Machine-specific zsh helpers
if [[ "$MACHINE" == "mac" ]]; then
  _link "$DOTFILES/zsh/sv-proxy.zsh"   ~/.config/zsh/
  _link "$DOTFILES/zsh/ssh-theme.zsh"  ~/.config/zsh/
else
  _link "$DOTFILES/zsh/sv-completion.zsh" ~/.config/zsh/
fi

# --- Mac-only ---
if [[ "$MACHINE" == "mac" ]]; then
  mkdir -p ~/.ssh
  _link "$M/ssh/config" ~/.ssh/config

  GHOSTTY_DIR="$HOME/Library/Application Support/com.mitchellh.ghostty"
  mkdir -p "$GHOSTTY_DIR"
  _link "$M/ghostty/config" "$GHOSTTY_DIR/config"
fi

# --- VM-only ---
if [[ "$MACHINE" == "vm" ]]; then
  mkdir -p ~/.local/bin
  _link "$M/bin/sv" ~/.local/bin/sv
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
        if [[ "$sub_name" == "skills" ]]; then
          # Individual skill symlinks (same pattern as global skills)
          [[ -L "$local_pi/skills" ]] && rm "$local_pi/skills"
          mkdir -p "$local_pi/skills"
          for skill in "$sub"*/; do
            [[ ! -d "$skill" ]] && continue
            _linkd "$skill" "$local_pi/skills/$(basename "$skill")"
          done
        else
          _linkd "$sub" "$local_pi/$sub_name"
        fi
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
  _link "$DOTFILES/git/hooks/pre-commit" "$DOTFILES/.git/hooks/pre-commit"
fi

echo "✅ Dotfiles linked ($MACHINE)"
