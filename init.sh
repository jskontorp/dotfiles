#!/bin/bash
# One-liner entry point for a fresh machine:
#   bash <(curl -fsSL https://raw.githubusercontent.com/jskontorp/dotfiles/main/init.sh)
#
# Works for both public and private repos. If the unauthenticated clone fails,
# prompts for a GitHub personal access token.
set -euo pipefail

REPO="jskontorp/dotfiles"
DEST="$HOME/dotfiles"

if [[ -d "$DEST" ]]; then
  echo "$HOME/dotfiles already exists. To update:"
  echo "  cd ~/dotfiles && git pull && just link"
  exit 1
fi

# Ensure git is available
if ! command -v git &>/dev/null; then
  case "$(uname -s)" in
    Darwin)
      echo "Installing Xcode Command Line Tools (provides git)..."
      xcode-select --install
      echo "Re-run this command after installation completes."
      exit 0
      ;;
    Linux)
      sudo apt-get update -qq && sudo apt-get install -y -qq git
      ;;
  esac
fi

# Try unauthenticated clone first; fall back to token auth for private repos
if ! git clone "https://github.com/${REPO}.git" "$DEST" 2>/dev/null; then
  echo ""
  echo "Clone failed — repo may be private."
  echo "Create a token at: https://github.com/settings/personal-access-tokens/new"
  echo "  → Repository access: Only select repositories → $REPO"
  echo "  → Permissions: Contents → Read-only"
  echo ""
  read -rsp "🔑 Paste your GitHub token (hidden): " GH_TOKEN
  echo ""

  [[ -z "$GH_TOKEN" ]] && { echo "No token provided."; exit 1; }

  git clone "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" "$DEST"

  # Strip the token from the remote URL — gh auth login handles auth going forward
  git -C "$DEST" remote set-url origin "https://github.com/${REPO}.git"
fi

case "$(uname -s)" in
  Darwin) exec "$DEST/machine/mac/bootstrap.sh" ;;
  Linux)  exec "$DEST/machine/vm/bootstrap.sh" ;;
  *)      echo "Unsupported OS: $(uname -s)"; exit 1 ;;
esac
