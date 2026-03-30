#!/bin/bash
# Validate the dotfiles install in clean Docker containers.
# Usage: ./test/verify.sh [vm|mac|both]
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

  printf "Running install.sh...\n"
  dexec bash -c "cd ~/dotfiles && ./install.sh"
  printf "\nVerifying...\n"

  # --- Shared ---
  check "~/.gitconfig symlinked"            'dexec test -L /home/testuser/.gitconfig'
  check "~/.pi/agent/AGENTS.md symlinked"   'dexec test -L /home/testuser/.pi/agent/AGENTS.md'
  check "~/.pi/agent/skills symlinked"      'dexec test -L /home/testuser/.pi/agent/skills'
  check "10 skills present"                 'dexec bash -c "[ \$(ls ~/.pi/agent/skills | wc -l) -eq 10 ]"'
  check "bat theme symlinked"              'dexec test -L "/home/testuser/.config/bat/themes/Catppuccin Mocha.tmTheme"'

  # --- Machine configs ---
  check "~/.zshrc symlinked"               'dexec test -L /home/testuser/.zshrc'
  check "~/.tmux.conf symlinked"           'dexec test -L /home/testuser/.tmux.conf'
  check "starship.toml symlinked"          'dexec test -L /home/testuser/.config/starship.toml'
  check "lazygit config symlinked"         'dexec bash -c "test -L \$(find ~/.config -path */lazygit/config.yml 2>/dev/null || echo /nonexistent)"'

  # --- zsh helpers ---
  check "git-helpers.zsh linked"           'dexec test -L /home/testuser/.config/zsh/git-helpers.zsh'

  if [[ "$machine" == "mac" ]]; then
    check "sv-proxy.zsh linked"            'dexec test -L /home/testuser/.config/zsh/sv-proxy.zsh'
    check "ssh-theme.zsh linked"           'dexec test -L /home/testuser/.config/zsh/ssh-theme.zsh'
    check "sv-completion.zsh absent"       'dexec bash -c "! test -e /home/testuser/.config/zsh/sv-completion.zsh"'
    check "~/.ssh/config linked"           'dexec test -L /home/testuser/.ssh/config'
    check "Ghostty config linked"          'dexec test -L "/home/testuser/Library/Application Support/com.mitchellh.ghostty/config"'
  fi

  if [[ "$machine" == "vm" ]]; then
    check "sv-completion.zsh linked"       'dexec test -L /home/testuser/.config/zsh/sv-completion.zsh'
    check "sv-proxy.zsh absent"            'dexec bash -c "! test -e /home/testuser/.config/zsh/sv-proxy.zsh"'
    check "ssh-theme.zsh absent"           'dexec bash -c "! test -e /home/testuser/.config/zsh/ssh-theme.zsh"'
    check "~/.local/bin/sv linked"         'dexec test -L /home/testuser/.local/bin/sv'
    check "~/.config/nvim linked"          'dexec test -L /home/testuser/.config/nvim'
  fi

  # --- Project: valuesync_os ---
  local vs
  if [[ "$machine" == "mac" ]]; then vs="/home/testuser/code/valuesync_os"; else vs="/home/testuser/work/valuesync_os"; fi

  check "valuesync_os .pi/skills linked"   "dexec test -L $vs/.pi/skills"
  check "valuesync_os .pi/extensions linked" "dexec test -L $vs/.pi/extensions"
  check "5 project skills"                 "dexec bash -c '[ \$(ls $vs/.pi/skills | wc -l) -eq 5 ]'"
  check "3 extension entries"              "dexec bash -c '[ \$(ls $vs/.pi/extensions | wc -l) -eq 3 ]'"

  # --- Integrity ---
  check "no broken symlinks" \
    'dexec bash -c "! find /home/testuser -maxdepth 5 -type l ! -exec test -e {} \; -print 2>/dev/null | grep -qv .git"'

  check "zshrc sources cleanly" \
    'dexec zsh -i -c "exit 0"'

  check "install.sh is idempotent" \
    'dexec bash -c "cd ~/dotfiles && ./install.sh"'

  # --- Skill content spot checks ---
  check "delegate has scripts/" \
    'dexec test -d /home/testuser/.pi/agent/skills/delegate/scripts'
  check "solve-ticket has no skill-loading table" \
    'dexec bash -c "! grep -q \"Load skills when\" ~/.pi/agent/skills/solve-ticket/SKILL.md"'
  check "AGENTS.md contains NAJA" \
    'dexec grep -q NAJA /home/testuser/.pi/agent/AGENTS.md'

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
