#!/usr/bin/env bash
# Claude Code status line. Mirrors Starship aesthetic (Catppuccin Macchiato).
# Reads JSON session data on stdin; prints one styled line.
# Schema: https://code.claude.com/docs/en/statusline

set -u
input=$(cat)

# --- Catppuccin Macchiato truecolor escapes (ANSI-C quoting so \e renders) ---
RESET=$'\e[0m'
TEXT=$'\e[38;2;202;211;245m'   # #cad3f5 — directory / model
PEACH=$'\e[38;2;245;169;127m'  # #f5a97f — branch / mid zone
MUTED=$'\e[38;2;165;173;203m'  # #a5adcb — git flags
GREEN=$'\e[38;2;166;218;149m'  # #a6da95 — ok zone
RED=$'\e[38;2;237;135;150m'    # #ed8796 — danger zone
SEP=$'\e[38;2;110;115;141m'    # #6e738d — separators

# --- Pull fields, one per line so empty lines are preserved (bash 3.2 has no
#     mapfile, and whitespace IFS in `read` would collapse leading empty fields).
#     // "" turns null/missing into empty strings. ---
fields=()
while IFS= read -r line; do
  fields+=("$line")
done < <(jq -r '
  .model.display_name // "",
  .workspace.current_dir // .cwd // "",
  (.context_window.used_percentage // "" | tostring),
  (.rate_limits.five_hour.used_percentage // "" | tostring),
  (.rate_limits.seven_day.used_percentage // "" | tostring)
' <<<"$input")
model="${fields[0]:-}"
cwd="${fields[1]:-}"
ctx_pct="${fields[2]:-}"
r5="${fields[3]:-}"
rw="${fields[4]:-}"

# --- cwd: replace $HOME with ~, then keep last 2 path components. ---
short_cwd="${cwd/#$HOME/\~}"
short_cwd=$(awk -v p="$short_cwd" 'BEGIN{
  n=split(p, a, "/")
  if (n <= 3) print p
  else        print a[n-1] "/" a[n]
}')

# --- Git branch + dirty flags (skip locks; never block the status line). ---
branch=""
flags=""
if GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --show-toplevel >/dev/null 2>&1; then
  branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
        || GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  porcelain=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" status --porcelain=v1 -b 2>/dev/null)
  echo "$porcelain" | grep -qE '^.[MD]'  && flags+="!"   # worktree-modified/deleted
  echo "$porcelain" | grep -qE '^[MADRC]' && flags+="+"   # staged
  echo "$porcelain" | grep -q  '^?? '     && flags+="?"   # untracked
  hdr=$(echo "$porcelain" | head -1)
  echo "$hdr" | grep -q 'ahead'  && flags+="⇡"
  echo "$hdr" | grep -q 'behind' && flags+="⇣"
fi

# --- Threshold-based color. 80% is auto-compaction; 60% is a soft warning. ---
zone_color() {
  local pct=${1%.*}
  [ -z "$pct" ] && { printf '%s' "$MUTED"; return; }
  if   [ "$pct" -ge 80 ]; then printf '%s' "$RED"
  elif [ "$pct" -ge 60 ]; then printf '%s' "$PEACH"
  else                         printf '%s' "$GREEN"
  fi
}

# --- 21-char bar: 20 fill cells (5% each) with a tick inserted at the 80% mark. ---
make_bar() {
  local pct=${1:-0}; pct=${pct%.*}; [ -z "$pct" ] && pct=0
  local cells=20
  local mark=16
  local fill=$(( pct * cells / 100 ))
  [ "$fill" -gt "$cells" ] && fill=$cells
  local i out=""
  for ((i=0; i<=cells; i++)); do
    if   [ "$i" -eq "$mark" ]; then out+="│"
    else
      local idx=$i
      [ "$i" -gt "$mark" ] && idx=$((i-1))
      if [ "$idx" -lt "$fill" ]; then out+="█"; else out+="░"; fi
    fi
  done
  printf '%s' "$out"
}

# --- Assemble. Parts that lack data are simply omitted. ---
out=""
[ -n "$model"     ] && out+="${TEXT}${model}${RESET}  "
[ -n "$short_cwd" ] && out+="${TEXT}${short_cwd}${RESET}"
if [ -n "$branch" ]; then
  out+="  ${PEACH}${branch}${RESET}"
  [ -n "$flags" ] && out+=" ${MUTED}(${flags})${RESET}"
fi
if [ -n "$ctx_pct" ]; then
  c=$(zone_color "$ctx_pct")
  out+="  ${c}$(make_bar "$ctx_pct") ${ctx_pct%.*}%${RESET}"
fi
if [ -n "$r5" ]; then
  c=$(zone_color "$r5")
  out+="  ${SEP}·${RESET} ${c}5h:${r5%.*}%${RESET}"
fi
if [ -n "$rw" ]; then
  c=$(zone_color "$rw")
  out+=" ${SEP}·${RESET} ${c}w:${rw%.*}%${RESET}"
fi

printf '%s\n' "$out"
