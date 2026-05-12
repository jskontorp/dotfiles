#!/usr/bin/env bash
# Tests for peer-review-spawn.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/../scripts"
# shellcheck source=lib/helpers.sh
. "$SCRIPT_DIR/lib/helpers.sh"

SCRIPT="$SCRIPTS_DIR/peer-review-spawn.sh"

# Short pi timeout for tests — not the failure under test; the stubbed pi
# exits fast with scripted rc.
export PI_TIMEOUT=5

# ----- per-test helpers -----

prep_dirs() {
  export WT="$TMP/wt"
  export STATE_DIR="$TMP/state"
  mkdir -p "$WT" "$STATE_DIR"
}

# Stub `pi` with a body. Tests control pi.rc and pi.out in $STUB_STATE_DIR.
install_pi_stub() {
  # timeout stub: drop the duration arg, exec the rest.
  make_stub timeout '
shift
exec "$@"
'
  local body='
[ -f "$STUB_STATE_DIR/pi.out" ] && cat "$STUB_STATE_DIR/pi.out"
[ -f "$STUB_STATE_DIR/pi.rc" ] && exit "$(cat "$STUB_STATE_DIR/pi.rc")"
exit 0
'
  make_stub pi "$body"
}

set_pi() {
  local rc="$1" out="${2:-review output}"
  echo "$rc" > "$STUB_STATE_DIR/pi.rc"
  printf '%s\n' "$out" > "$STUB_STATE_DIR/pi.out"
}

# ----- tests -----

test_bad_args() {
  local rc
  "$SCRIPT" 2>/dev/null; rc=$?
  assert_exit 64 "$rc" "zero args → 64"
  "$SCRIPT" a b c 2>/dev/null; rc=$?
  assert_exit 64 "$rc" "three args → 64"
}

test_help() {
  local out
  out=$("$SCRIPT" --help)
  assert_contains "$out" "Usage:" "--help prints usage"
}

test_first_round_success() {
  prep_dirs
  install_pi_stub
  set_pi 0 "looks good"
  local rc
  "$SCRIPT" tech-1 "$WT" "$STATE_DIR" main >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "first round → exit 0"
  assert_file_exists "$STATE_DIR/tech-1-review-1.md" "review-1.md written"
  assert_file_absent "$STATE_DIR/tech-1-review-1.md.partial" "partial file cleaned up"
  local content
  content=$(cat "$STATE_DIR/tech-1-review-1.md")
  assert_contains "$content" "looks good" "review output contains pi stdout"
  # Critical: nullglob with zero matches → ROUND=1 (not "0" or empty → file named review-.md).
  assert_file_absent "$STATE_DIR/tech-1-review-.md" "no file named review-.md (nullglob zero-match correctness)"
}

test_second_round() {
  prep_dirs
  install_pi_stub
  set_pi 0 "round 1"
  "$SCRIPT" tech-2 "$WT" "$STATE_DIR" main >/dev/null 2>&1
  set_pi 0 "round 2"
  local rc
  "$SCRIPT" tech-2 "$WT" "$STATE_DIR" main >/dev/null 2>&1; rc=$?
  assert_exit 0 "$rc" "second round → exit 0"
  assert_file_exists "$STATE_DIR/tech-2-review-2.md" "review-2.md written"
  local content
  content=$(cat "$STATE_DIR/tech-2-review-2.md")
  assert_contains "$content" "round 2" "round 2 output"
}

test_third_round_cap() {
  prep_dirs
  install_pi_stub
  # Pre-populate two rounds so a third call hits the cap.
  : > "$STATE_DIR/tech-3-review-1.md"
  : > "$STATE_DIR/tech-3-review-2.md"
  set_pi 0 "should not run"
  local rc
  "$SCRIPT" tech-3 "$WT" "$STATE_DIR" main >/dev/null 2>&1; rc=$?
  assert_exit 71 "$rc" "third round → exit 71 (cap)"
  assert_file_absent "$STATE_DIR/tech-3-review-3.md" "no review-3.md created"
  assert_eq "0" "$(stub_count pi)" "pi NOT invoked after cap"
}

