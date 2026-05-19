#!/usr/bin/env bash
# Tests for git/lib/canonical-path.sh + global-hooks-path warning (JSK-42).
#
# Two assertions:
#   1. canonical_repo_dir resolves to canonical's working tree from BOTH
#      canonical and a temporary worktree. This is the regression class
#      pi/agent/AGENTS.md calls "Canonical-side hook scripts that source
#      canonical-only paths" — broken any time `git rev-parse --show-toplevel`
#      is used in a hook, fixed by `--git-common-dir | dirname`.
#   2. `git config --get core.hooksPath` is empty. A globally-set hooks path
#      (husky, lefthook, the pre-commit framework, some lazygit setups)
#      silently bypasses every per-repo hook in this checkout — including
#      JSK-35's secret gate and JSK-36's silencing gate. Warn loudly; don't
#      hard-fail (some users may legitimately want a non-empty value, this
#      script just makes the failure mode visible).
#
# bash 3.2 portable; matches the existing test/check-*.sh idioms.
set -uo pipefail

# Critical: this script invokes `git worktree add` and `git rev-parse` against
# the canonical repo. When run from inside a pre-commit hook, git sets
# GIT_INDEX_FILE (and friends) pointing at the calling commit's staging index.
# `git worktree add` writes a fresh index when initialising the new worktree;
# if it inherits GIT_INDEX_FILE, that fresh index *overwrites the parent
# commit's staging index*, silently producing an empty commit. Unset all
# git env vars so this script's git invocations can't poison the caller.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_DIR/git/lib/canonical-path.sh"

if [[ ! -f "$LIB" ]]; then
    printf "  ❌ %s missing\n" "$LIB" >&2
    exit 1
fi

# Bootstrap: compute the expected canonical path *without* using the helper,
# so the test can detect a helper that always returns the cwd or always
# returns the wrong thing.
CANONICAL_EXPECTED="$(dirname "$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir)")"
# Normalise via cd, in case the bootstrap returns a path with `.` or symlinks
# that the helper would resolve differently.
CANONICAL_EXPECTED="$(cd "$CANONICAL_EXPECTED" && pwd -P)"

# shellcheck source=../git/lib/canonical-path.sh
. "$LIB"

errors=0

printf "canonical-path resolution:\n"

# --- Case 1: from current cwd (which is whatever invoked just check) -------
got="$(canonical_repo_dir | xargs -I{} bash -c 'cd "$1" && pwd -P' _ {})"
if [[ "$got" == "$CANONICAL_EXPECTED" ]]; then
    printf "  ✅ from cwd: %s\n" "$got"
else
    printf "  ❌ from cwd: got %s, expected %s\n" "$got" "$CANONICAL_EXPECTED" >&2
    errors=$((errors + 1))
fi

# --- Case 2: from a fresh detached worktree --------------------------------
# Create the worktree under $TMPDIR (NOT inside dotfiles tree — would mess
# with manifest scans). Use --detach so we don't pollute the branch list.
TMP_WT="$(mktemp -d -t jsk42-canonical-path-wt.XXXXXX)"
cleanup() {
    git -C "$CANONICAL_EXPECTED" worktree remove --force "$TMP_WT" >/dev/null 2>&1 || rm -rf "$TMP_WT"
}
trap cleanup EXIT

if ! git -C "$CANONICAL_EXPECTED" worktree add --quiet --detach "$TMP_WT" HEAD 2>/tmp/jsk42-wt.err; then
    printf "  ❌ failed to create test worktree at %s\n" "$TMP_WT" >&2
    sed 's/^/     /' /tmp/jsk42-wt.err >&2
    errors=$((errors + 1))
else
    got="$(cd "$TMP_WT" && canonical_repo_dir | xargs -I{} bash -c 'cd "$1" && pwd -P' _ {})"
    if [[ "$got" == "$CANONICAL_EXPECTED" ]]; then
        printf "  ✅ from worktree: %s → %s\n" "$TMP_WT" "$got"
    else
        printf "  ❌ from worktree: got %s, expected %s\n" "$got" "$CANONICAL_EXPECTED" >&2
        errors=$((errors + 1))
    fi
    # Also test the explicit-dir form.
    got="$(canonical_repo_dir "$TMP_WT" | xargs -I{} bash -c 'cd "$1" && pwd -P' _ {})"
    if [[ "$got" == "$CANONICAL_EXPECTED" ]]; then
        printf "  ✅ explicit dir arg: %s → %s\n" "$TMP_WT" "$got"
    else
        printf "  ❌ explicit dir arg: got %s, expected %s\n" "$got" "$CANONICAL_EXPECTED" >&2
        errors=$((errors + 1))
    fi

    # install.sh must refuse from a non-canonical worktree (hardening fix #1).
    # Copy the install.sh under test into the detached worktree so this check
    # sees uncommitted edits when run pre-commit.
    cp "$REPO_DIR/install.sh" "$TMP_WT/install.sh"
    install_err="$(mktemp -t jsk-install-guard.XXXXXX)"
    if (cd "$TMP_WT" && ./install.sh >"$install_err" 2>&1); then
        printf "  ❌ install.sh guard: expected refusal from worktree, but command succeeded\n" >&2
        errors=$((errors + 1))
    elif grep -q 'install.sh: refusing to run from a git worktree' "$install_err"; then
        printf "  ✅ install.sh guard: worktree run refused\n"
    else
        printf "  ❌ install.sh guard: refusal message missing/unexpected\n" >&2
        sed 's/^/     /' "$install_err" >&2
        errors=$((errors + 1))
    fi
    rm -f "$install_err"
fi

# --- Case 3: core.hooksPath warning ----------------------------------------
# Per AGENTS.md "Known regression classes": a globally-set core.hooksPath
# silently bypasses git's per-worktree hooks fallback. Both JSK-35 and
# JSK-36 install per-repo hooks; they will silently NOT fire if a hooks
# framework is installed globally. Warn so the failure mode is visible.
printf "\nglobal hooks-path:\n"
hooks_path="$(git config --get core.hooksPath 2>/dev/null || true)"
if [[ -z "$hooks_path" ]]; then
    printf "  ✅ core.hooksPath unset (per-repo hooks fire)\n"
else
    printf "  ⚠  core.hooksPath = %s\n" "$hooks_path" >&2
    printf "     This silently bypasses every per-repo hook (secret-gate, silencing-gate).\n" >&2
    printf "     Investigate: %s\n" "$(git config --show-origin --get core.hooksPath 2>/dev/null || echo unknown)" >&2
    printf "     If intentional, ensure your hooks framework chains to .git/hooks/.\n" >&2
    # Warning, not fail. See header.
fi

if [[ $errors -eq 0 ]]; then
    printf "\n  ✅ all canonical-path tests passed\n"
    exit 0
else
    printf "\n  ❌ %d canonical-path test(s) failed\n" "$errors" >&2
    exit 1
fi
