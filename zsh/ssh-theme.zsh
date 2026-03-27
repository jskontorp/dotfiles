# ssh-theme.zsh — Change terminal background on SSH to visually distinguish remote sessions
#
# Uses OSC 11 (set bg) escape sequences.
# Ghostty, iTerm2, and most modern terminals support these.
#
# NOTE: background-opacity can't be changed per-session (it's a Ghostty
# window-level setting). At 0.96 the transparency is barely visible anyway.

# Local Ghostty background (must match ghostty/config)
_LOCAL_BG="#181825"

# Remote backgrounds — add entries for each host
typeset -A _SSH_BG
_SSH_BG[oracle]="#0f2028"   # dark teal tint — immediately distinguishable

ssh() {
  local host=""
  local bg=""

  # Parse hostname from ssh args (skip flags and their values)
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

  if [[ -n "$bg" ]]; then
    # Change background before SSH
    printf '\e]11;%s\e\\' "$bg"
  fi

  # Run real ssh
  command ssh "$@"
  local ret=$?

  if [[ -n "$bg" ]]; then
    # Restore local background after SSH exits
    printf '\e]11;%s\e\\' "$_LOCAL_BG"
  fi

  return $ret
}
