# zsh/dotfiles-freshness.zsh — sourced from ~/.config/zsh/ (glob)
#
# Async warning when canonical dotfiles checkout is behind/ahead of
# origin/main. Backgrounded so the prompt is never blocked. Opt-in via
# DOTFILES_FRESHNESS=1 (set by machine/mac/zshrc; not set on VMs or in
# pi/Claude harness subshells by default).
#
# Throttled: refuses to re-fetch within DOTFILES_FRESHNESS_MIN_AGE seconds
# (default 1800 = 30 min). Caches the stamp under
# ${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles-freshness/.
#
# Out of scope (acknowledged):
#   - Prompt redraw: async output may land mid-prompt. Cost accepted.
#   - Cross-machine ledger collision detection: tracked separately
#     (JSK-49, ledger collision under concurrent multi-machine batches).

# Hard gates — return cheaply when not applicable.
[[ -n ${DOTFILES_FRESHNESS:-} ]] || return 0
[[ -o interactive ]] || return 0
[[ -n ${DOTFILES:-} && -d $DOTFILES/.git ]] || return 0

__dotfiles_freshness() {
  emulate -L zsh
  setopt err_return no_unset pipe_fail
  zmodload zsh/datetime 2>/dev/null  # Provides $EPOCHSECONDS under emulate -L zsh.

  local repo=$DOTFILES
  local cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles-freshness
  local stamp=$cache_dir/last-fetch
  local min_age=${DOTFILES_FRESHNESS_MIN_AGE:-1800}

  mkdir -p $cache_dir
  if [[ -f $stamp ]]; then
    local now=$EPOCHSECONDS
    local mtime=$(stat -f %m $stamp 2>/dev/null || stat -c %Y $stamp 2>/dev/null || echo 0)
    local age=$(( now - mtime ))
    (( age < min_age )) && return 0
  fi
  touch $stamp

  # Resolve canonical (not the calling worktree) and compare main↔origin/main
  # so worktree shells don't misfire on their feature-branch divergence.
  local gitdir canonical
  gitdir=$(git -C $repo rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  canonical=${gitdir:h}

  # ConnectTimeout=5 caps stuck SSH; BatchMode=yes avoids passphrase prompts.
  # --no-write-fetch-head: don't bump FETCH_HEAD (we only need origin/main updated).
  GIT_SSH_COMMAND='ssh -o ConnectTimeout=5 -o BatchMode=yes' \
    git -C $canonical fetch --quiet --no-write-fetch-head origin main 2>/dev/null || return 0

  local behind ahead
  behind=$(git -C $canonical rev-list --count refs/heads/main..refs/remotes/origin/main 2>/dev/null) || behind=0
  ahead=$(git -C $canonical  rev-list --count refs/remotes/origin/main..refs/heads/main 2>/dev/null) || ahead=0
  : ${behind:=0} ${ahead:=0}

  # Skip ANSI when stderr isn't a TTY (e.g. captured by an agent harness).
  local c="" r=""
  [[ -t 2 ]] && { c=$'\e[33m'; r=$'\e[0m'; }

  (( behind > 0 )) && print -u2 -- "${c}⚠ dotfiles: $behind commits behind origin/main — run 'just sync'${r}"
  (( ahead  > 0 )) && print -u2 -- "${c}⚠ dotfiles: $ahead commits ahead origin/main — push before switching machines${r}"
}

{ __dotfiles_freshness } &!
