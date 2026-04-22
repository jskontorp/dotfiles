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

_link "$DOTFILES/shared/gitconfig"         ~/.gitconfig
mkdir -p ~/.config/git
_link "$DOTFILES/shared/gitignore_global" ~/.config/git/ignore
_linkd "$DOTFILES/shared/nvim"          ~/.config/nvim
_link "$DOTFILES/pi/agent/AGENTS.md"    ~/.pi/agent/AGENTS.md
_link "$DOTFILES/pi/agent/settings.json" ~/.pi/agent/settings.json
_link "$DOTFILES/pi/agent/models.json"   ~/.pi/agent/models.json
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

# --- Claude Code linking ---
# Mirror pi skills compatible with Claude Code into ~/.claude/skills/, and
# materialise the Claude-only CLAUDE.md addendum (which @-imports the shared
# AGENTS.md). Skills opt out via `claude-compatible: false` in their SKILL.md
# frontmatter (pi ignores unknown fields). This only applies to global pi
# skills; per-project skills are authored deliberately and are mirrored as-is.
_claude_skill_excluded() {
  local skill_md="$1/SKILL.md"
  [[ -f "$skill_md" ]] || return 1
  grep -Eq '^claude-compatible:[[:space:]]*false[[:space:]]*$' "$skill_md"
}

mkdir -p ~/.claude ~/.claude/skills

# Prune broken symlinks (pre-migration debris + stale entries from prior runs)
find ~/.claude/skills -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null

# Generate ~/.claude/CLAUDE.md from template with $DOTFILES substituted so the
# @-import resolves to an absolute path on any host (macOS, Linux VM, Docker
# test). Written as a real file rather than a symlink because the path must be
# host-absolute for Claude's import resolver. rm -f first so we don't write
# through a stale symlink back into the template. Not added to the manifest —
# validate-manifest.sh asserts symlinks only.
rm -f ~/.claude/CLAUDE.md
sed "s|\$DOTFILES|$DOTFILES|g" "$DOTFILES/claude/CLAUDE.md" > ~/.claude/CLAUDE.md

for skill in "$DOTFILES/pi/agent/skills"/*/; do
  [[ ! -d "$skill" ]] && continue
  _claude_skill_excluded "$skill" && continue
  _linkd "$skill" ~/.claude/skills/"$(basename "$skill")"
done

# --- Marketplace pi skills (from lock file) ---
SKILL_LOCK="$DOTFILES/pi/skill-lock.json"
SKILL_CACHE="$HOME/.local/share/pi-skills"
if [[ -f "$SKILL_LOCK" ]]; then
  mkdir -p "$SKILL_CACHE"

  # One-time migration from old cache at ~/.agents/skills/ (was in pi's global
  # scan path, caused project-scoped skills to leak globally).
  if [[ -d "$HOME/.agents/skills" ]]; then
    for d in "$HOME/.agents/skills"/*/; do
      [[ ! -d "$d" ]] && continue
      base=$(basename "$d")
      [[ -d "$SKILL_CACHE/$base" ]] || mv "$d" "$SKILL_CACHE/$base"
    done
    rmdir "$HOME/.agents/skills" 2>/dev/null || true
  fi
  # Clean up leftover ~/.agents/.skill-lock.json from the old cache scheme
  rm -f "$HOME/.agents/.skill-lock.json"
  rmdir "$HOME/.agents" 2>/dev/null || true

  python3 -c "
import json, os, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for name, info in data.get('skills', {}).items():
    skill_dir = os.path.dirname(info['skillPath'])
    print(f'{name}\\t{info[\"sourceUrl\"]}\\t{skill_dir}')
" "$SKILL_LOCK" | while IFS=$'\t' read -r name url skill_dir; do
    [[ -d "$SKILL_CACHE/$name" ]] && continue
    echo "Installing pi skill: $name"
    tmp=$(mktemp -d)
    if git clone --depth 1 --filter=blob:none --sparse "$url" "$tmp/repo" 2>/dev/null &&
       (cd "$tmp/repo" && git sparse-checkout set "$skill_dir" 2>/dev/null); then
      cp -r "$tmp/repo/$skill_dir" "$SKILL_CACHE/$name"
    else
      echo "  ⚠ Failed to install $name" >&2
    fi
    rm -rf "$tmp"
  done

  # Symlink marketplace skills. `scope` field (optional per entry) is either
  # "global" (default → ~/.pi/agent/skills/<name>) or "project:<name>" →
  # resolves via projects.conf and symlinks into <repo>/.pi/skills/<name>.
  # If scope changes between runs, stale symlinks at other locations (that we
  # created, identified by target matching $SKILL_CACHE/<name>) are removed.
  python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for name, info in data.get('skills', {}).items():
    print(f'{name}\t{info.get(\"scope\", \"global\")}')
