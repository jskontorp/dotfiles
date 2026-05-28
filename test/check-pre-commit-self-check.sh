#!/bin/bash
# Tests for git/hooks/pre-commit's staged-index self-check (JSK-46).
# Builds isolated tmprepos, installs the real pre-commit hook, and puts a
# fake `just` first on PATH so each case can simulate a hook subprocess that
# either leaves the index alone or mutates it during `just check`.
set -uo pipefail

# Regression class: GIT_DIR / GIT_INDEX_FILE inheritance (JSK-44 enforces
# this idiom in any test/check-*.sh that invokes `git init`). These tmprepos
# must be isolated from the parent pre-commit hook's git environment.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_DIR/git/hooks/pre-commit"
SECRET_LIB="$REPO_DIR/git/lib/secret-gate.sh"
SELF_CHECK_SIG='pre-commit self-check: staged index changed'
JUST_FAIL_SIG='just check failed'

pass=0
fail=0
ok()  { printf "  ✅ %s\n" "$1"; pass=$((pass + 1)); }
bad() { printf "  ❌ %s\n" "$1" >&2; fail=$((fail + 1)); }

TMP="$(mktemp -d -t jsk46-precommit-self-check.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

CASE_DIR=''
case_n=0

write_fake_just() {
  mkdir -p "$CASE_DIR/bin"
  cat > "$CASE_DIR/bin/just" <<'EOF'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" != "check" ]]; then
  printf 'fake just: expected `check`, got `%s`\n' "${1:-}" >&2
  exit 2
fi
if [[ -n "${JSK46_MARKER:-}" ]]; then
  printf 'ran\n' >> "$JSK46_MARKER"
fi

case "${JSK46_FAKE_JUST_MODE:-pass}" in
  pass)
    exit 0
    ;;
  fail)
    printf 'fake just deliberate failure\n' >&2
    exit 7
    ;;
  add)
    printf 'mutated\n' > mutation-added.txt
    git add -- mutation-added.txt
    exit 0
    ;;
  remove)
    git rm --cached -q -- staged-remove.txt
    exit 0
    ;;
  modify)
    printf 'mutated\n' > staged-modify.txt
    git add -- staged-modify.txt
    exit 0
    ;;
  mode)
    chmod +x mode-file.txt
    git add -- mode-file.txt
    exit 0
    ;;
  space)
    mkdir -p dir
    printf 'space mutation\n' > "dir/path with spaces.txt"
    git add -- "dir/path with spaces.txt"
    exit 0
    ;;
  *)
    printf 'fake just: unknown mode %s\n' "$JSK46_FAKE_JUST_MODE" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$CASE_DIR/bin/just"
}

install_hook_fixture() {
  mkdir -p git/hooks git/lib .git/hooks
  cp "$HOOK" git/hooks/pre-commit
  cp "$SECRET_LIB" git/lib/secret-gate.sh
  ln -sf "$PWD/git/hooks/pre-commit" .git/hooks/pre-commit
  chmod +x .git/hooks/pre-commit git/hooks/pre-commit
  write_fake_just
}

new_repo() {
  local name="$1"
  local seed_mode="$2"
  case_n=$((case_n + 1))
  CASE_DIR="$(mktemp -d "$TMP/${case_n}-${name}.XXXXXX")"
  cd "$CASE_DIR" || exit 1
  git init -q -b main .
  git config --local --unset-all core.hooksPath 2>/dev/null || true
  git config user.email "test@example.com"
  git config user.name  "test"
  git config commit.gpgsign false
  git config core.filemode true

  if [[ "$seed_mode" == "seed" ]]; then
    printf 'seed\n' > seed.txt
    git add seed.txt
    git commit -q -m "seed"
  fi

  install_hook_fixture
}

run_commit() {
  local mode="$1"
  local marker="$2"
  local log="$3"
  shift 3
  PATH="$CASE_DIR/bin:$PATH" \
    JSK46_FAKE_JUST_MODE="$mode" \
    JSK46_MARKER="$marker" \
    git commit -q "$@" >"$log" 2>&1
}

log_contains() {
  local log="$1"
  local needle="$2"
  grep -qF -- "$needle" "$log"
}

