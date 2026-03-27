#!/bin/bash
# Remote bootstrap — curl this to set up a fresh VM.
# Prompts for a GitHub token, clones the private repo, and runs bootstrap.sh.
#
# Usage:
#   curl -fsSL https://gist.githubusercontent.com/<you>/<id>/raw/setup.sh | bash
set -euo pipefail

REPO="jskontorp/dotfiles"
DEST="$HOME/dotfiles"

echo ""
echo "🖥️  dotfiles — remote bootstrap"
echo ""

# --- Pre-flight ---
if [[ -d "$DEST" ]]; then
  echo "❌ $DEST already exists. Remove it first or run ./bootstrap.sh directly."
  exit 1
fi

# --- GitHub token ---
echo "This repo is private. You need a GitHub personal access token with"
echo "read-only access to $REPO."
echo ""
echo "Create one at: https://github.com/settings/personal-access-tokens/new"
echo "  → Repository access: Only select repositories → $REPO"
echo "  → Permissions: Contents → Read-only"
echo "  → Expiration: 7 days (you only need it once)"
echo ""
read -rsp "🔑 Paste your GitHub token (hidden): " GH_TOKEN
echo ""

if [[ -z "$GH_TOKEN" ]]; then
  echo "❌ No token provided."
  exit 1
fi

# --- Validate token ---
echo ""
echo "🔍 Validating token..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/$REPO")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "❌ Token rejected (HTTP $HTTP_CODE). Check the token has Contents read access to $REPO."
  exit 1
fi
echo "   ✅ Token valid"

# --- Ensure git is available ---
if ! command -v git &>/dev/null; then
  echo ""
  echo "📦 Installing git..."
  sudo apt-get update -qq && sudo apt-get install -y -qq git
fi

# --- Clone ---
echo ""
echo "📥 Cloning $REPO..."
git clone "https://x-access-token:${GH_TOKEN}@github.com/${REPO}.git" "$DEST"

# Strip the token from the remote URL so it's not stored on disk.
# After bootstrap, `gh auth login` handles authentication.
git -C "$DEST" remote set-url origin "https://github.com/${REPO}.git"

# --- Run bootstrap ---
echo ""
cd "$DEST"
exec ./machine/vm/bootstrap.sh
