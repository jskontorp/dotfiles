# dotfiles — unified config for macOS and Linux

default:
    @just --list

DOTFILES := justfile_directory()
MAC      := DOTFILES / "machine/mac"
VM       := DOTFILES / "machine/vm"

# Global pnpm packages — shared across mac and vm update recipes
GLOBAL_PNPM := "@anthropic-ai/claude-code @earendil-works/pi-coding-agent pyright typescript"

# Tools that both platforms must report in `just status`.
# Platform-specific tools (brew, fnm, docker, etc.) are added per-recipe.
SHARED_STATUS_TOOLS := "zsh nvim tmux node pnpm git gh delta starship eza bat rg fzf zoxide lazygit glow pi claude"

# --- Setup ---

# Full bootstrap (fresh machine)
[macos]
init:
    {{MAC}}/bootstrap.sh

[linux]
init:
    {{VM}}/bootstrap.sh

# Update packages + tools
[macos]
update:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "📦 Homebrew..."
    brew update && brew bundle --file="{{MAC}}/Brewfile" && brew upgrade && brew cleanup
    echo "📦 global pnpm packages..."
    # Ensure pnpm's global bin exists + is on PATH for this shell. PNPM_HOME
    # itself is exported from zsh/core.zsh; we re-export here because `just`
    # recipes don't inherit interactive-shell config. pnpm ≥10 uses
    # $PNPM_HOME/bin as its global-bin-dir (older pnpm used $PNPM_HOME).
    # Creating the dir is what `pnpm setup` would do — we skip `pnpm setup`
    # to avoid it appending a duplicate PNPM_HOME block to ~/.zshrc.
    export PNPM_HOME="$HOME/Library/pnpm"
    export PATH="$PNPM_HOME/bin:$PATH"
    mkdir -p "$PNPM_HOME/bin"
    # Legacy package scope was renamed; remove old name if present.
    pnpm rm -g @mariozechner/pi-coding-agent >/dev/null 2>&1 || true
    pnpm add -g {{GLOBAL_PNPM}}

    # Ensure Claude Code's native binary is present (see VM recipe for rationale).
    # pnpm ≥11 nests global packages under a content-hashed dir, so
    # `pnpm root -g` no longer points at the package itself — query
    # `pnpm list -g --parseable` for the resolved path.
    echo "📦 claude native binary..."
    CLAUDE_PKG="$(pnpm list -g --parseable 2>/dev/null | grep '/@anthropic-ai/claude-code$' | head -1)"
    if [[ -n "$CLAUDE_PKG" && -f "$CLAUDE_PKG/install.cjs" ]]; then
      node "$CLAUDE_PKG/install.cjs" || echo "  ⚠ claude install.cjs failed — run manually: node $CLAUDE_PKG/install.cjs"
    elif ! claude --version >/dev/null 2>&1; then
      echo "  ⚠ claude binary not runnable and no install.cjs present."
      echo "    Try: pnpm install -g --force @anthropic-ai/claude-code"
    fi

    echo "📦 tmux plugins..."
    "$HOME/.tmux/plugins/tpm/bin/install_plugins"
    echo "✅ Done"

