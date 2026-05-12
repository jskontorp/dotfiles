#!/bin/bash
# Tests for git/lib/secret-gate.sh + git/hooks/pre-commit secret-path block (JSK-35).
# Two layers:
#   1. Unit: feed positive/negative paths to secret_gate_match.
#   2. Integration: real `git init` tmprepo, real `git commit`, assert the hook
#      blocks/allows + that SKIP_SECRET_GATE=1 unblocks.
set -uo pipefail

# Critical: this script invokes `git init`, `git commit`, `git add` etc.
# inside a tmprepo (see integration cases). When run from inside a pre-commit
# hook context (via `just check`), git sets GIT_INDEX_FILE / GIT_DIR /
# GIT_WORK_TREE pointing at the *parent* commit's staging index and gitdir;
# subprocesses inherit them, so a `git commit` inside the tmprepo writes
# through to the parent's index, silently producing an empty commit on the
# parent. Unset all git env vars so this script's git invocations operate
# strictly on the tmprepo it sets up. Regression class:
# pi/agent/AGENTS.md "GIT_INDEX_FILE poisoning from pre-commit hook
# subprocesses".
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_DIR/git/lib/secret-gate.sh"
HOOK="$REPO_DIR/git/hooks/pre-commit"

if [[ ! -f "$LIB" ]]; then
  printf "  ❌ %s missing\n" "$LIB" >&2
  exit 1
fi
# shellcheck source=../git/lib/secret-gate.sh
. "$LIB"

errors=0

# --- Unit: match table -------------------------------------------------------
# Format: "expected<TAB>path"  (expected = "block" or "allow")
CASES=(
  "block	.env"
  "block	.env.production"
  "block	.env.local"
  "block	nested/dir/.env"
  "block	nested/.env.staging"
  "block	.envrc"
  "block	foo.pem"
  "block	certs/tls.key"
  "block	id_ed25519"
  "block	~/.ssh/id_rsa"
  "block	.pgpass"
  "block	.netrc"
  "block	.npmrc"
  "block	.aws/credentials"
  "block	.kube/config"
  "block	kubeconfig"
  "block	secrets.yaml"
  "block	credentials.json"
  "block	service-account-prod.json"
  "block	terraform.tfvars"
  "block	prod.tfvars.json"
  "block	.htpasswd"
  "block	keystore.jks"
  "allow	.env.example"
  "allow	.env.sample"
  "allow	.env.template"
  "allow	.env.dist"
  "allow	package-lock.json"
  "allow	id_ed25519.pub"
  "allow	id_rsa.pub"
  "allow	Pemfile"
  "allow	README.md"
  "allow	src/env.ts"
  "allow	docs/secrets.md"
  "allow	.gitignore"
)

printf "secret-gate unit cases:\n"
for entry in "${CASES[@]}"; do
  expected="${entry%%	*}"
  path="${entry#*	}"
  if secret_gate_match "$path"; then
    actual="block"
  else
    actual="allow"
  fi
  if [[ "$expected" == "$actual" ]]; then
    printf "  ✅ %-5s %s\n" "$actual" "$path"
  else
    printf "  ❌ expected %s, got %s for %s\n" "$expected" "$actual" "$path" >&2
    errors=$((errors + 1))
  fi
done

# --- Integration: real git commit through the hook --------------------------
# Stage scenarios in a throwaway repo and assert hook exit codes.
if [[ ! -x "$HOOK" ]]; then
  printf "  ❌ hook not executable: %s\n" "$HOOK" >&2
  errors=$((errors + 1))
fi

tmp="$(mktemp -d -t jsk35-secretgate.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

