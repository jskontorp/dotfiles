# Global justfile — invoked via `gust <recipe>` from anywhere.
# Symlinked to ~/.config/just/justfile by install.sh.
# Recipes run in $HOME (see `gust` alias in zsh/core.zsh). Use
# {{invocation_directory()}} inside a recipe if it needs the caller's cwd.

set shell := ["bash", "-uc"]

# Canonical dotfiles path — resolved from this justfile's symlink target so
# `gust link` / `check` / `skills` work regardless of where dotfiles is
# checked out on the host (mac vs vm).
DOTFILES := `dirname "$(dirname "$(realpath ~/.config/just/justfile)")"`

# List available recipes (default).
default:
    @just --justfile {{justfile()}} --list

# Attach to the oracle `odev` tmux session — locally on oracle, via ssh from mac.
odev:
    @if [[ "$(uname -s)" == "Linux" ]]; then tmux a -t odev; else ssh -t oracle tmux attach -t odev; fi

# Attach to the mac `dev` tmux session — only meaningful on mac.
dev:
    @[[ "$(uname -s)" == "Darwin" ]] || { echo "'dev' is the mac session; use 'gust odev' on linux" >&2; exit 1; }
    @tmux a -t dev

# --- Defaults ------------------------------------------------------------

# Re-run dotfiles install (idempotent).
link:
    cd {{DOTFILES}} && ./install.sh

# Run the dotfiles host-side check suite.
check:
    cd {{DOTFILES}} && just check

# Show the unified skills inventory.
skills:
    cd {{DOTFILES}} && just skills

# Update brew + pnpm globals (mac).
update:
    brew update && brew upgrade && brew cleanup
    pnpm self-update
    pnpm -g update

# --- Networking / peers ---

[doc("Send <path> to $PEER_HOST (rsync over SSH). Mirrors paths under $HOME → ~/… on peer.")]
[positional-arguments]
push path destination='':
    #!/usr/bin/env bash
    # Default destination mirrors the local path: paths under $HOME map to
    # ~/… on the peer (remote shell expands ~ for that user's home, so
    # different remote usernames are fine). Paths outside $HOME require an
    # explicit destination — we don't silently target absolute remote paths.
    #
    # Trailing slash on <path> keeps rsync's "contents of dir" semantics.
    # `.git` is always excluded; honours a local .gitignore if present.
    # Set DRY_RUN=1 to preview without transferring.
    #
    # Prereq: rsync ≥ 3.0 (the Brewfile installs GNU rsync on mac; the VM's
    # apt rsync is 3.2+). Peer must be reachable as `ssh "$PEER_HOST"` with
    # this machine's pubkey in the peer's ~/.ssh/authorized_keys.
    set -euo pipefail
    cd {{quote(invocation_directory())}}
    : "${PEER_HOST:?set PEER_HOST in zshrc (mac→oracle, vm→<mac tailscale name>)}"

    src="$1"
    dst="${2:-}"
    home="${HOME%/}"

    # Reject option-shaped args. The `--` separator on the rsync line below
    # protects against rsync flag-parsing, but a literal leading dash still
    # confuses error output — fail early with a hint.
    case "$src" in -*) echo "push: src may not start with '-' (try ./$src)" >&2; exit 2 ;; esac
    case "$dst" in -*) echo "push: destination may not start with '-'" >&2; exit 2 ;; esac

    [ -e "$src" ] || [ -L "$src" ] || { echo "push: no such path: $src" >&2; exit 1; }

    # Normalise trailing slashes: capture intent, collapse 1+ trailing slashes
    # to a single canonical one. POSIX `${var%/}` strips one; loop for runs.
    case "$src" in */) trail="/" ;; *) trail="" ;; esac
    while [ "$src" != "${src%/}" ]; do src="${src%/}"; done
    [ -n "$trail" ] && src="$src/"

    if [ -z "$dst" ]; then
      abs="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")$trail"
      case "$abs" in
        "$home"/*) dst="${abs#"$home"/}" ;;  # relative to remote $HOME (rsync host:relpath semantics)
        "$home")   dst="" ;;
        *)         echo "push: $abs is outside \$HOME; pass an explicit destination" >&2; exit 2 ;;
      esac
    else
      # If the caller passed ~ in the destination, strip it — rsync's -s flag
      # disables remote shell expansion, so a literal ~ would be sent verbatim.
      case "$dst" in
        "~"/*) dst="${dst#"~/"}" ;;
        "~")   dst="" ;;
      esac
    fi

    flags=(-avz --partial --progress -s --mkpath --filter=':- .gitignore' --exclude='.git')
    # macOS default /usr/bin/rsync is openrsync, which rejects -s (and other
    # GNU-only flags). Brew's GNU rsync lives at /opt/homebrew/bin/rsync
    # (ARM) or /usr/local/bin/rsync (Intel), but non-interactive SSH PATH on
    # macOS is /usr/bin:/bin:/usr/sbin:/sbin — brew dirs missing. Prefix
    # both onto remote PATH; Linux peers harmlessly ignore the absent dirs.
    flags+=(--rsync-path='PATH=/opt/homebrew/bin:/usr/local/bin:$PATH rsync')
    [ "${DRY_RUN:-}" = "1" ] && flags+=(-n)

    exec rsync "${flags[@]}" -- "$src" "$PEER_HOST:$dst"

# Show external IP + listening ports — quick "what's this machine doing".
net:
    @echo "External: $(curl -s ifconfig.me)"
    @echo "Listening:"
    @lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk 'NR>1 {print "  " $1, $9}' | sort -u

# Fuzzy-pick a git repo/worktree under ~/code and print its path. Use as: cd "$(gust wt)".
wt:
    @find ~/code -maxdepth 4 -name .git \( -type d -o -type f \) 2>/dev/null \
      | sed 's|/\.git$||' \
      | fzf --prompt="worktree> " --preview 'cd {} && git log --oneline -10 2>/dev/null'
