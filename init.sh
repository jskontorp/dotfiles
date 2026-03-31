#!/bin/bash
# One-liner entry point for a fresh machine:
#   bash <(curl -fsSL https://raw.githubusercontent.com/jskontorp/dotfiles/main/init.sh)
set -euo pipefail

DEST="$HOME/dotfiles"

if [[ -d "$DEST" ]]; then
  echo "~/dotfiles already exists. To update:"
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

git clone https://github.com/jskontorp/dotfiles.git "$DEST"

case "$(uname -s)" in
  Darwin) exec "$DEST/machine/mac/bootstrap.sh" ;;
  Linux)  exec "$DEST/machine/vm/bootstrap.sh" ;;
  *)      echo "Unsupported OS: $(uname -s)"; exit 1 ;;
esac
