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
SEP=$'\e[38;2;110;115;141m'    # #6e738d — separators
# Gradient endpoints (#a6da95 green, #ed8796 red) are inlined in zone_color.

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

# --- Gradient color: green ≤10%, linear ramp to red at 80%, red beyond.
#     Endpoints match Catppuccin Macchiato green (#a6da95) and red (#ed8796). ---
zone_color() {
  local pct=${1%.*}
  [ -z "$pct" ] && { printf '%s' "$MUTED"; return; }
  local r g b
  if   [ "$pct" -le 10 ]; then r=166; g=218; b=149
  elif [ "$pct" -ge 80 ]; then r=237; g=135; b=150
  else
    # t = (pct-10)/70, scaled by 1000 for integer math.
    local t=$(( (pct - 10) * 1000 / 70 ))
    r=$(( 166 + t * (237 - 166) / 1000 ))
    g=$(( 218 + t * (135 - 218) / 1000 ))
    b=$(( 149 + t * (150 - 149) / 1000 ))
  fi
  printf '\e[38;2;%d;%d;%dm' "$r" "$g" "$b"
}

# --- 20-cell bar, 5% per cell. ---
make_bar() {
  local pct=${1:-0}; pct=${pct%.*}; [ -z "$pct" ] && pct=0
  local cells=20
  local fill=$(( pct * cells / 100 ))
  [ "$fill" -gt "$cells" ] && fill=$cells
  local i out=""
  for ((i=0; i<cells; i++)); do
    if [ "$i" -lt "$fill" ]; then out+="█"; else out+="░"; fi
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
