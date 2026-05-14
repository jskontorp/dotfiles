#!/bin/bash
# Silencing-pattern matcher (JSK-36). Sourced by git/hooks/commit-msg and
# test/check-silencing-gate.sh.
#
# Single source of truth for the *patterns* is pi/agent/review-patterns.md
# § "Check-silencing patterns", bounded by the HTML-comment sentinels
#   <!-- silencing-gate:begin -->  …  <!-- silencing-gate:end -->
# Every backticked token in that slice is rendered into an ERE and grepped
# against staged additions. This file is the *engine*, not the catalogue.
#
# KNOWN GAP — only backticked tokens are enforced. Behavioural bullets in the
# same section ("Lowering coverage thresholds", "Catching and swallowing the
# previously-uncaught exception", "Deleting the failing test file",
# "Replacing assertEquals with assertTrue") have no diff-greppable form and
# remain human-review-only.
#
# Bash 3.2 portable (no `mapfile`, no `${var,,}`); BSD/GNU `grep -E` and
# `sed -E` portable. Case-sensitive throughout.

# --- Locating the pattern source --------------------------------------------
# Resolve the dotfiles repo root from this lib's path. The lib is sourced via
# absolute path by the hook (see git/hooks/commit-msg), so BASH_SOURCE here
# is the real file under git/lib/, not a symlink in .git/hooks.
_silencing_gate_lib_dir() {
  local src="${BASH_SOURCE[0]}"
  # Resolve one symlink hop if needed (POSIX-portable; no `readlink -f`).
  if [[ -L "$src" ]]; then
    src="$(cd "$(dirname "$src")" && pwd)/$(basename "$(readlink "$src")")"
  fi
  cd "$(dirname "$src")" && pwd
}

SILENCING_GATE_PATTERNS_MD_DEFAULT="$(_silencing_gate_lib_dir)/../../pi/agent/review-patterns.md"
: "${SILENCING_GATE_PATTERNS_MD:=$SILENCING_GATE_PATTERNS_MD_DEFAULT}"

# --- Path allowlist ----------------------------------------------------------
# Files where these tokens legitimately appear (prose, deny-config, the gate
# itself). Markdown discusses; code adds. Keep tight; the trailer override is
# the escape hatch for the long tail.
SILENCING_GATE_ALLOWLIST_RE='(\.md$|^claude/settings\.json$|^claude/agents/|^pi/agent/extensions/(destructive-gate|secret-read-gate)\.ts$|^git/hooks/commit-msg$|^git/lib/silencing-gate\.sh$|^test/check-silencing-gate\.sh$|^test/check-hook-chain\.sh$)'

# --- Pattern extraction -----------------------------------------------------
# Render one backticked token into an ERE.
#   1. Replace placeholder spans with a single-char sentinel each before
#      ERE-escaping, then swap the sentinel for `.*?`-equivalent.
#      ERE has no non-greedy; use `.*` — adequate, line-bounded by grep.
#      Placeholder forms recognised:
#        <…>           e.g. # type: ignore[<code>]
#        (...)         literal three-dot, e.g. cast(...), pytest.skip(...)
#        [...]         literal three-dot, e.g. — none today, future-proof
#        {...}         literal three-dot, future-proof
# Sentinels: \x01 (paren), \x02 (bracket), \x03 (brace), \x04 (angle).
silencing_gate_token_to_regex() {
  local tok="$1" out
  # 1. mark placeholder spans
  out=$(printf '%s' "$tok" \
    | sed -E 's/\(\.\.\.\)/\x01/g; s/\[\.\.\.\]/\x02/g; s/\{\.\.\.\}/\x03/g; s/<[^>]*>/\x04/g')
  # 2. ERE-escape everything else
  out=$(printf '%s' "$out" | sed -E 's/[][\.\\^$*+?(){}|\/]/\\&/g')
  # 3. swap sentinels for wildcard-bracketed literals
  out=$(printf '%s' "$out" \
    | sed -E "s/\x01/\\\\(.*\\\\)/g; s/\x02/\\\\[.*\\\\]/g; s/\x03/\\\\{.*\\\\}/g; s/\x04/.*/g")
  printf '%s' "$out"
}

# Print every parsed pattern (one per line) from the sentinel-bounded slice
# of the markdown source. De-duped, order-preserving.
silencing_gate_patterns() {
  if [[ ! -f "$SILENCING_GATE_PATTERNS_MD" ]]; then
    return 1
  fi
  awk '
    /<!-- silencing-gate:begin/ { inside=1; next }
    /silencing-gate:end -->/    { inside=0; next }
    inside { print }
  ' "$SILENCING_GATE_PATTERNS_MD" \
  | grep -oE '`[^`]+`' \
  | sed -E 's/^`//; s/`$//' \
  | awk '!seen[$0]++' \
  | while IFS= read -r tok; do
      [[ -z "$tok" ]] && continue
      silencing_gate_token_to_regex "$tok"
      printf '\n'
    done
}

# --- Path filter ------------------------------------------------------------
silencing_gate_path_allowed() {
  local path="$1"
  [[ -z "$path" ]] && return 1
  printf '%s' "$path" | grep -Eq -- "$SILENCING_GATE_ALLOWLIST_RE"
}

# --- Scan -------------------------------------------------------------------
# silencing_gate_scan_staged_added
# Print "<path>:<line-preview>:<matched-pattern>" for every staged ADDITION
# (lines starting with `+` in `git diff --cached -U0`, excluding `+++` file
# headers and allowlisted paths). Exit 0 if any hit, 1 if clean.
# Honours $SKIP_SILENCING_GATE=1 by always reporting clean.
silencing_gate_scan_staged_added() {
  if [[ "${SKIP_SILENCING_GATE:-0}" == "1" ]]; then
    return 1
  fi
  local patterns=()
  local pat
  while IFS= read -r pat; do
    [[ -n "$pat" ]] && patterns+=("$pat")
  done < <(silencing_gate_patterns)
  if [[ ${#patterns[@]} -eq 0 ]]; then
    printf "silencing-gate: no patterns parsed from %s — refusing to run\n" \
      "$SILENCING_GATE_PATTERNS_MD" >&2
    return 2
  fi

  local current_path="" hits=0 line preview p
  # `-U0` = no context. Filter `--diff-filter=ACM` = added/copied/modified
  # (renames are flagged as adds in the new path — by design).
  while IFS= read -r line; do
    case "$line" in
      "+++ b/"*)
        current_path="${line#+++ b/}"
        ;;
      "+++ /dev/null")
        current_path=""
        ;;
      "+"*)
        # Skip the `+` itself; never match on file headers.
        [[ -z "$current_path" ]] && continue
        silencing_gate_path_allowed "$current_path" && continue
        preview="${line:1}"
        for p in "${patterns[@]}"; do
          if printf '%s' "$preview" | grep -Eq -- "$p"; then
            # Trim long previews for output.
            local short="$preview"
            if [[ ${#short} -gt 120 ]]; then
              short="${short:0:117}..."
            fi
            printf '%s: %s  ⟵  /%s/\n' "$current_path" "$short" "$p"
            hits=1
            break
          fi
        done
        ;;
    esac
  done < <(git diff --cached -U0 --diff-filter=ACM)

  [[ $hits -eq 1 ]]
}
