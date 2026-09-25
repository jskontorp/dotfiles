#!/usr/bin/env bash
# Review-time sweep for ad-hoc Homebrew installs. Companion to
# pi/agent/extensions/untracked-brew.ts, which gates `brew install` at
# call time; this script catches everything that slipped past — installs
# made outside pi, before the gate existed, or approved as one-offs.
#
# Untracked = installed-on-request formulae (brew leaves
# --installed-on-request) or casks (brew list --cask) absent from BOTH
# machine/mac/Brewfile AND machine/mac/Brewfile-untracked.acked.
# Advisory: always exits 0 when brew is present. Wired as `just
# brew-untracked`; run it whenever, or fold into your review ritual.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
command -v brew >/dev/null 2>&1 || { echo "brew not on PATH" >&2; exit 1; }

tracked="$(grep -E '^[[:space:]]*(brew|cask|mas|tap)[[:space:]]' Brewfile \
  | awk -F'"' '{print $2}' | sort -u)"
acked="$(sed -E 's/[[:space:]]*:.*$//; s/^#.*$//; s/[[:space:]]+//g' \
  Brewfile-untracked.acked 2>/dev/null | grep -v '^$' | sort -u)"
known="$(printf '%s\n%s\n' "$tracked" "$acked" | sort -u | grep -v '^$')"

leaves="$(brew leaves --installed-on-request | sort)"
casks="$(brew list --cask 2>/dev/null | sort)"
untracked_f="$(comm -23 <(printf '%s\n' "$leaves") <(printf '%s\n' "$known"))"
untracked_c="$(comm -23 <(printf '%s\n' "$casks") <(printf '%s\n' "$known"))"

if [[ -z "$untracked_f" && -z "$untracked_c" ]]; then
  echo "✅ no untracked brew packages (Brewfile + acked cover everything)"
  exit 0
fi
echo "⚠ Untracked Homebrew packages — decide each: track, ack, or uninstall:"
[[ -n "$untracked_f" ]] && { echo "  formulas:"; sed 's/^/    /' <<<"$untracked_f"; }
[[ -n "$untracked_c" ]] && { echo "  casks:"; sed 's/^/    /' <<<"$untracked_c"; }
echo "  track: add to machine/mac/Brewfile with a project comment"
echo "  ack:   append '<name>: reason' to machine/mac/Brewfile-untracked.acked"
echo "  drop:  brew uninstall <name>"
exit 0
