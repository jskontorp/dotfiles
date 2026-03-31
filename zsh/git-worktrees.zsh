# Git worktree management with tmux integration
#
# Worktrees are created in a sibling directory: <repo>_worktrees/<name>
# Each worktree gets a tmux window for quick switching.
#
# Commands:
#   gwt  <name> [base]  — Create worktree (and branch if needed)
#   gwts <name>         — Switch to existing worktree
#   gwtl                — Interactive picker
#   gwtr [-b] <name>    — Remove worktree
#   gwtra               — Remove all worktrees except main

# --- Internals ---

_gwt_root() {
  command git worktree list 2>/dev/null | awk 'NR==1 {print $1}'
}

_gwt_dir() {
  local root=$(_gwt_root)
  [[ -z "$root" ]] && return 1
  echo "$(command dirname "$root")/$(command basename "$root")_worktrees"
}

# _gwt_project_setup - Idempotent post-create/switch setup
# Detects lockfile in root, symlinks env file, installs deps if missing.
_gwt_project_setup() {
  local wt="$1" root="$2"

  if [[ -f "$root/pnpm-lock.yaml" ]]; then
    [[ -f "$root/.env.local" && ! -e "$wt/.env.local" ]] && command ln -s "$root/.env.local" "$wt/.env.local"
    [[ ! -d "$wt/node_modules" ]] && ( cd "$wt" && command pnpm install )
  elif [[ -f "$root/uv.lock" ]]; then
    [[ -f "$root/.env" && ! -e "$wt/.env" ]] && command ln -s "$root/.env" "$wt/.env"
    [[ ! -d "$wt/.venv" ]] && ( cd "$wt" && command uv sync )
  fi
}

_gwt_tmux_window() {
  [[ -z "$TMUX" ]] && return
  local wt_path="$1" win_name="${2:-$(command basename "$1")}"
  local session
  session=$(tmux display-message -p '#S')

  if tmux list-windows -t "$session" -F '#W' | command grep -qx "$win_name"; then
    tmux select-window -t "$session:$win_name"
  else
    tmux new-window -t "$session" -n "$win_name" -c "$wt_path"
  fi
}

_gwt_kill_tmux_window() {
  [[ -z "$TMUX" ]] && return
  local win_name="$1"
  local session
  session=$(tmux display-message -p '#S')

  tmux list-windows -t "$session" -F '#W' | command grep -qx "$win_name" \
    && tmux kill-window -t "$session:$win_name"
}

# --- Commands ---

# gwt - Create a new worktree (and branch if needed)
# Usage: gwt <name> [base_branch]
alias gwt &>/dev/null && unalias gwt
gwt() {
  local name="${1:-}" base="${2:-}"
  [[ -z "$name" ]] && { echo "Usage: gwt <name> [base_branch]"; return 1; }

  local root=$(_gwt_root)
  [[ -z "$root" ]] && { echo "Not in a git repo"; return 1; }

  local wt_dir=$(_gwt_dir)
  local wt_path="$wt_dir/$name"

  if [[ -d "$wt_path" ]]; then
    echo "Worktree '$name' already exists at $wt_path"
    echo "Use: gwts $name"
    return 1
  fi

  command mkdir -p "$wt_dir"

  if command git show-ref -q "refs/heads/$name"; then
    echo "Branch '$name' already exists."
    read -q "confirm?Create worktree from this branch? [y/N] "
    echo ""
    [[ "$confirm" != "y" ]] && { echo "Aborted"; return 0; }
    command git worktree add "$wt_path" "$name" || return 1
  else
    command git worktree add --no-track -b "$name" "$wt_path" ${base:-} || return 1
  fi

  cd "$wt_path"
  _gwt_project_setup "$wt_path" "$root"
  _gwt_tmux_window "$wt_path" "$name"
}

