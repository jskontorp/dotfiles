#!/bin/bash
# Lint shell files for bash≥4 features that break on macOS's bundled bash 3.2.
#
# Scope: only paths that actually execute under macOS system bash 3.2:
#   - init.sh                            (curl-piped bootstrap one-liner)
#   - install.sh                         (run from a fresh mac via /bin/bash)
#   - machine/{mac,vm}/bootstrap.sh      (interactive fresh-machine bootstrap)
#   - test/*.sh                          (invoked by pre-commit and `just test`,
#                                         which call them with `bash` — system
#                                         bash on host, 5+ in Docker)
#   - git/hooks/*                        (hook shebangs are #!/bin/bash)
#
# Out of scope (run under user/agent-chosen shells, not macOS system bash):
#   - claude/**, pi/agent/skills/**/scripts/**, shared/**, zsh/**, *.zsh.
#
# Has prevented one observed regression class (commit 2fbdded).
#
# Usage: bash test/check-bash-portability.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Patterns that require bash≥4 (extended regex, anchored to non-comment lines).
# Comments are stripped before matching so `# bash 3.2 — no mapfile` doesn't fire.
PATTERN='(\bmapfile\b|\breadarray\b|\$\{[A-Za-z_][A-Za-z0-9_]*,,?\}|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^?\})'

# Explicit allow-list of bash-3.2-constrained paths. Find them all up front,
# null-delimited, so paths with spaces survive.
files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(
  {
    [[ -f "$REPO_DIR/init.sh" ]] && printf '%s\0' "$REPO_DIR/init.sh"
    [[ -f "$REPO_DIR/install.sh" ]] && printf '%s\0' "$REPO_DIR/install.sh"
    find "$REPO_DIR/test" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null
    find "$REPO_DIR/machine" -type f -name 'bootstrap.sh' -print0 2>/dev/null
    find "$REPO_DIR/git/hooks" -type f -print0 2>/dev/null
  }
)

errors=0
for file in "${files[@]}"; do
  # Strip trailing comments, then grep. -n preserves line numbers.
  hits=$(sed -E 's/[[:space:]]*#.*$//' "$file" | grep -nE "$PATTERN" || true)
  if [[ -n "$hits" ]]; then
    rel="${file#"$REPO_DIR/"}"
    while IFS= read -r line; do
      printf "  ❌ bash≥4 feature in %s:%s\n" "$rel" "$line"
      errors=$((errors + 1))
    done <<< "$hits"
  fi
done

if [[ $errors -gt 0 ]]; then
  printf "  %d bash-portability violation(s)\n" "$errors" >&2
  exit 1
fi
printf "  ✅ no bash≥4 features detected (%d files scanned)\n" "${#files[@]}"
