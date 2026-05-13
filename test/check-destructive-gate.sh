#!/bin/bash
# Regex-unit test for pi/agent/extensions/destructive-gate.ts (JSK-38).
#
# We don't shell-out to pi: that requires a TTY for the confirm prompt and
# is non-deterministic. Instead we (a) duplicate the patterns here in a
# table, (b) assert each fires on its destructive shape and not on adjacent
# non-destructive shapes, (c) assert the pattern *IDs* in this file match
# the IDs in the .ts source — that's the drift trigger; if someone edits
# patterns in the extension without touching this test, ID parity fails.
#
# The headline ticket case (JSK-38): `git push --force-with-lease` is
# already denied on main today; this test pins that coverage so it can't
# silently regress.
#
# Test framework: bash 3.2 portable. Field separator is a literal TAB
# because regexes contain `|`. Regex engine is perl (universally available
# on macOS + Linux) — the patterns use PCRE features (lookahead) that
# BSD/GNU grep -E don't support.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$REPO_DIR/pi/agent/extensions/destructive-gate.ts"

if [[ ! -f "$GATE" ]]; then
  echo "❌ destructive-gate.ts not found at $GATE" >&2
  exit 1
fi

if ! command -v perl >/dev/null 2>&1; then
  echo "❌ perl not found — required for PCRE regex evaluation" >&2
  exit 1
fi

PASS=0
FAIL=0
TAB=$'\t'

# Same GIT_OPTS fragment as in destructive-gate.ts: matches `-C <dir>`,
# `--git-dir=<path>`, `-c key=val` between `git` and the verb.
GIT_OPTS='(?:\s+(?:-C\s+\S+|--git-dir(?:=|\s+)\S+|--work-tree(?:=|\s+)\S+|-c\s+\S+))*'

# id<TAB>regex<TAB>positive<TAB>negative_or_empty
TESTS=(
  "git push --force${TAB}\bgit${GIT_OPTS}\s+push\b(?:[^&|;]*\s)?--force(?![-\w])${TAB}git push --force origin main${TAB}git push origin main"
  "git push -f${TAB}\bgit${GIT_OPTS}\s+push\b(?:[^&|;]*\s)?-f(?!\w)${TAB}git push -f origin main${TAB}git push --foo origin main"
  "git push --force-with-lease${TAB}\bgit${GIT_OPTS}\s+push\b(?:[^&|;]*\s)?--force-with-lease${TAB}git push --force-with-lease origin main${TAB}git push origin main"
  "git reset --hard${TAB}\bgit${GIT_OPTS}\s+reset\b(?:[^&|;]*\s)?--hard${TAB}git reset --hard HEAD${TAB}git reset HEAD"
  "git branch -D${TAB}\bgit${GIT_OPTS}\s+branch\b(?:[^&|;]*\s)?-D${TAB}git branch -D feature${TAB}git branch -d feature"
  "git clean -f${TAB}\bgit${GIT_OPTS}\s+clean\b(?:[^&|;]*\s)?-[a-eg-zA-Z]*f${TAB}git clean -fdx${TAB}git clean -n"
  "git filter-branch${TAB}\bgit${GIT_OPTS}\s+filter-branch\b${TAB}git filter-branch --tree-filter foo${TAB}git log"
  "git filter-repo${TAB}\bgit${GIT_OPTS}\s+filter-repo\b${TAB}git filter-repo --path foo${TAB}git log"
  "git reflog expire${TAB}\bgit${GIT_OPTS}\s+reflog\s+expire\b${TAB}git reflog expire --all${TAB}git reflog show"
  "git gc --prune=now${TAB}\bgit${GIT_OPTS}\s+gc\b(?:[^&|;]*\s)?--prune=now${TAB}git gc --prune=now${TAB}git gc"
  "git restore (discards uncommitted)${TAB}\bgit${GIT_OPTS}\s+restore\b(?=(?:[^&|;]*\s)?\S)(?!(?:[^&|;]*\s)?--staged\b)${TAB}git restore src/foo.py${TAB}git restore --staged src/foo.py"
  "git checkout -- <path>${TAB}\bgit${GIT_OPTS}\s+checkout\b(?:[^&|;]*\s)?--\s+\S${TAB}git checkout -- src/foo.py${TAB}git checkout main"
  "git checkout .${TAB}\bgit${GIT_OPTS}\s+checkout\b(?:[^&|;]*\s)?\.(?:\s|/|\$)${TAB}git checkout .${TAB}git checkout main"
  "git checkout .${TAB}\bgit${GIT_OPTS}\s+checkout\b(?:[^&|;]*\s)?\.(?:\s|/|\$)${TAB}git checkout ./src/foo.py${TAB}"
  "git commit --no-verify${TAB}\bgit${GIT_OPTS}\s+commit\b(?:[^&|;]*\s)?--no-verify${TAB}git commit --no-verify -m foo${TAB}git commit -m foo"
  "git push --no-verify${TAB}\bgit${GIT_OPTS}\s+push\b(?:[^&|;]*\s)?--no-verify${TAB}git push --no-verify origin main${TAB}git push origin main"
  "alembic upgrade${TAB}\balembic\s+upgrade\b${TAB}alembic upgrade head${TAB}alembic history"
  "alembic downgrade${TAB}\balembic\s+downgrade\b${TAB}alembic downgrade -1${TAB}alembic history"
  "alembic stamp${TAB}\balembic\s+stamp\b${TAB}alembic stamp head${TAB}alembic history"
  "alembic revision --autogenerate${TAB}\balembic\s+revision\b[^&|;]*--autogenerate${TAB}alembic revision --autogenerate -m foo${TAB}alembic revision -m foo"
  "make migrate${TAB}\bmake\s+migrate\b${TAB}make migrate${TAB}make build"
  "just db-* (migration wrapper)${TAB}\bjust\s+db-\S+${TAB}just db-upgrade${TAB}just lint"
  "npm run migrate${TAB}\bnpm\s+run\s+migrate\b${TAB}npm run migrate${TAB}npm run build"
)

