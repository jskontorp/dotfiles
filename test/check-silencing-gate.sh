#!/bin/bash
# Tests for git/lib/silencing-gate.sh + git/hooks/commit-msg (JSK-36).
# Builds a tmprepo, stages synthetic diffs covering each token-shape
# category, and asserts hook accept/reject + trailer override + path
# allowlist + parser-floor drift.
#
# FIXTURE NOTE: this file embeds silencing tokens for testing. Do not load
# during execution turns (Rana priming). Hook-self-exempt via allowlist.
set -o pipefail

# Critical: this script invokes `git init`, `git commit`, etc. inside a
# tmprepo. When run from inside a pre-commit hook (e.g. via `just check`),
# git sets GIT_INDEX_FILE / GIT_DIR / GIT_WORK_TREE pointing at the *parent*
# commit's staging index and gitdir. Subprocesses inherit them, so a `git
# commit` inside the tmprepo writes through to the parent's index, silently
# producing an empty commit on the parent. Unset all git env vars so this
# script's git invocations operate strictly on the tmprepo it sets up.
# Regression class: pi/agent/AGENTS.md "GIT_INDEX_FILE poisoning ...".
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE_LIB="$REPO_DIR/git/lib/silencing-gate.sh"
HOOK="$REPO_DIR/git/hooks/commit-msg"
PATTERNS_MD="$REPO_DIR/pi/agent/review-patterns.md"

pass=0
fail=0
ok()   { printf "  ✅ %s\n" "$1"; pass=$((pass + 1)); }
bad()  { printf "  ❌ %s\n" "$1" >&2; fail=$((fail + 1)); }

# --- Unit: pattern parser ---------------------------------------------------
printf "unit: parser floor (canonical tokens must appear)\n"
export SILENCING_GATE_PATTERNS_MD="$PATTERNS_MD"
# shellcheck source=../git/lib/silencing-gate.sh
. "$GATE_LIB"

mapfile_compat() {
  local _arr_name="$1"; shift
  local _line _vals=()
  while IFS= read -r _line; do _vals+=("$_line"); done
  eval "$_arr_name=(\"\${_vals[@]}\")"
}