assert_log_contains() {
  local log="$1"
  local needle="$2"
  local label="$3"
  if log_contains "$log" "$needle"; then
    ok "$label"
  else
    bad "$label — missing '$needle'"
    sed -n '1,40p' "$log" >&2
  fi
}

assert_log_not_contains() {
  local log="$1"
  local needle="$2"
  local label="$3"
  if log_contains "$log" "$needle"; then
    bad "$label — unexpected '$needle'"
    sed -n '1,40p' "$log" >&2
  else
    ok "$label"
  fi
}

assert_head_unchanged() {
  local before="$1"
  local label="$2"
  local after
  after="$(git rev-parse HEAD)"
  if [[ "$after" == "$before" ]]; then
    ok "$label"
  else
    bad "$label — HEAD moved from $before to $after"
  fi
}

printf "pre-commit self-check integration cases:\n"

# Green 1: initial commit on an unborn branch.
new_repo "initial" "empty"
printf 'initial\n' > initial.txt
git add initial.txt
marker="$TMP/initial.marker"
log="$TMP/initial.log"
if run_commit pass "$marker" "$log" -m "initial"; then
  ok "initial commit passes without index mutation"
else
  bad "initial commit should pass"
  sed -n '1,40p' "$log" >&2
fi
if [[ -s "$marker" ]]; then ok "initial commit: hook ran"; else bad "initial commit: hook marker missing"; fi

# Green 2: ordinary commit with a pre-existing HEAD.
new_repo "normal" "seed"
printf 'normal\n' > normal.txt
git add normal.txt
marker="$TMP/normal.marker"
log="$TMP/normal.log"
if run_commit pass "$marker" "$log" -m "normal"; then
  ok "normal commit passes without index mutation"
else
  bad "normal commit should pass"
  sed -n '1,40p' "$log" >&2
fi
if [[ -s "$marker" ]]; then ok "normal commit: hook ran"; else bad "normal commit: hook marker missing"; fi
assert_log_not_contains "$log" "$SELF_CHECK_SIG" "normal commit: no self-check mutation message"

# Existing hook failure path: fake just exits nonzero but does not mutate.
new_repo "just-fail" "seed"
printf 'failing just\n' > just-fail.txt
git add just-fail.txt
head_before="$(git rev-parse HEAD)"
marker="$TMP/just-fail.marker"
log="$TMP/just-fail.log"
if run_commit fail "$marker" "$log" -m "just fails"; then
  bad "just failure case should refuse commit"
else
  ok "just failure case refuses commit"
fi
assert_log_contains "$log" "$JUST_FAIL_SIG" "just failure case: original failure message preserved"
assert_log_not_contains "$log" "$SELF_CHECK_SIG" "just failure case: no mutation message"
assert_head_unchanged "$head_before" "just failure case: HEAD unchanged"
if [[ -s "$marker" ]]; then ok "just failure case: hook ran"; else bad "just failure case: hook marker missing"; fi

# Red 1: a hook subprocess stages an additional path.
new_repo "add" "seed"
printf 'base\n' > base.txt
git add base.txt
head_before="$(git rev-parse HEAD)"
marker="$TMP/add.marker"
log="$TMP/add.log"
if run_commit add "$marker" "$log" -m "mutating add"; then
  bad "add mutation should refuse commit"
else
  ok "add mutation refuses commit"
fi
assert_log_contains "$log" "$SELF_CHECK_SIG" "add mutation: self-check message"
assert_log_contains "$log" "mutation-added.txt" "add mutation: names added path"
assert_head_unchanged "$head_before" "add mutation: HEAD unchanged"
if git diff --cached --name-only -- mutation-added.txt | grep -q '^mutation-added.txt$'; then
  ok "add mutation: mutated index left for inspection"
else
  bad "add mutation: staged added path missing after refusal"
fi

# Red 2: a hook subprocess removes a staged path.
new_repo "remove" "seed"
printf 'remove me\n' > staged-remove.txt
git add staged-remove.txt
head_before="$(git rev-parse HEAD)"
marker="$TMP/remove.marker"
log="$TMP/remove.log"
if run_commit remove "$marker" "$log" -m "mutating remove"; then
  bad "remove mutation should refuse commit"
else
  ok "remove mutation refuses commit"
