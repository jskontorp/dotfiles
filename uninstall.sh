#!/bin/bash
# Reverse install.sh: remove every symlink recorded in .install-manifest.
# Idempotent. No backups, no package removal — see footer for things this
# does NOT touch.
#
# The manifest is the contract: if a path appears in .install-manifest,
# install.sh wrote a symlink there via _link/_linkd, and uninstall.sh
# removes that symlink. Targets are NOT inspected — install.sh
# legitimately points symlinks outside $DOTFILES (e.g. marketplace
# skills under ~/.local/share/pi-skills/), and a target-prefix guard
# would skip them. The one skip-branch is "the path is no longer a
# symlink" (state drift — preserves user content).
#
# Manifest grammar (mirrors install.sh): one absolute path per line, no
# blanks, no comments, no escaping. Enforced by _link/_linkd which
# append a single `echo "$dest" >> $INSTALL_MANIFEST` per call.
#
# Exit codes: 0 on the happy path and on the no-manifest no-op. Non-zero
# only if `rm` fails on a manifest entry (set -e abort, manifest left
# behind for a re-run to pick up the survivors). State-drift skips
# warn on stderr without affecting the exit code.
#
# Usage: ./uninstall.sh
set -euo pipefail

DOTFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_MANIFEST="$DOTFILES/.install-manifest"

# Migration / idempotence: hosts that ran an install.sh predating the
# manifest, or those that already uninstalled (we delete the manifest as
# the last step), have no manifest. No-op success.
if [[ ! -f "$INSTALL_MANIFEST" ]]; then
  echo "uninstall.sh: no manifest at $INSTALL_MANIFEST — nothing to do."
  exit 0
fi

removed=0
skipped_not_symlink=0

# Manifest-as-contract: if a path is in .install-manifest, install.sh put a
# symlink there, and we own removal of that path. We do NOT inspect the
# target — install.sh legitimately creates symlinks pointing outside
# $DOTFILES (e.g. marketplace skills under ~/.local/share/pi-skills/),
# and a target-prefix guard would skip them. The state-drift branch
# ("not a symlink") still applies: if the user replaced one of our
# symlinks with a real file post-install, we won't `rm` their content.
while IFS= read -r path || [[ -n "$path" ]]; do
  # Defensive: handle a trailing newline-less last line, where the
  # `|| [[ -n "$path" ]]` clause runs the body once with empty $path.
  [[ -z "$path" ]] && continue

  if [[ ! -L "$path" ]]; then
    if [[ -e "$path" ]]; then
      printf "  ⚠ skip %s (not a symlink — state drift)\n" "$path" >&2
      skipped_not_symlink=$((skipped_not_symlink + 1))
    fi
    # Path absent entirely: silent — already gone, idempotent on re-runs.
    continue
  fi

  # Symlink at a manifest-recorded path: ours by construction. Remove it
  # whether or not its target currently resolves (handles dangling links
  # without realpath portability divergence) and regardless of where the
  # target points (handles marketplace-skill symlinks correctly).
  rm "$path"
  removed=$((removed + 1))
done < "$INSTALL_MANIFEST"

# Delete the manifest (matches install.sh's `: > "$INSTALL_MANIFEST"` at
# the top of every run — re-running install.sh recreates it). Removing
# rather than truncating means a second uninstall.sh hits the no-manifest
# branch above and exits cleanly.
rm -f "$INSTALL_MANIFEST"

# --- Summary ---
printf "\n"
printf "Removed: %d symlinks.\n" "$removed"
if (( skipped_not_symlink > 0 )); then
  printf "Skipped: %d state-drift (not a symlink, preserved).\n" \
    "$skipped_not_symlink"
fi

# --- Footer: things uninstall does NOT touch ---
# Quoted heredoc — the `just …` line below uses backticks which would
# otherwise be interpreted as command substitution.
cat <<'EOF'

Not touched (clean up manually if you also want these gone, or run
  `just uninstall-full --yes` on Mac for the nuclear option):

  Real files written by install.sh (intentionally outside the manifest):
    ~/.pi/agent/settings.json   # pi runtime state (lastChangelogVersion, etc.)
    ~/.claude/CLAUDE.md         # generated, contains absolute path to this checkout

  User-authored files install.sh never created:
    ~/.gitconfig.local   # git identity from bootstrap.sh
    ~/.zshrc.local       # local shell overrides

  Other dotfiles-installed artefacts (out of scope for uninstall):
EOF

if [[ "$(uname -s)" == "Darwin" ]]; then
  cat <<'EOF'
    ~/.tmux/plugins/        # tmux plugin manager + plugins (from bootstrap.sh + just update)
    ~/.claude/plugins/      # Claude Code marketplace (from `just claude-plugins-install`)
    ~/Library/LaunchAgents/com.volve.*.plist
                            # launchd jobs materialised by install.sh (real files,
                            # not symlinks → not in manifest). To fully decommission:
                            #   launchctl bootout gui/$(id -u)/com.volve.memory-sync
                            #   rm ~/Library/LaunchAgents/com.volve.memory-sync.plist
    ~/Library/pnpm/         # pnpm runtime + global packages
    Global pnpm packages: pnpm rm -g @anthropic-ai/claude-code @mariozechner/pi-coding-agent pyright typescript
    Brewfile packages:    brew bundle --file=machine/mac/Brewfile cleanup --force
EOF
else
  cat <<'EOF'
    ~/.tmux/plugins/                   # tmux plugin manager + plugins
    ~/.claude/plugins/                 # Claude Code marketplace (from `just claude-plugins-install`)
    ~/.local/share/zsh/plugins/        # zsh-autosuggestions, zsh-syntax-highlighting
    ~/.local/share/fnm/                # fnm + node toolchain
    ~/.local/share/pnpm/               # pnpm runtime + global packages
    ~/.local/bin/{zoxide,starship,just,uv}    # user-local binaries from just update
    /usr/local/bin/{nvim,bat,eza,delta,lazygit,tmux,fd,batcat}
                                       # sudo-installed binaries from just update
    /opt/nvim/                         # nvim payload (sudo)
    Global pnpm packages: pnpm rm -g @anthropic-ai/claude-code @mariozechner/pi-coding-agent pyright typescript
    apt packages: see machine/vm/update — common system tools, recommend keeping
EOF
fi

printf "\n✅ Done.\n"
