#!/bin/bash
# Tests the chained refusal UX between pre-commit (secret-path gate, JSK-35)
# and commit-msg (silencing-gate, JSK-36) hooks. JSK-43.
#
# Why this test exists: a commit triggering both gates only surfaces the
# pre-commit refusal on the first attempt — commit-msg is never consulted
# because pre-commit aborts first. Users fixing both issues see two
# refusals across two iterations. A regression that broke either gate's
# exit-code propagation (so the chain swallowed one of the refusals) would
# land green without this test. The integration is otherwise unverified.
#
# FIXTURE NOTE: this file embeds the literal token `# noqa` for testing.
# Path is self-exempt via git/lib/silencing-gate.sh's allowlist regex
# (^test/check-hook-chain\.sh$).

set -uo pipefail

# Regression class: GIT_DIR / GIT_INDEX_FILE inheritance (JSK-44 enforces
# this idiom in any test/check-*.sh that invokes `git init`). The hook
# chain's tmprepo MUST be isolated from the parent shell's git env.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PRE_COMMIT="$REPO_DIR/git/hooks/pre-commit"
COMMIT_MSG="$REPO_DIR/git/hooks/commit-msg"
SECRET_LIB="$REPO_DIR/git/lib/secret-gate.sh"
SILENCING_LIB="$REPO_DIR/git/lib/silencing-gate.sh"
PATTERNS_MD="$REPO_DIR/pi/agent/review-patterns.md"

pass=0
fail=0
ok()  { printf "  ✅ %s\n" "$1"; pass=$((pass + 1)); }
bad() { printf "  ❌ %s\n" "$1" >&2; fail=$((fail + 1)); }

# Exact stderr signatures the test asserts on. Confirmed against current
# hook source on 2026-05-14 (JSK-43 review). Pinned strings — drift here
# is itself a regression worth catching by these tests failing loudly.
SECRET_GATE_SIG='secret-path gate: staged file(s) match'
SILENCING_GATE_SIG='silencing-gate: staged addition(s) match'

# --- Tmprepo setup ----------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cd "$TMP" || exit 1

git init -q -b main .
# Defend against a global `core.hooksPath` (AGENTS.md regression class,
# JSK-42): inherited from user config, it would silently bypass the
# symlinked .git/hooks/{pre-commit,commit-msg} below and the test would
# fail (or pass) for the wrong reason. Blind reviewer Q5 (batch-15).
git config --local --unset-all core.hooksPath 2>/dev/null || true
git config user.email "test@example.com"
git config user.name  "test"
git config commit.gpgsign false

mkdir -p .git/hooks pi/agent git/hooks git/lib

# Mirror the dotfiles layout inside the tmprepo. The hooks resolve
# CANONICAL_DIR via `git rev-parse --path-format=absolute --git-common-dir`
# then `dirname`, so canonical inside the tmprepo is $TMP. The libs must
# live at $TMP/git/lib/*; patterns MD at $TMP/pi/agent/review-patterns.md.
cp "$PRE_COMMIT"     git/hooks/pre-commit
cp "$COMMIT_MSG"     git/hooks/commit-msg
cp "$SECRET_LIB"     git/lib/secret-gate.sh
cp "$SILENCING_LIB"  git/lib/silencing-gate.sh
cp "$PATTERNS_MD"    pi/agent/review-patterns.md
ln -sf "$PWD/git/hooks/pre-commit" .git/hooks/pre-commit
ln -sf "$PWD/git/hooks/commit-msg" .git/hooks/commit-msg
chmod +x .git/hooks/pre-commit .git/hooks/commit-msg

# Stub `justfile` so the pre-commit hook's terminal `just check` step does
# not recurse into a non-existent dotfiles check suite. The real pre-commit
# ends with `( cd "$REPO_ROOT" && just check )`; in this tmprepo $REPO_ROOT
# is $TMP. Without a stub, `just check` fails → pre-commit exits 1 → Case 2
# (which expects pre-commit to PASS so commit-msg can fire) is unreachable.
# Discovered in JSK-43 plan review (guided reviewer crit 4).
printf 'check:\n\t@true\n' > justfile

# Seed an initial commit so HEAD exists.
echo "seed" > seed.txt
git add seed.txt
SKIP_SECRET_GATE=1 git commit -q -m "seed"

# --- Case 1: chained — pre-commit fires, commit-msg never runs --------------
# Stage two trigger files in the same commit:
#   - id_ed25519 matches secret-gate's `(^|/)id_(rsa|dsa|ecdsa|ed25519)$`.
#   - src/silenced.py contains `# noqa`, which would match silencing-gate.
# Pre-commit (secret-gate) runs first and refuses; commit-msg is not consulted.
printf "\nintegration: case 1 — pre-commit fires before commit-msg\n"

