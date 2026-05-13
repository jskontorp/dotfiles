# shellcheck shell=bash
# git/lib/canonical-path.sh — resolve canonical repo dir from any worktree.
#
# Motivation: hooks and scripts that live under git/ resolve their siblings
# (other libs, sentinel files in the repo) relative to "the repo." When a
# command runs from a worktree, `git rev-parse --show-toplevel` returns the
# *worktree* dir, so a hook that does `source $(git rev-parse --show-toplevel)/git/lib/foo.sh`
# silently sources the worktree's copy — which may not exist on a branch that
# pre-dates `foo.sh`, may have local edits unrelated to the canonical install,
# or may be missing entirely (hard-blocks every commit).
#
# `--git-common-dir` returns the shared `.git` dir (canonical's, regardless of
# which worktree is asking). `dirname` of that is canonical's working tree.
# Requires git ≥ 2.31 for `--path-format=absolute` (released 2021-03; well
# below this repo's bash-3.2/macOS portability floor).
#
# Usage:
#   . "${BASH_SOURCE%/*}/canonical-path.sh"
#   CANONICAL="$(canonical_repo_dir)"          # from $PWD
#   CANONICAL="$(canonical_repo_dir /some/wt)" # from explicit dir
#
# Documented in pi/agent/AGENTS.md "Known regression classes" — this helper
# is the prescribed fix; consumers (git/hooks/*) source it instead of
# inlining the `git rev-parse` invocation.

canonical_repo_dir() {
    dirname "$(git -C "${1:-$PWD}" rev-parse --path-format=absolute --git-common-dir)"
}
