#!/bin/bash
# Lint shell files for bash≥4 features that break on macOS's bundled bash 3.2.
#
# install.sh runs under /bin/bash on a fresh mac (system bash, 3.2.57). New
# coreutils-style features (mapfile, readarray, ${var,,}, ${var^^}) silently
# corrupt or fail there. This catch is cheap and has prevented one observed
# regression class (commit 2fbdded).
#
# Usage: bash test/check-bash-portability.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Patterns that require bash≥4 (extended regex, anchored to non-comment lines).
# Comments are stripped before matching so `# bash 3.2 — no mapfile` doesn't fire.
PATTERN='(\bmapfile\b|\breadarray\b|\$\{[A-Za-z_][A-Za-z0-9_]*,,?\}|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^?\})'

errors=0
while IFS= read -r -d '' file; do
  # Strip trailing comments, then grep. -n preserves line numbers.
  hits=$(sed -E 's/[[:space:]]*#.*$//' "$file" | grep -nE "$PATTERN" || true)
  if [[ -n "$hits" ]]; then
    rel="${file#"$REPO_DIR/"}"
    while IFS= read -r line; do
      printf "  ❌ bash≥4 feature in %s:%s\n" "$rel" "$line"
      errors=$((errors + 1))
    done <<< "$hits"
  fi
done < <(find "$REPO_DIR" \
  \( -path "$REPO_DIR/.git" -o -path "$REPO_DIR/.pi-delegate" -o -path "$REPO_DIR/tmp" \) -prune \
  -o -type f \( -name '*.sh' -o -name '*.zsh' \) -print0)

if [[ $errors -gt 0 ]]; then
  printf "  %d bash-portability violation(s)\n" "$errors" >&2
  exit 1
fi
printf "  ✅ no bash≥4 features detected\n"