mkdir -p src
echo "BEGIN OPENSSH PRIVATE KEY" > id_ed25519
echo "x = 1  # noqa" > src/silenced.py
git add id_ed25519 src/silenced.py
if git commit -q -m "add: trigger both gates" >/tmp/jsk43-out 2>&1; then
  bad "case 1: commit succeeded — pre-commit should have refused"
else
  if grep -qF "$SECRET_GATE_SIG" /tmp/jsk43-out; then
    ok "case 1: pre-commit refused with secret-gate signature"
  else
    bad "case 1: commit refused but missing secret-gate signature; saw:"
    sed -n '1,10p' /tmp/jsk43-out >&2
  fi
  # Load-bearing negative assertion: silencing-gate signature MUST be absent.
  # If both signatures appear, the hook chain ordering is broken — commit-msg
  # would be running before pre-commit (or pre-commit not propagating exit 1).
  if grep -qF "$SILENCING_GATE_SIG" /tmp/jsk43-out; then
    bad "case 1: silencing-gate fired in same iteration as secret-gate (chain broken)"
  else
    ok "case 1: silencing-gate did NOT fire (chain ordering correct)"
  fi
fi

# --- Case 2: after the secret-path fix, silencing-gate now fires ------------
# `git rm --cached id_ed25519` simulates the user removing the bait file
# (not just unstaging — the file content on disk is also removed via the
# implicit `rm -f` from `git rm` without --cached... wait, --cached means
# index-only, working tree preserved. Add explicit `rm` for clarity in
# the test). Working tree state after: src/silenced.py exists and staged.
printf "\nintegration: case 2 — after secret-fix, silencing-gate fires\n"

git rm --cached -q id_ed25519
rm -f id_ed25519
# src/silenced.py is still staged from case 1's `git add` and not unstaged.
# Confirm only the silencing-gate fixture is staged now.
staged="$(git diff --cached --name-only | sort | tr '\n' ',')"
if [[ "$staged" != "src/silenced.py," ]]; then
  bad "case 2 precondition: staged set is '$staged', expected 'src/silenced.py,'"
else
  if git commit -q -m "add: trigger silencing only" >/tmp/jsk43-out 2>&1; then
    bad "case 2: commit succeeded — commit-msg should have refused"
  else
    if grep -qF "$SILENCING_GATE_SIG" /tmp/jsk43-out; then
      ok "case 2: silencing-gate refused on second iteration (chain reachable)"
    else
      bad "case 2: commit refused but missing silencing-gate signature; saw:"
      sed -n '1,10p' /tmp/jsk43-out >&2
    fi
  fi
fi

# --- Case 3: standalone commit-msg invocation (disambiguator) ---------------
# Calling the commit-msg hook directly bypasses pre-commit entirely. This
# confirms the silencing-gate refusal in case 2 is owned by commit-msg, not
# an artefact of pre-commit producing the same exit code. Provides users
# with a documented debugging path:
#   `git/hooks/commit-msg path/to/COMMIT_EDITMSG`
# to test their fix in isolation without re-staging.
printf "\nintegration: case 3 — standalone commit-msg (disambiguator)\n"

# src/silenced.py is still staged from case 2 (we expect that commit to
# have been refused, not reset — verify).
staged="$(git diff --cached --name-only | sort | tr '\n' ',')"
if [[ "$staged" != "src/silenced.py," ]]; then
  bad "case 3 precondition: staged set is '$staged', expected 'src/silenced.py,'"
else
  echo "add: standalone test" > /tmp/jsk43-msg
  if "$PWD/.git/hooks/commit-msg" /tmp/jsk43-msg >/tmp/jsk43-out 2>&1; then
    bad "case 3: standalone commit-msg succeeded — should have refused"
  else
    if grep -qF "$SILENCING_GATE_SIG" /tmp/jsk43-out; then
      ok "case 3: standalone commit-msg refused with silencing-gate signature"
    else
      bad "case 3: refused but missing silencing-gate signature; saw:"
      sed -n '1,10p' /tmp/jsk43-out >&2
    fi
  fi
fi

# --- Summary ----------------------------------------------------------------
echo
if (( fail == 0 )); then
  printf "  ✅ hook-chain: %d cases passed\n" "$pass"
  exit 0
else
  printf "  ❌ hook-chain: %d passed, %d failed\n" "$pass" "$fail" >&2
  exit 1
fi
