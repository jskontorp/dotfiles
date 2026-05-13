# ssh-theme.zsh — Change terminal background on remote sessions to visually
# distinguish them from local. Wraps both `ssh` and `mosh`.
#
# Uses OSC 11 (set bg) escape sequences.
# Ghostty, iTerm2, and most modern terminals support these.
#
# NOTE: background-opacity can't be changed per-session (it's a Ghostty
# window-level setting). At 0.96 the transparency is barely visible anyway.
#
# POLICY: `ssh` is the default for remote shells. Reach for `mosh` only when
# UDP roaming / suspend-resume / flaky-link resilience actually matters —
# mosh has no scrollback by design (State Synchronisation Protocol syncs the
# visible viewport, never sends scrolled-off bytes; upstream #122 declined,
# unfixable client-side). Do NOT alias `ssh=mosh` here or anywhere; the
# friction of typing `mosh` in full is the intended signal that you're
# trading scrollback / native search / mouse selection for resilience.

# Local Ghostty background (must match ghostty/config)
_LOCAL_BG="#181825"

# Remote backgrounds — add entries for each host
typeset -A _SSH_BG
_SSH_BG[oracle]="#0f2028"   # dark teal tint — immediately distinguishable

# Run a remote-shell command ($1 = ssh|mosh) with a host-specific terminal
# background, restoring the local bg on exit. Hostname is parsed from args
# using ssh's flag conventions; mosh-only short flags that take values
# (rare in practice) may misparse — the wrapper degrades to no-bg-change
# rather than misfiring.
_with_host_bg() {
  local cmd="$1"; shift
  local host="" bg=""

  # First non-flag argument is the host (skip ssh flags and their values).
  local skip_next=false
  for arg in "$@"; do
    if $skip_next; then skip_next=false; continue; fi
    case "$arg" in
      -[bcDEeFIiJLlmOopQRSWw]) skip_next=true ;;  # flags that take a value
      -*) ;;                                         # other flags
      *)  host="$arg"; break ;;                      # first non-flag = host
    esac
  done

  bg="${_SSH_BG[$host]}"

  [[ -n "$bg" ]] && printf '\e]11;%s\e\\' "$bg"
  command "$cmd" "$@"
  local ret=$?
  [[ -n "$bg" ]] && printf '\e]11;%s\e\\' "$_LOCAL_BG"

  return $ret
}

ssh()  { _with_host_bg ssh  "$@"; }
mosh() { _with_host_bg mosh "$@"; }
