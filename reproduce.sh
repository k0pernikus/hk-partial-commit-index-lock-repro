#!/usr/bin/env bash
# Deterministic reproduction of an hk pre-commit bug — EXITS NON-ZERO (red) when the bug is present.
#
# CLAIM: hk's pre-commit stash (stash = "git") aborts the run when it cannot acquire the worktree
# index.lock while stashing a partial (path-subset) change. PR #1060 (shipped v1.51.0) added
# run_git_stash, which WAITS up to 775 ms for a lock that already exists — so a lock RELEASED inside
# that window now recovers. It is a pre-flight wait, not a retry: the command is still issued exactly
# once, so a lock that outlives the window still aborts the commit.
#
# Three cases, run against one pinned hk:
#   control   no lock                          -> expect exit 0 (pipeline is otherwise sound)
#   transient lock released after 300 ms       -> expect exit 0 on >= 1.51.0 (this is what #1060 fixed)
#   held      lock held for the whole run      -> expect exit 0 once fixed; today it ABORTS
#
# Isolated via `hk run pre-commit`, NOT `git commit`: a plain `git commit` with a pre-held index.lock
# fails on git's OWN lock before hk runs (see diag.sh), which would confound the report.
#
# Exit status is inverted on purpose: NON-ZERO = bug still present so CI goes RED; ZERO = the held
# case survived, meaning the retry landed. Self-contained: pins hk via mise.toml, overridable with
# HK_VERSION=<x.y.z> for exploring other releases.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(mktemp --directory)"
trap 'rm --recursive --force "$repo"' EXIT
cd "$repo" || exit 1

cp "$here/hk.pkl" "$here/mise.toml" .
if [ -n "${HK_VERSION:-}" ]; then
  printf '[tools]\n"aqua:jdx/hk" = "%s"\n' "$HK_VERSION" >mise.toml
fi
mise trust "$repo/mise.toml" >/dev/null
mise install >/dev/null
hkbin="$(mise which hk)" || exit 1
PATH="$(dirname "$hkbin"):$PATH"
export PATH

hk_version="$(hk --version 2>&1)"
git_version="$(git --version)"
echo "### $hk_version  ($(type -p hk))"
echo "### $git_version"

git init --quiet --initial-branch=main
git config user.email repro@example.com
git config user.name repro
printf 'v1\n' >keep.txt
printf 'v1\n' >other.txt
git add keep.txt other.txt hk.pkl mise.toml
git commit --quiet --message init
hk install >/dev/null

# PARTIAL state: keep.txt staged, other.txt modified but UNSTAGED. hk stashes the unstaged remainder
# as a path subset via the shell `git stash push -- <paths>` — the single-attempt path.
reset_partial_state() {
  git stash clear
  printf 'v2\n' >keep.txt
  printf 'v2\n' >other.txt
  git add keep.txt
}

# Prints: <hk-exit> <stashes-left-behind> <other.txt-content>
run_case() {
  local mode="$1" out rc releaser stashes worktree
  reset_partial_state

  releaser=""
  case "$mode" in
    none) ;;
    transient)
      : >.git/index.lock
      (sleep 0.3 && rm --force .git/index.lock) &
      releaser=$!
      ;;
    held)
      : >.git/index.lock
      ;;
  esac

  out="$(hk run pre-commit 2>&1)"
  rc=$?

  if [ -n "$releaser" ]; then
    wait "$releaser"
  fi
  rm --force .git/index.lock

  stashes="$(git stash list | wc --lines)"
  worktree="$(cat other.txt)"
  printf '  %-9s hk exit=%s  stashes-left=%s  other.txt=%s\n' \
    "$mode" "$rc" "$stashes" "$(printf '%s' "$worktree" | tr --delete '\n')"
  LAST_OUTPUT="$out"
  return "$rc"
}

echo
echo "### control — no lock held"
run_case none
control_rc=$?

echo
echo "### transient — index.lock released after 300 ms (inside hk's 775 ms wait window)"
run_case transient
transient_rc=$?
transient_output="$LAST_OUTPUT"

echo
echo "### held — index.lock held for the whole run (outlives the wait window)"
run_case held
held_rc=$?
echo "  --- held-case output ---"
printf '%s\n' "$LAST_OUTPUT" | sed 's/^/  | /'
echo "  ------------------------"

echo
if [ "$control_rc" -ne 0 ]; then
  echo "HARNESS BROKEN: the no-lock control failed (exit $control_rc), so nothing below is meaningful."
  exit 1
fi

if [ "$transient_rc" -ne 0 ]; then
  echo "REGRESSION or PRE-#1060: a lock released inside the 775 ms window still aborted the run."
  echo "On >= 1.51.0 this is a regression of #1060; on <= 1.50.0 it is expected (no wait existed)."
  printf '%s\n' "$transient_output" | sed 's/^/  | /'
  exit 1
fi

if [ "$held_rc" -ne 0 ]; then
  echo "BUG REPRODUCED: a lock released inside the window recovers (#1060 works), but a lock that"
  echo "outlives the 775 ms window still aborts the run — the stash command is issued once and never"
  echo "retried. Failing on purpose so this run is RED."
  exit 1
fi

echo "NOT REPRODUCED: the held lock no longer aborts the run — the retry landed."
exit 0
