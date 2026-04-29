#!/usr/bin/env bash
# Tests for scan.sh — TMUX TOPOLOGY filtering.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/.."
. "$SCRIPT_DIR/lib/helpers.sh"

SCRIPT="$SCRIPTS_DIR/scan.sh"

# ---- helpers ----

# Make a repo with one initial commit on `main`. Echoes resolved path.
make_main_repo() {
  local name="$1"
  local path="$TMP/$name"
  git init -q -b main "$path"
  ( cd "$path" && git commit --allow-empty -q -m init )
  ( cd "$path" && pwd -P )
}

# Stub `tmux`. The script invokes:
#   tmux list-panes -aF '<format>'
#   tmux display-message -p -t <addr> '#{pane_id}'
# We make the stub respond to both. Lines for list-panes come from
# $STUB_STATE_DIR/tmux-panes.txt; display-message returns '%0' for everything
# (tests don't assert on the current-pane marker here).
make_tmux_stub() {
  local panes_file="$1"
  cp "$panes_file" "$STUB_STATE_DIR/tmux-panes.txt"
  make_stub tmux '
case "$1" in
  list-panes)
    cat "$STUB_STATE_DIR/tmux-panes.txt"
    ;;
  display-message)
    echo "%0"
    ;;
  *)
    exit 0
    ;;
esac
'
}

# ---- tests ----

test_pane_in_main_worktree_included() {
  local repo; repo=$(make_main_repo include1)
  printf '%s\n' "main:1.0|11111|$repo|zsh|zsh" > "$TMP/panes.txt"
  make_tmux_stub "$TMP/panes.txt"
  local out
  out=$( cd "$repo" && export TMUX="/tmp/fake,1,0" TMUX_PANE="%99"; "$SCRIPT" 2>&1 )
  assert_contains "$out" "TMUX TOPOLOGY (1 panes touching this repo)" "1 pane in main worktree counted"
  assert_contains "$out" "main:1.0" "main:1.0 pane rendered"
}

test_pane_in_sibling_worktree_included() {
  local repo; repo=$(make_main_repo sib-main)
  ( cd "$repo" && git worktree add -q -b feature "$repo-feature" )
  local sibling="$repo-feature"
  printf '%s\n' \
    "main:1.0|11111|$repo|zsh|zsh" \
    "main:1.1|22222|$sibling|zsh|zsh" \
    > "$TMP/panes.txt"
  make_tmux_stub "$TMP/panes.txt"
  local out
  out=$( cd "$repo" && export TMUX="/tmp/fake,1,0" TMUX_PANE="%99"; "$SCRIPT" 2>&1 )
  assert_contains "$out" "TMUX TOPOLOGY (2 panes touching this repo)" "2 panes (main + sibling) counted"
  assert_contains "$out" "main:1.0" "current worktree pane rendered"
  assert_contains "$out" "main:1.1" "sibling worktree pane rendered"
}

test_pane_in_unrelated_repo_excluded() {
  local repo; repo=$(make_main_repo include2)
  local unrelated="$TMP/some-other-place"
  mkdir -p "$unrelated"
  printf '%s\n' \
    "main:1.0|11111|$repo|zsh|zsh" \
    "other:1.0|22222|$unrelated|zsh|zsh" \
    > "$TMP/panes.txt"
  make_tmux_stub "$TMP/panes.txt"
  local out
  out=$( cd "$repo" && export TMUX="/tmp/fake,1,0" TMUX_PANE="%99"; "$SCRIPT" 2>&1 )
  assert_contains "$out" "TMUX TOPOLOGY (1 panes touching this repo)" "only repo pane counted"
  if printf '%s' "$out" | grep -q "other:1.0"; then
    fail "unrelated pane should be excluded"
  else
    pass "unrelated pane excluded"
  fi
}

test_pane_in_subdirectory_matches_via_prefix() {
  local repo; repo=$(make_main_repo subdir-test)
  mkdir -p "$repo/app/foo"
  local sub="$repo/app/foo"
  printf '%s\n' "main:1.0|11111|$sub|zsh|zsh" > "$TMP/panes.txt"
  make_tmux_stub "$TMP/panes.txt"
  local out
  out=$( cd "$repo" && export TMUX="/tmp/fake,1,0" TMUX_PANE="%99"; "$SCRIPT" 2>&1 )
  assert_contains "$out" "TMUX TOPOLOGY (1 panes touching this repo)" "subdirectory pane matched via prefix"
  assert_contains "$out" "$sub" "subdirectory path rendered"
}

# ---- runner ----

run_test "pane in main worktree"        test_pane_in_main_worktree_included
run_test "pane in sibling worktree"     test_pane_in_sibling_worktree_included
run_test "pane in unrelated repo"       test_pane_in_unrelated_repo_excluded
run_test "pane in subdirectory"         test_pane_in_subdirectory_matches_via_prefix

summary
