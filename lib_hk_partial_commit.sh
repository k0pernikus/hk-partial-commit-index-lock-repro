# shellcheck shell=bash
# Shared setup for the three hk partial-commit index.lock checks.
#
# Each check builds the SAME scenario — a partial commit, some paths staged and one path left
# modified but unstaged — and differs only in how long .git/index.lock is held while hk's
# pre-commit stash runs. hk stashes the unstaged remainder as a path subset through the shell
# `git stash push -- <paths>`, which is the code path under test.
#
# The checks drive `hk run pre-commit`, NOT `git commit`: with a held .git/index.lock a plain
# `git commit` fails on git's OWN lock before hk ever runs, which would confound the result.

hk_scenario_setup() {
  local here="$1" repo
  repo="$(mktemp --directory)"
  # shellcheck disable=SC2064
  trap "rm --recursive --force '$repo'" EXIT
  cd "$repo" || return 1

  cp "$here/hk.pkl" "$here/mise.toml" .
  if [ -n "${HK_VERSION:-}" ]; then
    printf '[tools]\n"aqua:jdx/hk" = "%s"\n' "$HK_VERSION" >mise.toml
  fi
  mise trust "$repo/mise.toml" >/dev/null
  mise install >/dev/null
  local hkbin
  hkbin="$(mise which hk)" || return 1
  PATH="$(dirname "$hkbin"):$PATH"
  export PATH

  echo "### $(hk --version 2>&1)  ($(type -p hk))"
  echo "### $(git --version)"
  echo

  git init --quiet --initial-branch=main
  git config user.email repro@example.com
  git config user.name repro
  printf 'v1\n' >keep.txt
  printf 'v1\n' >other.txt
  git add keep.txt other.txt hk.pkl mise.toml
  git commit --quiet --message init
  hk install >/dev/null
}

hk_scenario_partial_state() {
  git stash clear
  printf 'v2\n' >keep.txt
  printf 'v2\n' >other.txt
  git add keep.txt
}

# Runs `hk run pre-commit` with index.lock held per $1 (none|transient|held).
# Sets HK_OUTPUT to hk's combined output; returns hk's exit status.
hk_run_pre_commit_with_lock() {
  local mode="$1" releaser="" rc
  hk_scenario_partial_state

  case "$mode" in
    transient)
      : >.git/index.lock
      (sleep 0.3 && rm --force .git/index.lock) &
      releaser=$!
      ;;
    held)
      : >.git/index.lock
      ;;
  esac

  HK_OUTPUT="$(hk run pre-commit 2>&1)"
  rc=$?

  if [ -n "$releaser" ]; then
    wait "$releaser"
  fi
  rm --force .git/index.lock

  echo "  hk exit=$rc  stashes-left=$(git stash list | wc --lines)  other.txt=$(tr --delete '\n' <other.txt)"
  return "$rc"
}

hk_print_output() {
  echo "  --- hk output ---"
  printf '%s\n' "$HK_OUTPUT" | sed 's/^/  | /'
  echo "  -----------------"
}
