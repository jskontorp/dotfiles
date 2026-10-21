#!/bin/zsh
# No real credentials or GitHub calls: exercise the wrapper with a stub CLI.
set -eu
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR
unset GH_TOKEN GITHUB_TOKEN

repo=${0:A:h:h}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
typeset -a chpwd_functions=()
source "$repo/zsh/core.zsh" >/dev/null

# Only the wrapper's config lookup is stubbed; command gh uses the executable.
gh_test_pin=pinned
git() {
  [[ "$*" == 'config --get credential.https://github.com.username' ]] || return 1
  [[ -n $gh_test_pin ]] || return 1
  print -r -- "$gh_test_pin"
}

export GH_TEST_LOG="$tmp/calls"
touch "$GH_TEST_LOG"
command cat > "$tmp/gh" <<'SH'
#!/bin/sh
printf '%s|%s\n' "${GH_TOKEN-unset}" "$*" >> "$GH_TEST_LOG"
if [ "$*" = 'auth token -u pinned' ]; then
  printf 'fake-pinned-token\n'
  exit 0
fi
if [ "$*" = 'auth token -u missing' ]; then
  exit 1
fi
printf '%s|%s\n' "${GH_TOKEN-unset}" "$*"
exit "${GH_TEST_EXIT:-0}"
SH
chmod +x "$tmp/gh"
path=("$tmp" $path)

for subcommand in switch status login logout setup-git token git-credential; do
  before=$(wc -l < "$GH_TEST_LOG")
  actual=$(gh auth "$subcommand" --help)
  [[ $actual == "unset|auth $subcommand --help" ]] || {
    print -u2 "FAIL: gh auth $subcommand received an injected token"
    exit 1
  }
  after=$(wc -l < "$GH_TEST_LOG")
  (( after == before + 1 )) || {
    print -u2 "FAIL: gh auth $subcommand looked up the pinned token"
    exit 1
  }
done

[[ $(gh api user) == 'fake-pinned-token|api user' ]]
[[ ! -v GH_TOKEN ]]
[[ $(GH_TOKEN=explicit-token gh auth status) == 'explicit-token|auth status' ]]

gh_test_pin=''
[[ $(gh api user) == 'unset|api user' ]]
gh_test_pin=missing
[[ $(gh api user 2>/dev/null) == 'unset|api user' ]]
gh_test_pin=pinned

export GH_TEST_EXIT=7
if gh auth switch -u personal >/dev/null; then
  print -u2 'FAIL: gh auth switch lost its exit status'
  exit 1
else
  [[ $? -eq 7 ]]
fi
if gh api user >/dev/null; then
  print -u2 'FAIL: pinned gh command lost its exit status'
  exit 1
else
  [[ $? -eq 7 ]]
fi

print 'gh wrapper: auth bypass, pinning, fallback, environment and exit status checks passed'
