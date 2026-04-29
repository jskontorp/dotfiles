#!/usr/bin/env bash
# Run all session-scan script tests. Exits non-zero if any file failed.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0
failures=()
for t in "$HERE"/*.test.sh; do
  [ -x "$t" ] || continue
  if ! "$t"; then
    rc=$?
    failures+=("$(basename "$t")")
  fi
done

echo ""
echo "================ session-scan tests ================"
if [ "${#failures[@]}" -eq 0 ]; then
  echo "✅ all test files passed"
  exit 0
fi
echo "❌ failed: ${failures[*]}"
exit "$rc"