fi
assert_log_contains "$log" "$SELF_CHECK_SIG" "remove mutation: self-check message"
assert_log_contains "$log" "staged-remove.txt" "remove mutation: names removed path"
assert_head_unchanged "$head_before" "remove mutation: HEAD unchanged"
if git diff --cached --name-only -- staged-remove.txt | grep -q .; then
  bad "remove mutation: removed path still staged after refusal"
else
  ok "remove mutation: mutated index left for inspection"
fi

# Red 3: a hook subprocess rewrites and re-stages an already staged path.
new_repo "modify" "seed"
printf 'original\n' > staged-modify.txt
git add staged-modify.txt
head_before="$(git rev-parse HEAD)"
marker="$TMP/modify.marker"
log="$TMP/modify.log"
if run_commit modify "$marker" "$log" -m "mutating modify"; then
  bad "modify mutation should refuse commit"
else
  ok "modify mutation refuses commit"
fi
assert_log_contains "$log" "$SELF_CHECK_SIG" "modify mutation: self-check message"
assert_log_contains "$log" "staged-modify.txt" "modify mutation: names modified path"
assert_head_unchanged "$head_before" "modify mutation: HEAD unchanged"
if [[ "$(git show :staged-modify.txt 2>/dev/null)" == "mutated" ]]; then
  ok "modify mutation: mutated blob left staged"
else
  bad "modify mutation: staged blob was not the mutated content"
fi

# Red 4: mode-only restage is detected.
new_repo "mode" "seed"
printf 'mode\n' > mode-file.txt
chmod 644 mode-file.txt
git add mode-file.txt
head_before="$(git rev-parse HEAD)"
marker="$TMP/mode.marker"
log="$TMP/mode.log"
if run_commit mode "$marker" "$log" -m "mutating mode"; then
  bad "mode mutation should refuse commit"
else
  ok "mode mutation refuses commit"
fi
assert_log_contains "$log" "$SELF_CHECK_SIG" "mode mutation: self-check message"
assert_log_contains "$log" "mode-file.txt" "mode mutation: names mode-only path"
assert_head_unchanged "$head_before" "mode mutation: HEAD unchanged"
if git ls-files --stage -- mode-file.txt | grep -q '^100755 '; then
  ok "mode mutation: executable bit left staged"
else
  bad "mode mutation: executable bit not staged after refusal"
fi

# Red 5: path diagnostics survive spaces.
new_repo "space" "seed"
printf 'base\n' > base.txt
git add base.txt
head_before="$(git rev-parse HEAD)"
marker="$TMP/space.marker"
log="$TMP/space.log"
if run_commit space "$marker" "$log" -m "mutating space"; then
  bad "space-path mutation should refuse commit"
else
  ok "space-path mutation refuses commit"
fi
assert_log_contains "$log" "$SELF_CHECK_SIG" "space-path mutation: self-check message"
if log_contains "$log" "dir/path with spaces.txt" || log_contains "$log" "dir/path\\ with\\ spaces.txt"; then
  ok "space-path mutation: names path with spaces"
else
  bad "space-path mutation: path with spaces missing from output"
  sed -n '1,80p' "$log" >&2
fi
assert_head_unchanged "$head_before" "space-path mutation: HEAD unchanged"
if git diff --cached --name-only -- "dir/path with spaces.txt" | grep -q 'path with spaces'; then
  ok "space-path mutation: staged path left for inspection"
else
  bad "space-path mutation: staged path missing after refusal"
fi

# Edge: amend from a clean worktree should pass, and the marker proves the
# hook actually ran.
new_repo "amend" "seed"
marker="$TMP/amend.marker"
log="$TMP/amend.log"
if run_commit pass "$marker" "$log" --amend --no-edit; then
  ok "amend from clean state passes"
else
  bad "amend from clean state should pass"
  sed -n '1,40p' "$log" >&2
fi
if [[ -s "$marker" ]]; then ok "amend: hook ran"; else bad "amend: hook marker missing"; fi
assert_log_not_contains "$log" "$SELF_CHECK_SIG" "amend: no self-check mutation message"

echo
if (( fail == 0 )); then
  printf "  ✅ pre-commit self-check: %d checks passed\n" "$pass"
  exit 0
else
  printf "  ❌ pre-commit self-check: %d passed, %d failed\n" "$pass" "$fail" >&2
  exit 1
fi
