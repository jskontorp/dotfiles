#!/bin/bash
# Bootstrap a fresh Ubuntu (aarch64) dev box from scratch.
# Usage: git clone ... ~/code/personal/dotfiles && cd ~/code/personal/dotfiles && ./machine/vm/bootstrap.sh
#
# One-time OS setup (swap, SSH, firewall, shell plugins), then delegates all
# tool installation to `just update` — the single source of truth for tools.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOTFILES="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "🚀 Bootstrapping dev environment..."

# --- Ensure local bin dir exists and is on PATH ---
mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"

# --- System packages ---
sudo apt-get update -qq
sudo apt-get install -y -qq \
  zsh git gh curl wget unzip jq fzf \
  ripgrep fd-find bat \
  fail2ban \
  build-essential

sudo ln -sf "$(which fdfind)" /usr/local/bin/fd 2>/dev/null || true
sudo ln -sf "$(which batcat)" /usr/local/bin/bat 2>/dev/null || true

# --- Swap (4GB, skip if exists) ---
if ! swapon --show | grep -q swapfile; then
  echo "📦 Creating 4GB swap..."
  sudo fallocate -l 4G /swapfile
  sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
  grep -q swapfile /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
fi

# --- Zsh plugins ---
ZSH_PLUGINS="$HOME/.local/share/zsh/plugins"
mkdir -p "$ZSH_PLUGINS"
[[ -d "$ZSH_PLUGINS/zsh-autosuggestions" ]] || \
  git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$ZSH_PLUGINS/zsh-autosuggestions"
[[ -d "$ZSH_PLUGINS/zsh-syntax-highlighting" ]] || \
  git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH_PLUGINS/zsh-syntax-highlighting"

# --- Install just (needed to run `just update`) ---
if ! command -v just &>/dev/null; then
  echo "📦 Installing just..."
  curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to "$HOME/.local/bin"
fi

# --- TPM (must exist before `just update` runs tmux plugin install) ---
[[ -d "$HOME/.tmux/plugins/tpm" ]] || \
  git clone --depth=1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
ln -sf "$DOTFILES/shared/tmux.conf" ~/.tmux.shared.conf
ln -sf "$SCRIPT_DIR/tmux.conf" ~/.tmux.conf

# --- Install all tools via just update ---
just -f "$DOTFILES/justfile" update

# --- Tailscale ---
if ! command -v tailscale &>/dev/null; then
  echo "📦 Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# --- SSH hardening ---
echo "🔒 Hardening SSH..."
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl reload sshd

# --- UFW (initial — public SSH so we don't lose access before Tailscale) ---
echo "🔒 Configuring firewall..."
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment "SSH (temporary, tightened after Tailscale)"
sudo ufw allow 41641/udp comment "Tailscale direct"
echo "y" | sudo ufw enable

# --- fail2ban ---
sudo systemctl enable --now fail2ban

# --- Configure & link dotfiles ---
source "$DOTFILES/install.sh"

# --- Set default shell ---
if [[ "$SHELL" != */zsh ]]; then
  sudo chsh -s "$(which zsh)" "$USER"
fi

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
echo "  2. sudo tailscale up"
echo "  3. Verify Tailscale: tailscale status"
echo "  4. Lock SSH to Tailscale only:"
echo "       sudo ufw delete allow 22/tcp"
echo "       sudo ufw allow in on tailscale0 to any port 22 proto tcp comment 'SSH via Tailscale'"
echo "       sudo ufw reload"
echo "  5. Tighten Oracle Cloud security list (see README)"
echo "  6. Open nvim to let LazyVim install plugins"
echo "  7. Log out and back in for zsh"
