# sv — Remote wrapper for VM-based pi agent sessions (v3)
#
# All sessions and worktrees live on the VM. This proxies to
# the standalone sv script (~/.local/bin/sv) over SSH.
#
# VM sv v3 uses a single "sv" tmux session with ticket windows.

# --- Constants ---

_SV_REMOTE="oracle"
_SV_REMOTE_SV="~/.local/bin/sv"
_SV_REMOTE_REPO="~/work/valuesync_os"
_SV_LOCAL_REPO="$HOME/code/valuesync_os"
_SV_LOCAL_WT_BASE="${_SV_LOCAL_REPO}_worktrees"
_SV_CACHE="$HOME/.cache/sv-tickets"
_SV_SESSION="sv"

# --- Port forwarding ---
_SV_TUNNEL_DIR="$HOME/.cache/sv-tunnels"

_sv_ticket_port() {
  local digits="${1//[^0-9]/}"
  [[ ${#digits} -gt 3 ]] && digits="${digits: -3}"
  echo $(( 3000 + 10#$digits ))
}

_sv_start_tunnel() {
  local port=$1
  mkdir -p "$_SV_TUNNEL_DIR"
  local pidfile="$_SV_TUNNEL_DIR/$port.pid"

  if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    return 0
  fi

  ssh -NL "$port:localhost:$port" "$_SV_REMOTE" &>/dev/null &
  local pid=$!
  disown $pid 2>/dev/null
  echo $pid > "$pidfile"
  echo "  🔗 localhost:$port → vm:$port"
}

_sv_stop_tunnel() {
  local port=$1
  local pidfile="$_SV_TUNNEL_DIR/$port.pid"
  [[ -f "$pidfile" ]] || return 0
  local pid=$(<"$pidfile")
  kill "$pid" 2>/dev/null && echo "  ✗ Closed port forward: $port"
  rm -f "$pidfile"
}

# --- Helpers ---

_sv_warn_local() {
  local lower="$1"
  [[ ! -d "$_SV_LOCAL_REPO" ]] && return 0

  local signals=()
  [[ -d "$_SV_LOCAL_WT_BASE/$lower" ]] && signals+=("worktree: $_SV_LOCAL_WT_BASE/$lower")
  git -C "$_SV_LOCAL_REPO" show-ref -q "refs/heads/$lower" 2>/dev/null && signals+=("branch: $lower")

  [[ ${#signals} -eq 0 ]] && return 0

  echo "⚠️  Local work detected for ${lower:u} on this Mac:"
  for s in "${signals[@]}"; do echo "   $s"; done
  echo ""
  echo "Running 'sv' will start a separate VM session."
  read -q "confirm?Continue? [y/N] "
  echo ""
  [[ "$confirm" == "y" ]]
}

# --- Remote helper ---

# Run a single command string on the VM inside the repo directory.
_sv_remote() { ssh "$_SV_REMOTE" "cd $_SV_REMOTE_REPO && $*"; }

_sv_usage() {
  cat <<'EOF'
Usage: sv [ticket] [options]

  sv                          Attach to the sv session
  sv <ticket>                 Launch agent or reattach
  sv <ticket> --fresh         Kill window, start fresh
  sv <ticket> --comment "…"   Pass context to agent
  sv <ticket> --shelve        Tear down window + worktree, keep branch + PR
  sv <ticket> --close         Full cleanup: window, worktree, branch, PR
  sv --list | sv -l           Show active solve tickets

Switch tickets with ctrl-b n/p or ctrl-b <number>.
Detach with ctrl-b d to return to your shell.
EOF
}

# --- Main ---

sv() {
  local quoted_args=()
  for arg in "$@"; do quoted_args+=("${(qq)arg}"); done

  # Classify the command
  local needs_attach=false is_list=false raw_ticket="" skip_next=false
  for arg in "$@"; do
    if $skip_next; then skip_next=false; continue; fi
    case "$arg" in
      --list|-l)                    is_list=true; needs_attach=false; break ;;
      --shelve|--close)             needs_attach=false; break ;;
      --comment)                    skip_next=true ;;
      --*)                          ;;
      *)                            raw_ticket="$arg"; needs_attach=true ;;
    esac
  done

  # --- Help: local, no VM needed ---
  for arg in "$@"; do
    [[ "$arg" == "--help" || "$arg" == "-h" ]] && { _sv_usage; return; }
  done

  # --- Bare sv: attach to existing session (no repo setup needed) ---
  if [[ $# -eq 0 ]]; then
    if ! ssh "$_SV_REMOTE" "tmux has-session -t '$_SV_SESSION'" 2>/dev/null; then
      echo "No sv session on $_SV_REMOTE. Start one with: sv <ticket>" >&2
      return 1
    fi
    if ! ssh -t "$_SV_REMOTE" "tmux attach -t '$_SV_SESSION'"; then
      echo "Attach failed. Reconnect with: ssh -t $_SV_REMOTE 'tmux attach -t $_SV_SESSION'" >&2
      return 1
    fi
    return
  fi

  # --- List: VM state + local-only scan ---
  if $is_list; then
    local vm_output
    vm_output=$(_sv_remote "$_SV_REMOTE_SV --list" 2>/dev/null)
    echo "$vm_output"

    # Extract VM ticket ids for dedup + cache
    local -a vm_tickets=()
    for line in ${(f)vm_output}; do
      [[ "$line" =~ 'VS-([0-9]+)' ]] && vm_tickets+=("vs-${match[1]}")
    done

    mkdir -p "$(dirname "$_SV_CACHE")"
    printf '%s\n' "${vm_tickets[@]#vs-}" > "$_SV_CACHE" 2>/dev/null

    # Show local-only tickets
    if [[ -d "$_SV_LOCAL_REPO" ]]; then
      local -a local_only=()

      if [[ -d "$_SV_LOCAL_WT_BASE" ]]; then
        for d in "$_SV_LOCAL_WT_BASE"/vs-*(N); do
          local t=$(basename "$d")
          (( ${vm_tickets[(I)$t]} )) || local_only+=("$t")
        done
      fi

      for b in $(git -C "$_SV_LOCAL_REPO" branch --format='%(refname:short)' 2>/dev/null | grep -E '^vs-[0-9]+$'); do
        (( ${local_only[(I)$b]} )) || (( ${vm_tickets[(I)$b]} )) || local_only+=("$b")
      done

      if [[ ${#local_only} -gt 0 ]]; then
        echo "  Local (this Mac):"
        for t in ${(o)local_only}; do
          local parts=()
          [[ -d "$_SV_LOCAL_WT_BASE/$t" ]] && parts+=("worktree")
          git -C "$_SV_LOCAL_REPO" show-ref -q "refs/heads/$t" 2>/dev/null && parts+=("branch")
          printf "  %-10s  ⚠ %s\n" "${t:u}" "${(j:, :)parts}"
        done
        echo ""

        for t in "${local_only[@]}"; do echo "${t#vs-}"; done >> "$_SV_CACHE"
      fi
    fi
    return
  fi

  # --- Attach: two-phase SSH ---
  if $needs_attach; then
    local lower=$(echo "$raw_ticket" | tr '[:upper:]' '[:lower:]')
    [[ "$lower" =~ ^[0-9]+$ ]] && lower="vs-$lower"
    if [[ ! "$lower" =~ ^vs-[0-9]+$ ]]; then
      echo "Invalid ticket: $raw_ticket"
      return 1
    fi

    _sv_warn_local "$lower" || return 0

    local port=$(_sv_ticket_port "$lower")

    # Phase 1: set up session on VM (no attach, no TTY needed)
    _sv_remote "$_SV_REMOTE_SV --no-attach ${quoted_args[*]}" || return 1

    # Phase 2: start port-forward tunnel
    _sv_start_tunnel "$port"

    # Phase 3: attach to the sv session (v3: single session, ticket windows)
    if ! ssh -t "$_SV_REMOTE" "tmux attach -t '$_SV_SESSION'"; then
      echo "Attach failed. Reconnect with: ssh -t $_SV_REMOTE 'tmux attach -t $_SV_SESSION'" >&2
      return 1
    fi
    return
  fi

  # --- Passthrough: --shelve, --close (need the repo) ---
  local action="" has_yes=false
  for arg in "$@"; do
    case "$arg" in
      --shelve) action="Shelve" ;;
      --close)  action="Close" ;;
      --yes|-y) has_yes=true ;;
    esac
  done

  if [[ -n "$action" ]] && ! $has_yes; then
    if [[ ! -t 0 ]]; then
      echo "Cannot confirm: not a terminal. Pass --yes to skip." >&2
      return 1
    fi
    local upper="${raw_ticket:u}"
    [[ "$upper" =~ ^[0-9]+$ ]] && upper="VS-$upper"
    local detail="This will tear down the window and worktree."
    [[ "$action" == "Close" ]] && detail="This will delete the branch, PR, and all local state."
    printf "%s %s? %s [y/N] " "$action" "$upper" "$detail"
    local answer
    read -r answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
      echo "Aborted." >&2
      return 1
    fi
    quoted_args+=("'--yes'")
  fi

  _sv_remote "$_SV_REMOTE_SV ${quoted_args[*]}"

  # Stop port-forward tunnel on shelve/close
  if [[ -n "$action" && -n "$raw_ticket" ]]; then
    local _lower=$(echo "$raw_ticket" | tr '[:upper:]' '[:lower:]')
    [[ "$_lower" =~ ^[0-9]+$ ]] && _lower="vs-$_lower"
    _sv_stop_tunnel "$(_sv_ticket_port "$_lower")"
  fi
}

# --- Completion ---

_sv() {
  local -a tickets=() flags=(--comment --fresh --shelve --close --list -l --help -h)

  if [[ -f "$_SV_CACHE" ]]; then
    tickets=(${(f)"$(<$_SV_CACHE)"})
  fi

  if [[ -d "$_SV_LOCAL_REPO" ]]; then
    for d in "$_SV_LOCAL_WT_BASE"/vs-*(N); do
      [[ -d "$d" ]] && tickets+=(${$(basename "$d")#vs-})
    done
    for b in $(git -C "$_SV_LOCAL_REPO" branch --format='%(refname:short)' 2>/dev/null | sed -n 's/^vs-//p'); do
      [[ -n "$b" ]] && tickets+=($b)
    done
  fi

  tickets=(${(u)tickets})
  [[ "$words[CURRENT-1]" == "--comment" ]] && return

  case "$words[CURRENT]" in
    -*) compadd -- "${flags[@]}" ;;
    *)  compadd -- "${tickets[@]}" ;;
  esac
}
(( $+functions[compdef] )) && compdef _sv sv
