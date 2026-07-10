#!/usr/bin/env bash
# Deterministic reproduction of an hk pre-commit bug — EXITS NON-ZERO (red) when the bug is present.
#
# CLAIM: hk's pre-commit stash (stash = "git") aborts the run with NO retry when it cannot acquire
# the worktree index.lock while stashing a partial (path-subset) change. The SAME pipeline with no
# lock succeeds — so the lock is the sole blocker, and the success is exactly the recovery a retry
# would give once a (in the wild, transient) lock clears. hk has no such retry, so it stops.
#
# Isolated via `hk run pre-commit`, NOT `git commit`: a plain `git commit` with a pre-held index.lock
# fails on git's OWN lock before hk runs (see diag.sh), which would confound the report.
#
# Exit status is inverted on purpose: NON-ZERO = bug reproduced (hk stopped) so CI goes RED; ZERO =
# hk did NOT stop (retry added / behaviour changed). Self-contained: pins hk via mise.toml.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(mktemp --directory)"
trap 'rm --recursive --force "$repo"' EXIT
cd "$repo"

cp "$here/hk.pkl" "$here/mise.toml" .
mise trust "$repo/mise.toml" >/dev/null 2>&1 || true
mise install >/dev/null 2>&1 || true
if hkbin="$(mise which hk 2>/dev/null)"; then
  export PATH="$(dirname "$hkbin"):$PATH"
fi
echo "### hk: $(hk --version 2>&1)  ($(type -p hk))"

git init --quiet --initial-branch=main
git config user.email repro@example.com
git config user.name repro
printf 'v1\n' >keep.txt
printf 'v1\n' >other.txt
git add keep.txt other.txt hk.pkl mise.toml
git commit --quiet --message init
hk install >/dev/null 2>&1

# PARTIAL state: keep.txt staged, other.txt modified but UNSTAGED. hk stashes the unstaged remainder
# as a path subset via the shell `git stash push -- <paths>` — the no-retry path.
printf 'v2\n' >keep.txt
printf 'v2\n' >other.txt
git add keep.txt

echo
echo "### 1) 'hk run pre-commit' while .git/index.lock is held (stands in for a transient holder)"
aborts=0
for attempt in 1 2 3; do
  : >.git/index.lock
  out="$(hk run pre-commit 2>&1)"
  rc=$?
  rm --force .git/index.lock
  hit=no
  printf '%s\n' "$out" | grep --quiet --ignore-case --extended-regexp 'index\.lock|another git process' && hit=yes
  echo "  attempt $attempt: hk exit=$rc  index.lock-abort=$hit"
  if [ "$rc" -ne 0 ] && [ "$hit" = yes ]; then
    aborts=$((aborts + 1))
  fi
  if [ "$attempt" -eq 1 ]; then
    echo "  --- attempt 1 output ---"
    printf '%s\n' "$out" | sed 's/^/  | /'
    echo "  ------------------------"
  fi
done

echo
echo "### 2) same pipeline, NO held lock (the recovery a retry would reach)"
out="$(hk run pre-commit 2>&1)"
clean_rc=$?
echo "  hk run pre-commit (no lock): exit=$clean_rc"

echo
if [ "$aborts" -eq 3 ] && [ "$clean_rc" -eq 0 ]; then
  echo "BUG REPRODUCED: hk stopped 3/3 on a held index.lock with no retry, yet the identical pipeline"
  echo "succeeds with no lock (exit 0) — so a bounded retry over the transient lock would recover."
  echo "Failing on purpose so this run is RED."
  exit 1
fi
echo "NOT REPRODUCED: hk did not stop under a held lock (aborts=$aborts/3, no-lock exit=$clean_rc)."
echo "Looks fixed — retry/behaviour changed."
exit 0