run_hook_in() {
  # $1 = mode: "block" or "allow"; $2 = label; remaining args = paths to stage.
  # Optional env: SKIP_SECRET_GATE.
  # Invokes the REAL pre-commit hook against a tmprepo so the BASH_SOURCE /
  # git rev-parse path resolution is exercised end-to-end. We assert based on
  # stderr containing the secret-gate marker rather than exit code: the rest
  # of the hook (shellcheck, just check) will fail in a non-dotfiles tmprepo,
  # and that's noise we don't care about for this test.
  local mode="$1" label="$2"; shift 2
  local sub log
  sub="$(mktemp -d "$tmp/case.XXXXXX")"
  log="$sub/hook.log"
  (
    cd "$sub" || exit 99
    git init -q
    git config user.email t@t && git config user.name t
    : > .keep && git add .keep && git commit -q -m init
    # Provide the lib at the path the hook will resolve via git rev-parse.
    mkdir -p git/lib
    cp "$LIB" git/lib/secret-gate.sh
    for f in "$@"; do
      mkdir -p "$(dirname "$f")"
      printf 'x\n' > "$f"
      git add -- "$f"
    done
    bash "$HOOK" >/dev/null 2>"$log" || true
  )
  if grep -q "secret-path gate: staged file(s) match" "$log"; then
    actual="block"
  else
    actual="allow"
  fi
  if [[ "$mode" == "$actual" ]]; then
    printf "  ✅ integration: %s (%s)\n" "$label" "$actual"
  else
    printf "  ❌ integration: %s expected %s got %s\n" "$label" "$mode" "$actual" >&2
    printf "     hook stderr:\n" >&2
    sed 's/^/       /' "$log" >&2
    errors=$((errors + 1))
  fi
}

printf "\nsecret-gate integration cases:\n"
run_hook_in block "stage .env blocks"                              .env
run_hook_in block "stage nested/.env.production blocks"            nested/.env.production
run_hook_in block "stage foo.pem blocks"                           foo.pem
run_hook_in block "stage id_ed25519 blocks"                        id_ed25519
run_hook_in allow "stage .env.example allows"                      .env.example
run_hook_in allow "stage package-lock.json allows"                 package-lock.json
run_hook_in allow "stage id_ed25519.pub allows"                    id_ed25519.pub
SKIP_SECRET_GATE=1 run_hook_in allow "SKIP_SECRET_GATE=1 .env allows" .env

# --- Drift check: the three surfaces must agree on the canonical token set ---
# Cheap basename-token check: every key fragment in secret-gate.sh must appear
# (verbatim) in the .ts extension and in claude/settings.json. Catches the
# common regression where a new pattern lands in only one surface.
printf "\nsecret-gate cross-surface drift:\n"
TS="$REPO_DIR/pi/agent/extensions/secret-read-gate.ts"
CLAUDE="$REPO_DIR/claude/settings.json"
DRIFT_TOKENS=(
  ".env"
  ".envrc"
  ".pem"
  ".key"
  ".ppk"
  ".p12"
  ".pfx"
  ".jks"
  ".keystore"
  "id_rsa"
  "id_ed25519"
  "id_ecdsa"
  "id_dsa"
  ".pgpass"
  ".netrc"
  ".htpasswd"
  ".npmrc"
  ".pypirc"
  ".terraformrc"
  ".aws/credentials"
  ".kube/config"
  "kubeconfig"
  "service-account"
  ".tfvars"
)
for tok in "${DRIFT_TOKENS[@]}"; do
  # Strip leading dot for substring matching: the .ts file embeds extension
  # tokens inside `(pem|key|...)` alternations without the leading `.`,
  # so checking for `pem` matches both `\.pem$` (claude/regex) and the
  # alternation form. False-positive surface is tiny for these tokens.
  needle="${tok#.}"
  # .ts surface: single bucket (the extension hooks every read tool).
  if tr -d '\\' < "$TS" | grep -qF -- "$needle"; then
    :
  else
    printf "  ❌ drift: token '%s' present in secret-gate.sh but missing in ts (%s)\n" "$tok" "$TS" >&2
    errors=$((errors + 1))
  fi
  # Claude surface: must appear under each of Read(, Edit(, Write( so the
  # deny is symmetric across read and write actions. A single bucket-wide
  # grep would silently miss a token that's only in Read. Uses two `grep -F`
  # passes (action prefix + needle substring) instead of `grep -E` with raw
  # interpolation — future tokens containing regex meta-chars (`.`, `*`,
  # `+`, `(`, `[`) would silently over-match under the ERE form and let real
  # drift through.
  for action in Read Edit Write; do
    if tr -d '\\' < "$CLAUDE" | grep -F "\"${action}(" | grep -qF -- "$needle"; then
      :
    else
      printf "  ❌ drift: token '%s' missing from claude/settings.json %s(...) deny\n" "$tok" "$action" >&2
      errors=$((errors + 1))
    fi
  done
done
if [[ $errors -eq 0 ]]; then
  printf "  ✅ all canonical tokens mirrored in .ts extension and claude/settings.json\n"
fi

if [[ $errors -eq 0 ]]; then
  printf "\n  ✅ all secret-gate tests passed\n"
  exit 0
else
  printf "\n  ❌ %d secret-gate test(s) failed\n" "$errors" >&2
  exit 1
fi
