# Git aliases
alias gco="git checkout"
alias gb="git branch"
alias gs="git status"
alias gpl="git pull"
alias gps="git push"
alias gpf="git push --force"
alias gl="git log --oneline"
alias gd="git diff"
alias ga="git add ."
alias gc="git commit -m"
alias gbd="git branch -D"
alias gca="git commit --amend --no-edit"
alias grc="git rebase --continue"
alias gra="git rebase --abort"
alias grr="git restore . && git clean -fd"

# --- Diff helpers ---

# gdc - git diff (excludes lockfiles), copies to clipboard if available
# Usage: gdc [branch] [file]
gdc() {
  local excludes=(
    ":(exclude).gitignore"
    ":(exclude)*.lock"
    ":(exclude)package-lock.json"
    ":(exclude)pnpm-lock.yaml"
    ":(exclude)yarn.lock"
  )

  local diff
  if [[ -n "$2" ]]; then
    diff=$(command git diff "$1" -- "$2" "${excludes[@]}")
  elif [[ -n "$1" ]]; then
    diff=$(command git diff "$1" -- "${excludes[@]}")
  else
    diff=$(command git diff -- "${excludes[@]}")
  fi

  if [[ -z "$diff" ]]; then
    echo "No diff output."
    return 0
  fi

  if command -v pbcopy &>/dev/null; then
    echo "$diff" | pbcopy
    echo "Copied to clipboard ($(echo "$diff" | wc -l | tr -d ' ') lines)"
  elif command -v xclip &>/dev/null && [[ -n "$DISPLAY" ]]; then
    echo "$diff" | xclip -selection clipboard
    echo "Copied to clipboard ($(echo "$diff" | wc -l | tr -d ' ') lines)"
  else
    echo "$diff"
  fi
}

# --- Staging helpers ---

# gae - git add by extension
# Usage: gae .ts
alias gae &>/dev/null && unalias gae
gae() {
  [[ -z "$1" ]] && { echo "Usage: gae <extension> (e.g., gae .ts)"; return 1; }
  local files=$(command git ls-files --modified --others --exclude-standard | grep "$1$")
  [[ -z "$files" ]] && { echo "No files match '*$1'"; return 0; }
  command git add -- ${(f)files}
}

# gam - git add by path match
# Usage: gam src
alias gam &>/dev/null && unalias gam
gam() {
  [[ -z "$1" ]] && { echo "Usage: gam <pattern> (e.g., gam src)"; return 1; }
  local files=$(command git ls-files --modified --others --exclude-standard | grep "$1")
  [[ -z "$files" ]] && { echo "No files match '$1'"; return 0; }
  command git add -- ${(f)files}
}

# gre - git restore staged by extension
# Usage: gre .ts
gre() {
  [[ -z "$1" ]] && { echo "Usage: gre <extension> (e.g., gre .ts)"; return 1; }
  local files=$(command git diff --cached --name-only | grep "$1$")
  [[ -z "$files" ]] && { echo "No staged files match '*$1'"; return 0; }
  command git restore --staged -- ${(f)files}
}

# grm - git restore staged by path match
# Usage: grm src
alias grm &>/dev/null && unalias grm
grm() {
  [[ -z "$1" ]] && { echo "Usage: grm <pattern> (e.g., grm src)"; return 1; }
  local files=$(command git diff --cached --name-only | grep "$1")
  [[ -z "$files" ]] && { echo "No staged files match '$1'"; return 0; }
  command git restore --staged -- ${(f)files}
}

# --- Worktree internals ---

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

# --- Worktree commands ---

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

# --- File checkout ---

# gcof - Checkout a file or directory from another branch
# Usage: gcof <branch> <path> [new_name]
gcof() {
  local branch="${1:-}" target_path="${2:-}" new_name="${3:-}"
  [[ -z "$branch" || -z "$target_path" ]] && { echo "Usage: gcof <branch> <path> [new_name]"; return 1; }

  local root
  root=$(command git rev-parse --show-toplevel 2>/dev/null) || { echo "Not in a git repo"; return 1; }

  local rel="$target_path"
  [[ "$rel" == "$root/"* ]] && rel="${rel#$root/}"
  rel="${rel%/}"

  local obj_type
  obj_type=$(command git cat-file -t "$branch:$rel" 2>/dev/null) \
    || { echo "Path '$rel' not found in branch '$branch'"; return 1; }

  local dest
  if [[ "$obj_type" == "tree" ]]; then
    dest="${new_name:-$root/$rel}"
    if [[ -d "$dest" ]]; then
      echo "⚠ Directory exists: $dest"
      echo "  Files inside will be overwritten."
      read -q "confirm?Continue? [y/N] "
      echo ""
      [[ "$confirm" != "y" ]] && { echo "Aborted"; return 0; }
    fi
    command mkdir -p "$dest" || return 1
    local strip=$(command tr '/' '\n' <<< "$rel" | wc -l | command tr -d ' ')
    command git archive "$branch" "$rel" | command tar -x -C "$dest" --strip-components="$strip" || return 1
  else
    dest="${new_name:-$root/$rel}"
    if [[ -f "$dest" ]]; then
      echo "⚠ File exists: $dest"
      local tmp=$(command mktemp)
      command git show "$branch:$rel" > "$tmp"
      if ! command diff -q "$dest" "$tmp" &>/dev/null; then
        echo "Diff (local → $branch):"
        command git diff --no-index -- "$dest" "$tmp" 2>/dev/null | head -30
      else
        echo "  (identical — no changes)"
        command rm -f "$tmp"
        return 0
      fi
      command rm -f "$tmp"
      echo ""
      read -q "confirm?Overwrite? [y/N] "
      echo ""
      [[ "$confirm" != "y" ]] && { echo "Aborted"; return 0; }
    fi
    command mkdir -p "$(command dirname "$dest")" 2>/dev/null
    command git show "$branch:$rel" > "$dest" || return 1
  fi

  echo "✓ $branch:$rel → $dest"
}
