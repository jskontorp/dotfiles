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
  [[ -e "$1" ]] || { printf "❌ install.sh: missing source %s (dest: %s)\n" "$1" "$2" >&2; exit 1; }
  ln -sf "$1" "$2"
  if [[ -d "$2" && ! -L "$2" ]]; then
    echo "${2%/}/$(basename "$1")" >> "$INSTALL_MANIFEST"
  else
    echo "$2" >> "$INSTALL_MANIFEST"
  fi
}

# _linkd <target> <dest> — symlink a directory (replaces existing)
_linkd() {
  [[ -e "$1" ]] || { printf "❌ install.sh: missing source %s (dest: %s)\n" "$1" "$2" >&2; exit 1; }
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

# pi extensions: symlink each .ts file into ~/.pi/agent/extensions/.
# Skip .d.ts (type-declaration only — no runtime export, pi rejects them
# at load time with "does not export a valid factory function").
# Prune any stale .d.ts symlink left behind by previous installs.
if [[ -d "$DOTFILES/pi/agent/extensions" ]]; then
  mkdir -p ~/.pi/agent/extensions
  for stale in ~/.pi/agent/extensions/*.d.ts; do
    [[ -L "$stale" ]] && rm "$stale"
  done
  for ext in "$DOTFILES/pi/agent/extensions"/*.ts; do
    [[ ! -f "$ext" ]] && continue
    [[ "$ext" == *.d.ts ]] && continue
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

# ~/.claude/settings.json is Claude's user-scope config (enabledPlugins, env,
# hooks, permissions). Symlink tracks it in dotfiles so it's portable across
# machines. `/plugin install` writes through the symlink, keeping dotfiles
# in sync automatically. Run `just claude-plugins-install` on a fresh machine
# to materialise the enabledPlugins set via `claude plugin install`.
_link "$DOTFILES/claude/settings.json" ~/.claude/settings.json
_link "$DOTFILES/claude/statusline.sh" ~/.claude/statusline.sh

for skill in "$DOTFILES/pi/agent/skills"/*/; do
  [[ ! -d "$skill" ]] && continue
  _claude_skill_excluded "$skill" && continue
  _linkd "$skill" ~/.claude/skills/"$(basename "$skill")"
done

# Mirror Claude-native subagents (dotfiles/claude/agents/*.md) into ~/.claude/agents/.
# Subagents differ from skills: they fork context, scope tools, and are invoked
# via the Task tool (not description-matching in the main loop).
mkdir -p ~/.claude/agents
find ~/.claude/agents -maxdepth 1 -type l ! -exec test -e {} \; -delete 2>/dev/null
if [[ -d "$DOTFILES/claude/agents" ]]; then
  for agent in "$DOTFILES/claude/agents"/*.md; do
    [[ -f "$agent" ]] || continue
    _link "$agent" ~/.claude/agents/"$(basename "$agent")"
  done
fi

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
    sha = info.get('skillFolderHash', '')
    print(f'{name}\\t{info[\"sourceUrl\"]}\\t{skill_dir}\\t{sha}')
" "$SKILL_LOCK" | while IFS=$'\t' read -r name url skill_dir sha; do
    [[ -d "$SKILL_CACHE/$name" ]] && continue
    echo "Installing pi skill: $name"
    tmp=$(mktemp -d)
    # Pin to recorded SHA when present. Falls back to HEAD with a warning if
    # the SHA is unreachable (force-pushed away, repo gone private, etc.) so
    # an installation never silently shifts versions across machines.
    fetched=""
    if [[ -n "$sha" ]]; then
      if (cd "$tmp" && git init -q repo && cd repo \
          && git remote add origin "$url" \
          && git fetch --depth 1 --filter=blob:none origin "$sha" 2>/dev/null \
          && git sparse-checkout init --cone 2>/dev/null \
          && git sparse-checkout set "$skill_dir" 2>/dev/null \
          && git checkout -q FETCH_HEAD 2>/dev/null); then
        fetched="$sha"
      else
        echo "  ⚠ $name: pinned SHA $sha unreachable, falling back to HEAD" >&2
        rm -rf "$tmp/repo"
      fi
    fi
    if [[ -z "$fetched" ]]; then
      if ! (git clone --depth 1 --filter=blob:none --sparse "$url" "$tmp/repo" 2>/dev/null \
            && cd "$tmp/repo" && git sparse-checkout set "$skill_dir" 2>/dev/null); then
        echo "  ❌ Failed to install $name" >&2
        rm -rf "$tmp"
        continue
      fi
    fi
    cp -r "$tmp/repo/$skill_dir" "$SKILL_CACHE/$name"
    rm -rf "$tmp"
  done

  # Symlink marketplace skills. `scope` field (optional per entry) is either
  # "global" (default → ~/.pi/agent/skills/<name> + ~/.claude/skills/<name>) or
  # "project:<name>" → resolves via projects/<name>/.path and symlinks into
  # <repo>/.pi/skills/<name> + <repo>/.claude/skills/<name>. Claude mirror is
  # skipped for skills with `claude-compatible: false` in their SKILL.md.
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

    # Compute the desired symlink targets for the current scope.
    desired=""
    desired_claude=""
    claude_ok=true
    _claude_skill_excluded "$content" && claude_ok=false
    # A custom skill with this name already linked above (as a symlink, via
    # _linkd) shadows the marketplace entry. Leave desired/desired_claude
    # empty so the cleanup block below wipes any stale cache-pointing
    # symlinks (including per-project links from a prior scope), and the
    # create block no-ops. Guard by source dir, not link type.
    if [[ ! -d "$DOTFILES/pi/agent/skills/$name" ]]; then
      if [[ "$scope" == "global" ]]; then
        desired="$HOME/.pi/agent/skills/$name"
        $claude_ok && desired_claude="$HOME/.claude/skills/$name"
      elif [[ "$scope" == project:* ]]; then
        proj="${scope#project:}"
        repo=""
        path_file="$DOTFILES/projects/$proj/.path"
        if [[ -f "$path_file" ]]; then
          while IFS= read -r p_path; do
            [[ "$p_path" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${p_path// /}" ]] && continue
            p_path="${p_path/#\~/$HOME}"
            if [[ -d "$p_path/.git" ]]; then
              repo="$p_path"
              break
            fi
          done < "$path_file"
        fi
        if [[ -n "$repo" ]]; then
          mkdir -p "$repo/.pi/skills"
          desired="$repo/.pi/skills/$name"
          if $claude_ok; then
            mkdir -p "$repo/.claude/skills"
            desired_claude="$repo/.claude/skills/$name"
          fi
        else
          echo "  ⚠ Scope project:$proj for $name: project not registered (projects/$proj/.path missing) or not checked out, skipping" >&2
        fi
      else
        echo "  ⚠ Skill $name has unknown scope '$scope', skipping" >&2
      fi
    fi

    # Clean up stale symlinks we previously created at other locations.
    # Only remove symlinks whose target is $SKILL_CACHE/<name> (our ownership guard).
    for link_root in "$HOME/.pi/agent/skills" "$HOME/.claude/skills"; do
      stale="$link_root/$name"
      case "$link_root" in
        */.claude/skills) want="$desired_claude" ;;
        *)                want="$desired"        ;;
      esac
      if [[ -L "$stale" && "$(readlink "$stale")" == "$SKILL_CACHE/$name" && "$stale" != "$want" ]]; then
        rm "$stale"
      fi
    done
    for path_file in "$DOTFILES/projects"/*/.path; do
      [[ ! -f "$path_file" ]] && continue
      while IFS= read -r p_path; do
        [[ "$p_path" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${p_path// /}" ]] && continue
        p_path="${p_path/#\~/$HOME}"
        for sub in ".pi/skills" ".claude/skills"; do
          stale="$p_path/$sub/$name"
          case "$sub" in
            .claude/skills) want="$desired_claude" ;;
            *)              want="$desired"        ;;
          esac
          if [[ -L "$stale" && "$(readlink "$stale")" == "$SKILL_CACHE/$name" && "$stale" != "$want" ]]; then
            rm "$stale"
          fi
        done
      done < "$path_file"
    done

    # Create the symlinks at the desired locations.
    [[ -n "$desired" ]]        && _linkd "$content" "$desired"
    [[ -n "$desired_claude" ]] && _linkd "$content" "$desired_claude"
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
      # Remove dangling symlinks (target now missing) at both global roots
      # and at every known project's pi/claude skill dirs
      for link in "$HOME/.pi/agent/skills/$name" "$HOME/.claude/skills/$name"; do
        [[ -L "$link" && ! -e "$link" ]] && rm "$link"
      done
      for path_file in "$DOTFILES/projects"/*/.path; do
        [[ ! -f "$path_file" ]] && continue
        while IFS= read -r p_path; do
          [[ "$p_path" =~ ^[[:space:]]*# ]] && continue
          [[ -z "${p_path// /}" ]] && continue
          p_path="${p_path/#\~/$HOME}"
          for link in "$p_path/.pi/skills/$name" "$p_path/.claude/skills/$name"; do
            [[ -L "$link" && ! -e "$link" ]] && rm "$link"
          done
        done < "$path_file"
      done
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
# Walks projects/<name>/ directories. Each project advertises its on-disk
# location via projects/<name>/.path (single line, may use ~). install.sh
# symlinks the project's skills/, hookify/, and other subdirs into the
# checked-out repo's .pi/ and .claude/ dirs. AGENTS.md is NOT managed here
# — it lives in the project repo and follows normal git.
for pdir in "$DOTFILES/projects"/*/; do
  [[ ! -d "$pdir" ]] && continue
  name="$(basename "$pdir")"
  path_file="$pdir.path"
  if [[ ! -f "$path_file" ]]; then
    echo "$name has no .path file, skipping project config" >&2
    continue
  fi
  candidate=""
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    line="${line/#\~/$HOME}"
    if [[ -d "$line/.git" ]]; then
      candidate="$line"
      break
    fi
  done < "$path_file"

  if [[ -z "$candidate" ]]; then
    echo "$name not found, skipping project config"
    continue
  fi

  echo "Found $name at $candidate"
  local_pi="$candidate/.pi"
  mkdir -p "$local_pi"

  # Symlink each subdirectory present in projects/<name>/
  for sub in "$pdir"*/; do
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
    elif [[ "$sub_name" == "hookify" ]]; then
      # Claude hookify rules: symlink each hookify.*.local.md into
      # <repo>/.claude/ (hookify discovers rules there by naming convention).
      mkdir -p "$candidate/.claude"
      for rule in "$sub"hookify.*.local.md; do
        [[ ! -f "$rule" ]] && continue
        _link "$rule" "$candidate/.claude/$(basename "$rule")"
      done
    else
      _linkd "$sub" "$local_pi/$sub_name"
    fi
  done
done

# --- Git hooks (for the dotfiles repo itself) ---
if [[ -d "$DOTFILES/.git" ]]; then
  mkdir -p "$DOTFILES/.git/hooks"
  _link "$DOTFILES/git/hooks/pre-commit" "$DOTFILES/.git/hooks/pre-commit"
fi

echo "✅ Dotfiles linked ($MACHINE)"
