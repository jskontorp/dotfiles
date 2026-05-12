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
  "$HOME/.config/just/justfile"
  "$HOME/.claude/statusline.sh"
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
# Bucketed into two distinct failure modes — same find, different remediation:
#   UNTRACKED (target exists) → raw ln in install.sh that should use _link/_linkd.
#   ORPHAN    (target missing) → cruft from a deleted file or decommissioned
#     project (e.g. commit 6afb180 removed projects/valuesync_os/ but left the
#     work-tree symlinks behind; install.sh only links forward, never cleans up).
#     install.sh / uninstall.sh have no handle on these — they live outside
#     the manifest. Remediation: rm the symlink.
# Use `find -lname` to push the target match into find itself — avoids
# spawning a readlink subshell per symlink (~3900 in $HOME on a populated
# host, costs ~7s; pre-filter drops it to ~250ms). `-lname` matches the
# literal target text whether or not it resolves, so broken symlinks are
# caught here too.
untracked=0
orphans=0
while IFS= read -r link; do
  # Skip if already in the manifest.
  grep -qxF "$link" "$MANIFEST" && continue
  target=$(readlink "$link" 2>/dev/null || true)
  if [[ -e "$link" ]]; then
    printf "  ⚠️  UNTRACKED: %s → %s\n" "${link#"$HOME"/}" "${target#"$HOME"/}"
    untracked=$((untracked + 1))
  else
    printf "  ⚠️  ORPHAN:    %s → %s (target missing)\n" "${link#"$HOME"/}" "${target#"$HOME"/}"
    orphans=$((orphans + 1))
  fi
done < <(find "$HOME" -maxdepth 5 -type l -lname "$REPO_DIR/*" -not -path "$REPO_DIR/*" 2>/dev/null)

if [[ $untracked -gt 0 ]]; then
  printf "  ❌ %d symlink(s) bypass the manifest (use _link/_linkd in install.sh)\n" "$untracked"
  errors=$((errors + 1))
fi
if [[ $orphans -gt 0 ]]; then
  printf "  ❌ %d orphan symlink(s) point at deleted repo paths (rm them; install.sh does not clean up)\n" "$orphans"
  errors=$((errors + 1))
fi

# ~/.claude/CLAUDE.md is generated (sed-substituted with $DOTFILES) rather
# than symlinked, so it falls outside the manifest's symlink check. Validate
# it explicitly: file present, contains the @-import to this checkout's
# AGENTS.md. Catches the moved-checkout regression where a stale CLAUDE.md
# from a previous $DOTFILES path keeps pointing at a vanished location.
claude_md="$HOME/.claude/CLAUDE.md"
expected_import="@$REPO_DIR/pi/agent/AGENTS.md"
if [[ ! -f "$claude_md" ]]; then
  printf "  ❌ MISSING: ~/.claude/CLAUDE.md (run install.sh)\n"
  errors=$((errors + 1))
elif ! grep -qF "$expected_import" "$claude_md"; then
  printf "  ❌ STALE: ~/.claude/CLAUDE.md does not @-import %s (re-run install.sh)\n" "$expected_import"
  errors=$((errors + 1))
else
  printf "  ✅ ~/.claude/CLAUDE.md imports %s\n" "${expected_import#@}"
fi

printf "\n  %d symlinks verified" "$count"
[[ $untracked -eq 0 && $orphans -eq 0 ]] && printf ", no untracked or orphans"
printf "\n"

exit $errors
