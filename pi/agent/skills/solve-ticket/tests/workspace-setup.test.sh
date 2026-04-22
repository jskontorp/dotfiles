#!/usr/bin/env bash
# Tests for workspace-setup.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/../scripts"
# shellcheck source=lib/helpers.sh
. "$SCRIPT_DIR/lib/helpers.sh"

SCRIPT="$SCRIPTS_DIR/workspace-setup.sh"

# ---- per-test helpers ----

# Initialise a mock ROOT repo with an `origin` bare remote + `main` branch.
# Echoes the root path. PM stubbed to exit 0.
make_mock_root() {
  local pm="$1"
  local origin="$TMP/origin.git"
  local root="$TMP/root"
  git init --bare -q -b main "$origin"
  git clone -q "$origin" "$root" 2>/dev/null
  ( cd "$root" && git commit --allow-empty -q -m init && git push -q origin main )
  # Lockfile marker.
  case "$pm" in
    pnpm) touch "$root/pnpm-lock.yaml" ;;
    bun)  touch "$root/bun.lock" ;;
    yarn) touch "$root/yarn.lock" ;;
    npm)  touch "$root/package-lock.json" ;;
    none) ;;  # no lockfile
  esac
  # Stub the PM — just exits 0.
  [ "$pm" != "none" ] && make_stub "$pm" 'exit 0'
  echo "$root"
}

# ---- tests ----

test_bad_args() {
  "$SCRIPT" 2>/dev/null; local rc=$?
  assert_exit 64 "$rc" "zero args → exit 64"
  "$SCRIPT" only 2>/dev/null; rc=$?
  assert_exit 64 "$rc" "one arg → exit 64"
  "$SCRIPT" tech-1 "" 2>/dev/null; rc=$?
  assert_exit 64 "$rc" "empty base → exit 64"
}

test_help() {
  local out
  out=$("$SCRIPT" --help)
  assert_contains "$out" "Usage:" "--help prints usage"
  assert_contains "$out" "workspace-setup.sh" "--help names the script"
}

test_no_lockfile() {
  local root; root=$(make_mock_root none)
  local rc
  ( cd "$root" && "$SCRIPT" tech-1 main ) 2>/dev/null; rc=$?
  assert_exit 66 "$rc" "no lockfile → exit 66 (not silent)"
}

test_pnpm_lockfile_success() {
  local root; root=$(make_mock_root pnpm)
  local rc
  ( cd "$root" && "$SCRIPT" tech-1 main ) >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "pnpm lockfile → success"
  local state_dir="${root}_worktrees/.pi-state"
  local env_file="$state_dir/tech-1.env"
  assert_file_exists "$env_file" "env file written"
  # shellcheck disable=SC1090
  . "$env_file"
  assert_eq "pnpm" "$PM" "PM=pnpm in env file"
  assert_eq "$(cd "${root}_worktrees/tech-1" && pwd -P)" "$(cd "$WT" && pwd -P)" "WT path in env file"
  assert_eq "0" "$BRANCH_EXISTED" "new branch → BRANCH_EXISTED=0"
  assert_file_exists "$WT/.git" "worktree created"
  # $PM install was called
  assert_eq "1" "$(stub_count pnpm)" "pnpm invoked once"
  assert_contains "$(stub_log pnpm)" "install" "pnpm invoked with 'install'"
}

test_bun_lockfile() {
  local root; root=$(make_mock_root bun)
  ( cd "$root" && "$SCRIPT" tech-2 main ) >/dev/null 2>&1
  local env_file="${root}_worktrees/.pi-state/tech-2.env"
  # shellcheck disable=SC1090
  . "$env_file"
  assert_eq "bun" "$PM" "bun lockfile → PM=bun"
}

test_pm_precedence() {
  # Both pnpm-lock.yaml AND package-lock.json present → pnpm wins.
  local root; root=$(make_mock_root pnpm)
  touch "$root/package-lock.json"
  make_stub npm 'exit 0'
  ( cd "$root" && "$SCRIPT" tech-3 main ) >/dev/null 2>&1
  local env_file="${root}_worktrees/.pi-state/tech-3.env"
  # shellcheck disable=SC1090
  . "$env_file"
  assert_eq "pnpm" "$PM" "pnpm > npm when both lockfiles present"
  assert_eq "1" "$(stub_count pnpm)" "pnpm invoked"
  assert_eq "0" "$(stub_count npm)" "npm NOT invoked"
}

