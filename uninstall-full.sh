#!/bin/bash
# Nuclear uninstall: reverse install.sh AND tear down every adjacent
# bootstrap artefact this Mac picked up — Homebrew packages, plugin
# caches, runtime state, pi/Claude credentials.
#
# Scope (in order):
#   1. ./uninstall.sh                          (73 manifest symlinks)
#   2. brew bundle cleanup --force             (Brewfile formulae + casks)
#   3. pnpm rm -g <known dotfiles globals>     (best effort)
#   4. rm -rf documented runtime / cache dirs  (see PURGE_PATHS below)
#
# Preserves (intentional — see footer):
#   ~/.gitconfig.local        — git identity from bootstrap
#   ~/.zsh_history            — shell history
#   $DOTFILES (the checkout)  — this script lives there; deleting it would
#                               saw the branch we're sitting on. Manual
#                               `rm -rf $DOTFILES` if you want it gone.
#
# Not handled here:
#   - Linux/VM bootstrap (apt packages, ~/.local/bin/{just,uv,...},
#     /opt/nvim, etc.). Add a `Linux)` branch if/when needed.
#   - Tooling installed outside Brewfile (manual `brew install foo`,
#     `npm install -g`, etc.). User's responsibility.
#
# Confirmation gate: refuses to run without `--yes` or
# UNINSTALL_FULL_CONFIRM=YES. There is no interactive prompt — explicit
# opt-in via flag/env makes this safe to invoke from a justfile recipe
# without TTY assumptions.
#
# Idempotent: every step is `|| true`-equivalent. Re-running after a
# partial run completes the rest. Missing tools (brew, pnpm) are
# skipped, not errored.
#
# Exit codes: 0 on completion (including partial — caller already
# opted in). Non-zero only if confirmation is missing or platform
# is unsupported.
#
# Usage:
#   ./uninstall-full.sh --yes
#   UNINSTALL_FULL_CONFIRM=YES ./uninstall-full.sh
#   just uninstall-full --yes
set -uo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Confirmation gate ------------------------------------------------
if [[ "${1:-}" != "--yes" && "${UNINSTALL_FULL_CONFIRM:-}" != "YES" ]]; then
  cat <<EOF >&2
uninstall-full.sh: refusing to run without explicit confirmation.

This will:
  • remove all dotfiles symlinks (./uninstall.sh)
  • uninstall every formula and cask listed in machine/mac/Brewfile
    (22 CLI tools + ghostty + orbstack); manual brew installs are kept
  • remove pnpm globals: @anthropic-ai/claude-code,
    @earendil-works/pi-coding-agent,
    @mariozechner/pi-coding-agent, pyright, typescript
  • delete plugin/cache/runtime dirs under ~/.tmux, ~/.claude,
    ~/.local/share, ~/Library/pnpm, ~/.orbstack,
    ~/Library/Containers/dev.kdrag0n.MacVirt
  • delete pi credentials and sessions:
    ~/.pi/agent/{settings.json,auth.json,sessions}

Preserves ~/.gitconfig.local, ~/.zsh_history, the dotfiles checkout.

Re-run with:  ./uninstall-full.sh --yes
         or:  UNINSTALL_FULL_CONFIRM=YES ./uninstall-full.sh
EOF
  exit 2
fi

# --- Platform gate ----------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "uninstall-full.sh: Mac-only for now (uname=$(uname -s))." >&2
  echo "On Linux, run ./uninstall.sh and clean up by hand — the VM" >&2
  echo "bootstrap doesn't have a tracked package list to undo against." >&2
  exit 3
fi

step() { printf "\n──── %s ────\n" "$1"; }

# --- 1. Manifest-tracked symlinks ------------------------------------
step "1/4  Removing manifest symlinks (./uninstall.sh)"
"$DOTFILES/uninstall.sh" || true

