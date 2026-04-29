#!/usr/bin/env bash
# Tests for scan.sh — SIBLINGS detection.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/.."
. "$SCRIPT_DIR/lib/helpers.sh"

SCRIPT="$SCRIPTS_DIR/scan.sh"

# ---- helpers ----

make_main_repo() {
  local name="$1"
  local path="$TMP/$name"
  git init -q -b main "$path"
  ( cd "$path" && git commit --allow-empty -q -m init )
  ( cd "$path" && pwd -P )
}

# Build a fake /proc-like dir at $TMP/fakeproc with one pid_dir per entry.
# Each entry: "PID CWD". Creates $fakeproc/$pid/cwd as a symlink to CWD.
build_fake_proc() {
  local fakeproc="$TMP/fakeproc"
  mkdir -p "$fakeproc"
  for entry in "$@"; do
    local pid; pid=$(printf '%s' "$entry" | awk '{print $1}')
    local cwd; cwd=$(printf '%s' "$entry" | cut -d' ' -f2-)
    mkdir -p "$fakeproc/$pid"
    ln -sf "$cwd" "$fakeproc/$pid/cwd"
  done
  echo "$fakeproc"
}

# Stub pgrep to emit pre-baked lines from $STUB_STATE_DIR/pgrep-out.txt.
# Tests write the desired output there (in `pgrep -lf` format: "PID first-tok rest").
make_pgrep_stub() {
  local out_file="$1"
  cp "$out_file" "$STUB_STATE_DIR/pgrep-out.txt"
  make_stub pgrep '
# Always return our pre-baked output regardless of args.
cat "$STUB_STATE_DIR/pgrep-out.txt" 2>/dev/null || true
'
}

# ---- tests ----

test_sibling_claude_same_worktree() {
  local repo; repo=$(make_main_repo same-claude)
  local fake; fake=$(build_fake_proc "91234 $repo")
  printf '%s\n' "91234 claude" > "$TMP/pgrep.txt"
  make_pgrep_stub "$TMP/pgrep.txt"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; \
         export SESSION_SCAN_PROC_DIR="$fake"; \
         export SESSION_SCAN_OWN_PID=99999; \
         "$SCRIPT" 2>&1 )
  assert_contains "$out" "1 Claude/pi in same worktree" "count = 1 same worktree"
  assert_contains "$out" "0 in sibling worktrees" "count = 0 sibling worktrees"
  assert_contains "$out" "⚠" "warning glyph present"
  assert_contains "$out" "PID 91234" "PID 91234 reported"
  assert_contains "$out" "editing this checkout" "warning line uses 'editing this checkout' phrasing"
}

test_sibling_pi_same_worktree() {
  local repo; repo=$(make_main_repo same-pi)
  local fake; fake=$(build_fake_proc "77777 $repo")
  printf '%s\n' "77777 pi" > "$TMP/pgrep.txt"
  make_pgrep_stub "$TMP/pgrep.txt"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; \
         export SESSION_SCAN_PROC_DIR="$fake"; \
         export SESSION_SCAN_OWN_PID=99999; \
         "$SCRIPT" 2>&1 )
  assert_contains "$out" "1 Claude/pi in same worktree" "pi process counted as sibling"
  assert_contains "$out" "PID 77777" "pi PID reported in warning"
}

test_sibling_in_sibling_worktree() {
  local repo; repo=$(make_main_repo sib-w)
  ( cd "$repo" && git worktree add -q -b feature "$repo-feature" )
  local sib; sib=$(cd "$repo-feature" && pwd -P)
  local fake; fake=$(build_fake_proc "55555 $sib")
  printf '%s\n' "55555 claude" > "$TMP/pgrep.txt"
  make_pgrep_stub "$TMP/pgrep.txt"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; \
         export SESSION_SCAN_PROC_DIR="$fake"; \
         export SESSION_SCAN_OWN_PID=99999; \
         "$SCRIPT" 2>&1 )
  assert_contains "$out" "0 Claude/pi in same worktree" "no same-worktree match"
  assert_contains "$out" "1 in sibling worktrees" "1 in sibling worktrees"
  # No ⚠ warning line should be present in SIBLINGS section beyond the optional none-line.
  if printf '%s' "$out" | grep -q "SAME WORKTREE"; then
    fail "SAME WORKTREE label present for sibling-only case"
  else
    pass "SAME WORKTREE label absent (sibling-only)"
  fi
}

test_sibling_in_unrelated_path_excluded() {
  local repo; repo=$(make_main_repo unrel)
  local elsewhere="$TMP/somewhere-else"
  mkdir -p "$elsewhere"
  local fake; fake=$(build_fake_proc "88888 $elsewhere")
  printf '%s\n' "88888 claude" > "$TMP/pgrep.txt"
  make_pgrep_stub "$TMP/pgrep.txt"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; \
         export SESSION_SCAN_PROC_DIR="$fake"; \
         export SESSION_SCAN_OWN_PID=99999; \
         "$SCRIPT" 2>&1 )
  assert_contains "$out" "0 Claude/pi in same worktree, 0 in sibling worktrees" "unrelated agent ignored entirely"
}

test_self_exclusion() {
  local repo; repo=$(make_main_repo selfex)
  # Use the test process's actual PID (same as SESSION_SCAN_OWN_PID we'll set)
  # plus a "real" sibling. Self should NOT appear; sibling should.
  local fake; fake=$(build_fake_proc "12345 $repo" "67890 $repo")
  # pgrep emits both. Script's exclude-list will be {12345}.
  printf '%s\n' "12345 claude" "67890 claude" > "$TMP/pgrep.txt"
  make_pgrep_stub "$TMP/pgrep.txt"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; \
         export SESSION_SCAN_PROC_DIR="$fake"; \
         export SESSION_SCAN_OWN_PID=12345; \
         "$SCRIPT" 2>&1 )
  assert_contains "$out" "1 Claude/pi in same worktree" "self excluded → only the other counted"
  assert_contains "$out" "PID 67890" "non-self sibling reported"
  if printf '%s' "$out" | grep -q "PID 12345"; then
    fail "self PID 12345 leaked into SIBLINGS"
  else
    pass "self PID 12345 excluded from SIBLINGS"
  fi
}

test_non_agent_processes_filtered_out() {
  local repo; repo=$(make_main_repo notagent)
  # pgrep's regex (claude|pi) matches "spider" and "tmux a -t pi-sessions" too.
  # The script must reject these because their first-token basename is not claude/pi.
  local fake; fake=$(build_fake_proc "11111 $repo" "22222 $repo")
  printf '%s\n' \
    "11111 spider --port 8080" \
    "22222 tmux a -t pi-sessions" \
    > "$TMP/pgrep.txt"
  make_pgrep_stub "$TMP/pgrep.txt"
  local out
  out=$( cd "$repo" && unset TMUX TMUX_PANE; \
         export SESSION_SCAN_PROC_DIR="$fake"; \
         export SESSION_SCAN_OWN_PID=99999; \
         "$SCRIPT" 2>&1 )
  assert_contains "$out" "0 Claude/pi in same worktree, 0 in sibling worktrees" \
    "non-agent matches (spider, tmux) filtered out"
}

# ---- runner ----

run_test "sibling claude in same worktree"      test_sibling_claude_same_worktree
run_test "sibling pi in same worktree"          test_sibling_pi_same_worktree
run_test "sibling in sibling worktree"          test_sibling_in_sibling_worktree
run_test "sibling in unrelated path"            test_sibling_in_unrelated_path_excluded
run_test "self-exclusion"                       test_self_exclusion
run_test "non-agent processes filtered"         test_non_agent_processes_filtered_out

summary
