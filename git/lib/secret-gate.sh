#!/bin/bash
# Secret-path matcher (JSK-35). Sourced by git/hooks/pre-commit and
# test/check-secret-gate.sh; the canonical pattern set lives here so both
# the hook and the test see the same regex.
#
# This file mirrors (in shape) the patterns in:
#   - pi/agent/extensions/secret-read-gate.ts  (pi harness gate)
#   - claude/settings.json                     (Claude deny block, Read/Edit/Write)
# When changing patterns here, update the other two surfaces in the same commit.
#
# Bash 3.2 portable (no `mapfile`, no `${var,,}`); BSD/GNU `grep -E` portable.
# Intentionally case-sensitive — secrets in this set are conventionally lowercase.
#
# Curated, not exhaustive. Won't catch custom-named SSH keys (`id_rsa_work`,
# `~/.ssh/personal`) or arbitrary user-named credential files. The pattern set
# is tuned for near-zero false positives on conventional names; widen it
# deliberately and update all three surfaces (this file, the .ts extension,
# claude/settings.json) in the same commit.

# --- Patterns ----------------------------------------------------------------
# Each entry is a basic ERE matched against the path with `grep -E`. Anchored
# with `(^|/)` for basename matches, otherwise file-extension matches.
SECRET_GATE_PATTERNS=(
  # dotenv family — `.env`, `.env.production`, `.env.local` …
  '(^|/)\.env(\.[^/]+)?$'
  # direnv config (can hold inline secrets)
  '(^|/)\.envrc$'
  # private keys & key-bearing containers
  '\.(pem|key|ppk|p12|pfx|jks|keystore)$'
  # SSH private keys (NOT .pub)
  '(^|/)id_(rsa|dsa|ecdsa|ed25519)$'
  # tool credential files
  '(^|/)(\.pgpass|\.netrc|\.htpasswd|\.npmrc|\.pypirc|\.terraformrc)$'
  # cloud / orchestrator credential layouts
  '(^|/)\.aws/credentials$'
  '(^|/)\.kube/config$'
  '(^|/)kubeconfig$'
  # cloud service-account JSON / generic secret bundles
  '(^|/)(secrets|credentials|service[-_]account[^/]*)\.(ya?ml|json)$'
  # terraform variable files (often hold secrets)
  '\.tfvars(\.json)?$'
)

# Suffixes that flip a positive into a negative — these are the canonical
# "sample / template" filenames that ship to source control intentionally.
# Matched as the very end of the path (case-sensitive).
SECRET_GATE_EXEMPT_SUFFIXES_RE='\.(example|sample|template|dist)$'

# --- API ---------------------------------------------------------------------
# secret_gate_match <path>
# Exit 0 (match) if <path> is a secret path that should be blocked.
# Exit 1 (no match) otherwise.
secret_gate_match() {
  local path="$1"
  [[ -z "$path" ]] && return 1
  # Exemption first: `.env.example` and friends are not secrets.
  if printf '%s' "$path" | grep -Eq "$SECRET_GATE_EXEMPT_SUFFIXES_RE"; then
    return 1
  fi
  local pat
  for pat in "${SECRET_GATE_PATTERNS[@]}"; do
    if printf '%s' "$path" | grep -Eq -- "$pat"; then
      return 0
    fi
  done
  return 1
}

# secret_gate_scan_staged
# Print every staged path (Added/Copied/Modified/Renamed) that matches.
# Exit 0 if any matched, 1 if clean. Caller decides what to do with output.
# Honours $SKIP_SECRET_GATE=1 by always reporting clean.
secret_gate_scan_staged() {
  if [[ "${SKIP_SECRET_GATE:-0}" == "1" ]]; then
    return 1
  fi
  local hits=0 path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if secret_gate_match "$path"; then
      printf '%s\n' "$path"
      hits=1
    fi
  done < <(git diff --cached --name-only --diff-filter=ACMR)
  [[ $hits -eq 1 ]]
}
