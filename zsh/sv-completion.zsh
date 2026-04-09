# Tab completion for the sv command (~/.local/bin/sv)

_sv() {
  local -a tickets=() flags=(--comment --fresh --shelve --close --list -l --no-attach --yes -y --help -h)

  [[ "$words[CURRENT-1]" == "--comment" ]] && return

  # Resolve repo root (mirrors sv_resolve_repo in bin/sv)
  local repo r=$(git rev-parse --git-common-dir 2>/dev/null)
  if [[ "$r" == ".git" ]]; then
    r=$(pwd)
  elif [[ -n "$r" ]]; then
    r="${r%/.git}"
  fi
  [[ -n "$r" ]] && r=$(cd "$r" && pwd)
  [[ -n "$r" && "$(basename "$r")" == "valuesync_os" ]] && repo="$r"

  # Gather ticket numbers only when inside the repo
  if [[ -n "$repo" ]]; then
    local wt_base="${repo}_worktrees"

    # From sv session windows
    local w
    for w in $(tmux list-windows -t sv -F '#W' 2>/dev/null | grep -oE '^tech-[0-9]+' | sed 's/^tech-//' | sort -u); do
      tickets+=($w)
    done

    # From dev sessions (still separate tmux sessions)
    local s
    for s in $(tmux list-sessions -F '#S' 2>/dev/null | sed -n 's/^tech-\([0-9]\{1,\}\)-dev$/\1/p' | sort -u); do
      tickets+=($s)
    done

    # From worktrees and branches
    for d in "$wt_base"/tech-*(N); do
      [[ -d "$d" ]] && tickets+=(${$(basename "$d")#tech-})
    done
    local b
    for b in $(git -C "$repo" branch --format='%(refname:short)' 2>/dev/null | sed -n 's/^tech-//p'); do
      [[ -n "$b" ]] && tickets+=($b)
    done

    tickets=(${(u)tickets})
  fi

  case "$words[CURRENT]" in
    -*) compadd -- "${flags[@]}" ;;
    *)  compadd -- "${tickets[@]}" ;;
  esac
}
(( $+functions[compdef] )) && compdef _sv sv
true
