#!/bin/bash
# Validate justfile health: syntax, mac/vm parity for status tools and
# global pnpm packages.
# Runs on the host (requires just). No Docker needed.
# Usage: bash test/check-justfile.sh
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")/.." && pwd)"
JUSTFILE="${JUSTFILE:-$DOTFILES/justfile}"
errors=0

# --- Justfile parses ---
printf "Justfile syntax:\n"
if just --justfile "$JUSTFILE" --evaluate >/dev/null 2>&1; then
  printf "  ✅ justfile parses\n"
else
  printf "  ❌ justfile parse error\n"
  just --justfile "$JUSTFILE" --evaluate 2>&1 | head -5
  exit 1
fi

# --- Shared status tools appear in both platform recipes ---
printf "\nStatus tool parity:\n"
SHARED_TOOLS=$(just --justfile "$JUSTFILE" --evaluate SHARED_STATUS_TOOLS)

if [[ -z "$SHARED_TOOLS" ]]; then
  printf "  ❌ SHARED_STATUS_TOOLS is empty\n"
  exit 1
fi

# Extract tool names from printf lines in each status block.
# Accumulates consecutive [...] attribute lines so stacked attributes
# (e.g. [macos] + [group('info')]) are handled correctly.
extract_status_tools() {
  local platform="$1"
  awk -v plat="$platform" '
    /^\[/ { attrs = attrs " " $0; next }
    /^[a-z_-]+:/ {
      if (/^status:/ && attrs ~ plat) { capture = 1 } else { capture = 0 }
      attrs = ""
      next
    }
    /^$/ { next }
    !/^[[:space:]]/ { attrs = ""; capture = 0 }
    capture && /printf/ {
      # Lines look like: printf "%-12s %s\n" "toolname"  "$(...)"
      # Extract the second quoted string (the tool name)
      n = split($0, parts, /"/)
      if (n >= 4) print parts[4]
    }
  ' "$JUSTFILE"
}

mac_tools=$(extract_status_tools "macos")
linux_tools=$(extract_status_tools "linux")

for tool in $SHARED_TOOLS; do
  mac_ok=true linux_ok=true
  echo "$mac_tools" | grep -qxF "$tool" || mac_ok=false
  echo "$linux_tools" | grep -qxF "$tool" || linux_ok=false

  if $mac_ok && $linux_ok; then
    printf "  ✅ %s (both)\n" "$tool"
  else
    missing=""
    $mac_ok  || missing+="mac "
    $linux_ok || missing+="linux "
    printf "  ❌ %s (missing from: %s)\n" "$tool" "${missing% }"
    errors=$((errors + 1))
  fi
done

# --- GLOBAL_PNPM used in both update recipes ---
printf "\nGlobal pnpm parity:\n"

# Check that both [macos] update and [linux] update recipes reference {{GLOBAL_PNPM}}
for plat in macos linux; do
  in_recipe=$(awk -v plat="$plat" '
    /^\[/ { attrs = attrs " " $0; next }
    /^[a-z_-]+:/ {
      if (/^update:/ && attrs ~ plat) { capture = 1 } else { capture = 0 }
      attrs = ""
      next
    }
    /^$/ { next }
    !/^[[:space:]]/ { attrs = ""; capture = 0 }
    capture && /\{\{GLOBAL_PNPM\}\}/ { found = 1 }
    END { print (found ? "yes" : "no") }
  ' "$JUSTFILE")
  if [[ "$in_recipe" == "yes" ]]; then
    printf "  ✅ GLOBAL_PNPM referenced in %s update\n" "$plat"
  else
    printf "  ❌ GLOBAL_PNPM missing from %s update\n" "$plat"
    errors=$((errors + 1))
  fi
done

# Verify no hardcoded pnpm add -g lines bypass the variable
hardcoded=$(grep -n 'pnpm add -g' "$JUSTFILE" | grep -vF 'GLOBAL_PNPM' || true)
if [[ -n "$hardcoded" ]]; then
  printf "  ❌ hardcoded pnpm add -g bypasses GLOBAL_PNPM:\n"
  printf "       %s\n" "$hardcoded"
  errors=$((errors + 1))
else
  printf "  ✅ no hardcoded pnpm add -g (all use GLOBAL_PNPM)\n"
fi

# --- Summary ---
printf "\n"
if [[ $errors -gt 0 ]]; then
  printf "❌ %d parity issue(s) found\n" "$errors"
  exit 1
else
  printf "✅ Justfile checks passed\n"
fi
