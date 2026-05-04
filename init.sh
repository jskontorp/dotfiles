#!/bin/bash
# One-liner entry point for a fresh machine:
#   bash <(curl -fsSL https://raw.githubusercontent.com/jskontorp/dotfiles/main/init.sh)
#
# Works for both public and private repos. If the unauthenticated clone fails,
# prompts for a GitHub personal access token.
set -euo pipefail

REPO="jskontorp/dotfiles"
DEST="$HOME/code/personal/dotfiles"

if [[ -d "$DEST" ]]; then
  echo "$DEST already exists. To update:"
  echo "  cd $DEST && git pull && just link"
  exit 1
fi

mkdir -p "$(dirname "$DEST")"

# Ensure git is available.
# On macOS, /usr/bin/git is a stub that triggers the CLT installer GUI on first
# invocation — `command -v git` returns true even when nothing is installed.
# Check `xcode-select -p` as the source of truth.
case "$(uname -s)" in
  Darwin)
    if ! xcode-select -p &>/dev/null; then
      echo "⚠️  Xcode Command Line Tools are required (provides git, clang, make)."
      echo "   The installer GUI will open in a moment. This download is ~1.5 GB"
      echo "   and can take 10–30 minutes — it may look stuck; let it finish."
      echo ""
      xcode-select --install || true
      echo ""
      echo "Re-run this command once the GUI installer reports completion:"
      echo "  bash <(curl -fsSL https://raw.githubusercontent.com/${REPO}/main/init.sh)"
      exit 0
    fi
    ;;
  Linux)
    if ! command -v git &>/dev/null; then
      sudo apt-get update -qq && sudo apt-get install -y -qq git
    fi
    ;;
esac

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
