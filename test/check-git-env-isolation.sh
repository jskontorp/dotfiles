#!/usr/bin/env bash
# test/check-git-env-isolation.sh
#
# Enforces the GIT_DIR / GIT_INDEX_FILE unset idiom for any shell script under
# test/, git/lib/, or git/hooks/ that builds its own git repo (via `git init`,
# `git worktree add`, or `git clone`).
#
# Background: pre-commit hook subprocesses inherit GIT_INDEX_FILE / GIT_DIR /
# GIT_WORK_TREE from the parent commit. A helper script that runs `git init`
# in a tmprepo to set up an integration fixture will — without the unset —
# silently target the *parent* repo's gitdir/index instead of the tmprepo,
# corrupting it. Same failure mode for `git worktree add` and `git clone`.
#
# Two incidents in batch 13 (May 13 2026):
#   - Empty commit 196879d on main: `git worktree add` poisoning during the
#     JSK-42 cherry-pick.
#   - Canonical .git/config corruption (bare=true, fake user) during the
#     JSK-36 cherry-pick on 8f22955: `git init` + `git config` in
#     check-silencing-gate.sh writing through to canonical via inherited
#     GIT_DIR.
#
# This is the *static* half of closing the regression class (JSK-44). The
# *runtime* half — snapshot-and-compare the staged set across hook entry
# and exit — is tracked in JSK-46. Documented in pi/agent/AGENTS.md
# "Known regression classes".
#
# Trigger set is deliberately narrow: only commands that *build* a new repo
# need this isolation. Read-only ops against the calling repo (`git diff
# --cached`, `git log`, `git config --get`) correctly inherit GIT_DIR and
# are intentionally allowed to.
#
# Usage: bash test/check-git-env-isolation.sh

set -uo pipefail

# Eat own dogfood: the test-the-test phase below writes a fixture file
# containing the literal text "git init". When this lint scans itself
# (test/*.sh is in scope), the trigger fires on that heredoc line and the
# unset line MUST appear earlier. The fact that this script never actually
# executes git init from its own shell is irrelevant — the rule is checked
# statically, on file text. This unset line is the dogfood.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Triggers that signal "I am building my own repo and need to be isolated
# from the calling shell's git env vars". Match is a substring within a
# non-comment line (lines whose first non-whitespace character is `#` are
# skipped before matching).
TRIGGERS=(
  'git init'
  'git worktree add'
  'git clone'
)

# The canonical unset line required before any trigger appears.
# If a script needs a different variant (subset of vars, different order),
# extend ALLOWED_UNSET_LINES below with a justification comment.
REQUIRED_UNSET_LINE='unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR'

# Documented variants. Add entries here with rationale; do not extend silently.
ALLOWED_UNSET_LINES=(
  "$REQUIRED_UNSET_LINE"
  # (no variants yet)
)

# --- check_file ------------------------------------------------------------
# Returns 0 if file passes, 1 otherwise. Sets `violation` (global) on failure.
violation=''
check_file() {
  local path="$1"
  local unset_ln=''
  local trigger_ln tpattern allowed

  # Find earliest line matching any allowed unset variant. Strip leading
  # whitespace + leading-comment lines before comparing.
  for allowed in "${ALLOWED_UNSET_LINES[@]}"; do
    local found
    found="$(awk -v needle="$allowed" '
      {
        s=$0
        sub(/^[[:space:]]+/, "", s)
        if (s ~ /^#/) next
        if (s == needle) { print NR; exit }
      }
    ' "$path")"
    if [[ -n "$found" ]]; then
      if [[ -z "$unset_ln" || "$found" -lt "$unset_ln" ]]; then
        unset_ln="$found"
      fi
    fi
  done

  for tpattern in "${TRIGGERS[@]}"; do
    trigger_ln="$(awk -v pat="$tpattern" '
      {
        s=$0
        sub(/^[[:space:]]+/, "", s)
        if (s ~ /^#/) next
        if (index($0, pat) > 0) { print NR; exit }
      }
    ' "$path")"

    [[ -z "$trigger_ln" ]] && continue

    if [[ -z "$unset_ln" ]]; then
      violation="${path}:${trigger_ln}: contains trigger '${tpattern}' but missing required line: '${REQUIRED_UNSET_LINE}'"
      return 1
    fi
    if (( unset_ln >= trigger_ln )); then
      violation="${path}:${trigger_ln}: trigger '${tpattern}' appears before unset line (at L${unset_ln})"
      return 1
    fi
  done

  return 0
}

# --- Phase 1: scan real surface --------------------------------------------
errors=0

files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(
  {
    find "$REPO_DIR/test" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null
    find "$REPO_DIR/git/lib" -maxdepth 1 -type f -print0 2>/dev/null
    find "$REPO_DIR/git/hooks" -maxdepth 1 -type f -print0 2>/dev/null
  }
)

printf "  scanning %d files (test/*.sh + git/lib/* + git/hooks/*)\n" "${#files[@]}"
for f in "${files[@]}"; do
  if ! check_file "$f"; then
    printf "  ❌ %s\n" "$violation" >&2
    errors=$((errors + 1))
  fi
done
if (( errors == 0 )); then
  printf "  ✅ phase 1: all in-scope files satisfy the unset-before-trigger rule\n"
fi

# --- Phase 2: test-the-test ------------------------------------------------
# Synthetic fixture: a file with `git init` but no unset. The lint MUST
# refuse it. Phase 2 PASSES when the lint correctly fails on the fixture
# and the failure message is well-formed (mentions the trigger and the
# missing required line).
printf "\n  phase 2 (test-the-test): synthetic violation fixture\n"

tmpfix="$(mktemp -t git-env-isolation-fixture.XXXXXX)"
trap 'rm -f "$tmpfix"' EXIT

# Single-quoted heredoc — no expansion, literal text preserved.
cat > "$tmpfix" <<'EOF'
#!/usr/bin/env bash
# A fixture that simulates a buggy helper: builds its own repo but
# does NOT isolate from the caller's git environment.
set -e
git init -q some-tmprepo
cd some-tmprepo
git config user.email "test@example.com"
EOF

if check_file "$tmpfix"; then
  printf "  ❌ phase 2: lint FAILED to catch fixture (synthetic violation passed!)\n" >&2
  errors=$((errors + 1))
else
  if [[ "$violation" == *"git init"* && "$violation" == *"missing required"* ]]; then
    printf "  ✅ phase 2: lint correctly refused fixture\n"
    printf "     sample message: %s\n" "$violation"
  else
    printf "  ❌ phase 2: lint refused fixture but message is malformed: %s\n" "$violation" >&2
    errors=$((errors + 1))
  fi
fi

# --- Exit ------------------------------------------------------------------
if (( errors == 0 )); then
  printf "\n  ✅ git-env isolation lint passing\n"
  exit 0
else
  printf "\n  ❌ %d violation(s) — see above\n" "$errors" >&2
  exit 1
fi
