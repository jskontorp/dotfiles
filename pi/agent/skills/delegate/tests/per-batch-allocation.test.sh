#!/usr/bin/env bash
# Tests for the per-batch .pi-delegate/ allocation idiom shared by the
# `delegate` and `triple-review` SKILL.md files. The idiom itself is bash
# (atomic `mkdir` without `-p` + retry loop), inlined into each SKILL.md
# rather than factored into a script — so this test re-inlines it and
# exercises the contract:
#
#   1. Empty .pi-delegate/   → allocates batch-1
#   2. Existing batch-1/     → allocates batch-2
#   3. Two concurrent allocators in the same cwd → distinct batch dirs,
#      no collision (validates the mkdir-without-`-p` retry)
#   4. Numeric sort (≥10 batches) sorts correctly (not lexically)
#
# Out of scope: cross-cwd tmux window-name uniqueness. That's a tmux probe
# property, not an FS allocation property, and exercising it would require
# a tmux server inside the test sandbox. The contract that justifies it
# ("keep FS probe independent of tmux probe") is documented in AGENTS.md
# and enforced by code review.

set -uo pipefail

passed=0
failed=0
failures=()

# Inline the allocation idiom under test. Must match the block in
# pi/agent/skills/{delegate,triple-review}/SKILL.md. If the SKILL.md
# version drifts, update this fixture and the SKILL.md in lockstep.
allocate_batch() {
  local delegate_dir="$1"
  mkdir -p "$delegate_dir"
  local n batch
  while true; do
    n=$(ls -1d "$delegate_dir"/batch-* 2>/dev/null | sed -E 's|.*/batch-||' | sort -n | tail -1)
    batch="batch-$(( ${n:-0} + 1 ))"
    mkdir "$delegate_dir/$batch" 2>/dev/null && break
  done
  echo "$batch"
}

run_case() {
  local name="$1"; shift
  if "$@"; then
    passed=$((passed + 1))
    echo "  ✅ $name"
  else
    failed=$((failed + 1))
    failures+=("$name")
    echo "  ❌ $name"
  fi
}

# --- Case 1: empty dir → batch-1 ---
case_empty_allocates_batch1() {
  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand-now is intentional: $tmp is out of scope when RETURN trap fires
  trap "rm -rf '$tmp'" RETURN
  local got
  got=$(allocate_batch "$tmp/.pi-delegate")
  [ "$got" = "batch-1" ] && [ -d "$tmp/.pi-delegate/batch-1" ]
}

# --- Case 2: existing batch-1 → batch-2 ---
case_existing_advances() {
  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand-now is intentional: $tmp is out of scope when RETURN trap fires
  trap "rm -rf '$tmp'" RETURN
  mkdir -p "$tmp/.pi-delegate/batch-1"
  local got
  got=$(allocate_batch "$tmp/.pi-delegate")
  [ "$got" = "batch-2" ] && [ -d "$tmp/.pi-delegate/batch-2" ]
}

# --- Case 3: numeric sort across ≥10 batches ---
case_numeric_sort() {
  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand-now is intentional: $tmp is out of scope when RETURN trap fires
  trap "rm -rf '$tmp'" RETURN
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11; do
    mkdir -p "$tmp/.pi-delegate/batch-$i"
  done
  local got
  got=$(allocate_batch "$tmp/.pi-delegate")
  # Lexical sort would put batch-9 last → expect batch-10; numeric sort
  # puts batch-11 last → expect batch-12. We want the numeric answer.
  [ "$got" = "batch-12" ]
}

# --- Case 4: concurrent allocation, no collision ---
# Spawn N background allocators against one .pi-delegate/. Each writes its
# allocated batch ID to a unique file; we then assert the union of IDs has
# no duplicates and that batch-1..batch-N all exist.
case_concurrent_no_collision() {
  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand-now is intentional: $tmp is out of scope when RETURN trap fires
  trap "rm -rf '$tmp'" RETURN
  local n=8 i
  local pids=()
  for i in $(seq 1 "$n"); do
    (allocate_batch "$tmp/.pi-delegate" > "$tmp/got-$i") &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid"; done

  # All N output files should contain distinct batch-K values, K in 1..N.
  local ids
  ids=$(cat "$tmp"/got-* 2>/dev/null | sort -u)
  local count
  count=$(printf '%s\n' "$ids" | wc -l | tr -d ' ')
  [ "$count" = "$n" ] || { echo "    expected $n unique IDs, got $count: $ids"; return 1; }

  # And the FS should have batch-1..batch-N.
  for i in $(seq 1 "$n"); do
    [ -d "$tmp/.pi-delegate/batch-$i" ] || { echo "    missing batch-$i"; return 1; }
  done
}

echo ""
echo "================ per-batch allocation tests ================"
run_case "empty dir allocates batch-1"           case_empty_allocates_batch1
run_case "existing batch-1 advances to batch-2"  case_existing_advances
run_case "numeric sort across ≥10 batches"       case_numeric_sort
run_case "concurrent allocators get distinct IDs" case_concurrent_no_collision

echo ""
if [ "$failed" -eq 0 ]; then
  echo "✅ per-batch-allocation: $passed/$passed passed"
  exit 0
fi
echo "❌ per-batch-allocation: $failed failed (${failures[*]})"
exit 1
