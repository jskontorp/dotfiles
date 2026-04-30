#!/bin/bash
# Validate that every entry in .install-manifest is a working symlink.
# Also detects symlinks pointing into the dotfiles repo that bypassed the
# manifest (raw ln calls that should use _link/_linkd).
#
# Usage: bash test/validate-manifest.sh
#
# Resolves the repo root from the script's own location, so it runs both
# inside the Docker test (~/dotfiles) and on a host where the repo lives
# elsewhere (e.g. ~/code/personal/dotfiles).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_DIR/.install-manifest"

if [[ ! -f "$MANIFEST" ]]; then
  printf "  ❌ no manifest at %s\n" "$MANIFEST" >&2
  exit 1
fi

errors=0
count=0

while IFS= read -r dest; do
  [[ -z "$dest" ]] && continue
  count=$((count + 1))
  label="${dest#"$HOME"/}"
  if [[ ! -L "$dest" ]]; then
    printf "  ❌ NOT A SYMLINK: %s\n" "$label"
    errors=$((errors + 1))
  elif [[ ! -e "$dest" ]]; then
    printf "  ❌ BROKEN TARGET: %s\n" "$label"
    errors=$((errors + 1))
  else
    printf "  ✅ %s\n" "$label"
  fi
done < "$MANIFEST"

# --- Expected critical paths (guards against accidental removal) ---
# If a _link/_linkd call is dropped from install.sh, the manifest won't
# contain it and this section catches the regression.
EXPECTED=(
  "$HOME/.gitconfig"
  "$HOME/.config/nvim"
  "$HOME/.pi/agent/AGENTS.md"
  "$HOME/.pi/agent/skills/commit"
  "$HOME/.zshrc"
  "$HOME/.tmux.shared.conf"
  "$HOME/.tmux.conf"
  "$HOME/.config/starship.toml"
)

for path in "${EXPECTED[@]}"; do
  label="${path#"$HOME"/}"
  if grep -qxF "$path" "$MANIFEST"; then
    printf "  ✅ expected: %s\n" "$label"
  else
    printf "  ❌ MISSING FROM MANIFEST: %s\n" "$label"
    errors=$((errors + 1))
  fi
done

# Find symlinks pointing into the dotfiles repo that bypassed the manifest.
# These indicate a raw ln in install.sh that should use _link/_linkd.
# Use `find -lname` to push the target match into find itself — avoids
# spawning a readlink subshell per symlink (~3900 in $HOME on a populated
# host, costs ~7s; pre-filter drops it to ~250ms).
orphans=0
while IFS= read -r link; do
  # Check if it's in the manifest
  if ! grep -qxF "$link" "$MANIFEST"; then
    target=$(readlink "$link" 2>/dev/null || true)
    printf "  ⚠️  UNTRACKED: %s → %s\n" "${link#"$HOME"/}" "${target#"$HOME"/}"
    orphans=$((orphans + 1))
  fi
done < <(find "$HOME" -maxdepth 5 -type l -lname "$REPO_DIR/*" -not -path "$REPO_DIR/*" 2>/dev/null)

if [[ $orphans -gt 0 ]]; then
  printf "  ❌ %d symlink(s) bypass the manifest (use _link/_linkd in install.sh)\n" "$orphans"
  errors=$((errors + 1))
fi

printf "\n  %d symlinks verified" "$count"
[[ $orphans -eq 0 ]] && printf ", no untracked"
printf "\n"

exit $errors
