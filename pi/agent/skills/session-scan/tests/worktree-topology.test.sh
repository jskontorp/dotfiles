#!/usr/bin/env bash
# Tests for scan.sh — WORKTREES section.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/.."
. "$SCRIPT_DIR/lib/helpers.sh"

SCRIPT="$SCRIPTS_DIR/scan.sh"

# ---- helpers ----

# Make a repo with one initial commit on `main`.
make_main_repo() {
  local name="$1"
  local path="$TMP/$name"
  git init -q -b main "$path"
  ( cd "$path" && git commit --allow-empty -q -m init )
  echo "$path"
}

# Add N additional worktrees off the given repo. Branch names: br-1, br-2, ...
add_worktrees() {
  local repo="$1" n="$2"
  local i=1
  while [ "$i" -le "$n" ]; do
    ( cd "$repo" && git worktree add -q -b "br-$i" "$repo-wt-$i" 2>/dev/null )
    i=$((i + 1))
  done
}

# ---- tests ----

test_single_worktree() {
  local repo; repo=$(make_main_repo solo)
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  assert_contains "$out" "WORKTREES (1)" "single worktree counted"
  # Should have an asterisk marker for the current worktree.
  if printf '%s\n' "$out" | grep -q "^  \* .*solo (main)"; then
    pass "current worktree marked with *"
  else
    fail "current worktree not marked with *"
  fi
}

test_three_worktrees_current_marked() {
  local repo; repo=$(make_main_repo trio)
  add_worktrees "$repo" 2
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  assert_contains "$out" "WORKTREES (3)" "3 worktrees counted"
  # All branches present.
  assert_contains "$out" "(main)" "main worktree shown"
  assert_contains "$out" "(br-1)" "br-1 worktree shown"
  assert_contains "$out" "(br-2)" "br-2 worktree shown"
  # Current marker on `trio` (main).
  if printf '%s\n' "$out" | grep -E "^  \* .*/trio \(main\)$" >/dev/null; then
    pass "main marked as current"
  else
    fail "main not marked as current"
  fi
}

test_eight_worktrees_truncated() {
  local repo; repo=$(make_main_repo bigly)
  add_worktrees "$repo" 7
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  assert_contains "$out" "WORKTREES (8)" "8 worktrees counted"
  # Truncation summary line.
  if printf '%s\n' "$out" | grep -E "^  \.\.\. and [0-9]+ more$" >/dev/null; then
    pass "truncation summary line rendered"
  else
    fail "no '... and N more' line rendered"
  fi
  # Render at most current + 5 normal rows = 6 (with one of them being current).
  local rows
  rows=$(printf '%s\n' "$out" | awk '/^WORKTREES/{flag=1; next} flag && /^[A-Z]/{flag=0} flag && /^  /{print}')
  local row_count
  row_count=$(printf '%s\n' "$rows" | grep -c -v '^  \.\.\.' || true)
  if [ "$row_count" -le 6 ]; then
    pass "at most 6 detailed rows rendered (got $row_count)"
  else
    fail "too many rows rendered ($row_count)"
  fi
}

test_locked_flag() {
  local repo; repo=$(make_main_repo locked-test)
  add_worktrees "$repo" 1
  ( cd "$repo" && git worktree lock "$repo-wt-1" >/dev/null 2>&1 )
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  assert_contains "$out" "[locked]" "locked flag rendered"
}

test_prunable_worktree_flag() {
  local repo; repo=$(make_main_repo prunable-test)
  add_worktrees "$repo" 1
  # A worktree whose checkout directory has been removed is reported as
  # prunable by `git worktree list --porcelain`.
  rm -rf "$repo-wt-1"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  assert_contains "$out" "[prunable]" "prunable flag rendered"
}

# ---- runner ----

run_test "single worktree"           test_single_worktree
run_test "three worktrees"           test_three_worktrees_current_marked
run_test "eight worktrees truncate"  test_eight_worktrees_truncated
run_test "locked flag"               test_locked_flag
run_test "prunable flag"             test_prunable_worktree_flag

summary