# --- 2. Homebrew bundle cleanup --------------------------------------
step "2/4  Uninstalling Brewfile packages (brew uninstall)"
if command -v brew >/dev/null 2>&1; then
  # Uninstall only what the dotfiles Brewfile tracks — manually installed
  # formulae outside the Brewfile are the user's, not ours to remove.
  # `brew bundle cleanup --force` does the inverse (removes everything
  # NOT in the file), which would over-reach on a daily-driver Mac.
  BREWFILE="$DOTFILES/machine/mac/Brewfile"
  formulae=$(brew bundle list --formula --file="$BREWFILE" 2>/dev/null | grep -v '^✔︎' || true)
  casks=$(brew bundle list --cask --file="$BREWFILE" 2>/dev/null | grep -v '^✔︎' || true)
  if [ -n "$formulae" ]; then
    # shellcheck disable=SC2086
    brew uninstall --formula --ignore-dependencies $formulae 2>/dev/null || true
  fi
  if [ -n "$casks" ]; then
    # shellcheck disable=SC2086
    brew uninstall --cask $casks 2>/dev/null || true
  fi
else
  echo "  brew not found — skipping"
fi

# --- 3. pnpm globals --------------------------------------------------
step "3/4  Removing pnpm globals"
if command -v pnpm >/dev/null 2>&1; then
  # Known globals from machine/mac/update; -g may error on already-
  # gone packages on some pnpm versions, hence || true.
  pnpm rm -g \
    @anthropic-ai/claude-code \
    @earendil-works/pi-coding-agent \
    @mariozechner/pi-coding-agent \
    pyright \
    typescript 2>/dev/null || true
else
  echo "  pnpm not found — skipping"
fi

# --- 4. Runtime / cache / credential dirs -----------------------------
step "4/4  Removing runtime/cache/credential dirs"
PURGE_PATHS=(
  # tmux plugin manager + plugins (tpm + 5)
  "$HOME/.tmux/plugins"

  # Claude Code generated + plugin state
  "$HOME/.claude/plugins"
  "$HOME/.claude/cache"
  "$HOME/.claude/backups"
  "$HOME/.claude/policy-limits.json"
  "$HOME/.claude/.update.lock"
  "$HOME/.claude/mcp-needs-auth-cache.json"
  "$HOME/.claude/CLAUDE.md"

  # Local-share runtime (delta themes, nvim plugin/parser cache,
  # marketplace skills installed by skill-lock.json, tmux plugin data)
  "$HOME/.local/share/delta"
  "$HOME/.local/share/nvim"
  "$HOME/.local/share/pi-skills"
  "$HOME/.local/share/tmux"

  # pnpm runtime (after brew uninstall removed the binary)
  "$HOME/Library/pnpm"

  # OrbStack runtime + VM container
  "$HOME/.orbstack"
  "$HOME/Library/Containers/dev.kdrag0n.MacVirt"

  # pi state (settings, credentials, session transcripts)
  "$HOME/.pi/agent/settings.json"
  "$HOME/.pi/agent/auth.json"
  "$HOME/.pi/agent/sessions"
)

removed=0
for p in "${PURGE_PATHS[@]}"; do
  if [[ -e "$p" || -L "$p" ]]; then
    rm -rf "$p"
    printf "  ✓ %s\n" "$p"
    removed=$((removed + 1))
  fi
done
printf "  (%d paths removed, %d already absent)\n" \
  "$removed" "$(( ${#PURGE_PATHS[@]} - removed ))"

# --- Footer -----------------------------------------------------------
cat <<EOF

✅ Nuclear uninstall complete.

Preserved (delete manually if you also want these gone):
  ~/.gitconfig.local       — git identity from bootstrap.sh
  ~/.zsh_history           — shell history
  $DOTFILES
                           — the dotfiles checkout itself

Brewfile taps, manually installed formulae outside the Brewfile, and
brew dependencies pulled in transitively were not touched. Verify with:
  brew list && brew tap

To re-bootstrap from scratch:
  cd $DOTFILES && ./install.sh
EOF
