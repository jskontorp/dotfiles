#!/bin/zsh
# Re-source safety check — validates that sourcing ~/.zshrc twice
# doesn't produce PATH duplicates, hook duplicates, or FUNCNEST crashes.
#
# Run: zsh -i /path/to/resource-check.zsh
# (-i sources ~/.zshrc once; the script sources it again)

# Re-source
source ~/.zshrc

errors=0

# --- PATH duplicates ---
typeset -A path_seen
local path_dupes=()
for d in ${(s.:.)PATH}; do
  if (( ${+path_seen[$d]} )); then
    path_dupes+=("$d")
  fi
  path_seen[$d]=1
done
if (( ${#path_dupes} )); then
  print -u2 "PATH duplicates: ${(j:, :)path_dupes}"
  errors=$((errors + 1))
fi

# --- chpwd_functions duplicates ---
typeset -A hook_seen
local hook_dupes=()
for f in $chpwd_functions; do
  if (( ${+hook_seen[$f]} )); then
    hook_dupes+=("$f")
  fi
  hook_seen[$f]=1
done
if (( ${#hook_dupes} )); then
  print -u2 "chpwd_functions duplicates: ${(j:, :)hook_dupes}"
  errors=$((errors + 1))
fi

# --- precmd_functions duplicates ---
typeset -A precmd_seen
local precmd_dupes=()
for f in $precmd_functions; do
  if (( ${+precmd_seen[$f]} )); then
    precmd_dupes+=("$f")
  fi
  precmd_seen[$f]=1
done
if (( ${#precmd_dupes} )); then
  print -u2 "precmd_functions duplicates: ${(j:, :)precmd_dupes}"
  errors=$((errors + 1))
fi

exit $errors
