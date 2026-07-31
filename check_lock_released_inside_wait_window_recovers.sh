#!/usr/bin/env bash
# CHECKS: an index.lock released 300 ms into hk's 775 ms wait window no longer aborts the commit.
#
# This is the case PR #1060 fixed (shipped v1.51.0). run_git_stash resolves the worktree index.lock
# and sleeps in bounded backoff — 25/50/100/200/400 ms — for as long as the lock exists, then issues
# the stash. A lock that clears inside that budget is therefore survivable, and hk recovers.
#
# Green is the expected result on hk >= 1.51.0, and this check is what proves the shipped fix works.
# It fails on <= 1.50.0, where no wait existed at all — run `HK_VERSION=1.50.0` to see that.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_hk_partial_commit.sh
. "$here/lib_hk_partial_commit.sh"

hk_scenario_setup "$here" || exit 1
hk_lock_scenario_files
hk_scenario_commit_base

echo "### index.lock held, then released after 300 ms — inside hk's 775 ms wait window"
hk_run_pre_commit_with_lock transient
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: hk waited out the transient lock and completed the stash. #1060 works as intended."
  exit 0
fi

hk_print_output
echo "FAIL: a lock released well inside the 775 ms window still aborted the run."
echo "On hk >= 1.51.0 that is a regression of #1060; on <= 1.50.0 it is expected, since the wait"
echo "was only introduced in 1.51.0."
exit 1