test_env_symlinks() {
  local root; root=$(make_mock_root pnpm)
  printf 'X=1\n' > "$root/.env.local"
  printf 'Y=2\n' > "$root/.env"
  # .env.development NOT created → should not be symlinked
  ( cd "$root" && "$SCRIPT" tech-4 main ) >/dev/null 2>&1
  local wt="${root}_worktrees/tech-4"
  assert_file_exists "$wt/.env.local" ".env.local symlinked"
  assert_file_exists "$wt/.env" ".env symlinked"
  assert_file_absent "$wt/.env.development" ".env.development absent (not in root)"
  [ -L "$wt/.env.local" ] && pass ".env.local is a symlink" || fail ".env.local should be a symlink"
}

test_dangling_symlink_handling() {
  # ln -sfn should overwrite existing/dangling symlinks at the destination.
  local root; root=$(make_mock_root pnpm)
  printf 'X=1\n' > "$root/.env.local"
  # Create worktree first with a dangling symlink already at .env.local
  ( cd "$root" && "$SCRIPT" tech-dangle main ) >/dev/null 2>&1
  local wt="${root}_worktrees/tech-dangle"
  rm -f "$wt/.env.local"
  ln -s "$TMP/nonexistent" "$wt/.env.local"
  # Re-run — should replace the dangling link.
  ( cd "$root" && "$SCRIPT" tech-dangle main ) >/dev/null 2>&1
  [ -e "$wt/.env.local" ] && pass "dangling symlink replaced by ln -sfn" \
    || fail "dangling symlink NOT replaced"
}

test_idempotent_resume() {
  local root; root=$(make_mock_root pnpm)
  ( cd "$root" && "$SCRIPT" tech-5 main ) >/dev/null 2>&1
  # Second call — worktree already exists.
  local rc
  ( cd "$root" && "$SCRIPT" tech-5 main ) >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "second call → success"
  local env_file="${root}_worktrees/.pi-state/tech-5.env"
  # shellcheck disable=SC1090
  . "$env_file"
  assert_eq "1" "$BRANCH_EXISTED" "BRANCH_EXISTED=1 on re-run"
  assert_eq "2" "$(stub_count pnpm)" "pnpm install ran both times"
}

test_state_file_pm_wins_over_lockfile() {
  # Pre-populate env file with PM=yarn; real lockfile is pnpm. State wins.
  local root; root=$(make_mock_root pnpm)
  local state_dir="${root}_worktrees/.pi-state"
  mkdir -p "$state_dir"
  printf 'PM=yarn\n' > "$state_dir/tech-6.env"
  make_stub yarn 'exit 0'
  ( cd "$root" && "$SCRIPT" tech-6 main ) >/dev/null 2>&1
  # shellcheck disable=SC1090
  . "$state_dir/tech-6.env"
  assert_eq "yarn" "$PM" "persisted PM wins over lockfile detection"
}

test_install_failure() {
  local root; root=$(make_mock_root pnpm)
  # Override the pnpm stub to fail.
  make_stub pnpm 'exit 1'
  local rc
  ( cd "$root" && "$SCRIPT" tech-7 main ) >/dev/null 2>&1; rc=$?
  assert_exit 73 "$rc" "install failure → exit 73"
}

# ---- runner ----

run_test "bad args"                         test_bad_args
run_test "--help"                           test_help
run_test "no lockfile"                      test_no_lockfile
run_test "pnpm lockfile — success path"     test_pnpm_lockfile_success
run_test "bun lockfile"                     test_bun_lockfile
run_test "pnpm > npm precedence"            test_pm_precedence
run_test "env symlinks"                     test_env_symlinks
run_test "dangling symlink handling"        test_dangling_symlink_handling
run_test "idempotent resume"                test_idempotent_resume
run_test "persisted PM wins"                test_state_file_pm_wins_over_lockfile
run_test "install failure"                  test_install_failure

summary
