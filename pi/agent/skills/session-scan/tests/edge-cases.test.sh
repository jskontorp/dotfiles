#!/usr/bin/env bash
# Tests for scan.sh — edge cases (no repo, no tmux, missing tools).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/.."
# shellcheck source=lib/helpers.sh
. "$SCRIPT_DIR/lib/helpers.sh"

SCRIPT="$SCRIPTS_DIR/scan.sh"

# ---- tests ----

test_outside_git_repo() {
  # Run scan.sh in a freshly-created directory that is NOT a git repo.
  local nonrepo="$TMP/nonrepo"
  mkdir -p "$nonrepo"
  local out rc
  out=$( cd "$nonrepo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 ); rc=$?
  assert_exit 0 "$rc" "outside repo → exit 0"
  assert_contains "$out" "═══ nonrepo session scan" "header rendered with cwd basename"
  assert_contains "$out" "not a git repo" "stub message printed"
  # No other section should render.
  if printf '%s' "$out" | grep -q "^REPO$"; then
    fail "REPO section unexpectedly rendered outside git repo"
  else
    pass "REPO section not rendered outside git repo"
  fi
  if printf '%s' "$out" | grep -q "^WORKTREES"; then
    fail "WORKTREES section unexpectedly rendered outside git repo"
  else
    pass "WORKTREES section not rendered outside git repo"
  fi
}

test_no_tmux_env() {
  local repo="$TMP/repo"
  git init -q -b main "$repo"
  ( cd "$repo" && git commit --allow-empty -q -m init )
  local out rc
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 ); rc=$?
  assert_exit 0 "$rc" "in repo without TMUX → exit 0"
  assert_contains "$out" "REPO" "REPO section rendered"
  assert_contains "$out" "WORKTREES" "WORKTREES section rendered"
  if printf '%s' "$out" | grep -q "TMUX TOPOLOGY"; then
    fail "TMUX TOPOLOGY rendered without TMUX env"
  else
    pass "TMUX TOPOLOGY omitted without TMUX env"
  fi
}

test_missing_tmux_binary() {
  local repo="$TMP/repo"
  git init -q -b main "$repo"
  ( cd "$repo" && git commit --allow-empty -q -m init )
  # Strip tmux from PATH while keeping pgrep/git/etc.
  local out rc
  out=$(
    cd "$repo" || exit 1
    export TMUX="/tmp/fake-tmux-socket,1234,0"
    export TMUX_PANE="%0"
    # PATH excludes anything containing tmux. Easier: PATH set to a directory
    # that has only the system minimum, and we drop /usr/local/bin etc.
    # Cleanest: remove tmux symlinks from $STUB_DIR and ensure no real tmux on
    # PATH by limiting to /usr/bin:/bin:/usr/sbin:/sbin (no tmux there on macOS).
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$SCRIPT" 2>&1
  ); rc=$?
  assert_exit 0 "$rc" "missing tmux on PATH → exit 0"
  if printf '%s' "$out" | grep -q "TMUX TOPOLOGY"; then
    fail "TMUX TOPOLOGY rendered with tmux missing from PATH"
  else
    pass "TMUX TOPOLOGY omitted gracefully"
  fi
}

test_missing_pgrep_binary() {
  local repo="$TMP/repo"
  git init -q -b main "$repo"
  ( cd "$repo" && git commit --allow-empty -q -m init )
  # Strip pgrep from PATH while keeping system bin dirs. macOS's pgrep lives in
  # /usr/bin so we set PATH to /usr/bin minus a shadow that hides it. Easiest:
  # put a directory ahead of PATH containing a `pgrep` stub that returns 127,
  # but our script uses `command -v pgrep` which would still find it on the
  # original PATH. Instead, replace PATH entirely with a synthetic dir that
  # has every required tool except pgrep, sourced from /usr/bin & /bin.
  local nopgrep="$TMP/nopgrep-bin"
  mkdir -p "$nopgrep"
  for tool in env bash git awk basename cat date grep head printf ps readlink stat tr cut find sed; do
    for src in /opt/homebrew/bin /usr/local/bin /usr/bin /bin; do
      if [ -x "$src/$tool" ]; then
        ln -sf "$src/$tool" "$nopgrep/$tool"
        break
      fi
    done
  done
  # tmux not in this PATH either — keeps the test simple.
  local out rc
  out=$( cd "$repo" && unset TMUX TMUX_PANE; PATH="$nopgrep" "$SCRIPT" 2>&1 ); rc=$?
  assert_exit 0 "$rc" "missing pgrep on PATH → exit 0"
  if printf '%s' "$out" | grep -q "^SIBLINGS$"; then
    fail "SIBLINGS rendered with pgrep missing"
  else
    pass "SIBLINGS omitted gracefully when pgrep missing"
  fi
}

test_header_format() {
  local repo="$TMP/repo"
  git init -q -b main "$repo"
  ( cd "$repo" && git commit --allow-empty -q -m init )
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; "$SCRIPT" 2>&1 )
  # Header must be the first line and match the format.
  local header
  header=$(printf '%s\n' "$out" | head -1)
  case "$header" in
    "═══ repo session scan · "[0-9][0-9][0-9][0-9]"-"*"Z ═══")
      pass "header line matches format" ;;
    *)
      fail "header line wrong: $header" ;;
  esac
}

# ---- runner ----

run_test "outside git repo"       test_outside_git_repo
run_test "no TMUX env var"        test_no_tmux_env
run_test "tmux binary missing"    test_missing_tmux_binary
run_test "pgrep binary missing"   test_missing_pgrep_binary
run_test "header format"          test_header_format

summary