patterns=()
mapfile_compat patterns < <(silencing_gate_patterns)
[[ ${#patterns[@]} -gt 0 ]] && ok "parsed ${#patterns[@]} patterns" || bad "parser produced 0 patterns"

# Floor: representative tokens that must be expressible. The drift signal —
# if any of these vanish, the markdown source moved or was reformatted.
declare -a CANONICAL_PROBES=(
  "# noqa"
  "# type: ignore"
  "--no-verify"
  "@ts-ignore"
  "@ts-expect-error"
  "@pytest.mark.skip"
  "@pytest.mark.xfail"
  "// eslint-disable"
  "// eslint-disable-next-line"
  "@SuppressWarnings(foo)"
  "cast(x, int)"
  "pytest.skip('reason')"
  "it.skip('case', fn)"
  "describe.skip('group', fn)"
  "test.skip('case', fn)"
  "# type: ignore[arg-type]"
  "pytest -k 'not failing_test'"
  "--ignore=path/to/file"
)
for probe in "${CANONICAL_PROBES[@]}"; do
  hit=0
  for p in "${patterns[@]}"; do
    if printf '%s' "$probe" | grep -Eq -- "$p"; then hit=1; break; fi
  done
  [[ $hit -eq 1 ]] && ok "probe matched: '$probe'" || bad "no parsed pattern matched probe: '$probe'"
done

# Negative probes — these must NOT match (false-positive guards).
declare -a NEGATIVE_PROBES=(
  "Anyone can read this"          # 'Any' is not a parsed token (assertion-weakening section is outside sentinels)
  "object orientation"            # ditto for 'object'
  "I noqaed the bad line"         # '# noqa' requires the '#' literal
)
for probe in "${NEGATIVE_PROBES[@]}"; do
  hit=0
  for p in "${patterns[@]}"; do
    if printf '%s' "$probe" | grep -Eq -- "$p"; then hit=1; break; fi
  done
  [[ $hit -eq 0 ]] && ok "no false positive: '$probe'" || bad "false positive on: '$probe'"
done

# --- Integration: real commit-msg hook in a tmprepo ------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

git init -q -b main .
git config user.email "test@example.com"
git config user.name  "test"
git config commit.gpgsign false
mkdir -p .git/hooks pi/agent

# Symlink the hook + its lib + a copy of the patterns file. The hook resolves
# the lib via $(git rev-parse --show-toplevel)/git/lib/silencing-gate.sh, so
# we mirror the dotfiles layout inside the tmprepo.
mkdir -p git/hooks git/lib pi/agent
cp "$HOOK"        git/hooks/commit-msg
cp "$GATE_LIB"    git/lib/silencing-gate.sh
cp "$PATTERNS_MD" pi/agent/review-patterns.md
ln -sf "$PWD/git/hooks/commit-msg" .git/hooks/commit-msg
chmod +x .git/hooks/commit-msg

# Seed an initial commit so HEAD exists.
echo "seed" > seed.txt
git add seed.txt
git commit -q -m "seed"

# stage_and_commit <expected:pass|fail> <case-name> <commit-msg> <file:body...>
# Stages the listed files (one per arg, "path|content"), runs commit, asserts.
stage_and_commit() {
  local expect="$1" name="$2" msg="$3"; shift 3
  local f path content
  for f in "$@"; do
    path="${f%%|*}"; content="${f#*|}"
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    git add "$path"
  done
  if git commit -q -m "$msg" >/tmp/silgate-out 2>&1; then
    rc=0
  else
    rc=1
  fi
  # Reset to HEAD~ if commit succeeded so subsequent cases start clean.
  if [[ $rc -eq 0 ]]; then
    git reset -q --soft HEAD~1 || true
    git reset -q HEAD || true
    # Restore working tree to seed-only state.
    for f in "$@"; do
      path="${f%%|*}"
      git checkout -q -- "$path" 2>/dev/null || rm -f "$path"
    done
  else
    git reset -q HEAD || true
    for f in "$@"; do
      path="${f%%|*}"
      rm -f "$path"
    done
  fi
  if [[ "$expect" == "pass" && $rc -eq 0 ]]; then
    ok "case [$name] (commit succeeded as expected)"
  elif [[ "$expect" == "fail" && $rc -eq 1 ]]; then
    ok "case [$name] (commit refused as expected)"
  else
    bad "case [$name] expected=$expect rc=$rc"
    sed -n '1,20p' /tmp/silgate-out >&2
  fi
}

printf "\nintegration: synthetic diffs through the real hook\n"

# Fail: each token-shape category.
stage_and_commit fail "noqa-bare"        "add: bare noqa"               "src/a.py|x = 1  # noqa"
stage_and_commit fail "noqa-coded"       "add: coded noqa"              "src/b.py|x = 1  # noqa: E501"
stage_and_commit fail "type-ignore"      "add: type ignore"             "src/c.py|x = 1  # type: ignore"
stage_and_commit fail "type-ignore-code" "add: type ignore w/ code"     "src/d.py|x = 1  # type: ignore[arg-type]"
stage_and_commit fail "ts-ignore"        "add: ts-ignore"               "src/e.ts|// @ts-ignore"
stage_and_commit fail "ts-expect-err"    "add: ts-expect-error"         "src/f.ts|// @ts-expect-error"
stage_and_commit fail "eslint-next-line" "add: eslint disable"          "src/g.ts|// eslint-disable-next-line"
stage_and_commit fail "pytest-skip-deco" "add: pytest skip decorator"   "src/test_h.py|@pytest.mark.skip"
stage_and_commit fail "pytest-skip-call" "add: pytest skip call"        "src/test_i.py|pytest.skip('todo')"
stage_and_commit fail "jest-skip"        "add: jest it.skip"            "src/j.test.ts|it.skip('case', () => {})"
stage_and_commit fail "supress-warn"     "add: SuppressWarnings"        "src/K.java|@SuppressWarnings(\"all\")"
stage_and_commit fail "cast-silence"     "add: cast() to silence"       "src/l.py|y = cast(int, x)"
stage_and_commit fail "no-verify-script" "add: --no-verify in script"   "scripts/m.sh|git commit --no-verify"
stage_and_commit fail "skip-tests-flag"  "add: --skip-tests in script"  "scripts/n.sh|run --skip-tests"

# Pass: clean diff.
stage_and_commit pass "clean-diff" "add: clean code" "src/clean.py|def f(): return 1"

# Pass: trailer override (non-empty value required).
stage_and_commit pass "trailer-ok" "$(printf 'add: deliberate suppression\n\nSilencing-approved: third-party stub lacks types')" \
  "src/p.py|x = 1  # type: ignore"

# Fail: empty trailer value.
stage_and_commit fail "trailer-empty" "$(printf 'add: empty trailer\n\nSilencing-approved:')" \
  "src/q.py|x = 1  # type: ignore"

# Pass: SKIP env override.
SKIP_SILENCING_GATE=1 \
  stage_and_commit pass "skip-env" "add: skipped via env" \
  "src/r.py|x = 1  # noqa"

# Pass: allowlisted path (markdown legitimately discussing the token).
stage_and_commit pass "allowlist-md" "docs: discuss noqa" \
  "docs/policy.md|We forbid # noqa in production code."

# Pass: HEAD already contains the token; new diff doesn't add it.
echo "x = 1  # noqa" > src/preexisting.py
git add src/preexisting.py
SKIP_SILENCING_GATE=1 git commit -q -m "seed: pre-existing noqa"
unset SKIP_SILENCING_GATE
stage_and_commit pass "preexisting-untouched" "edit: append below pre-existing" \
  "src/preexisting.py|$(printf 'x = 1  # noqa\nz = 2')"

# Pass: merge commit source (synthetic — invoke hook directly with $2=merge).
echo "y = 2  # noqa" > src/merge_sim.py
git add src/merge_sim.py
echo "merge: simulated" > /tmp/silgate-msg
if "$HOOK" /tmp/silgate-msg merge >/tmp/silgate-out 2>&1; then
  ok "case [merge-source-skip] (hook bypassed for \$2=merge)"
else
  bad "case [merge-source-skip] hook fired on merge source"
  cat /tmp/silgate-out >&2
fi
git reset -q HEAD; rm -f src/merge_sim.py

# --- Fail-open guard: `silencing_gate_scan_staged_added` returning 2 ---
# When the patterns MD is missing / sentinels removed / awk slice broken,
# the function prints to stderr and returns 2 ("refusing to run"). The
# commit-msg hook must propagate that as exit 1, not swallow it via `|| true`.
# This case copies the patterns MD to a temp file with the begin sentinel
# renamed, points SILENCING_GATE_PATTERNS_MD at it, stages a clean diff, and
# asserts the commit is REFUSED — the gate must not fail open just because
# its catalogue went missing.
printf "\nintegration: fail-open guard (zero patterns ⇒ refuse, not allow)\n"
FAKE_MD="$(mktemp -t silgate-fake-md.XXXXXX).md"
sed -E 's/<!-- silencing-gate:begin/<!-- silencing-gate:DISARMED/' \
  "$PATTERNS_MD" > "$FAKE_MD"
echo "clean line" > src/failopen.py
git add src/failopen.py
if SILENCING_GATE_PATTERNS_MD="$FAKE_MD" git commit -q -m "failopen probe" >/tmp/silgate-failopen 2>&1; then
  bad "case [failopen-zero-patterns] commit accepted; gate failed open on missing patterns"
  cat /tmp/silgate-failopen >&2
else
  if grep -q "refusing to run" /tmp/silgate-failopen; then
    ok "case [failopen-zero-patterns] commit refused with sentinel error"
  else
    bad "case [failopen-zero-patterns] commit refused but without sentinel error msg"
    cat /tmp/silgate-failopen >&2
  fi
fi
rm -f "$FAKE_MD"
git reset -q HEAD; rm -f src/failopen.py

# --- Summary ---------------------------------------------------------------
printf "\n  %d passed, %d failed\n" "$pass" "$fail"
[[ $fail -eq 0 ]]
