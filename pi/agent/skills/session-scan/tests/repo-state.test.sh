#!/usr/bin/env bash
# Tests for scan.sh — REPO section.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/.."
. "$SCRIPT_DIR/lib/helpers.sh"

SCRIPT="$SCRIPTS_DIR/scan.sh"

# ---- helpers ----

# Make a fresh repo with one commit. Echoes its absolute path.
make_repo() {
  local name="${1:-repo}"
  local path="$TMP/$name"
  git init -q -b main "$path"
  ( cd "$path" && git commit --allow-empty -q -m init )
  echo "$path"
}

# ---- tests ----

test_repo_section_basic() {
  local repo; repo=$(make_repo)
  # macOS resolves /var/folders/... to /private/var/folders/... via pwd -P.
  local repo_resolved; repo_resolved=$(cd "$repo" && pwd -P)
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  assert_contains "$out" "REPO" "REPO label rendered"
  assert_contains "$out" "path:     $repo_resolved" "path line shows resolved cwd"
  assert_contains "$out" "kind:     main checkout" "marked as main checkout"
  assert_contains "$out" "branch:   main" "branch line includes 'main'"
  assert_contains "$out" "state:    clean" "clean state for fresh repo"
}

test_repo_section_dirty() {
  local repo; repo=$(make_repo dirty-repo)
  echo "modification" >> "$repo/README"
  ( cd "$repo" && git add . )
  echo "more" >> "$repo/README"
  echo "untracked" > "$repo/new.txt"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  assert_contains "$out" "state:    dirty" "dirty state detected"
}

test_inflight_rebase() {
  local repo; repo=$(make_repo rebase-repo)
  # Simulate an in-flight rebase by creating the rebase-merge dir under .git.
  mkdir -p "$repo/.git/rebase-merge"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  assert_contains "$out" "inflight: rebase" "rebase-merge dir → inflight: rebase"
}

test_inflight_none() {
  local repo; repo=$(make_repo clean-repo)
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  assert_contains "$out" "inflight: none" "no in-progress op → inflight: none"
}

test_inflight_merge() {
  local repo; repo=$(make_repo merge-repo)
  : > "$repo/.git/MERGE_HEAD"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  assert_contains "$out" "inflight: merge" "MERGE_HEAD → inflight: merge"
}

test_index_lock_present() {
  local repo; repo=$(make_repo lock-repo)
  : > "$repo/.git/index.lock"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  assert_contains "$out" "index.lock PRESENT" "lock file → index.lock PRESENT"
  rm -f "$repo/.git/index.lock"
}

test_index_lock_absent() {
  local repo; repo=$(make_repo nolock-repo)
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  assert_contains "$out" "index.lock absent" "no lock file → index.lock absent"
}

# ---- runner ----

run_test "REPO section basic"        test_repo_section_basic
run_test "REPO section dirty"        test_repo_section_dirty
run_test "inflight rebase"           test_inflight_rebase
run_test "inflight none"             test_inflight_none
run_test "inflight merge"            test_inflight_merge
run_test "index.lock present"        test_index_lock_present
run_test "index.lock absent"         test_index_lock_absent

summary
