# dotfiles — unified config for macOS and Linux

default:
    @just --list

DOTFILES := justfile_directory()
MAC      := DOTFILES / "machine/mac"
VM       := DOTFILES / "machine/vm"

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
      ripgrep fd-find \
      build-essential
    sudo apt-get autoremove -y -qq
    sudo ln -sf "$(which fdfind)" /usr/local/bin/fd 2>/dev/null || true

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
    export PNPM_HOME="$HOME/.local/share/pnpm"
    export PATH="$PNPM_HOME:$PATH"
    curl -fsSL https://get.pnpm.io/install.sh | SHELL=/bin/bash sh -
    echo "📦 global pnpm packages..."
    pnpm add -g @anthropic-ai/claude-code @mariozechner/pi-coding-agent

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

[linux]
status:
    #!/usr/bin/env bash
    export PATH="$HOME/.local/bin:$HOME/.local/share/fnm:$HOME/.local/share/pnpm:$PATH"
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
    printf "%-12s %s\n" "fnm"      "$(fnm --version 2>/dev/null | awk '{print $2}' || echo 'missing')"
    printf "%-12s %s\n" "just"     "$(just --version 2>/dev/null | awk '{print $2}' || echo 'missing')"
    printf "%-12s %s\n" "docker"   "$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo 'missing')"
    printf "%-12s %s\n" "pi"       "$(pi --version 2>/dev/null | awk '{print $NF}' || echo 'missing')"
    printf "%-12s %s\n" "claude"   "$(claude --version 2>/dev/null | awk '{print $1}' || echo 'missing')"

# --- Management ---

# Symlink all configs
link:
    {{DOTFILES}}/install.sh

# Run install validation in Docker
test target="both":
    {{DOTFILES}}/test/verify.sh {{target}}

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