" "$SKILL_LOCK" | while IFS=$'\t' read -r name scope; do
    content="$SKILL_CACHE/$name"
    [[ ! -d "$content" ]] && continue

    # Compute the desired symlink target for the current scope.
    desired=""
    if [[ "$scope" == "global" ]]; then
      # Custom skills (already linked above, real dir not a symlink) take precedence
      if [[ -e ~/.pi/agent/skills/"$name" && ! -L ~/.pi/agent/skills/"$name" ]]; then
        continue
      fi
      desired="$HOME/.pi/agent/skills/$name"
    elif [[ "$scope" == project:* ]]; then
      proj="${scope#project:}"
      repo=""
      if [[ -f "$DOTFILES/projects.conf" ]]; then
        while IFS= read -r line; do
          [[ "$line" =~ ^[[:space:]]*# ]] && continue
          [[ -z "${line// /}" ]] && continue
          read -r p_name p_path <<< "$line"
          [[ "$p_name" != "$proj" ]] && continue
          p_path="${p_path/#\~/$HOME}"
          if [[ -d "$p_path/.git" ]]; then
            repo="$p_path"
            break
          fi
        done < "$DOTFILES/projects.conf"
      fi
      if [[ -n "$repo" ]]; then
        mkdir -p "$repo/.pi/skills"
        desired="$repo/.pi/skills/$name"
      else
        echo "  ⚠ Scope project:$proj for $name: project not found in projects.conf or not checked out, skipping" >&2
      fi
    else
      echo "  ⚠ Skill $name has unknown scope '$scope', skipping" >&2
    fi

    # Clean up stale symlinks we previously created at other locations.
    # Only remove symlinks whose target is $SKILL_CACHE/<name> (our ownership guard).
    glink="$HOME/.pi/agent/skills/$name"
    if [[ -L "$glink" && "$(readlink "$glink")" == "$SKILL_CACHE/$name" && "$glink" != "$desired" ]]; then
      rm "$glink"
    fi
    if [[ -f "$DOTFILES/projects.conf" ]]; then
      while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        read -r _ p_path <<< "$line"
        p_path="${p_path/#\~/$HOME}"
        plink="$p_path/.pi/skills/$name"
        if [[ -L "$plink" && "$(readlink "$plink")" == "$SKILL_CACHE/$name" && "$plink" != "$desired" ]]; then
          rm "$plink"
        fi
      done < "$DOTFILES/projects.conf"
    fi

    # Create the symlink at the desired location.
    if [[ -n "$desired" ]]; then
      _linkd "$content" "$desired"
    fi
  done

  # Prune marketplace skills no longer in the lock file
  lock_names=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print('\n'.join(data.get('skills', {}).keys()))
" "$SKILL_LOCK")
  for skill_dir in "$SKILL_CACHE"/*/; do
    [[ ! -d "$skill_dir" ]] && continue
    name=$(basename "$skill_dir")
    if ! echo "$lock_names" | grep -qx "$name"; then
      echo "Pruning pi skill: $name"
      rm -rf "$skill_dir"
      link="$HOME/.pi/agent/skills/$name"
      # Remove dangling symlink (target now missing)
      [[ -L "$link" && ! -e "$link" ]] && rm "$link"
    fi
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
_link "$DOTFILES/zsh/pi-notion-routing.zsh" ~/.config/zsh/

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
          # Individual skill symlinks (same pattern as global skills).
          # Exclusion is frontmatter-driven (claude-compatible: false), so a
          # project skill can opt out for Claude explicitly without any
          # central list — no risk of silent name-shadowing.
          [[ -L "$local_pi/skills" ]] && rm "$local_pi/skills"
          mkdir -p "$local_pi/skills"
          local_claude_skills="$candidate/.claude/skills"
          mkdir -p "$local_claude_skills"
          find "$local_claude_skills" -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null
          for skill in "$sub"*/; do
            [[ ! -d "$skill" ]] && continue
            skill_name="$(basename "$skill")"
            _linkd "$skill" "$local_pi/skills/$skill_name"
            _claude_skill_excluded "$skill" && continue
            _linkd "$skill" "$local_claude_skills/$skill_name"
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