test_pi_timeout_exit_124() {
  prep_dirs
  install_pi_stub
  set_pi 124 "partial before timeout"
  local rc
  "$SCRIPT" tech-4 "$WT" "$STATE_DIR" main >/dev/null 2>&1; rc=$?
  assert_exit 124 "$rc" "pi rc=124 → exit 124"
  # Partial output preserved at the slot file.
  assert_file_exists "$STATE_DIR/tech-4-review-1.md" "partial output preserved"
  local content
  content=$(cat "$STATE_DIR/tech-4-review-1.md")
  assert_contains "$content" "partial before timeout" "partial content preserved"
}

test_pi_failure_exit_70() {
  prep_dirs
  install_pi_stub
  set_pi 1 "error msg"
  local rc
  "$SCRIPT" tech-5 "$WT" "$STATE_DIR" main >/dev/null 2>&1; rc=$?
  assert_exit 70 "$rc" "pi rc=1 → exit 70"
  # Script should have marked the slot as failed (not left with partial content).
  assert_file_exists "$STATE_DIR/tech-5-review-1.md" "slot file exists"
  local content
  content=$(cat "$STATE_DIR/tech-5-review-1.md")
  assert_contains "$content" "peer-review failed" "failure marker in slot file"
}

test_slot_race_existing_file() {
  prep_dirs
  install_pi_stub
  # Simulate a concurrent run that already reserved the slot.
  printf 'preexisting\n' > "$STATE_DIR/tech-6-review-1.md"
  set_pi 0 "should not run"
  local rc
  "$SCRIPT" tech-6 "$WT" "$STATE_DIR" main >/dev/null 2>&1; rc=$?
  # ROUND=2 because one file already exists.
  assert_exit 0 "$rc" "existing slot → advances to ROUND=2, not 72"
  assert_file_exists "$STATE_DIR/tech-6-review-2.md" "round 2 file created"
  # Pre-existing file untouched.
  local pre
  pre=$(cat "$STATE_DIR/tech-6-review-1.md")
  assert_eq "preexisting" "$pre" "pre-existing round 1 file not overwritten"
}

test_prompt_contains_uppercase_ticket_and_base() {
  prep_dirs
  install_pi_stub
  set_pi 0 "ok"
  "$SCRIPT" tech-7 "$WT" "$STATE_DIR" develop >/dev/null 2>&1
  local log
  log=$(stub_log pi)
  assert_contains "$log" "TECH-7" "prompt includes uppercase ticket"
  assert_contains "$log" "origin/develop" "prompt includes base branch"
  assert_contains "$log" -- "--no-session" "pi invoked with --no-session"
  assert_contains "$log" -- "--no-skills" "pi invoked with --no-skills"
}

test_no_bare_or_true_swallow() {
  # Grep the script itself — this is a structural assertion that the
  # || true → swallow-everything pattern doesn't come back.
  assert_file_exists "$SCRIPT" "script file present"
  if grep -E '^\s*\|\| true\s*$' "$SCRIPT" > /dev/null; then
    fail "script contains bare '|| true' (swallow pattern regressed)"
  else
    pass "script has no bare '|| true' swallow pattern"
  fi
}

# ----- runner -----

run_test "bad args"                             test_bad_args
run_test "--help"                               test_help
run_test "first round success (nullglob 0→1)"   test_first_round_success
run_test "second round"                         test_second_round
run_test "third round → cap (exit 71)"          test_third_round_cap
run_test "pi rc=124 → exit 124, partial kept"   test_pi_timeout_exit_124
run_test "pi rc=1 → exit 70"                    test_pi_failure_exit_70
run_test "existing round file → advances"       test_slot_race_existing_file
run_test "prompt + pi argv contents"            test_prompt_contains_uppercase_ticket_and_base
run_test "no bare '|| true' regression"         test_no_bare_or_true_swallow

summary