# gwts - Switch to an existing worktree
# Usage: gwts <name>
alias gwts &>/dev/null && unalias gwts
gwts() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "Usage: gwts <name>"; return 1; }

  local root=$(_gwt_root)
  [[ -z "$root" ]] && { echo "Not in a git repo"; return 1; }

  local wt_path="$(_gwt_dir)/$name"
  [[ ! -d "$wt_path" ]] && { echo "Worktree '$name' not found. Use: gwt $name"; return 1; }

  cd "$wt_path"
  _gwt_project_setup "$wt_path" "$root"
  _gwt_tmux_window "$wt_path" "$name"
}

# gwtl - Interactive worktree picker → opens/switches tmux window
alias gwtl &>/dev/null && unalias gwtl
gwtl() {
  local worktrees
  worktrees=$(command git worktree list)

  if [[ -z "$TMUX" ]]; then
    echo "$worktrees"
    return
  fi

  local i=1
  while IFS= read -r line; do
    echo "  $i) $line"
    i=$((i + 1))
  done <<< "$worktrees"

  echo ""
  read "choice?Select worktree [1-$((i - 1))]: "
  [[ -z "$choice" ]] && return

  local wt_path=$(echo "$worktrees" | awk "NR==$choice {print \$1}")
  [[ -z "$wt_path" ]] && { echo "Invalid selection"; return 1; }

  _gwt_tmux_window "$wt_path"
}

# gwtr - Remove a worktree
# Usage: gwtr [-b|--delete-branch] <name>
gwtr() {
  local delete_branch=false name

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--delete-branch) delete_branch=true ;;
      *) name="$1" ;;
    esac
    shift
  done

  [[ -z "$name" ]] && { echo "Usage: gwtr [-b|--delete-branch] <name>"; return 1; }

  local root=$(_gwt_root)
  [[ -z "$root" ]] && { echo "Not in a git repo"; return 1; }

  local wt_path="$(_gwt_dir)/$name"
  [[ ! -d "$wt_path" ]] && { echo "Worktree '$name' not found at $wt_path"; return 1; }

  [[ "$PWD" == "$wt_path"* ]] && cd "$root"

  if [[ -n "$(command git -C "$wt_path" status --porcelain 2>/dev/null)" ]]; then
    echo "⚠ Worktree '$name' has uncommitted changes:"
    command git -C "$wt_path" status --short
    echo ""
    read -q "confirm?Remove anyway? [y/N] "
    echo ""
    [[ "$confirm" != "y" ]] && { echo "Aborted"; return 0; }
  fi

  command git worktree remove --force "$wt_path" || return 1

  _gwt_kill_tmux_window "$name"
  tmux kill-session -t "$name" 2>/dev/null
  tmux kill-session -t "$name-dev" 2>/dev/null

  if $delete_branch; then
    command git show-ref -q "refs/heads/$name" \
      && command git branch -D "$name" \
      || echo "Branch '$name' not found"
  fi
}

# gwtra - Remove all worktrees except main
gwtra() {
  local root=$(_gwt_root)
  [[ -z "$root" ]] && { echo "Not in a git repo"; return 1; }

  local wt_dir=$(_gwt_dir)
  local worktrees=$(command git worktree list | awk 'NR>1 {print $1}')

  [[ -z "$worktrees" ]] && { echo "No worktrees to remove"; return 0; }

  echo "The following worktrees will be removed:"
  echo "$worktrees"
  echo ""
  read -q "confirm?Are you sure? [y/N] "
  echo ""
  [[ "$confirm" != "y" ]] && { echo "Aborted"; return 0; }

  [[ "$PWD" == "$wt_dir"* ]] && cd "$root"

  for worktree in ${(f)worktrees}; do
    local wt_name=$(command basename "$worktree")
    _gwt_kill_tmux_window "$wt_name"
    tmux kill-session -t "$wt_name" 2>/dev/null
    tmux kill-session -t "$wt_name-dev" 2>/dev/null
    command git worktree remove --force "$worktree" 2>/dev/null || echo "Failed to remove: $worktree"
  done

  command git worktree prune
}
