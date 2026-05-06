#!/bin/bash
# Validate the dotfiles install in clean Docker containers.
# Usage: ./test/verify.sh [vm|mac|both]
#
# shellcheck disable=SC2294  # eval in check() is the intended test-harness pattern
# shellcheck disable=SC2016  # single-quoted command strings are eval'd, not expanded here
set -euo pipefail

DOTFILES="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-both}"

if ! command -v docker &>/dev/null; then
  cat >&2 <<'EOF'
❌ docker not found on PATH.

`just test` runs install.sh inside clean Linux/macOS-shim containers and
requires a Docker runtime. Most edits don't need it — `just check` covers
the host-side suite (justfile parity, manifest integrity, bash portability)
and is what the pre-commit hook runs.

To enable the full suite, install one of:
  brew install orbstack          # lighter on macOS
  brew install --cask docker     # Docker Desktop

Then start the runtime and re-run `just test`. (See machine/mac/Brewfile
for the opt-in cask lines.)
EOF
  exit 1
fi

# PID suffix isolates parallel invocations of this script (e.g. `just test`
# in one pane while `just test vm` runs in another) so they don't share a
# container name and stomp each other's `docker rm -f`.
RUN_ID=$$
trap 'docker rm -f "dotfiles-verify-vm-$RUN_ID" "dotfiles-verify-mac-$RUN_ID" >/dev/null 2>&1 || true' EXIT INT TERM

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
  CONTAINER="dotfiles-verify-$machine-$RUN_ID"

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
  # Pre-existing user-authored file the uninstall block asserts survives.
  # bootstrap.sh would normally create this from interactive prompts; here
  # we seed it directly so the assertion has something to check against.
  dexec bash -c "printf '[user]\n\tname = Test User\n\temail = test@example.com\n' > ~/.gitconfig.local"

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

    # --- sv-proxy _sv_ticket_port parity with VM ticket_port ---
    printf "\nsv-proxy _sv_ticket_port:\n"
    dexec zsh -c 'sed -n "/_sv_ticket_port()/,/^}/p" ~/.config/zsh/sv-proxy.zsh > /tmp/sv_ticket_port.zsh'
    check "tech-123 → 3123"     'dexec zsh -c "source /tmp/sv_ticket_port.zsh; [[ \$(_sv_ticket_port tech-123) == 3123 ]]"'
    check "tech-1234 → 3234"    'dexec zsh -c "source /tmp/sv_ticket_port.zsh; [[ \$(_sv_ticket_port tech-1234) == 3234 ]]"'
    check "tech-0 → 3000"       'dexec zsh -c "source /tmp/sv_ticket_port.zsh; [[ \$(_sv_ticket_port tech-0) == 3000 ]]"'
  fi
  if [[ "$machine" == "vm" ]]; then
    check "sv-proxy.zsh absent"            'dexec bash -c "! test -e /home/testuser/.config/zsh/sv-proxy.zsh"'
    check "ssh-theme.zsh absent"           'dexec bash -c "! test -e /home/testuser/.config/zsh/ssh-theme.zsh"'

    # --- sv ticket_port logic ---
    # Extract just the function (can't source sv — top-level code exits outside a repo)
    printf "\nsv ticket_port:\n"
    dexec zsh -c 'sed -n "/^ticket_port()/,/^}/p" ~/.local/bin/sv > /tmp/ticket_port.zsh'
    check "tech-1 → 3001"       'dexec zsh -c "source /tmp/ticket_port.zsh; [[ \$(ticket_port tech-1) == 3001 ]]"'
    check "tech-123 → 3123"     'dexec zsh -c "source /tmp/ticket_port.zsh; [[ \$(ticket_port tech-123) == 3123 ]]"'
    check "tech-1234 → 3234"    'dexec zsh -c "source /tmp/ticket_port.zsh; [[ \$(ticket_port tech-1234) == 3234 ]]"'
    check "tech-8 → 3008"       'dexec zsh -c "source /tmp/ticket_port.zsh; [[ \$(ticket_port tech-8) == 3008 ]]"'
    check "tech-0 → 3000"       'dexec zsh -c "source /tmp/ticket_port.zsh; [[ \$(ticket_port tech-0) == 3000 ]]"'
    check "tech-0000 → 3000"    'dexec zsh -c "source /tmp/ticket_port.zsh; [[ \$(ticket_port tech-0000) == 3000 ]]"'
    check "tech-2123 → 3123 (collision with tech-123)" \
                                'dexec zsh -c "source /tmp/ticket_port.zsh; [[ \$(ticket_port tech-2123) == 3123 ]]"'
  fi

  # --- Config syntax validation ---
  printf "\nConfig syntax:\n"
  check "gitconfig parses cleanly"         'dexec git config --file /home/testuser/.gitconfig --list'

  # --- pi-notion-routing cwd → auth file mapping ---
  printf "\npi-notion-routing auth mapping:\n"
  check "personal: ~/code/personal/foo → personal" \
    'dexec zsh -c "source ~/.config/zsh/pi-notion-routing.zsh; [[ \$(_pi_notion_auth_file /home/testuser/code/personal/foo) == */notion-mcp-auth-personal.json ]]"'
  check "personal wins over volve segment" \
    'dexec zsh -c "source ~/.config/zsh/pi-notion-routing.zsh; [[ \$(_pi_notion_auth_file /home/testuser/code/personal/volve-notes) == */notion-mcp-auth-personal.json ]]"'
  check "volve: /repos/volve/api → volve" \
    'dexec zsh -c "source ~/.config/zsh/pi-notion-routing.zsh; [[ \$(_pi_notion_auth_file /repos/volve/api) == */notion-mcp-auth-volve.json ]]"'
  check "volve: trailing segment /srv/volve → volve" \
    'dexec zsh -c "source ~/.config/zsh/pi-notion-routing.zsh; [[ \$(_pi_notion_auth_file /srv/volve) == */notion-mcp-auth-volve.json ]]"'
  check "volve: underscore separator /srv/x_volve_y → volve" \
    'dexec zsh -c "source ~/.config/zsh/pi-notion-routing.zsh; [[ \$(_pi_notion_auth_file /srv/x_volve_y) == */notion-mcp-auth-volve.json ]]"'
  check "no match: /tmp/foo → empty (default fallback)" \
    'dexec zsh -c "source ~/.config/zsh/pi-notion-routing.zsh; [[ -z \$(_pi_notion_auth_file /tmp/foo) ]]"'
  check "no false positive: /srv/evolve/x → empty" \
    'dexec zsh -c "source ~/.config/zsh/pi-notion-routing.zsh; [[ -z \$(_pi_notion_auth_file /srv/evolve/x) ]]"'

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
  check "at least 5 skill symlinks"        'dexec bash -c "[[ \$(find ~/.pi/agent/skills -maxdepth 1 -type l | wc -l) -ge 5 ]]"'
  check "settings.json lists pi-linear-tools package" \
    'dexec grep -q "@fink-andreas/pi-linear-tools" /home/testuser/.pi/agent/settings.json'
  check "settings.json lists pi-notion package" \
    'dexec grep -q "@feniix/pi-notion" /home/testuser/.pi/agent/settings.json'

  # --- Claude Code linking ---
  printf "\nClaude Code linking:\n"
  check "\$HOME/.claude/CLAUDE.md is a regular file (not symlink)" \
    'dexec bash -c "[[ -f /home/testuser/.claude/CLAUDE.md && ! -L /home/testuser/.claude/CLAUDE.md ]]"'
  check "CLAUDE.md @-import path is substituted to absolute" \
    'dexec grep -q "^@/home/testuser/dotfiles/pi/agent/AGENTS.md" /home/testuser/.claude/CLAUDE.md'
  check "CLAUDE.md has no unsubstituted \$DOTFILES" \
    'dexec bash -c "! grep -q \"\\\\\$DOTFILES\" /home/testuser/.claude/CLAUDE.md"'
  check "imported AGENTS.md exists at the substituted path" \
    'dexec test -f /home/testuser/dotfiles/pi/agent/AGENTS.md'
  # Mirror invariant: each skill in pi/agent/skills/ is mirrored to
  # ~/.claude/skills/ unless its SKILL.md frontmatter sets
  # `claude-compatible: false`. Derived from frontmatter so adding/removing
  # a skill doesn't require touching this test.
  for skill_dir in "$DOTFILES/pi/agent/skills"/*/; do
    [[ -d "$skill_dir" ]] || continue
    name="$(basename "$skill_dir")"
    skill_md="$skill_dir/SKILL.md"
    [[ -f "$skill_md" ]] || continue
    if grep -Eq '^claude-compatible:[[:space:]]*false[[:space:]]*$' "$skill_md"; then
      check "claude excluded: $name" \
        "dexec bash -c \"! test -e /home/testuser/.claude/skills/$name\""
    else
      check "claude mirrored: $name" \
        "dexec test -L /home/testuser/.claude/skills/$name"
    fi
  done

  # --- Claude Code agents (~/.claude/agents/) ---
  # Scoped to Claude-authored subagents only — pi skills legitimately use
  # Bash(pi:*) / linear tool names, so global grep would false-positive.
  printf "\nClaude Code agents:\n"
  check "\$HOME/.claude/agents/solve-ticket.md is a live symlink" \
    'dexec bash -c "[[ -L /home/testuser/.claude/agents/solve-ticket.md && -e /home/testuser/.claude/agents/solve-ticket.md ]]"'
  check "solve-ticket agent has no Bash(pi:*) refs" \
    'dexec bash -c "! grep -q \"Bash(pi:\\*)\" /home/testuser/.claude/agents/solve-ticket.md"'
  check "solve-ticket agent has no \"pi -p\" invocations" \
    'dexec bash -c "! grep -Eq \"\\\\bpi -p\\\\b\" /home/testuser/.claude/agents/solve-ticket.md"'
  check "solve-ticket agent has no claude-compatible frontmatter (wrong schema)" \
    'dexec bash -c "! grep -q \"^claude-compatible:\" /home/testuser/.claude/agents/solve-ticket.md"'
  check "solve-ticket agent has no allowed-tools frontmatter (wrong schema)" \
    'dexec bash -c "! grep -q \"^allowed-tools:\" /home/testuser/.claude/agents/solve-ticket.md"'
  check "solve-ticket agent tools: is single-line CSV" \
    'dexec bash -c "[[ \$(grep -c \"^tools:\" /home/testuser/.claude/agents/solve-ticket.md) -eq 1 ]]"'
  check "solve-ticket referenced scripts exist" \
    'dexec bash -c "test -x /home/testuser/dotfiles/pi/agent/skills/solve-ticket/scripts/workspace-setup.sh && test -x /home/testuser/dotfiles/pi/agent/skills/solve-ticket/scripts/dev-server.sh && test -x /home/testuser/dotfiles/pi/agent/skills/solve-ticket/scripts/peer-review-spawn.sh"'

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

  # --- Uninstall cycle ---
  # Verifies uninstall.sh: state-drift skips, foreign-target skips, manifest
  # removal, post-uninstall+reinstall byte-equality of the manifest
  # (strongest claim: install is deterministic enough that round-tripping
  # through uninstall produces the same set of links in the same order),
  # and the no-manifest no-op branch.
  printf "\nUninstall cycle:\n"
  # Snapshot the post-install manifest before any tampering.
  dexec bash -c "cp ~/dotfiles/.install-manifest /tmp/manifest.first"
  # Seed two states uninstall must distinguish: (a) the manifest-tracked
  # symlink replaced by a regular file (state drift — must be preserved,
  # could contain user content), and (b) the manifest-tracked symlink
  # whose target was changed to point outside $DOTFILES (still a symlink
  # at a manifest path — the manifest is the contract, must be removed
  # whatever the target). Targeting outside-of-$DOTFILES also covers the
  # marketplace-skills case where install.sh legitimately points symlinks
  # at ~/.local/share/pi-skills/ caches.
  dexec bash -c "rm ~/.config/zsh/git-aliases.zsh && echo 'user content' > ~/.config/zsh/git-aliases.zsh"  # state drift
  dexec bash -c "ln -sfn /tmp/foreign-target ~/.config/zsh/git-worktrees.zsh"                              # manifest-tracked, foreign target
  dexec bash -c "cd ~/dotfiles && ./uninstall.sh" >/dev/null

  check "manifest deleted"                 'dexec bash -c "! test -e ~/dotfiles/.install-manifest"'
  check "a non-seeded manifest entry is gone" \
    'dexec bash -c "! test -e ~/.zshrc"'
  check "in-repo pre-commit symlink gone"  'dexec bash -c "! test -L ~/dotfiles/.git/hooks/pre-commit"'
  check "state-drift file preserved"       'dexec bash -c "[[ \$(cat ~/.config/zsh/git-aliases.zsh) == \"user content\" ]]"'
  check "manifest-tracked foreign-target symlink removed" \
    'dexec bash -c "! test -L ~/.config/zsh/git-worktrees.zsh"'
  check "marketplace-skill symlinks removed (target outside \$DOTFILES)" \
    'dexec bash -c "! test -L ~/.pi/agent/skills/typescript-advanced-types"'
  check "gitconfig.local survives uninstall" 'dexec bash -c "grep -q test@example.com ~/.gitconfig.local"'
  check "pi settings.json survives uninstall"  'dexec bash -c "test -f ~/.pi/agent/settings.json"'
  check "claude CLAUDE.md survives uninstall"  'dexec bash -c "test -f ~/.claude/CLAUDE.md"'

  # Clean up the state-drift seed so re-install can proceed normally.
  # (The foreign-target symlink seed was already removed by uninstall.)
  dexec bash -c "rm -f ~/.config/zsh/git-aliases.zsh"
  dexec bash -c "cd ~/dotfiles && ./install.sh" >/dev/null

  check "reinstall manifest matches first install (byte-equal)" \
    'dexec bash -c "diff -q /tmp/manifest.first ~/dotfiles/.install-manifest"'

  # Idempotent uninstall: second run hits the no-manifest branch.
  dexec bash -c "cd ~/dotfiles && ./uninstall.sh" >/dev/null
  check "second uninstall removes manifest again" \
    'dexec bash -c "! test -e ~/dotfiles/.install-manifest"'
  check "third uninstall is a no-op (no manifest)" \
    'dexec bash -c "cd ~/dotfiles && ./uninstall.sh | grep -q \"nothing to do\""'

  # Restore install state for any later checks (none today, but keeps the
  # container in a sensible terminal state for ad-hoc inspection).
  dexec bash -c "cd ~/dotfiles && ./install.sh" >/dev/null

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
