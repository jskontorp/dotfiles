#!/usr/bin/env bash
# Tests for scan.sh — DIRTY section.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/.."
. "$SCRIPT_DIR/lib/helpers.sh"

SCRIPT="$SCRIPTS_DIR/scan.sh"

make_main_repo() {
  local name="$1"
  local path="$TMP/$name"
  git init -q -b main "$path"
  ( cd "$path" && git commit --allow-empty -q -m init )
  ( cd "$path" && pwd -P )
}

# ---- tests ----

test_mixed_status_counts() {
  local repo; repo=$(make_main_repo mixed)
  # Set up: 1 staged (A), 2 unstaged (M), 3 untracked.
  echo "tracked1" > "$repo/tracked1.txt"
  echo "tracked2" > "$repo/tracked2.txt"
  ( cd "$repo" && git add tracked1.txt tracked2.txt && git commit -q -m "add tracked" )
  # Stage a new file → 1 staged (A).
  echo "new staged" > "$repo/staged.txt"
  ( cd "$repo" && git add staged.txt )
  # Unstaged modifications.
  echo "mod1" >> "$repo/tracked1.txt"
  echo "mod2" >> "$repo/tracked2.txt"
  # Untracked.
  echo "u1" > "$repo/u1.txt"
  echo "u2" > "$repo/u2.txt"
  echo "u3" > "$repo/u3.txt"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  assert_contains "$out" "DIRTY" "DIRTY section rendered"
  assert_contains "$out" "2 unstaged" "2 unstaged counted"
  assert_contains "$out" "1 staged" "1 staged counted"
  assert_contains "$out" "3 untracked" "3 untracked counted"
}

test_clean_repo_no_dirty_section() {
  local repo; repo=$(make_main_repo clean)
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  if printf '%s' "$out" | grep -q "^DIRTY$"; then
    fail "DIRTY section unexpectedly rendered for clean repo"
  else
    pass "DIRTY section omitted when repo clean"
  fi
}

test_last_edit_format() {
  local repo; repo=$(make_main_repo recent-edit)
  # Create an untracked file so the dirty section renders.
  echo "fresh" > "$repo/fresh.txt"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  # Format like "Xs ago" or "Xm Ys ago" or "Xh Ym ago".
  if printf '%s\n' "$out" | grep -E "last edit ([0-9]+h [0-9]+m ago|[0-9]+m [0-9]+s ago|[0-9]+s ago)" >/dev/null; then
    pass "last-edit format matches Xs/Xm Ys/Xh Ym ago"
  else
    fail "last-edit format wrong"
  fi
  # And the script must NOT have shelled out to GNU date -d. We can't directly assert that,
  # but we can verify the elapsed value parses as small (0-2s).
  if printf '%s\n' "$out" | grep -E "last edit (0|1|2|3|4|5|6|7|8|9|10)s ago" >/dev/null; then
    pass "last-edit elapsed sub-10s for fresh file"
  else
    fail "last-edit elapsed not sub-10s"
  fi
}

test_top_3_paths_listed() {
  local repo; repo=$(make_main_repo top3)
  echo "a" > "$repo/aaa.txt"
  echo "b" > "$repo/bbb.txt"
  echo "c" > "$repo/ccc.txt"
  echo "d" > "$repo/ddd.txt"  # 4 files; only top 3 should render.
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  # Pull the DIRTY line.
  local dirty_line
  dirty_line=$(printf '%s\n' "$out" | awk '/^DIRTY$/{flag=1; next} flag{print; flag=0}')
  # Should contain at least 3 file references.
  local count=0
  for f in aaa.txt bbb.txt ccc.txt ddd.txt; do
    if printf '%s' "$dirty_line" | grep -q "$f"; then
      count=$((count + 1))
    fi
  done
  if [ "$count" -eq 3 ]; then
    pass "exactly 3 files listed in DIRTY line"
  else
    fail "expected 3 files in DIRTY line, got $count"
  fi
}

# ---- runner ----

run_test "mixed status counts"        test_mixed_status_counts
run_test "clean repo - no DIRTY"      test_clean_repo_no_dirty_section
run_test "last-edit format"           test_last_edit_format
run_test "top 3 paths listed"         test_top_3_paths_listed

summary
