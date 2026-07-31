#!/usr/bin/env bash
# CHECKS: the remedy. The same racing steps, each placed in its own Group, no longer collide.
#
# This is the green half of a pair. Its sibling
# check_script_spawned_git_collides.sh runs 48 steps whose generator script stages its own output and
# goes RED on index.lock contention. This check uses hk_script_spawned_git_groups.pkl: byte-for-byte the
# same steps, the same script, the same random delays — with each step wrapped in its own Group.
#
# hk's documentation already describes why that works: "A group is a collection of steps that are
# executed in parallel, waiting for previous steps/groups to finish and blocking other steps/groups from
# starting until it finishes." One writer per group therefore serialises the writers, and the race is
# gone.
#
# The pair is the argument. The mechanism to avoid the collision already exists and needs nothing added
# to hk; what is missing is any hint of it at the moment it is needed. When the race fires, hk reports
# git's raw message — "Unable to create '<repo>/.git/index.lock': File exists. Another git process seems
# to be running…" — which points an author at phantom stray git processes and stale lock files, not at
# their own hook's concurrency. Naming groups and depends in that failure would turn an afternoon of
# misdiagnosis into a one-line config change.
#
# Green is the expected result. A collision here would mean groups do not serialise as documented, which
# would be a much more serious finding than the one this repository is about.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_hk_partial_commit.sh
. "$here/lib_hk_partial_commit.sh"

hk_scenario_setup "$here" hk_script_spawned_git_groups.pkl || exit 1
hk_index_writer_scenario_files
hk_scenario_commit_base

echo "### the same 48 git-invoking steps, each in its own Group"
collisions=0
failures=0
for attempt in 2 3 4 5; do
  if ! hk_run_pre_commit_with_concurrent_index_writers "$attempt"; then
    failures=$((failures + 1))
    if hk_saw_index_lock_collision; then
      collisions=$((collisions + 1))
      if [ "$collisions" -eq 1 ]; then
        hk_print_output
      fi
    fi
  fi
done

echo
if [ "$collisions" -eq 0 ] && [ "$failures" -eq 0 ]; then
  echo "PASS: 4/4 runs clean. One group per git-invoking step serialises them and the collision is gone,"
  echo "using only what hk already provides. Its sibling check, identical but ungrouped, goes red — so"
  echo "the gap is not a missing feature but a missing hint in the failure that names this remedy."
  exit 0
fi

hk_print_output
if [ "$collisions" -gt 0 ]; then
  echo "FAIL: $collisions/4 runs still collided on index.lock despite one group per step. Groups are not"
  echo "serialising as hk documents them, which is a more serious defect than the ungrouped race."
  exit 1
fi

echo "FAIL: $failures/4 runs failed without an index.lock collision, so this scenario is broken rather"
echo "than informative. Fix the harness before drawing any conclusion from the grouped result."
exit 1
