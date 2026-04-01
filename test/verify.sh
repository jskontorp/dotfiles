#!/bin/bash
# Validate the dotfiles install in clean Docker containers.
# Usage: ./test/verify.sh [vm|mac|both]
#
# shellcheck disable=SC2294  # eval in check() is the intended test-harness pattern
# shellcheck disable=SC2016  # single-quoted command strings are eval'd, not expanded here
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-both}"

PASS=0
FAIL=0

check() {
  local desc="$1"; shift
  if eval "$@" >/dev/null 2>&1; then
    printf "  ✅ %s\n" "$desc"
    PASS=$((PASS + 1))
  else
    printf "  ❌ %s\n" "$desc"
    FAIL=$((FAIL + 1))
  fi
}

dexec() {
  docker exec "$CONTAINER" "$@"
}

run_test() {
  local machine="$1"
  local image="dotfiles-test-$machine"
  CONTAINER="dotfiles-verify-$machine"

  printf "\n=== Testing %s install ===\n\n" "$machine"

  docker build -q -t "$image" -f "$DOTFILES/test/Dockerfile.$machine" "$DOTFILES" || { echo "Build failed"; return 1; }
  docker rm -f "$CONTAINER" 2>/dev/null || true
  docker run -d --name "$CONTAINER" "$image" sleep 3600 >/dev/null

  # --- Seed old state for migration tests ---
  printf "Seeding old state...\n"
  dexec bash -c "mkdir -p ~/.config/zsh ~/old_dotfiles/zsh"
  dexec bash -c "echo '# old sv completion' > ~/old_dotfiles/zsh/sv.zsh"
  dexec bash -c "ln -sf ~/old_dotfiles/zsh/sv.zsh ~/.config/zsh/sv.zsh"
  dexec bash -c "ln -sf /nonexistent/old-helper.zsh ~/.config/zsh/old-helper.zsh"

  printf "Running install.sh...\n"
  dexec bash -c "cd ~/dotfiles && ./install.sh"

  # --- Symlinks (manifest-driven) ---
  # install.sh records every symlink to .install-manifest via _link/_linkd.
  # validate-manifest.sh checks each entry is a valid symlink with a live
  # target, verifies the count is sane, and detects raw ln calls that
  # bypassed the manifest.
  printf "\nSymlinks:\n"
  if dexec bash /home/testuser/dotfiles/test/validate-manifest.sh; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi

  # --- Platform correctness: wrong-platform files must be absent ---
  printf "\nPlatform correctness:\n"
  if [[ "$machine" == "mac" ]]; then
    check "sv-completion.zsh absent"       'dexec bash -c "! test -e /home/testuser/.config/zsh/sv-completion.zsh"'
  fi
  if [[ "$machine" == "vm" ]]; then
    check "sv-proxy.zsh absent"            'dexec bash -c "! test -e /home/testuser/.config/zsh/sv-proxy.zsh"'
    check "ssh-theme.zsh absent"           'dexec bash -c "! test -e /home/testuser/.config/zsh/ssh-theme.zsh"'
  fi

  # --- Config syntax validation ---
  printf "\nConfig syntax:\n"
  check "gitconfig parses cleanly"         'dexec git config --file /home/testuser/.gitconfig --list'

  # --- Install integrity ---
  printf "\nIntegrity:\n"
  check "no broken symlinks in \$HOME" \
    'dexec bash -c "! find /home/testuser -maxdepth 5 -type l ! -exec test -e {} \; -print 2>/dev/null | grep -qv .git"'
  check "zshrc sources cleanly" \
    'dexec zsh -i -c "exit 0"'
  check "install.sh is idempotent" \
    'dexec bash -c "cd ~/dotfiles && ./install.sh"'

  # --- Migration cleanup ---
  printf "\nMigration:\n"
  check "orphan sv.zsh removed"            'dexec bash -c "! test -e /home/testuser/.config/zsh/sv.zsh"'
  check "stale broken symlink removed"     'dexec bash -c "! test -L /home/testuser/.config/zsh/old-helper.zsh"'

  # --- Skill content spot checks ---
  printf "\nSkill content:\n"
  check "delegate has scripts/"            'dexec test -d /home/testuser/.pi/agent/skills/delegate/scripts'
  check "solve-ticket has no skill-loading table" \
    'dexec bash -c "! grep -q \"Load skills when\" ~/.pi/agent/skills/solve-ticket/SKILL.md"'
  check "AGENTS.md contains NAJA"          'dexec grep -q NAJA /home/testuser/.pi/agent/AGENTS.md'

  # --- Shell behaviour ---
  printf "\nShell behaviour:\n"
  check "core: EDITOR=nvim"               'dexec zsh -i -c "[[ \$EDITOR == nvim ]]"'
  check "core: HISTSIZE=10000"             'dexec zsh -i -c "[[ \$HISTSIZE -eq 10000 ]]"'
  check "core: auto_cd enabled"            'dexec zsh -i -c "[[ -o auto_cd ]]"'
  check "core: cat alias"                  'dexec zsh -i -c "whence -w cat | grep -q alias"'
  check "core: ls alias"                   'dexec zsh -i -c "whence -w ls | grep -q alias"'
  check "git alias: gco"                   'dexec zsh -i -c "whence -w gco | grep -q alias"'
  check "git alias: grr"                   'dexec zsh -i -c "whence -w grr | grep -q alias"'
  check "git fn: gdc"                      'dexec zsh -i -c "whence -w gdc | grep -q function"'
  check "git fn: gae"                      'dexec zsh -i -c "whence -w gae | grep -q function"'
  check "git fn: gcof"                     'dexec zsh -i -c "whence -w gcof | grep -q function"'
  check "git fn: gwt"                      'dexec zsh -i -c "whence -w gwt | grep -q function"'
  check "git fn: gwts"                     'dexec zsh -i -c "whence -w gwts | grep -q function"'
  check "git fn: gwtr"                     'dexec zsh -i -c "whence -w gwtr | grep -q function"'
  check "git fn: _gwt_root (internal)"     'dexec zsh -i -c "whence -w _gwt_root | grep -q function"'

  # --- Re-source safety ---
  printf "\nRe-source safety:\n"
  check "re-source safe (no dupes, no FUNCNEST)" \
    'dexec zsh -i /home/testuser/dotfiles/test/resource-check.zsh'
  check "core not double-sourced"          'dexec zsh -i -c "source ~/.zshrc; c=0; for f in \$chpwd_functions; do [[ \$f == __osc7_cwd ]] && ((c++)); done; (( c == 1 ))"'

  docker rm -f "$CONTAINER" >/dev/null 2>&1
  printf "\n"
}

# --- Run ---
[[ "$TARGET" == "both" || "$TARGET" == "vm" ]] && run_test vm
[[ "$TARGET" == "both" || "$TARGET" == "mac" ]] && run_test mac

printf "=== Results ===\n"
printf "  Passed: %d\n" "$PASS"
if [[ $FAIL -gt 0 ]]; then
  printf "  Failed: %d\n" "$FAIL"
  exit 1
else
  printf "  Failed: 0\n"
  printf "\nAll checks passed.\n"
fi
