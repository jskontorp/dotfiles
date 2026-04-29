#!/usr/bin/env bash
# session-scan: print a situational brief about the current repo.
#
# Always exits 0. Cross-platform (Linux + macOS). Plain stdout, no ANSI.
#
# Test hook: SESSION_SCAN_PROC_DIR overrides /proc for resolving a PID's cwd.
# When set, the script prefers "$SESSION_SCAN_PROC_DIR/<pid>/cwd" via readlink
# instead of /proc, even on systems where /proc would otherwise be present.
# Used by tests to exercise the Linux readlink path on macOS.
#
# Test hook: SESSION_SCAN_OWN_PID lets tests inject the "self" pid that the
# sibling-detection self-exclusion walks up from. Defaults to $$.

set -u

# ---------- helpers ----------

_have() { command -v "$1" >/dev/null 2>&1; }

# Resolve a PID's cwd. Echoes empty string on failure.
_pid_cwd() {
  local pid="$1"
  local proc_dir="${SESSION_SCAN_PROC_DIR:-/proc}"
  if [ -n "$pid" ] && [ -e "$proc_dir/$pid/cwd" ]; then
    readlink "$proc_dir/$pid/cwd" 2>/dev/null
    return
  fi
  if _have lsof; then
    # -a ANDs the filters (default is OR on BSD lsof). -Fn prints just the name field.
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/{print substr($0,2); exit}'
  fi
}

# Walk parent chain of a PID. Echoes the chain (one PID per line) including the
# starting PID. Stops at PID 1 or when ps fails.
_pid_ancestry() {
  local pid="$1"
  local count=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$count" -lt 16 ]; do
    echo "$pid"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    count=$((count + 1))
  done
}

# Format a duration in seconds into "Xh Ym ago" / "Xm Ys ago" / "Xs ago".
_human_ago() {
  local secs="$1"
  if [ "$secs" -lt 0 ]; then secs=0; fi
  local h=$((secs / 3600))
  local m=$(((secs % 3600) / 60))
  local s=$((secs % 60))
  if [ "$h" -gt 0 ]; then
    echo "${h}h ${m}m ago"
  elif [ "$m" -gt 0 ]; then
    echo "${m}m ${s}s ago"
  else
    echo "${s}s ago"
  fi
}

# Portable mtime in epoch seconds. Echoes empty string on failure.
_mtime() {
  local f="$1"
  if [ ! -e "$f" ]; then return; fi
  if stat -f '%m' "$f" 2>/dev/null; then return; fi
  if stat -c '%Y' "$f" 2>/dev/null; then return; fi
}

# ---------- header ----------