[linux]
update:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{VM}}/versions.env"

    echo "📦 apt..."
    sudo apt-get update -qq && sudo apt-get upgrade -y -qq
    sudo apt-get install -y -qq \
      zsh git gh curl wget unzip jq fzf \
      ripgrep fd-find bat \
      build-essential
    sudo apt-get autoremove -y -qq
    sudo ln -sf "$(which fdfind)" /usr/local/bin/fd 2>/dev/null || true
    sudo ln -sf "$(which batcat)" /usr/local/bin/bat 2>/dev/null || true

    echo "📦 zsh plugins..."
    ZSH_PLUGINS="$HOME/.local/share/zsh/plugins"
    mkdir -p "$ZSH_PLUGINS"
    for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
      if [[ -d "$ZSH_PLUGINS/$plugin" ]]; then
        git -C "$ZSH_PLUGINS/$plugin" pull -q
      else
        git clone --depth=1 "https://github.com/zsh-users/$plugin" "$ZSH_PLUGINS/$plugin"
      fi
    done

    _install() { echo "📦 $1..."; }

    # _fetch_binary <name> <url> <binary> [strip-components]
    # Downloads a tarball, extracts the named binary, installs to /usr/local/bin.
    _fetch_binary() {
      local name="$1" url="$2" binary="${3:-$1}" strip="${4:-0}"
      _install "$name"
      local tmp=$(mktemp -d)
      curl -sL "$url" | tar xz --strip-components="$strip" -C "$tmp"
      sudo mv "$tmp/$binary" /usr/local/bin/"$binary"
      rm -rf "$tmp"
    }

    _install neovim
    _tmp=$(mktemp -d)
    curl -sL "https://github.com/neovim/neovim/releases/latest/download/nvim-linux-arm64.tar.gz" | tar xz -C "$_tmp"
    sudo rm -rf /opt/nvim && sudo mv "$_tmp/nvim-linux-arm64" /opt/nvim
    sudo ln -sf /opt/nvim/bin/nvim /usr/local/bin/nvim
    rm -rf "$_tmp"

    BAT_VERSION=$(curl -s https://api.github.com/repos/sharkdp/bat/releases/latest | grep tag_name | cut -d'"' -f4)
    _fetch_binary bat \
      "https://github.com/sharkdp/bat/releases/download/${BAT_VERSION}/bat-${BAT_VERSION}-aarch64-unknown-linux-gnu.tar.gz" \
      bat 1
    bat cache --build 2>/dev/null

    EZA_VERSION=$(curl -s https://api.github.com/repos/eza-community/eza/releases/latest | grep tag_name | cut -d'"' -f4)
    _fetch_binary eza \
      "https://github.com/eza-community/eza/releases/download/${EZA_VERSION}/eza_aarch64-unknown-linux-gnu.tar.gz" \
      eza

    DELTA_VERSION=$(curl -s https://api.github.com/repos/dandavison/delta/releases/latest | grep tag_name | cut -d'"' -f4)
    _fetch_binary delta \
      "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/delta-${DELTA_VERSION}-aarch64-unknown-linux-gnu.tar.gz" \
      delta 1

    LAZYGIT_VERSION=$(curl -s https://api.github.com/repos/jesseduffield/lazygit/releases/latest | grep tag_name | cut -d'"' -f4 | sed 's/^v//')
    _fetch_binary lazygit \
      "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_arm64.tar.gz" \
      lazygit

    GLOW_VERSION=$(curl -s https://api.github.com/repos/charmbracelet/glow/releases/latest | grep tag_name | cut -d'"' -f4 | sed 's/^v//')
    _fetch_binary glow \
      "https://github.com/charmbracelet/glow/releases/download/v${GLOW_VERSION}/glow_${GLOW_VERSION}_Linux_arm64.tar.gz" \
      glow 1

    _install zoxide
    curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh

    _install starship
    curl -sS https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin"

    _install "fnm + node"
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
    export PATH="$HOME/.local/share/fnm:$PATH"
    eval "$(fnm env)"
    fnm install --lts

    _install just
    rm -f "$HOME/.local/bin/just"
    curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to "$HOME/.local/bin"

    _install tmux
    if ! command -v tmux &>/dev/null || [[ "$(tmux -V)" != "tmux $TMUX_VERSION" ]]; then
      sudo apt-get install -y -qq libevent-dev ncurses-dev bison
      _tmp=$(mktemp -d)
      ( cd "$_tmp"
        curl -sL "https://github.com/tmux/tmux/releases/download/${TMUX_VERSION}/tmux-${TMUX_VERSION}.tar.gz" | tar xz
        cd "tmux-${TMUX_VERSION}" && ./configure --prefix=/usr/local && make -j"$(nproc)" && sudo make install
      )
      rm -rf "$_tmp"
    else
      echo "  tmux $(tmux -V | awk '{print $2}') already at target"
    fi

    _install uv
    curl -LsSf https://astral.sh/uv/install.sh | sh

    _install docker
    if ! command -v docker &>/dev/null; then
      curl -fsSL https://get.docker.com | sh
      sudo usermod -aG docker "$USER"
      echo "  ⚠ Log out and back in for docker group"
    else
      echo "  docker $(docker --version | awk '{print $3}' | tr -d ',') already installed"
    fi

    _install pnpm
    # The standalone installer drops the `pnpm` binary at $PNPM_HOME/pnpm,
    # while pnpm ≥10 places globally-added shims under $PNPM_HOME/bin
    # (older pnpm used $PNPM_HOME for both). Keep both on PATH, but prefer
    # $PNPM_HOME/bin so modern shims win when legacy shims still exist.
    export PNPM_HOME="$HOME/.local/share/pnpm"
    export PATH="$PNPM_HOME/bin:$PNPM_HOME:$PATH"
    mkdir -p "$PNPM_HOME/bin"
    curl -fsSL https://get.pnpm.io/install.sh | SHELL=/bin/bash sh -
    echo "📦 global pnpm packages..."
    # Legacy package scope was renamed; remove old name if present.
    pnpm rm -g @mariozechner/pi-coding-agent >/dev/null 2>&1 || true
    pnpm add -g {{GLOBAL_PNPM}}

    # Claude Code ships a native binary via a postinstall script (install.cjs).
    # pnpm may skip postinstalls (--ignore-scripts) or optional deps
    # (--omit=optional), leaving `claude` launchable but failing with
    # "native binary not installed" at runtime. Running install.cjs
    # explicitly is idempotent and fixes both cases. Newer versions ship
    # install.cjs inside the package; if absent (older version), verify
    # runtime works and warn.
    # pnpm ≥11 nests global packages under a content-hashed dir; query
    # `pnpm list -g --parseable` instead of joining onto `pnpm root -g`.
    echo "📦 claude native binary..."
    CLAUDE_PKG="$(pnpm list -g --parseable 2>/dev/null | grep '/@anthropic-ai/claude-code$' | head -1)"
    if [[ -n "$CLAUDE_PKG" && -f "$CLAUDE_PKG/install.cjs" ]]; then
      node "$CLAUDE_PKG/install.cjs" || echo "  ⚠ claude install.cjs failed — run manually: node $CLAUDE_PKG/install.cjs"
    elif ! claude --version >/dev/null 2>&1; then
      echo "  ⚠ claude binary not runnable and no install.cjs present."
      echo "    Try: pnpm install -g --force @anthropic-ai/claude-code"
    fi

    echo "📦 tmux plugins..."
    "$HOME/.tmux/plugins/tpm/bin/install_plugins"

    echo "🧹 cleanup..."
    [[ -d "$HOME/.oh-my-zsh" ]] && rm -rf "$HOME/.oh-my-zsh" && echo "  removed ~/.oh-my-zsh"
    dpkg -l bat &>/dev/null && sudo apt-get remove -y -qq bat && echo "  removed apt bat"

    echo "✅ Done"

# Show installed tool versions
[macos]
status:
    #!/usr/bin/env bash
    printf "%-12s %s\n" "macOS"    "$(sw_vers -productVersion)"
    printf "%-12s %s\n" "chip"     "$(uname -m)"
    printf "%-12s %s\n" "zsh"      "$(zsh --version | awk '{print $2}')"
    printf "%-12s %s\n" "nvim"     "$(nvim --version | head -1 | awk '{print $2}')"
    printf "%-12s %s\n" "tmux"     "$(tmux -V | awk '{print $2}')"
    printf "%-12s %s\n" "node"     "$(node --version 2>/dev/null || echo 'missing')"
    printf "%-12s %s\n" "pnpm"     "$(pnpm --version 2>/dev/null || echo 'missing')"
    printf "%-12s %s\n" "git"      "$(git --version | awk '{print $3}')"
    printf "%-12s %s\n" "gh"       "$(gh --version | head -1 | awk '{print $3}')"
    printf "%-12s %s\n" "delta"    "$(delta --version 2>/dev/null | awk '{print $2}')"
    printf "%-12s %s\n" "starship" "$(starship --version | head -1 | awk '{print $2}')"
    printf "%-12s %s\n" "eza"      "$(eza --version | sed -n 2p | awk '{print $1}')"
    printf "%-12s %s\n" "bat"      "$(bat --version | awk '{print $2}')"
    printf "%-12s %s\n" "rg"       "$(rg --version | head -1 | awk '{print $2}')"
    printf "%-12s %s\n" "fzf"      "$(fzf --version | awk '{print $1}')"
    printf "%-12s %s\n" "fd"       "$(fd --version | awk '{print $2}')"
    printf "%-12s %s\n" "zoxide"   "$(zoxide --version 2>/dev/null | awk '{print $2}' || echo 'missing')"
    printf "%-12s %s\n" "lazygit"  "$(lazygit --version | head -1 | sed 's/.*version=//' | cut -d, -f1)"
    printf "%-12s %s\n" "glow"     "$(glow --version 2>/dev/null | awk '{print $3}' || echo 'missing')"
    printf "%-12s %s\n" "pi"       "$(command -v pi &>/dev/null && pi --version 2>&1 | awk '{print $NF}' || echo 'missing')"
    printf "%-12s %s\n" "claude"   "$(command -v claude &>/dev/null && claude --version 2>&1 | awk '{print $1}' || echo 'missing')"

[linux]
status:
    #!/usr/bin/env bash
    # pnpm ≥10 puts global bins under $PNPM_HOME/bin, but the standalone
    # installer drops the `pnpm` binary itself at $PNPM_HOME (no /bin).
    # Keep both on PATH — matches zsh/core.zsh (see commit 271471e).
    export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$HOME/.local/share/pnpm:$HOME/.local/share/pnpm/bin:$PATH"
    command -v fnm &>/dev/null && eval "$(fnm env)"
    printf "%-12s %s\n" "os"       "$(lsb_release -ds)"
    printf "%-12s %s\n" "kernel"   "$(uname -r)"
    printf "%-12s %s\n" "zsh"      "$(zsh --version | awk '{print $2}')"
    printf "%-12s %s\n" "nvim"     "$(nvim --version | head -1 | awk '{print $2}')"
    printf "%-12s %s\n" "tmux"     "$(tmux -V | awk '{print $2}')"
    printf "%-12s %s\n" "node"     "$(node --version 2>/dev/null || echo 'missing')"
    printf "%-12s %s\n" "pnpm"     "$(pnpm --version 2>/dev/null || echo 'missing')"
    printf "%-12s %s\n" "uv"       "$(uv --version 2>/dev/null | awk '{print $2}' || echo 'missing')"
    printf "%-12s %s\n" "git"      "$(git --version | awk '{print $3}')"
    printf "%-12s %s\n" "gh"       "$(gh --version | head -1 | awk '{print $3}')"
    printf "%-12s %s\n" "delta"    "$(delta --version 2>/dev/null | awk '{print $2}')"
    printf "%-12s %s\n" "starship" "$(starship --version | head -1 | awk '{print $2}')"
    printf "%-12s %s\n" "eza"      "$(eza --version | sed -n 2p | awk '{print $1}')"
    printf "%-12s %s\n" "bat"      "$(bat --version | awk '{print $2}')"
    printf "%-12s %s\n" "rg"       "$(rg --version | head -1 | awk '{print $2}')"
    printf "%-12s %s\n" "fzf"      "$(fzf --version | awk '{print $1}')"
    printf "%-12s %s\n" "zoxide"   "$(zoxide --version 2>/dev/null | awk '{print $2}' || echo 'missing')"
    printf "%-12s %s\n" "lazygit"  "$(lazygit --version | head -1 | sed 's/.*version=//' | cut -d, -f1)"
    printf "%-12s %s\n" "glow"     "$(glow --version 2>/dev/null | awk '{print $3}' || echo 'missing')"
    printf "%-12s %s\n" "fnm"      "$(fnm --version 2>/dev/null | awk '{print $2}' || echo 'missing')"
    printf "%-12s %s\n" "just"     "$(just --version 2>/dev/null | awk '{print $2}' || echo 'missing')"
    printf "%-12s %s\n" "docker"   "$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo 'missing')"
    printf "%-12s %s\n" "pi"       "$(command -v pi &>/dev/null && pi --version 2>&1 | awk '{print $NF}' || echo 'missing')"
    printf "%-12s %s\n" "claude"   "$(command -v claude &>/dev/null && claude --version 2>&1 | awk '{print $1}' || echo 'missing')"

# --- Management ---

# Re-pointing every `~` symlink at a worktree path produces dangling symlinks
# the moment that worktree is removed (`git worktree remove`), and per
# pi/agent/AGENTS.md's worktree-default rule the canonical checkout is the
# only valid linking source. The cascade: every recipe that auto-runs
# `just link` (new-skill / edit-skill / add-skill / update-skill, JSK-37)
# inherits this refusal — skill-mutation must happen from canonical. The fix
# is a one-liner: `cd "$canonical" && just <recipe>` (or `gust link`,
# which resolves canonical dynamically).
#
# Symlink all configs (refuses from a worktree; canonical-only).
link:
    #!/usr/bin/env bash
    set -euo pipefail
    canonical="$(dirname "$(git -C {{DOTFILES}} rev-parse --path-format=absolute --git-common-dir)")"
    cwd_canonical="$(dirname "$(git -C "$PWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo /dev/null/.git)")"
    if [[ "$canonical" != "$cwd_canonical" || "{{DOTFILES}}" != "$canonical" ]]; then
      printf "❌ just link: refusing to run from a worktree (or outside canonical).\n" >&2
      printf "   canonical = %s\n" "$canonical" >&2
      printf "   cwd repo  = %s\n" "$cwd_canonical" >&2
      printf "   DOTFILES  = %s\n" "{{DOTFILES}}" >&2
      printf "   Per pi/agent/AGENTS.md worktree-default rule, install.sh must run from canonical.\n" >&2
      printf "   Switch: cd \"$canonical\" && just <recipe>\n" >&2
      exit 1
    fi
    {{DOTFILES}}/install.sh

# Pull origin/main, re-link, verify. Refuses outside canonical (inherits
# `just link`'s guard via delegation). Refuses on detached HEAD, non-main
# branch, dirty tree, or local-ahead-of-origin. Surfaces a banner when
# the pulled range touches agent-policy surface (AGENTS.md / extensions /
# Claude settings / hooks) so live agent sessions get a restart hint.
# Surfaces a separate banner when the pulled range touches any
# `working/batches/**/state.md` (signals concurrent multi-machine ledger
# writes, flagged in JSK-49 for revisit).
sync:
    #!/usr/bin/env bash
    set -euo pipefail
    # Defensive: never inherit a pre-commit hook's git env. Not in JSK-44
    # lint scope (no `git init` / `worktree add` / `clone` here), but cheap.
    unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR

    canonical="$(dirname "$(git -C {{DOTFILES}} rev-parse --path-format=absolute --git-common-dir)")"
    if [[ "{{DOTFILES}}" != "$canonical" ]]; then
      printf "❌ just sync: refusing to run from a worktree (or outside canonical).\n" >&2
      printf "   canonical = %s\n   DOTFILES  = %s\n" "$canonical" "{{DOTFILES}}" >&2
      printf "   Switch: cd \"$canonical\" && just sync\n" >&2
      exit 1
    fi
    cd "$canonical"

    branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')"
    if [[ "$branch" != "main" ]]; then
      printf "❌ just sync: HEAD is on '%s', expected 'main'. Switch first.\n" "$branch" >&2
      exit 1
    fi
    if [[ -n "$(git status --porcelain)" ]]; then
      printf "❌ just sync: working tree dirty — commit/stash first.\n" >&2
      git status --short >&2
      exit 1
    fi
    # Per-machine user identity must be present; missing ~/.gitconfig.local
    # was the root cause of the May 13 canonical-config corruption (test
    # fixture's git config writes landed in canonical when no local user
    # was set). Fail loud before any pull.
    if [[ -z "$(git config --get user.email 2>/dev/null)" ]]; then
      printf "❌ just sync: git user.email unset. Create ~/.gitconfig.local first.\n" >&2
      exit 1
    fi

    GIT_SSH_COMMAND='ssh -o ConnectTimeout=5 -o BatchMode=yes' git fetch --quiet origin main
    behind="$(git rev-list --count main..origin/main 2>/dev/null || echo 0)"
    ahead="$(git  rev-list --count origin/main..main 2>/dev/null || echo 0)"

    if (( ahead > 0 && behind > 0 )); then
      printf "❌ diverged: %d ahead, %d behind. Reconcile manually (rebase or merge).\n" "$ahead" "$behind" >&2
      exit 1
    fi
    if (( ahead > 0 )); then
      printf "⚠ %d commits ahead origin/main — push first, then re-run.\n" "$ahead" >&2
      exit 1
    fi
    if (( behind == 0 )); then
      printf "✓ already up to date\n"
      just check
      exit 0
    fi

    # Capture pulled paths before mutating; used by both banners below.
    pulled="$(git log --name-only --pretty=format: main..origin/main | sort -u)"
    git merge --ff-only origin/main

    # Banner 1: agent rule surface changed — restart any live agent sessions.
    if printf '%s\n' "$pulled" | grep -qE '^(pi/agent/(AGENTS\.md|extensions/)|claude/(CLAUDE\.md|settings\.json|agents/)|git/hooks/)'; then
      printf "\n⚠ agent rule surface changed in pulled range — restart any running pi/Claude sessions before continuing.\n" >&2
    fi
    # Banner 2: ledger writes from another machine. Single-machine ledger
    # is the documented assumption; concurrent writes trigger JSK-XX.
    if printf '%s\n' "$pulled" | grep -qE '^working/batches/.*/state\.md$'; then
      printf "\n⚠ ledger state changed in pulled range — indicates concurrent multi-machine batches.\n" >&2
      printf "   Current ledger design assumes single-machine writes; revisit JSK-49 if this is happening regularly.\n" >&2
    fi

    # Delegate symlinking to `just link` so its worktree-refuse guard is
    # the canonical entry point (rather than calling install.sh directly).
    just link
    just check

# The manifest is the contract — see uninstall.sh's footer for the things
# this does NOT touch (pnpm globals, Brewfile, tmux/claude plugins,
# ~/.gitconfig.local, etc.). For a full Mac tear-down including brew +
# plugin caches + pi/Claude state, see `just uninstall-full`.
#
# Reverse install.sh: remove every symlink in .install-manifest. Idempotent.
uninstall:
    {{DOTFILES}}/uninstall.sh

# Reverses install.sh AND removes Brewfile packages, pnpm globals, plugin
# caches, OrbStack runtime, pi credentials and sessions. Preserves
# ~/.gitconfig.local, ~/.zsh_history, and the dotfiles checkout. Idempotent.
#
# Nuclear Mac uninstall: install.sh + brew + pnpm + plugin/pi state. Requires --yes.
uninstall-full *args:
    {{DOTFILES}}/uninstall-full.sh {{args}}

# Show unified pi skill inventory: name, scope, source, description
skills:
    #!/usr/bin/env python3
    import json, re, sys
    from pathlib import Path

    DOTFILES = Path("{{DOTFILES}}")
    entries = []

    def description(skill_md):
        if not skill_md.exists():
            return ""
        text = skill_md.read_text()
        m = re.search(r"^---\n(.*?)\n---", text, re.DOTALL)
        if not m:
            return ""
        try:
            import yaml
            data = yaml.safe_load(m.group(1)) or {}
            desc = str(data.get("description", ""))
        except Exception:
            desc = ""
            for line in m.group(1).splitlines():
                if line.startswith("description:"):
                    desc = line.split(":", 1)[1].strip().strip('"').strip("'")
                    break
        return " ".join(desc.split())

    custom_dir = DOTFILES / "pi/agent/skills"
    if custom_dir.exists():
        for d in sorted(custom_dir.iterdir()):
            if d.is_dir():
                entries.append((d.name, "global", "local", description(d / "SKILL.md")))

    lock = DOTFILES / "pi/skill-lock.json"
    if lock.exists():
        data = json.loads(lock.read_text())
        for name in sorted(data.get("skills", {})):
            info = data["skills"][name]
            scope = info.get("scope", "global")
            installed = Path.home() / ".local/share/pi-skills" / name / "SKILL.md"
            entries.append((name, scope, "github", description(installed)))

    projects_dir = DOTFILES / "projects"
    if projects_dir.exists():
        for proj in sorted(projects_dir.iterdir()):
            if not proj.is_dir():
                continue
            skills_dir = proj / "skills"
            if skills_dir.exists():
                for s in sorted(skills_dir.iterdir()):
                    if s.is_dir():
                        entries.append((s.name, f"project:{proj.name}", "local", description(s / "SKILL.md")))

    if not entries:
        print("(no skills found)")
        sys.exit(0)

    max_name = max(len(e[0]) for e in entries)
    max_scope = max(len(e[1]) for e in entries)
    header = f"{'NAME':<{max_name}}  {'SCOPE':<{max_scope}}  {'SOURCE':<7}  DESCRIPTION"
    print(header)
    print("-" * len(header))
    desc_width = max(20, 100 - max_name - max_scope - 7 - 6)
    for name, scope, source, desc in entries:
        if len(desc) > desc_width:
            desc = desc[:desc_width - 1] + "\u2026"
        print(f"{name:<{max_name}}  {scope:<{max_scope}}  {source:<7}  {desc}")
    print()
    print(f"({len(entries)} skills tracked by dotfiles. Pi sessions also load skills shipped by installed pi packages, e.g. setup-oauth + workspace-explorer from @feniix/pi-notion.)")

# Sub-second; safe to run before every commit (wired into git/hooks/pre-commit).
# For the full Docker integration suite, use `just test`.
#
# Fast host-side checks: justfile, manifest, bash portability, gates, tsc, Brewfile.
[group('test')]
check:
    #!/usr/bin/env bash
    set -euo pipefail
    printf "justfile:\n"
    bash {{DOTFILES}}/test/check-justfile.sh
    printf "\nmanifest:\n"
    bash {{DOTFILES}}/test/validate-manifest.sh
    printf "\nbash portability:\n"
    bash {{DOTFILES}}/test/check-bash-portability.sh
    printf "\ncanonical-path helper:\n"
    bash {{DOTFILES}}/test/check-canonical-path.sh
    printf "\nsilencing-gate:\n"
    bash {{DOTFILES}}/test/check-silencing-gate.sh
    printf "\nsecret-path gate (JSK-35):\n"
    bash {{DOTFILES}}/test/check-secret-gate.sh
    printf "\ndestructive-gate patterns:\n"
    bash {{DOTFILES}}/test/check-destructive-gate.sh
    printf "\nregression-class provenance:\n"
    bash {{DOTFILES}}/test/check-regression-provenance.sh
    printf "\ngit-env isolation (JSK-44):\n"
    bash {{DOTFILES}}/test/check-git-env-isolation.sh
    printf "\npre-commit self-check (JSK-46):\n"
    bash {{DOTFILES}}/test/check-pre-commit-self-check.sh
    printf "\nhook chain (JSK-43):\n"
    bash {{DOTFILES}}/test/check-hook-chain.sh
    printf "\nextensions (typescript):\n"
    if ! command -v tsc >/dev/null 2>&1; then
      printf "  ⚠ tsc not on PATH — skipped (run 'just update' to install)\n" >&2
    else
      ( cd {{DOTFILES}}/pi/agent/extensions && tsc --noEmit ) && printf "  ✅ no type errors\n"
    fi
    printf "\nextensions (node unit tests):\n"
    if ! command -v node >/dev/null 2>&1; then
      printf "  ⚠ node not on PATH — skipped\n" >&2
    else
      ( cd {{DOTFILES}} && node --test pi/agent/extensions/shared/*.test.mjs >/dev/null ) && printf "  ✅ unit tests pass\n"
    fi
    printf "\nBrewfile (mac):\n"
    if [[ "$(uname -s)" == "Darwin" ]]; then
      if ! command -v brew >/dev/null 2>&1; then
        printf "  ⚠ brew not on PATH — skipped\n" >&2
      else
        # --no-upgrade: presence-only check (don't trip on every upstream release).
        # HOMEBREW_NO_AUTO_UPDATE: don't trigger network auto-update during a fast check.
        HOMEBREW_NO_AUTO_UPDATE=1 brew bundle check --no-upgrade --file={{DOTFILES}}/machine/mac/Brewfile >/dev/null \
          && printf "  ✅ Brewfile satisfied\n" \
          || { printf "  ❌ Brewfile drift — run 'brew bundle install --file={{DOTFILES}}/machine/mac/Brewfile'\n" >&2; exit 1; }
      fi
    else
      printf "  — skipped on non-Darwin\n"
    fi

# Checks an agentic session's runtime: tool versions on PATH, $DOTFILES env
# matches this checkout, manifest symlinks intact, Claude plugins materialised
# against settings.json's enabledPlugins, and the notion-routing cwd→auth-file
# mapping behaves. No network calls; no keychain probing (those surface
# naturally when used). Exit non-zero on any failure.
#
# Probe runtime: tool PATH, $DOTFILES, symlinks, claude plugins, notion routing.
[group('test')]
doctor:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    ok()   { printf "  ✅ %s\n" "$1"; }
    warn() { printf "  ⚠  %s\n" "$1"; }
    fail() { printf "  ❌ %s\n" "$1"; rc=1; }

    printf "versions:\n"
    for tool in pi claude node python3 jq zsh; do
      if command -v "$tool" >/dev/null 2>&1; then
        ver=$("$tool" --version 2>&1 | head -1 | awk '{for(i=1;i<=NF;i++) if ($i ~ /[0-9]/) { print $i; exit }}')
        ok "$tool ${ver:-(version unparsed)}"
      else
        fail "$tool: not on PATH"
      fi
    done

    printf "\n\$DOTFILES env:\n"
    if [[ -z "${DOTFILES:-}" ]]; then
      warn "\$DOTFILES not exported in this shell (zsh/core.zsh sets it; ok if you're in a non-zsh shell)"
    elif [[ "$DOTFILES" != "{{DOTFILES}}" ]]; then
      fail "\$DOTFILES=$DOTFILES but justfile_directory() is {{DOTFILES}} (moved checkout? re-source ~/.zshrc)"
    else
      ok "\$DOTFILES=$DOTFILES"
    fi

    printf "\nsymlinks:\n"
    log=$(mktemp)
    if bash {{DOTFILES}}/test/validate-manifest.sh > "$log" 2>&1; then
      n=$(grep -c '^  ✅' "$log" || true)
      ok "manifest validated ($n entries)"
    else
      tail -10 "$log" >&2
      fail "manifest validation failed (run 'just check' for full output)"
    fi
    rm -f "$log"

    printf "\nclaude plugins:\n"
    settings="$HOME/.claude/settings.json"
    installed="$HOME/.claude/plugins/installed_plugins.json"
    if [[ ! -f "$settings" ]]; then
      fail "$settings missing — run 'just link'"
    elif [[ ! -f "$installed" ]]; then
      warn "$installed missing — run 'just claude-plugins-install'"
    else
      while IFS= read -r plugin; do
        [[ -z "$plugin" ]] && continue
        if jq -e --arg p "$plugin" '.plugins[$p] // empty' "$installed" >/dev/null 2>&1; then
          ok "$plugin"
        else
          warn "$plugin enabled in settings.json but not in installed_plugins.json (run 'just claude-plugins-install')"
        fi
      done < <(jq -r '.enabledPlugins | to_entries[] | select(.value) | .key' "$settings")
    fi

    printf "\nnotion routing (cwd → auth file):\n"
    if ! command -v zsh >/dev/null 2>&1; then
      warn "zsh not on PATH — skipping (routing source is zsh-only)"
    else
      check_route() {
        local cwd="$1" expected="$2"
        local got
        got=$(zsh -c "source {{DOTFILES}}/zsh/pi-notion-routing.zsh && _pi_notion_auth_file '$cwd'" 2>/dev/null)
        local exp_label="${expected##*/}"
        [[ -z "$expected" ]] && exp_label="(unset)"
        local got_label="${got##*/}"
        [[ -z "$got" ]] && got_label="(unset)"
        if [[ "$got" == "$expected" ]]; then
          ok "$cwd → $exp_label"
        else
          fail "$cwd → got $got_label, expected $exp_label"
        fi
      }
      check_route "$HOME/code/personal/foo"         "$HOME/.pi/agent/notion-mcp-auth-personal.json"
      check_route "$HOME/code/work/volve-ai"        "$HOME/.pi/agent/notion-mcp-auth-volve.json"
      check_route "$HOME/code/personal/volve-notes" "$HOME/.pi/agent/notion-mcp-auth-personal.json"
      check_route "$HOME/tmp/random"                ""
    fi

    printf "\nlinear routing extension:\n"
    ext="$HOME/.pi/agent/extensions/linear-routing.ts"
    if [[ -L "$ext" && -e "$ext" ]]; then
      target=$(readlink "$ext")
      ok "linear-routing.ts → ${target#$HOME/}"
    else
      fail "$ext missing or broken (run 'just link')"
    fi

    printf "\n"
    if [[ $rc -eq 0 ]]; then
      printf "✅ doctor: all checks passed\n"
    else
      printf "❌ doctor: issues found above\n" >&2
    fi
    exit $rc

# For fast skill unit tests, use `just test-skills` / `just test-skill <name>`.
#
# Run full dotfiles install validation in Docker (mac + vm). Slow.
[group('test')]
test target="both":
    {{DOTFILES}}/test/verify.sh {{target}}

# Run unit tests for a single skill (expects `<skill>/tests/run.sh`).
[group('test')]
test-skill name:
    #!/usr/bin/env bash
    set -euo pipefail
    runner="{{DOTFILES}}/pi/agent/skills/{{name}}/tests/run.sh"
    if [[ ! -x "$runner" ]]; then
      echo "error: no test runner at $runner" >&2
      exit 1
    fi
    exec "$runner"

# Tolerates missing tests/ (most skills don't have any); fails overall if
# any skill's suite fails.
#
# Run unit tests across every skill that has a tests/run.sh.
[group('test')]
test-skills:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    ran=0
    for d in {{DOTFILES}}/pi/agent/skills/*/tests; do
      [[ -d "$d" ]] || continue
      runner="$d/run.sh"
      [[ -x "$runner" ]] || continue
      ran=$((ran + 1))
      skill_name=$(basename "$(dirname "$d")")
      echo "==== $skill_name ===="
      "$runner" || rc=$?
    done
    if [[ "$ran" -eq 0 ]]; then
      echo "no skill tests found"
    fi
    exit "$rc"

# --- Claude Code plugins ---

# `claude plugin install` is a no-op on already-installed plugins. Run on
# a fresh machine after `just link` to materialise the plugin set.
#
# Install every enabled plugin from ~/.claude/settings.json. Idempotent.
[group('claude')]
claude-plugins-install:
    #!/usr/bin/env bash
    set -euo pipefail
    settings="$HOME/.claude/settings.json"
    if [[ ! -f "$settings" ]]; then
      echo "error: $settings not found — run 'just link' first" >&2
      exit 1
    fi
    if ! command -v claude >/dev/null 2>&1; then
      echo "error: 'claude' CLI not on PATH — install Claude Code first" >&2
      exit 1
    fi
    plugins=$(python3 -c "
    import json, sys
    with open(sys.argv[1]) as f:
        data = json.load(f)
    for name, enabled in (data.get('enabledPlugins') or {}).items():
        if enabled:
            print(name)
    " "$settings")
    if [[ -z "$plugins" ]]; then
      echo "no enabled plugins in $settings"
      exit 0
    fi
    # Ensure the official marketplace is registered — `claude plugin install
    # <name>@claude-plugins-official` fails with "unknown marketplace" on a
    # fresh machine otherwise. Idempotent: a no-op if already known.
    echo "==== claude plugin marketplace add anthropics/claude-plugins-official ===="
    claude plugin marketplace add anthropics/claude-plugins-official 2>/dev/null || true
    rc=0
    while IFS= read -r plugin; do
      echo "==== claude plugin install $plugin ===="
      # `claude plugin install` may self-upgrade the claude binary on first run.
      # hash -r refreshes bash's command cache so subsequent iterations find it.
      hash -r 2>/dev/null || true
      claude plugin install "$plugin" || rc=$?
    done <<< "$plugins"
    exit "$rc"

# --- Edit configs ---

[group('edit')]
zsh:
    nvim ~/.zshrc && source ~/.zshrc

[group('edit')]
tmux:
    nvim ~/.tmux.conf && tmux source-file ~/.tmux.conf

[group('edit')]
nvim:
    nvim ~/.config/nvim/

[group('edit')]
starship:
    nvim ~/.config/starship.toml

[group('edit')]
git:
    nvim ~/.gitconfig

[macos]
[group('edit')]
ghostty:
    nvim "$HOME/Library/Application Support/com.mitchellh.ghostty/config"

# Scaffold a new custom global skill (authored locally, tracked in dotfiles)
[group('edit')]
new-skill name:
    #!/usr/bin/env bash
    set -euo pipefail
    name="{{name}}"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "error: invalid skill name '$name' (use a-zA-Z0-9_-)" >&2; exit 1; }
    dir="{{DOTFILES}}/pi/agent/skills/$name"
    if [[ -e "$dir" ]]; then
      echo "error: $dir already exists" >&2
      exit 1
    fi
    mkdir -p "$dir"
    cat > "$dir/SKILL.md" <<EOF
    ---
    name: $name
    description: TODO — what this skill does and when to use it.
    ---

    # $name

    TODO
    EOF
    echo "created $dir/SKILL.md"
    echo "next: fill in the description (link runs automatically on exit)"
    ${EDITOR:-nvim} "$dir/SKILL.md" || true
    just link

# Add a marketplace skill to pi/skill-lock.json + install.
#
# Fetches HEAD SHA (unless rev given), appends entry, runs `just link`.
# Use dry-run as 6th arg to preview without writing.
# Usage: just add-skill <url> <name> [subpath] [scope] [rev] [dry-run]
# Positional args:
#   url         upstream GitHub URL
#   name        skill identifier (a-z, 0-9, _-)
#   subpath     path to skill dir inside upstream (default: skills/<name>)
#   scope       "global" (default) or "project:<project-name>"
#   rev         explicit commit SHA (default: resolves HEAD)
#   dry-run     "dry-run" to preview without writing
# Examples:
#   just add-skill https://github.com/vercel-labs/skills find-skills
#   just add-skill https://github.com/neondatabase/agent-skills neon-postgres skills/neon-postgres project:volve-ai
#   just add-skill https://github.com/x/y my-skill skills/my-skill global '' dry-run
#
# Add a marketplace skill to pi/skill-lock.json + install. Dry-run as 6th arg previews.
[group('edit')]
add-skill url name subpath="" scope="global" rev="" dry_run="":
    #!/usr/bin/env bash
    set -euo pipefail
    name="{{name}}"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "error: invalid skill name '$name' (use a-zA-Z0-9_-)" >&2; exit 1; }
    url="{{url}}"
    subpath="{{subpath}}"
    scope="{{scope}}"
    dry_run="{{dry_run}}"
    [[ -z "$subpath" ]] && subpath="skills/$name"
    # Catch common footgun: subpath accidentally receiving a scope value
    if [[ "$subpath" == project:* || "$subpath" == "global" ]]; then
      echo "error: subpath looks like a scope value ('$subpath'). Order: url name [subpath] [scope]" >&2
      exit 1
    fi
    [[ "$scope" == "global" || "$scope" == project:* ]] || { echo "error: invalid scope '$scope' (use 'global' or 'project:<name>')" >&2; exit 1; }
    # skill-lock.json stores skillPath including trailing SKILL.md
    skill_path="${subpath%/SKILL.md}/SKILL.md"
    lock="{{DOTFILES}}/pi/skill-lock.json"
    # Resolve upstream HEAD SHA (unless overridden via --rev)
    rev="{{rev}}"
    if [[ -z "$rev" ]]; then
      echo "Resolving HEAD SHA of $url ..."
      rev=$(git ls-remote "$url" HEAD | awk '{print $1}') || { echo "error: git ls-remote failed for $url" >&2; exit 1; }
      [[ -z "$rev" ]] && { echo "error: no HEAD found at $url" >&2; exit 1; }
    fi
    echo "  rev: $rev"
    # Append entry via python + json (preserves structure)
    python3 - "$lock" "$name" "$url" "$skill_path" "$rev" "$scope" "$dry_run" <<'PYEOF'
    import json, sys, datetime
    lock_path, name, url, skill_path, rev, scope, dry_run = sys.argv[1:8]
    with open(lock_path) as f:
        data = json.load(f)
    if name in data.get("skills", {}):
        print(f"error: skill '{name}' already in lock file", file=sys.stderr)
        sys.exit(1)
    entry = {
        "source": url.replace("https://github.com/", "").replace(".git", ""),
        "sourceType": "github",
        "sourceUrl": url,
        "skillPath": skill_path,
        "skillFolderHash": rev,
    }
    if scope != "global":
        entry["scope"] = scope
    if dry_run == "dry-run":
        print("--- preview (dry-run, nothing written) ---")
        print(f'  "{name}": ' + json.dumps(entry, indent=2))
        sys.exit(0)
    data.setdefault("skills", {})[name] = entry
    with open(lock_path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"added '{name}' to {lock_path}")
    PYEOF
    if [[ "$dry_run" == "dry-run" ]]; then
      echo "(dry-run: skipping just link)"
      exit 0
    fi
    just link

# Bump a marketplace skill's pinned SHA to upstream HEAD, then re-install.
[group('edit')]
update-skill name:
    #!/usr/bin/env bash
    set -euo pipefail
    name="{{name}}"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "error: invalid skill name '$name'" >&2; exit 1; }
    lock="{{DOTFILES}}/pi/skill-lock.json"
    url=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); e=d.get('skills',{}).get(sys.argv[2]); print(e['sourceUrl'] if e else '')" "$lock" "$name")
    [[ -z "$url" ]] && { echo "error: '$name' not found in $lock" >&2; exit 1; }
    echo "Resolving HEAD SHA of $url ..."
    rev=$(git ls-remote "$url" HEAD | awk '{print $1}') || { echo "error: git ls-remote failed" >&2; exit 1; }
    [[ -z "$rev" ]] && { echo "error: no HEAD found at $url" >&2; exit 1; }
    old=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['skills'][sys.argv[2]].get('skillFolderHash',''))" "$lock" "$name")
    if [[ "$rev" == "$old" ]]; then
      echo "already at HEAD ($rev); nothing to do"
      exit 0
    fi
    echo "  $old -> $rev"
    python3 - "$lock" "$name" "$rev" <<'PYEOF'
    import json, sys
    lock_path, name, rev = sys.argv[1:4]
    with open(lock_path) as f:
        data = json.load(f)
    data["skills"][name]["skillFolderHash"] = rev
    with open(lock_path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    PYEOF
    # Clear cache so install.sh re-fetches at the new rev
    rm -rf "$HOME/.local/share/pi-skills/$name"
    just link

# Open an existing pi skill's SKILL.md in $EDITOR, regardless of cwd
[group('edit')]
edit-skill name:
    #!/usr/bin/env bash
    set -euo pipefail
    name="{{name}}"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "error: invalid skill name '$name' (use a-zA-Z0-9_-)" >&2; exit 1; }
    editor="${EDITOR:-nvim}"
    global="{{DOTFILES}}/pi/agent/skills/$name/SKILL.md"
    lock="{{DOTFILES}}/pi/skill-lock.json"
    if [[ -f "$global" ]]; then
      $editor "$global" || true
      just link
      exit 0
    fi
    proj=()
    while IFS= read -r line; do proj+=("$line"); done < <(find "{{DOTFILES}}/projects" -mindepth 4 -maxdepth 4 -path "*/skills/$name/SKILL.md" 2>/dev/null)
    if [[ ${#proj[@]} -eq 1 ]]; then
      $editor "${proj[0]}" || true
      just link
      exit 0
    elif [[ ${#proj[@]} -gt 1 ]]; then
      echo "error: skill '$name' exists in multiple projects:" >&2
      printf '  %s\n' "${proj[@]}" >&2
      exit 1
    fi
    if command -v jq &>/dev/null && jq -e --arg n "$name" '.skills[$n]' "$lock" >/dev/null 2>&1; then
      url=$(jq -r --arg n "$name" '.skills[$n].sourceUrl' "$lock")
      path=$(jq -r --arg n "$name" '.skills[$n].skillPath' "$lock")
      echo "'$name' is a marketplace skill tracked in skill-lock.json" >&2
      echo "  source: $url" >&2
      echo "  path:   $path" >&2
      echo "editing the installed copy would be overwritten on next \`just link\`" >&2
      echo "to fork: copy to dotfiles/pi/agent/skills/$name/ and remove from skill-lock.json" >&2
      exit 1
    fi
    echo "error: no skill named '$name' found in dotfiles" >&2
    exit 1
