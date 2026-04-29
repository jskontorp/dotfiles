#!/usr/bin/env bash
# helpers.sh — sandbox + assert helpers for session-scan script tests.
# Sourced by each *.test.sh. Target: ≤200 LOC (trigger for re-evaluating bats).

# Caller must set SCRIPTS_DIR before sourcing.
: "${SCRIPTS_DIR:?SCRIPTS_DIR must be set by the test file}"

TESTS_PASS=0
TESTS_FAIL=0
FAILED_DESCS=()
CURRENT_TEST=""

_here_test() { [ -n "$CURRENT_TEST" ] && echo " ($CURRENT_TEST)" || true; }

pass() { TESTS_PASS=$((TESTS_PASS + 1)); printf '  ✅ %s%s\n' "$1" "$(_here_test)"; }
fail() {
  TESTS_FAIL=$((TESTS_FAIL + 1))
  FAILED_DESCS+=("$CURRENT_TEST: $1")
  printf '  ❌ %s%s\n' "$1" "$(_here_test)" >&2
}

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then pass "$msg"
  else fail "$msg (expected=$(printf '%q' "$expected") actual=$(printf '%q' "$actual"))"; fi
}

assert_exit() {
  local expected="$1" actual="$2" msg="$3"
  if [ "$expected" = "$actual" ]; then pass "$msg"
  else fail "$msg (expected rc=$expected actual rc=$actual)"; fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$msg"
  else fail "$msg (missing '$needle' in output)"; fi
}

assert_file_exists() {
  if [ -e "$1" ]; then pass "$2"
  else fail "$2 ($1 missing)"; fi
}

assert_file_absent() {
  if [ ! -e "$1" ]; then pass "$2"
  else fail "$2 ($1 unexpectedly exists)"; fi
}

# ----- sandbox -----

setup_sandbox() {
  TMP=$(mktemp -d 2>/dev/null || mktemp -d -t session-scan-test)
  export TMP
  export SANDBOX_HOME="$TMP/home"
  export STUB_DIR="$TMP/stubs"
  export STUB_STATE_DIR="$TMP/stubs-state"
  mkdir -p "$SANDBOX_HOME" "$STUB_DIR" "$STUB_STATE_DIR"

  # Isolate git entirely from the user's real config.
  export HOME="$SANDBOX_HOME"
  export GIT_CONFIG_GLOBAL="$SANDBOX_HOME/.gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[user]
	name = test
	email = test@example.com
[init]
	defaultBranch = main
EOF

  # Prepend stubs; keep real PATH so scripts can still find git/node/awk/etc.
  export ORIG_PATH="$PATH"
  export PATH="$STUB_DIR:$PATH"
}

teardown_sandbox() {
  [ -n "${TMP:-}" ] && rm -rf "$TMP"
  [ -n "${ORIG_PATH:-}" ] && export PATH="$ORIG_PATH"
}

# ----- stubs -----

# make_stub <name> <body>
# Body has access to "$@", $STUB_STATE_DIR. Its first line should NOT be a shebang.
# The stub auto-logs argv to $STUB_STATE_DIR/<name>.log and bumps $STUB_STATE_DIR/<name>.count.
make_stub() {
  local name="$1" body="$2"
  local path="$STUB_DIR/$name"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -u\n'
    printf 'name=%q\n' "$name"
    printf 'printf "%%s\\n" "$*" >> "$STUB_STATE_DIR/$name.log"\n'
    printf 'c="$STUB_STATE_DIR/$name.count"\n'
    printf 'n=$(( $(cat "$c" 2>/dev/null || echo 0) + 1 ))\n'
    printf 'echo "$n" > "$c"\n'
    printf '%s\n' "$body"
  } > "$path"
  chmod +x "$path"
}

stub_log()   { cat "$STUB_STATE_DIR/$1.log" 2>/dev/null || true; }
stub_count() { cat "$STUB_STATE_DIR/$1.count" 2>/dev/null || echo 0; }

# ----- driver -----

run_test() {
  CURRENT_TEST="$1"
  shift
  printf '\n▸ %s\n' "$CURRENT_TEST"
  setup_sandbox
  "$@"
  teardown_sandbox
  CURRENT_TEST=""
}

summary() {
  echo ""
  echo "----- $(basename "${0%.test.sh}").test.sh -----"
  echo "  passed: $TESTS_PASS"
  echo "  failed: $TESTS_FAIL"
  if [ "$TESTS_FAIL" -gt 0 ]; then
    echo "  failures:"
    for f in "${FAILED_DESCS[@]}"; do echo "    - $f"; done
    return 1
  fi
  return 0
}