CWD="$(pwd -P)"
NOW_EPOCH=$(date +%s)
NOW_ISO=$(date -u -r "$NOW_EPOCH" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ')

# Try to identify the repo. If we're not in one, render a stub and exit.
GIT_TOP=""
GIT_DIR=""
GIT_COMMON_DIR=""
if _have git && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_TOP=$(git rev-parse --show-toplevel 2>/dev/null)
  GIT_DIR=$(cd "$GIT_TOP" && git rev-parse --git-dir 2>/dev/null)
  GIT_COMMON_DIR=$(cd "$GIT_TOP" && git rev-parse --git-common-dir 2>/dev/null)
  # Make GIT_DIR / GIT_COMMON_DIR absolute relative to the worktree.
  case "$GIT_DIR" in
    /*) ;;
    *) GIT_DIR="$GIT_TOP/$GIT_DIR" ;;
  esac
  case "$GIT_COMMON_DIR" in
    /*) ;;
    *) GIT_COMMON_DIR="$GIT_TOP/$GIT_COMMON_DIR" ;;
  esac
fi

if [ -z "$GIT_TOP" ]; then
  REPO_NAME="$(basename "$CWD")"
  echo "═══ ${REPO_NAME} session scan · ${NOW_ISO} ═══"
  echo "not a git repo (cwd: $CWD)"
  exit 0
fi

REPO_NAME="$(basename "$GIT_TOP")"
echo "═══ ${REPO_NAME} session scan · ${NOW_ISO} ═══"

# ---------- REPO section ----------

# Main checkout vs linked worktree: GIT_COMMON_DIR's parent is the main repo's
# work tree. If that equals GIT_TOP, we're in the main checkout.
MAIN_TOP="$(cd "$GIT_COMMON_DIR/.." 2>/dev/null && pwd -P || echo "")"
if [ "$MAIN_TOP" = "$GIT_TOP" ] || [ -z "$MAIN_TOP" ]; then
  CHECKOUT_KIND="main checkout"
else
  CHECKOUT_KIND="worktree of $(basename "$MAIN_TOP")"
fi

# Branch + ahead/behind (first line of `git status -sb`).
BRANCH_LINE=$(cd "$GIT_TOP" && git status -sb 2>/dev/null | head -1)
# Strip leading "## ".
BRANCH_LINE="${BRANCH_LINE## }"
BRANCH_LINE="${BRANCH_LINE#\#\# }"

# Clean / dirty.
if [ -z "$(cd "$GIT_TOP" && git status --porcelain 2>/dev/null)" ]; then
  CLEAN_MARK="clean"
else
  CLEAN_MARK="dirty"
fi

# In-progress operation.
INFLIGHT="none"
if [ -d "$GIT_DIR/rebase-merge" ] || [ -d "$GIT_DIR/rebase-apply" ]; then
  INFLIGHT="rebase"
elif [ -e "$GIT_DIR/MERGE_HEAD" ]; then
  INFLIGHT="merge"
elif [ -e "$GIT_DIR/CHERRY_PICK_HEAD" ]; then
  INFLIGHT="cherry-pick"
elif [ -e "$GIT_DIR/BISECT_LOG" ]; then
  INFLIGHT="bisect"
fi

# index.lock presence.
if [ -e "$GIT_DIR/index.lock" ]; then
  LOCK_MARK="index.lock PRESENT"
else
  LOCK_MARK="index.lock absent"
fi

echo ""
echo "REPO"
echo "  path:     $CWD"
echo "  kind:     $CHECKOUT_KIND"
echo "  branch:   $BRANCH_LINE"
echo "  state:    $CLEAN_MARK"
echo "  inflight: $INFLIGHT"
echo "  lock:     $LOCK_MARK"

# ---------- WORKTREES section ----------

# Parse `git worktree list --porcelain` into parallel arrays.
WT_PATHS=()
WT_BRANCHES=()
WT_LOCKED=()
WT_PRUNABLE=()
_cur_path=""
_cur_branch=""
_cur_locked=""
_cur_prunable=""
_flush() {
  if [ -n "$_cur_path" ]; then
    WT_PATHS+=("$_cur_path")
    WT_BRANCHES+=("$_cur_branch")
    WT_LOCKED+=("$_cur_locked")
    WT_PRUNABLE+=("$_cur_prunable")
  fi
  _cur_path=""; _cur_branch=""; _cur_locked=""; _cur_prunable=""
}
while IFS= read -r line; do
  case "$line" in
    "worktree "*)
      _flush
      _cur_path="${line#worktree }"
      ;;
    "branch "*)   _cur_branch="${line#branch refs/heads/}" ;;
    "detached")   _cur_branch="(detached)" ;;
    "locked"*)    _cur_locked="locked" ;;
    "prunable"*)  _cur_prunable="prunable" ;;
    "")           ;;
  esac
done < <(cd "$GIT_TOP" && git worktree list --porcelain 2>/dev/null)
_flush

WT_COUNT=${#WT_PATHS[@]}

# Index of current worktree (the one whose path equals GIT_TOP).
CUR_IDX=-1
i=0
while [ "$i" -lt "$WT_COUNT" ]; do
  if [ "${WT_PATHS[$i]}" = "$GIT_TOP" ]; then
    CUR_IDX=$i
    break
  fi
  i=$((i + 1))
done

echo ""
echo "WORKTREES (${WT_COUNT})"

_render_wt_row() {
  local idx="$1"
  local p="${WT_PATHS[$idx]}"
  local b="${WT_BRANCHES[$idx]}"
  local locked="${WT_LOCKED[$idx]}"
  local prunable="${WT_PRUNABLE[$idx]}"
  local marker="  "
  [ "$idx" = "$CUR_IDX" ] && marker="* "
  local extras=""
  [ -n "$locked" ] && extras="$extras [locked]"
  [ -n "$prunable" ] && extras="$extras [prunable]"
  echo "  ${marker}${p} (${b})${extras}"
}

if [ "$WT_COUNT" -le 6 ]; then
  i=0
  while [ "$i" -lt "$WT_COUNT" ]; do
    _render_wt_row "$i"
    i=$((i + 1))
  done
else
  # Render current first if not already in first 5, then first 5 (skipping current to avoid dup), then summary.
  rendered=0
  if [ "$CUR_IDX" -ge 5 ] && [ "$CUR_IDX" -ne -1 ]; then
    _render_wt_row "$CUR_IDX"
    rendered=$((rendered + 1))
  fi
  i=0
  shown=0
  while [ "$i" -lt "$WT_COUNT" ] && [ "$shown" -lt 5 ]; do
    if [ "$i" -ne "$CUR_IDX" ] || [ "$CUR_IDX" -lt 5 ]; then
      _render_wt_row "$i"
      shown=$((shown + 1))
      rendered=$((rendered + 1))
    fi
    i=$((i + 1))
  done
  remaining=$((WT_COUNT - rendered))
  if [ "$remaining" -gt 0 ]; then
    echo "  ... and ${remaining} more"
  fi
fi

# ---------- TMUX TOPOLOGY section ----------

# Only render if $TMUX is set AND tmux is on PATH.
if [ -n "${TMUX:-}" ] && _have tmux; then
  echo ""
  # Capture once: 6 fields. pane_id is appended so we can mark the current pane
  # without a per-row tmux call.
  TMUX_RAW=$(tmux list-panes -aF '#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}|#{pane_current_path}|#{pane_current_command}|#{pane_title}|#{pane_id}' 2>/dev/null || true)

  # Filter to panes whose pane_current_path is at OR inside any worktree path.
  matching_panes=""
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    pane_cwd=$(printf '%s' "$row" | awk -F'|' '{print $3}')
    [ -z "$pane_cwd" ] && continue
    matched=0
    j=0
    while [ "$j" -lt "$WT_COUNT" ]; do
      wt_path="${WT_PATHS[$j]}"
      # Prefix match — a pane in /repo/app/foo matches worktree /repo.
      case "$pane_cwd" in
        "$wt_path"|"$wt_path"/*) matched=1; break ;;
      esac
      j=$((j + 1))
    done
    if [ "$matched" = "1" ]; then
      matching_panes="${matching_panes}${row}
"
    fi
  done <<EOF
$TMUX_RAW
EOF

  # Count.
  pane_count=0
  if [ -n "$matching_panes" ]; then
    pane_count=$(printf '%s' "$matching_panes" | grep -c .)
  fi
  echo "TMUX TOPOLOGY (${pane_count} panes touching this repo)"

  if [ "$pane_count" -gt 0 ]; then
    # Render: marker if current pane (TMUX_PANE), then "session:window.pane | cwd | command | title"
    # plus annotation for sibling claude/pi.
    while IFS= read -r row; do
      [ -z "$row" ] && continue
      addr=$(printf '%s' "$row" | awk -F'|' '{print $1}')
      pid=$(printf '%s' "$row" | awk -F'|' '{print $2}')
      pane_cwd=$(printf '%s' "$row" | awk -F'|' '{print $3}')
      cmd=$(printf '%s' "$row" | awk -F'|' '{print $4}')
      title=$(printf '%s' "$row" | awk -F'|' '{print $5}')
      pid_field=$(printf '%s' "$row" | awk -F'|' '{print $6}')

      # Current pane marker — match the per-row pane_id against $TMUX_PANE.
      cur_marker="  "
      if [ -n "${TMUX_PANE:-}" ] && [ "$pid_field" = "$TMUX_PANE" ]; then
        cur_marker="* "
      fi

      # Sibling-agent annotation.
      annotation=""
      case "$cmd" in
        *claude*|*pi)
          # Same worktree?
          if [ "$pane_cwd" = "$GIT_TOP" ] || case "$pane_cwd" in "$GIT_TOP"/*) true;; *) false;; esac then
            annotation="  ⚠ SAME WORKTREE"
          else
            annotation="  (sibling)"
          fi
          ;;
      esac

      echo "  ${cur_marker}${addr} | ${pane_cwd} | ${cmd} | ${title}${annotation}"
    done <<EOF
$matching_panes
EOF
  fi
fi

# ---------- SIBLINGS section ----------

# Self-exclusion: walk up parent chain.
EXCLUDE_PIDS=""
OWN_PID="${SESSION_SCAN_OWN_PID:-$$}"
while IFS= read -r p; do
  EXCLUDE_PIDS="${EXCLUDE_PIDS} ${p}"
done < <(_pid_ancestry "$OWN_PID")

# Render only if pgrep is available — otherwise omit (tested edge case).
if _have pgrep; then
  echo ""
  # `pgrep -lf '(claude|pi)'` is portable across Linux (procps) and macOS (BSD).
  # Format: "PID first-arg [more args]". Collect candidate (pid, basename) pairs
  # in two passes: filter by basename, then batch-resolve their cwds via lsof
  # (single shot for all PIDs) or readlink-on-fakeproc per PID.
  same_worktree_count=0
  sibling_worktree_count=0
  same_worktree_lines=()
  cand_pids=()
  cand_names=()

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    pid=$(printf '%s' "$line" | awk '{print $1}')
    [ -z "$pid" ] && continue

    # Skip self and ancestors.
    skip=0
    for ep in $EXCLUDE_PIDS; do
      [ "$ep" = "$pid" ] && skip=1 && break
    done
    [ "$skip" = "1" ] && continue

    # Validate the matched process is actually `claude` or `pi`, not "spider" or
    # "tmux a -t pi-sessions". `pgrep -lf` prints "PID first-token [rest]" — we
    # accept the line iff the basename of `first-token` is `claude` or `pi`.
    first_tok=$(printf '%s' "$line" | awk '{print $2}')
    [ -z "$first_tok" ] && continue
    comm_base=$(basename "$first_tok" 2>/dev/null)
    case "$comm_base" in
      claude|pi) ;;
      *) continue ;;
    esac
    cand_pids+=("$pid")
    cand_names+=("$comm_base")
  done < <(pgrep -lf '(claude|pi)' 2>/dev/null)

  # Resolve all candidate cwds. Prefer fake-proc / real /proc readlink (one
  # readlink per pid is fast); fall back to a single batched lsof call.
  proc_dir="${SESSION_SCAN_PROC_DIR:-/proc}"
  pid_cwds=()
  # Use the readlink path if (a) the proc dir is a real directory AND
  # (b) at least one of: our self pid OR the first candidate has a /cwd entry.
  proc_usable=0
  if [ -d "$proc_dir" ]; then
    if [ -e "$proc_dir/$$/cwd" ]; then
      proc_usable=1
    elif [ "${#cand_pids[@]}" -gt 0 ] && [ -e "$proc_dir/${cand_pids[0]}/cwd" ]; then
      proc_usable=1
    fi
  fi
  if [ "$proc_usable" = "1" ]; then
    # Per-PID readlink — fast.
    i=0
    while [ "$i" -lt "${#cand_pids[@]}" ]; do
      cw=$(readlink "$proc_dir/${cand_pids[$i]}/cwd" 2>/dev/null)
      pid_cwds+=("$cw")
      i=$((i + 1))
    done
  elif _have lsof && [ "${#cand_pids[@]}" -gt 0 ]; then
    # Batched lsof: -p accepts comma-separated PIDs. -Fpn prints "pNNN" / "fcwd" / "nPATH".
    # macOS ships bash 3.2 (no associative arrays), so we keep parallel arrays.
    pids_csv=$(IFS=,; echo "${cand_pids[*]}")
    lsof_out=$(lsof -a -p "$pids_csv" -d cwd -Fpn 2>/dev/null || true)
    map_pids=()
    map_paths=()
    cur_pid=""
    while IFS= read -r ll; do
      case "$ll" in
        p*) cur_pid="${ll#p}" ;;
        n*)
          if [ -n "$cur_pid" ]; then
            map_pids+=("$cur_pid")
            map_paths+=("${ll#n}")
            cur_pid=""
          fi
          ;;
      esac
    done <<EOF
$lsof_out
EOF
    i=0
    while [ "$i" -lt "${#cand_pids[@]}" ]; do
      target="${cand_pids[$i]}"
      found=""
      k=0
      while [ "$k" -lt "${#map_pids[@]}" ]; do
        if [ "${map_pids[$k]}" = "$target" ]; then
          found="${map_paths[$k]}"
          break
        fi
        k=$((k + 1))
      done
      pid_cwds+=("$found")
      i=$((i + 1))
    done
  else
    i=0
    while [ "$i" -lt "${#cand_pids[@]}" ]; do
      pid_cwds+=("")
      i=$((i + 1))
    done
  fi

  # Cache the tmux pid→addr map once.
  TMUX_PID_MAP=""
  if [ -n "${TMUX:-}" ] && _have tmux; then
    TMUX_PID_MAP=$(tmux list-panes -aF '#{session_name}:#{window_index}.#{pane_index}|#{pane_pid}' 2>/dev/null || true)
  fi

  # Classify each candidate.
  i=0
  while [ "$i" -lt "${#cand_pids[@]}" ]; do
    pid="${cand_pids[$i]}"
    comm_base="${cand_names[$i]}"
    pcwd="${pid_cwds[$i]}"
    i=$((i + 1))
    [ -z "$pcwd" ] && continue

    if [ "$pcwd" = "$GIT_TOP" ] || case "$pcwd" in "$GIT_TOP"/*) true;; *) false;; esac then
      same_worktree_count=$((same_worktree_count + 1))
      addr=""
      if [ -n "$TMUX_PID_MAP" ]; then
        addr=$(printf '%s' "$TMUX_PID_MAP" | awk -F'|' -v p="$pid" '$2==p{print $1; exit}')
      fi
      if [ -n "$addr" ]; then
        same_worktree_lines+=("⚠ ${addr} (PID ${pid}) is editing this checkout — confirm with user before writing files.")
      else
        same_worktree_lines+=("⚠ PID ${pid} (${comm_base}) is editing this checkout — confirm with user before writing files.")
      fi
    else
      in_sibling=0
      j=0
      while [ "$j" -lt "$WT_COUNT" ]; do
        wt="${WT_PATHS[$j]}"
        if [ "$wt" != "$GIT_TOP" ]; then
          if [ "$pcwd" = "$wt" ] || case "$pcwd" in "$wt"/*) true;; *) false;; esac then
            in_sibling=1
            break
          fi
        fi
        j=$((j + 1))
      done
      if [ "$in_sibling" = "1" ]; then
        sibling_worktree_count=$((sibling_worktree_count + 1))
      fi
    fi
  done

  echo "SIBLINGS"
  echo "  ${same_worktree_count} Claude/pi in same worktree, ${sibling_worktree_count} in sibling worktrees"
  for l in "${same_worktree_lines[@]:-}"; do
    [ -n "$l" ] && echo "  $l"
  done
fi

# ---------- DIRTY section ----------

if [ "$CLEAN_MARK" = "dirty" ]; then
  # Use porcelain to count.
  unstaged=0
  staged=0
  untracked=0
  recent_files=()

  while IFS= read -r ln; do
    [ -z "$ln" ] && continue
    xy="${ln:0:2}"
    fname="${ln:3}"
    case "$xy" in
      "??") untracked=$((untracked + 1)); recent_files+=("$fname") ;;
      *)
        idx="${xy:0:1}"
        wt="${xy:1:1}"
        [ "$idx" != " " ] && [ "$idx" != "?" ] && staged=$((staged + 1))
        [ "$wt" != " " ] && [ "$wt" != "?" ] && unstaged=$((unstaged + 1))
        recent_files+=("$fname")
        ;;
    esac
  done < <(cd "$GIT_TOP" && git status --porcelain 2>/dev/null)

  # Find newest mtime among recent_files.
  newest=0
  for f in "${recent_files[@]:-}"; do
    [ -z "$f" ] && continue
    full="$GIT_TOP/$f"
    m=$(_mtime "$full")
    [ -z "$m" ] && continue
    [ "$m" -gt "$newest" ] && newest=$m
  done

  if [ "$newest" -gt 0 ]; then
    delta=$((NOW_EPOCH - newest))
    last_edit=$(_human_ago "$delta")
  else
    last_edit="unknown"
  fi

  # Top-3 paths.
  top3=""
  c=0
  for f in "${recent_files[@]:-}"; do
    [ -z "$f" ] && continue
    if [ -z "$top3" ]; then top3="$f"; else top3="$top3, $f"; fi
    c=$((c + 1))
    [ "$c" -ge 3 ] && break
  done

  echo ""
  echo "DIRTY"
  echo "  ${unstaged} unstaged, ${staged} staged, ${untracked} untracked · last edit ${last_edit} · ${top3}"
fi

exit 0