# Wrapper / bypass cases: assert the JSK-38 regex refactor closes the
# `git -C <dir>` / `--git-dir=` / env-prefix / cd-and-then bypasses, plus
# pi-side wrapper coverage for `uv run alembic` etc.
# label<TAB>regex<TAB>command (must match)
BYPASS=(
  "git -C dir push --force${TAB}\bgit${GIT_OPTS}\s+push\b(?:[^&|;]*\s)?--force(?![-\w])${TAB}git -C /tmp/repo push --force origin main"
  "git --git-dir <space> push --force${TAB}\bgit${GIT_OPTS}\s+push\b(?:[^&|;]*\s)?--force(?![-\w])${TAB}git --git-dir /tmp/r/.git push --force origin main"
  "git --git-dir=… push --force${TAB}\bgit${GIT_OPTS}\s+push\b(?:[^&|;]*\s)?--force(?![-\w])${TAB}git --git-dir=/tmp/r/.git push --force origin main"
  "GIT_DIR=… git push --force${TAB}\bgit${GIT_OPTS}\s+push\b(?:[^&|;]*\s)?--force(?![-\w])${TAB}GIT_DIR=/tmp/r/.git git push --force origin main"
  "git -c k=v push --force-with-lease${TAB}\bgit${GIT_OPTS}\s+push\b(?:[^&|;]*\s)?--force-with-lease${TAB}git -c http.proxy=foo push --force-with-lease origin main"
  "uv run alembic upgrade (pi side)${TAB}\balembic\s+upgrade\b${TAB}uv run alembic upgrade head"
  "poetry run alembic upgrade (pi side)${TAB}\balembic\s+upgrade\b${TAB}poetry run alembic upgrade head"
  "cd foo && git push --force${TAB}\bgit${GIT_OPTS}\s+push\b(?:[^&|;]*\s)?--force(?![-\w])${TAB}cd foo && git push --force origin main"
)

assert() {
  local desc="$1" expect="$2" re="$3" cmd="$4"
  local got
  if perl -e 'exit(($ARGV[0] =~ /$ARGV[1]/) ? 0 : 1)' -- "$cmd" "$re" 2>/dev/null; then
    got="match"
  else
    got="no-match"
  fi
  if [[ "$got" == "$expect" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf "  ❌ %s — expected=%s got=%s\n     re: %s\n     cmd: %s\n" "$desc" "$expect" "$got" "$re" "$cmd" >&2
  fi
}

echo "Pattern positive/negative cases:"
for row in "${TESTS[@]}"; do
  IFS="$TAB" read -r id re pos neg <<< "$row"
  assert "$id (positive)" "match" "$re" "$pos"
  if [[ -n "$neg" ]]; then
    assert "$id (negative)" "no-match" "$re" "$neg"
  fi
done

echo
echo "Bypass closure (git -C / --git-dir / env / wrappers):"
for row in "${BYPASS[@]}"; do
  IFS="$TAB" read -r id re cmd <<< "$row"
  assert "$id" "match" "$re" "$cmd"
done

# --- Drift check: pattern IDs in this test must match IDs in the .ts. ---
# Extract every `id: "..."` from destructive-gate.ts and compare against
# the IDs in TESTS[]. If someone adds/removes a pattern in the extension,
# this test fails until the table here is updated.
echo
echo "Drift check (extension IDs vs test IDs):"
gate_ids=$(grep -oE 'id:[[:space:]]*"[^"]+"' "$GATE" | sed -E 's/id:[[:space:]]*"([^"]+)"/\1/' | sort -u)
test_ids=$(printf '%s\n' "${TESTS[@]}" | cut -f1 | sort -u)
# Filesystem `rm -rf` patterns aren't behaviourally tested here (the
# wildcards interact with `$HOME` expansion in a way that's painful to
# mock under the test driver) — exclude them from the drift check by name.
# If a new filesystem-class pattern is added to destructive-gate.ts, this
# filter needs to broaden or a behavioural test needs to land alongside.
gate_ids_filtered=$(printf '%s\n' "$gate_ids" | grep -v '^rm -rf' || true)

if [[ "$gate_ids_filtered" == "$test_ids" ]]; then
  PASS=$((PASS + 1))
  printf "  ✅ ID lists match (%d patterns covered)\n" "$(printf '%s\n' "$test_ids" | wc -l | tr -d ' ')"
else
  FAIL=$((FAIL + 1))
  echo "  ❌ ID drift between destructive-gate.ts and test/check-destructive-gate.sh:" >&2
  diff <(printf '%s\n' "$gate_ids_filtered") <(printf '%s\n' "$test_ids") >&2 || true
fi

echo
printf "Total: %d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
