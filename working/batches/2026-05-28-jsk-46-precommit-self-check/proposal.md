# JSK-46 proposal: pre-commit self-check for staged-index mutation

## Goal

Add a runtime guard to `git/hooks/pre-commit` that detects whether any hook subprocess changed the staged set during the hook run, and refuses the commit with actionable output if it did.

This closes the runtime half of the `GIT_INDEX_FILE` poisoning regression class. JSK-44 already added the static lint that requires git-env unsetting in helper scripts that build tmprepos.

## Current hook shape

`git/hooks/pre-commit` currently:

1. enables `set -euo pipefail`;
2. resolves `REPO_ROOT`, `CANONICAL_DIR`, and `SECRET_GATE_LIB`;
3. runs the secret-path gate;
4. shellchecks staged `*.sh` files if `shellcheck` exists;
5. runs `( cd "$REPO_ROOT" && just check >/dev/null )` if `just` exists.

The self-check should wrap all existing steps without weakening their current exit behavior.

## Proposed implementation

### Snapshot format

Use `git diff --cached --raw --no-renames --abbrev=40 | sort` as the staged snapshot.

Why this format:

- includes path set changes;
- includes mode changes;
- includes staged blob hash changes on the same path;
- includes staged deletions, which `git ls-files --stage` alone would miss;
- avoids recomputing hashes because Git already has them in the index/diff metadata.

### Hook wiring

Near the top of `git/hooks/pre-commit`, after `REPO_ROOT` is known:

1. create a temp dir with `mktemp -d`;
2. write `pre.raw` from the snapshot command;
3. install `trap pre_commit_self_check_on_exit EXIT`.

The trap function:

1. captures the hook's current exit status (`$?`);
2. disables its own trap (`trap - EXIT`) to avoid recursion;
3. writes `post.raw` using the same snapshot command;
4. if `pre.raw` and `post.raw` match, removes the temp dir and exits with the original hook status;
5. if they differ, prints a JSK-46 error message and exits 1.

The mutation error should include:

- a short explanation that a pre-commit subprocess changed the staged set;
- a list of affected paths derived from the symmetric raw diff;
- the full before/after raw snapshots for debugging;
- a pointer to the `GIT_INDEX_FILE` poisoning regression class / JSK-44.

No opt-out env var is proposed. This repo does not use auto-format-and-restage hooks, and the guard's value is that it is unconditional.

### Design-question resolutions

1. **Trap signal**: use `EXIT`; preserve the original hook status unless a mutation is detected.
2. **Mutation definition**: path + mode + blob via `git diff --cached --raw --no-renames --abbrev=40`, not path-only.
3. **`commit --amend`**: no special handling; snapshot at hook entry reflects Git's amend-time staged state. Verify empirically.
4. **Chained hooks**: the outer pre-commit trap runs after all pre-commit work; inner mutations are still visible in the outer staged set.
5. **Squash/fixup**: no special handling; one hook invocation, same as normal commit.
6. **Recursive `git commit`**: no special handling beyond JSK-44's env isolation; if a nested process mutates the parent staged set anyway, this guard catches it.
7. **Legitimate hook mutation**: refuse outright; no whitelist or opt-out.
8. **Output**: print affected paths plus before/after raw snapshots.

## Proposed tests

Add `test/check-pre-commit-self-check.sh` and wire it into `just check`.

The test should build isolated tmprepos and copy the real `git/hooks/pre-commit` plus `git/lib/secret-gate.sh` into each fixture. It should place a fake `just` executable first on `PATH`, because the real hook already calls `just check`; the fake `just` can mutate the staged set to simulate a buggy hook subprocess without adding test-only branches to production hook code.

Cases:

1. **Green**: normal commit, fake `just` exits 0 without mutation → commit passes.
2. **Red add**: fake `just` creates and stages `mutation-added.txt` → commit refused; output names the file.
3. **Red remove**: fake `just` unstages a staged file → commit refused; output names the file.
4. **Red modify**: fake `just` rewrites and re-stages a staged file → commit refused; output names the file.
5. **Amend edge**: `git commit --amend --no-edit` from a clean state → passes.

The test itself must include the JSK-44 unset line before any `git init`.

## Files expected to change

- `git/hooks/pre-commit`
- `test/check-pre-commit-self-check.sh` (new)
- `justfile` (wire the new test into `just check`)
- `working/batches/2026-05-28-jsk-46-precommit-self-check/state.md` (session ledger)
- possibly `AGENTS.md` only after both runtime guard and static lint status can be stated with final SHAs; likely this belongs at close/commit-message time, not in the first implementation diff.

## Review questions

- Is `git diff --cached --raw --no-renames --abbrev=40` the right snapshot primitive, or is there a better staged-tree representation?
- Is printing before/after raw snapshots acceptable UX, or should the hook compute a cleaner categorized diff?
- Does the fake-`just` test strategy exercise the real runtime failure mode without adding test-only hook code?
- Is refusing all staged-set mutation too strict for this repo?
