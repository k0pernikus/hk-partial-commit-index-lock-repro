#!/usr/bin/env bash
# CHECKS: an index.lock that outlives hk's 775 ms wait window still aborts the whole commit.
#
# This is the case PR #1060 did NOT cover, and the reason this repository is red. run_git_stash
# waits only while the lock ALREADY exists, then issues `git stash push` exactly once:
#
#     for delay in LOCK_RETRY_DELAYS {
#         if !index_lock.exists() { break; }
#         thread::sleep(delay);
#     }
#     cmd.run()?;
#
# It is a pre-flight wait, not a retry. Nothing re-checks the lock after the final 400 ms sleep, and
# nothing re-issues the command, so a lock still held when the budget runs out — or acquired during
# the command — fails the commit outright. On v1.54.0 hk reports the failure at src/git.rs:84:5,
# which is that `cmd.run()?` inside run_git_stash itself.
#
# This check EXITS NON-ZERO while the bug is present, so its job is RED on purpose. It turns green
# when the stash command is retried within a bounded budget instead of merely waited on beforehand.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_hk_partial_commit.sh
. "$here/lib_hk_partial_commit.sh"

hk_scenario_setup "$here" || exit 1

echo "### index.lock held for the whole run — outlives hk's 775 ms wait window"
hk_run_pre_commit_with_lock held
rc=$?

echo
if [ "$rc" -ne 0 ]; then
  hk_print_output
  echo "BUG PRESENT: the lock outlived the wait window and hk aborted the commit."
  echo "The companion check proves a lock released inside the window recovers, so the wait itself"
  echo "works — what is missing is a retry of the stash command once the budget is exhausted."
  echo "Note stashes-left=0 above: git fails atomically here, creating no stash and leaving the"
  echo "worktree untouched, so a bounded retry cannot duplicate a stash."
  exit 1
fi

echo "FIXED: a lock outliving the wait window no longer aborts the run — the retry landed."
exit 0
