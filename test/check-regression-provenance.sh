#!/usr/bin/env bash
# test/check-regression-provenance.sh
#
# Assert every "Known regression classes" entry containing the substring
# "Evidence:" cites at least one 7+ hex-char SHA. The wiki layer in
# pi/agent/AGENTS.md "Persistence layers" requires provenance on every
# entry (so future agents can re-grep the original failure or its fix);
# this gate catches missing SHAs at commit time.
#
# Scope: scans pi/agent/AGENTS.md and the repo-local AGENTS.md ("Known
# regression classes" section, demarcated by "## Known regression classes"
# / "## Known gaps" / next "## " heading / EOF). Files outside that section
# are not touched.
#
# Exit codes: 0 = all entries have provenance; 1 = one or more entries fail.

set -uo pipefail

# Critical: this script may be invoked from a pre-commit hook context where
# GIT_INDEX_FILE / GIT_DIR / GIT_WORK_TREE etc. are set to the staging index.
# Subprocesses would inherit them and target the parent's gitdir; unset to
# keep this script's git ops local. Regression class:
# pi/agent/AGENTS.md "Known regression classes" → GIT_INDEX_FILE poisoning.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR

# Resolve the calling worktree's repo root — we want to check the *staged* content,
# not canonical's (possibly stale) view. The wiki rule lives in tracked files
# (`pi/agent/AGENTS.md`, `AGENTS.md`); both are present in any checkout.
REPO_ROOT="$(git rev-parse --show-toplevel)"

TARGETS=(
  "$REPO_ROOT/pi/agent/AGENTS.md"
  "$REPO_ROOT/AGENTS.md"
)

printf "\nregression-class provenance check:\n"

errors=0
checked=0
for target in "${TARGETS[@]}"; do
  if [[ ! -f "$target" ]]; then
    printf "  ⏭  skip: %s (not present)\n" "${target#$REPO_ROOT/}"
    continue
  fi

  # Extract the "Known regression classes" section: from a "## Known regression classes"
  # heading (any level: #, ##, ###) to the next same-or-higher heading or EOF.
  section="$(awk '
    /^#+ Known regression classes/ {flag=1; depth=length($0)-length($1); next}
    flag && /^#+ / {
      cur=length($0)-length($1)
      if (cur <= depth) {flag=0; next}
    }
    flag {print}
  ' "$target")"

  if [[ -z "$section" ]]; then
    printf "  ⏭  skip: %s (no 'Known regression classes' section)\n" "${target#$REPO_ROOT/}"
    continue
  fi

  # Split section into "entries". An entry is a bullet starting with "- **" or "- `"
  # (the existing entries' shape). For each entry that mentions "Evidence:" anywhere
  # in its body (the bullet + any indented continuation), require at least one
  # 7+ hex-char SHA within the same entry. SHAs are typically 7-12 chars; we accept
  # 7..40.
  #
  # Algorithm: walk lines, accumulate per-entry buffer, flush on next top-level bullet
  # or EOF.
  buf=""
  flush() {
    if [[ -n "$buf" && "$buf" == *"Evidence:"* ]]; then
      checked=$((checked + 1))
      if ! echo "$buf" | grep -qE '(^|[^a-z0-9])[0-9a-f]{7,40}([^a-z0-9]|$)'; then
        # Surface the first line of the entry so the user knows which one
        first_line="$(echo "$buf" | head -1 | sed 's/^- //')"
        printf "  ❌ %s :: entry missing SHA: %.80s\n" "${target#$REPO_ROOT/}" "$first_line" >&2
        errors=$((errors + 1))
      fi
    fi
  }

  while IFS= read -r line; do
    if [[ "$line" =~ ^-[[:space:]] ]]; then
      flush
      buf="$line"
    elif [[ -n "$buf" && ("$line" =~ ^[[:space:]] || -z "$line") ]]; then
      buf+=$'\n'"$line"
    elif [[ -n "$buf" ]]; then
      flush
      buf=""
    fi
  done <<< "$section"
  flush
done

if [[ $errors -eq 0 ]]; then
  if [[ $checked -eq 0 ]]; then
    printf "  ⏭  no 'Evidence:' entries to check (sections empty or all without provenance markers)\n"
  else
    printf "  ✅ %d entries with provenance, all cite a SHA\n" "$checked"
  fi
  exit 0
else
  printf "\n  ❌ %d regression-class entries lack a SHA after 'Evidence:'\n" "$errors" >&2
  printf "  Fix: add the commit SHA of the failure (or its fix) to each entry.\n" >&2
  printf "  See pi/agent/AGENTS.md \"Persistence layers\" \u00a7 Repo-internal wiki for the rule.\n" >&2
  exit 1
fi
