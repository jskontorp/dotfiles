#!/usr/bin/env bash
# Tests for scan.sh — cross-platform PID-cwd resolution.
# Verifies: with SESSION_SCAN_PROC_DIR set, the script uses readlink on the
# fake /proc; without it (and no real /proc), it falls back to lsof. Both paths
# produce equivalent output for equivalent input.
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

make_pgrep_stub() {
  local out_file="$1"
  cp "$out_file" "$STUB_STATE_DIR/pgrep-out.txt"
  make_stub pgrep '
cat "$STUB_STATE_DIR/pgrep-out.txt" 2>/dev/null || true
'
}

# ---- tests ----

test_proc_path_used_when_proc_dir_set() {
  local repo; repo=$(make_main_repo proc-test)
  local fake="$TMP/fakeproc"
  mkdir -p "$fake/42424"
  ln -sf "$repo" "$fake/42424/cwd"
  printf '%s\n' "42424 claude" > "$TMP/pgrep.txt"
  make_pgrep_stub "$TMP/pgrep.txt"
  # Stub lsof to FAIL — if the script falls back to lsof we'll know because
  # cwd resolution will return empty and the sibling will not be counted.
  make_stub lsof 'exit 1'
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; \
         export SESSION_SCAN_PROC_DIR="$fake"; \
         export SESSION_SCAN_OWN_PID=99999; \
         "$SCRIPT" 2>&1 )
  assert_contains "$out" "1 Claude/pi in same worktree" "readlink path resolved cwd from fake /proc"
  # lsof must not have been needed.
  assert_eq "0" "$(stub_count lsof)" "lsof NOT invoked when /proc path works"
}

test_lsof_path_used_when_proc_unavailable() {
  local repo; repo=$(make_main_repo lsof-test)
  # Point SESSION_SCAN_PROC_DIR at a nonexistent dir → script falls back to lsof.
  local missing="$TMP/no-proc-here"
  printf '%s\n' "33333 claude" > "$TMP/pgrep.txt"
  make_pgrep_stub "$TMP/pgrep.txt"
  # Stub lsof to return the same cwd that the proc-path test produced.
  make_stub lsof "
# Emit lsof -Fn-style output for any args.
echo p33333
echo fcwd
echo n$repo
"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; \
         export SESSION_SCAN_PROC_DIR="$missing"; \
         export SESSION_SCAN_OWN_PID=99999; \
         "$SCRIPT" 2>&1 )
  assert_contains "$out" "1 Claude/pi in same worktree" "lsof path resolved cwd"
  # lsof should have been invoked at least once.
  if [ "$(stub_count lsof)" -gt "0" ]; then
    pass "lsof invoked as fallback"
  else
    fail "lsof not invoked"
  fi
}

test_proc_and_lsof_paths_produce_same_output() {
  # Same PID, same cwd, same SCRIPT — proc path vs lsof path → identical output
  # for the SIBLINGS section.
  local repo; repo=$(make_main_repo equiv)
  local fake="$TMP/fakeproc"
  mkdir -p "$fake/55555"
  ln -sf "$repo" "$fake/55555/cwd"
  printf '%s\n' "55555 claude" > "$TMP/pgrep.txt"
  make_pgrep_stub "$TMP/pgrep.txt"

  # Run with proc path.
  make_stub lsof 'exit 1'
  local out_proc
  out_proc=$( cd "$repo" && unset TMUX TMUX_PANE; \
              export SESSION_SCAN_PROC_DIR="$fake"; \
              export SESSION_SCAN_OWN_PID=99999; \
              "$SCRIPT" 2>&1 )

  # Run with lsof path.
  make_stub lsof "
echo p55555
echo fcwd
echo n$repo
"
  local out_lsof
  out_lsof=$( cd "$repo" && unset TMUX TMUX_PANE; \
              export SESSION_SCAN_PROC_DIR="$TMP/no-such-dir"; \
              export SESSION_SCAN_OWN_PID=99999; \
              "$SCRIPT" 2>&1 )

  # Compare just the SIBLINGS section (drop header timestamps + DIRTY).
  local sib_proc sib_lsof
  sib_proc=$(printf '%s\n' "$out_proc"  | awk '/^SIBLINGS$/,/^$/')
  sib_lsof=$(printf '%s\n' "$out_lsof" | awk '/^SIBLINGS$/,/^$/')
  assert_eq "$sib_proc" "$sib_lsof" "SIBLINGS section identical from /proc and lsof paths"
}

# ---- runner ----

run_test "/proc path used when SESSION_SCAN_PROC_DIR set" test_proc_path_used_when_proc_dir_set
run_test "lsof path used when /proc unavailable"          test_lsof_path_used_when_proc_unavailable
run_test "/proc and lsof paths produce same output"       test_proc_and_lsof_paths_produce_same_output

summary
