#!/usr/bin/env bash
# Tests for the TUI viability gate added in dispatch.sh.
#
# The gate requires TMUX_PANE + jq + session has ≥1 attached client +
# pane_height ≥ DELEGATE_MIN_PANE_HEIGHT (default 20). All four cells of
# the attached × tall matrix exercised end-to-end. Verification is via the
# pi-shim's argv file: --session-dir = TUI branch, --no-session = headless.
#
# A `tmux` shim on PATH responds to `display -p ... session_attached` /
# `pane_height` from env vars TEST_ATTACHED / TEST_HEIGHT, and exits 0 for
# any other invocation (so dispatch.sh's `tmux select-pane -T ... || true`
# and watcher.sh's send-keys calls are no-ops in the test).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCH="$SCRIPT_DIR/../scripts/dispatch.sh"
SHIM_DIR="$SCRIPT_DIR/fixtures"

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP tui-gate.test.sh — jq not installed"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; pkill -P $$ 2>/dev/null || true' EXIT

# Shim layout: bin/pi → pi-shim.sh, bin/tmux → tmux-stub script.
BIN="$TMP/bin"
mkdir -p "$BIN"
ln -s "$SHIM_DIR/pi-shim.sh" "$BIN/pi"
chmod +x "$SHIM_DIR/pi-shim.sh"

cat > "$BIN/tmux" <<'TMUXSTUB'
#!/usr/bin/env bash
# Minimal tmux stub for the TUI-gate test. Recognises the two queries
# dispatch.sh makes (#{session_attached}, #{pane_height}); everything else
# is a no-op exit 0 so guarded callers (`|| true`) don't error.
if [ "${1:-}" = "display" ] && [ "${2:-}" = "-p" ]; then
  # Args: display -p -t TARGET FORMAT
  fmt="${5:-}"
  case "$fmt" in
    '#{session_attached}') echo "${TEST_ATTACHED:-0}"; exit 0 ;;
    '#{pane_height}')      echo "${TEST_HEIGHT:-0}";   exit 0 ;;
  esac
fi
exit 0
TMUXSTUB
chmod +x "$BIN/tmux"

export PATH="$BIN:$PATH"

passed=0
failed=0
failures=()

# run_cell <name> <attached> <height> <expect: tui|headless>
run_cell() {
  local name="$1" attached="$2" height="$3" expect="$4"
  local cdir="$TMP/$name"
  mkdir -p "$cdir/results"
  echo "prompt" > "$cdir/prompt.txt"

  export TEST_ATTACHED="$attached"
  export TEST_HEIGHT="$height"
  export PI_SHIM_ARGS_FILE="$cdir/results/task-1.args"
  export PI_SHIM_MODE="exit0"
  # The shim writes a session file iff PI_SHIM_SESSION_DIR is set; we set it
  # only for the TUI cell so watcher.sh sees a happy-path terminal condition.
  if [ "$expect" = "tui" ]; then
    export PI_SHIM_SESSION_DIR="$cdir/results/../sessions/task-1"
  else
    unset PI_SHIM_SESSION_DIR
  fi

  # DELEGATE_ASSUME_TTY=1 bypasses dispatch.sh's `[ -t 1 ]` tty guard
  # (added 2026-05-22). The test redirects stdout to a log file, so the
  # tty check would otherwise force USE_TUI=false for every cell and
  # collapse the matrix. Production callers must never set this.
  TMUX_PANE="%999" DELEGATE_ASSUME_TTY=1 \
    "$DISPATCH" task-1 "$cdir" 0 "$cdir/prompt.txt" "$cdir/results" "" "" \
    >"$cdir/dispatch.log" 2>&1 || true

  local args
  args="$(cat "$cdir/results/task-1.args" 2>/dev/null || echo MISSING)"

  case "$expect" in
    tui)
      if echo "$args" | grep -q '^--session-dir$' && ! echo "$args" | grep -q '^--no-session$'; then
        passed=$((passed+1))
      else
        failures+=("$name (attached=$attached height=$height expect=tui): argv was '$args'")
        failed=$((failed+1))
      fi
      ;;
    headless)
      if echo "$args" | grep -q '^--no-session$' && ! echo "$args" | grep -q '^--session-dir$'; then
        passed=$((passed+1))
      else
        failures+=("$name (attached=$attached height=$height expect=headless): argv was '$args'")
        failed=$((failed+1))
      fi
      ;;
  esac
}

# Four cells of the attached × pane_height matrix.
# Default DELEGATE_MIN_PANE_HEIGHT is 20; use 24 (tall) and 6 (short).
run_cell detached-tall  0 24 headless
run_cell detached-short 0  6 headless
run_cell attached-tall  1 24 tui
run_cell attached-short 1  6 headless

# Bonus cell: DELEGATE_MIN_PANE_HEIGHT override allows lower threshold.
DELEGATE_MIN_PANE_HEIGHT=5 \
  run_cell override-allows-short 1 6 tui

# tty guard (2026-05-22 oracle/odev fix): even with attached + tall pane +
# TMUX_PANE set, dispatch must refuse TUI when stdout isn't a tty. Run
# without DELEGATE_ASSUME_TTY and assert the headless branch is taken.
name=tty-guard-no-tty
cdir="$TMP/$name"
mkdir -p "$cdir/results"
echo "prompt" > "$cdir/prompt.txt"
export TEST_ATTACHED=1
export TEST_HEIGHT=24
export PI_SHIM_ARGS_FILE="$cdir/results/task-1.args"
export PI_SHIM_MODE="exit0"
unset PI_SHIM_SESSION_DIR
TMUX_PANE="%999" \
  "$DISPATCH" task-1 "$cdir" 0 "$cdir/prompt.txt" "$cdir/results" "" "" \
  >"$cdir/dispatch.log" 2>&1 || true
args="$(cat "$cdir/results/task-1.args" 2>/dev/null || echo MISSING)"
if echo "$args" | grep -q '^--no-session$' && ! echo "$args" | grep -q '^--session-dir$'; then
  passed=$((passed+1))
else
  failures+=("tty-guard-no-tty (stdout not a tty, expect=headless): argv was '$args'")
  failed=$((failed+1))
fi

echo ""
echo "tui-gate: passed=$passed failed=$failed"
if [ "$failed" -gt 0 ]; then
  printf '  - %s\n' "${failures[@]}"
  exit 1
fi
exit 0
