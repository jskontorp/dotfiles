#!/usr/bin/env bash
# Bidirectional sync of the volve-ai project memory dir between this host
# and oracle. Fired by Claude Code SessionStart.
#
# The auto-memory path slug encodes the absolute checkout path, so the two
# hosts store the *same logical content* under different directories:
#   mac    (~/code/work/volve-ai):  ~/.claude/projects/-Users-jorgens-kontorp-code-work-volve-ai/memory/
#   oracle (~/code/work/volve-ai):  ~/.claude/projects/-home-ubuntu-code-work-volve-ai/memory/
#
# Strategy: when on mac (the user's primary work machine, with an SSH alias
# `oracle` configured) do bidirectional rsync. When on oracle do nothing —
# writes made during the oracle session propagate back via mac's next
# SessionStart pull. This avoids requiring reverse SSH from oracle to mac.
#
# Conflict policy: rsync --update keeps the newer mtime per file. Files
# only ever appended-to or replaced (auto-memory semantics) converge
# cleanly. Deletes don't propagate — a `MEMORY.md` entry the user asked
# to forget will be removed in-place by the writing session, and the
# delete will replicate as "smaller file with newer mtime" via --update.

set -euo pipefail

MAC_DIR="$HOME/.claude/projects/-Users-jorgens-kontorp-code-work-volve-ai/memory/"
ORACLE_DIR_ON_ORACLE="$HOME/.claude/projects/-home-ubuntu-code-work-volve-ai/memory/"
ORACLE_DIR_VIA_MAC="oracle:.claude/projects/-home-ubuntu-code-work-volve-ai/memory/"

# Only sync when the active Claude session is inside a volve-ai project —
# keeps the hook silent + skips a network round-trip for unrelated work.
case "${CLAUDE_PROJECT_DIR:-$PWD}" in
  *volve-ai*) ;;
  *) exit 0 ;;
esac

case "$(uname -s)" in
  Darwin)
    mkdir -p "$MAC_DIR"
    # Pull first so newer writes from a recent oracle session land before
    # we push. Then push so any mac-side writes since the last sync go up.
    rsync -a --update --timeout=5 "$ORACLE_DIR_VIA_MAC" "$MAC_DIR" 2>/dev/null || true
    rsync -a --update --timeout=5 "$MAC_DIR" "$ORACLE_DIR_VIA_MAC" 2>/dev/null || true
    ;;
  Linux)
    # Oracle session: write locally; sync converges on mac's next start.
    # If reverse SSH from oracle to mac ever gets configured, this branch
    # can mirror the Darwin block against a `mac:` alias.
    mkdir -p "$ORACLE_DIR_ON_ORACLE"
    ;;
esac
