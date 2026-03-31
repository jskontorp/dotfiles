# Git helpers — diff, staging, and file checkout utilities

# --- Diff helpers ---

# gdc - git diff (excludes lockfiles), copies to clipboard if available
# Usage: gdc [branch] [file]
gdc() {
  local excludes=(
    ":(exclude).gitignore"
    ":(exclude)*.lock"
    ":(exclude)package-lock.json"
    ":(exclude)pnpm-lock.yaml"
    ":(exclude)yarn.lock"
  )

  local diff
  if [[ -n "$2" ]]; then
    diff=$(command git diff "$1" -- "$2" "${excludes[@]}")
  elif [[ -n "$1" ]]; then
    diff=$(command git diff "$1" -- "${excludes[@]}")
  else
    diff=$(command git diff -- "${excludes[@]}")
  fi

  if [[ -z "$diff" ]]; then
    echo "No diff output."
    return 0
  fi

  if command -v pbcopy &>/dev/null; then
    echo "$diff" | pbcopy
    echo "Copied to clipboard ($(echo "$diff" | wc -l | tr -d ' ') lines)"
  elif command -v xclip &>/dev/null && [[ -n "$DISPLAY" ]]; then
    echo "$diff" | xclip -selection clipboard
    echo "Copied to clipboard ($(echo "$diff" | wc -l | tr -d ' ') lines)"
  else
    echo "$diff"
  fi
}

# --- Staging helpers ---

# gae - git add by extension
# Usage: gae .ts
alias gae &>/dev/null && unalias gae
gae() {
  [[ -z "$1" ]] && { echo "Usage: gae <extension> (e.g., gae .ts)"; return 1; }
  local files=$(command git ls-files --modified --others --exclude-standard | grep "$1$")
  [[ -z "$files" ]] && { echo "No files match '*$1'"; return 0; }
  command git add -- ${(f)files}
}

# gam - git add by path match
# Usage: gam src
alias gam &>/dev/null && unalias gam
gam() {
  [[ -z "$1" ]] && { echo "Usage: gam <pattern> (e.g., gam src)"; return 1; }
  local files=$(command git ls-files --modified --others --exclude-standard | grep "$1")
  [[ -z "$files" ]] && { echo "No files match '$1'"; return 0; }
  command git add -- ${(f)files}
}

# gre - git restore staged by extension
# Usage: gre .ts
gre() {
  [[ -z "$1" ]] && { echo "Usage: gre <extension> (e.g., gre .ts)"; return 1; }
  local files=$(command git diff --cached --name-only | grep "$1$")
  [[ -z "$files" ]] && { echo "No staged files match '*$1'"; return 0; }
  command git restore --staged -- ${(f)files}
}

# grm - git restore staged by path match
# Usage: grm src
alias grm &>/dev/null && unalias grm
grm() {
  [[ -z "$1" ]] && { echo "Usage: grm <pattern> (e.g., grm src)"; return 1; }
  local files=$(command git diff --cached --name-only | grep "$1")
  [[ -z "$files" ]] && { echo "No staged files match '$1'"; return 0; }
  command git restore --staged -- ${(f)files}
}

# --- File checkout ---

# gcof - Checkout a file or directory from another branch
# Usage: gcof <branch> <path> [new_name]
gcof() {
  local branch="${1:-}" target_path="${2:-}" new_name="${3:-}"
  [[ -z "$branch" || -z "$target_path" ]] && { echo "Usage: gcof <branch> <path> [new_name]"; return 1; }

  local root
  root=$(command git rev-parse --show-toplevel 2>/dev/null) || { echo "Not in a git repo"; return 1; }

  local rel="$target_path"
  [[ "$rel" == "$root/"* ]] && rel="${rel#$root/}"
  rel="${rel%/}"

  local obj_type
  obj_type=$(command git cat-file -t "$branch:$rel" 2>/dev/null) \
    || { echo "Path '$rel' not found in branch '$branch'"; return 1; }

  local dest
  if [[ "$obj_type" == "tree" ]]; then
    dest="${new_name:-$root/$rel}"
    if [[ -d "$dest" ]]; then
      echo "⚠ Directory exists: $dest"
      echo "  Files inside will be overwritten."
      read -q "confirm?Continue? [y/N] "
      echo ""
      [[ "$confirm" != "y" ]] && { echo "Aborted"; return 0; }
    fi
    command mkdir -p "$dest" || return 1
    local strip=$(command tr '/' '\n' <<< "$rel" | wc -l | command tr -d ' ')
    command git archive "$branch" "$rel" | command tar -x -C "$dest" --strip-components="$strip" || return 1
  else
    dest="${new_name:-$root/$rel}"
    if [[ -f "$dest" ]]; then
      echo "⚠ File exists: $dest"
      local tmp=$(command mktemp)
      command git show "$branch:$rel" > "$tmp"
      if ! command diff -q "$dest" "$tmp" &>/dev/null; then
        echo "Diff (local → $branch):"
        command git diff --no-index -- "$dest" "$tmp" 2>/dev/null | head -30
      else
        echo "  (identical — no changes)"
        command rm -f "$tmp"
        return 0
      fi
      command rm -f "$tmp"
      echo ""
      read -q "confirm?Overwrite? [y/N] "
      echo ""
      [[ "$confirm" != "y" ]] && { echo "Aborted"; return 0; }
    fi
    command mkdir -p "$(command dirname "$dest")" 2>/dev/null
    command git show "$branch:$rel" > "$dest" || return 1
  fi

  echo "✓ $branch:$rel → $dest"
}
