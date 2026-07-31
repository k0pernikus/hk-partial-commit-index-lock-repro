#!/usr/bin/env bash
# CHECKS: a lock that never clears aborts the run — hk's INTENDED behaviour, pinned so it stays.
#
# This check passes when hk aborts. That is not a bug: #1060 states outright that it means to
# "preserve Git's normal failure when a lock persists", and a lock nobody releases is exactly that
# case. The lock here is a bare file this script creates and never removes until hk has returned, so
# no process holds it and no amount of waiting could ever recover — refusing to proceed is correct.
#
# It is kept as a passing check for two reasons. It bounds the wait: together with the companion
# transient check it shows the 775 ms budget recovers what is recoverable and gives up on what is
# not, so neither behaviour can regress unnoticed. And it forecloses a wrong diagnosis — that the
# index.lock failures this repository exists for are a matter of the timeout being too short. They
# are not. The defect lives in the concurrent-index-writer checks, where hk's own scheduling creates
# the contention with no lock planted at all.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_hk_partial_commit.sh
. "$here/lib_hk_partial_commit.sh"

hk_scenario_setup "$here" || exit 1
hk_lock_scenario_files
hk_scenario_commit_base

echo "### index.lock held for the whole run — a stale lock nothing will release"
hk_run_pre_commit_with_lock held
rc=$?

echo
if [ "$rc" -ne 0 ]; then
  echo "PASS: hk refused to proceed against a lock that never clears, which is the documented"
  echo "intent of #1060. Note stashes-left=0 above — git fails atomically here, creating no stash"
  echo "and leaving the worktree untouched."
  exit 0
fi

hk_print_output
echo "FAIL: hk proceeded despite a lock that was never released. Either the wait now blocks"
echo "indefinitely, or the stash bypassed the lock — both are worse than the abort this pins."
exit 1
