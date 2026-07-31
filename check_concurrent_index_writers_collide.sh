#!/usr/bin/env bash
# CHECKS: hk runs steps in parallel that each write the git index, and they collide on index.lock.
#
# THIS IS THE DEFECT. No lock is planted by this script and no process stalls — the contention is
# produced entirely by hk's own scheduling of an ordinary config.
#
# hk's step locking keys on the files a step DECLARES. The four steps here have DISJOINT globs, so hk
# sees no conflict and runs them concurrently. Each step's fix shells out to `git update-index`, an
# external git process outside hk's own Repo mutex, so nothing serialises their index writes. One of
# them loses the race:
#
#     fatal: Unable to create '<repo>/.git/index.lock': File exists.
#     Another git process seems to be running in this repository, e.g. …
#
# Two things make this worse than a lost write. hk's index path (`add()`, src/git.rs:1487) uses
# libgit2 with NO wait and NO retry — the 775 ms budget from #1060 exists only on the three shell
# `git stash push` sites — so a contended index fails instantly. And the losing step takes every
# sibling with it: the surviving steps are reported `aborted`, so an unrelated formatter is cancelled
# by a collision it had no part in.
#
# There is no way to express "this step writes the index, run it exclusively" in hk.pkl. The only
# lever a config author has is `depends`, which serialises by hand what hk cannot infer — and it
# cannot infer it, because the git call is inside an opaque command.
#
# This check EXITS NON-ZERO while the defect is present, so its job is RED on purpose.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_hk_partial_commit.sh
. "$here/lib_hk_partial_commit.sh"

hk_scenario_setup "$here" hk_concurrent_index_writers.pkl || exit 1
hk_index_writer_scenario_files
hk_scenario_commit_base

echo "### six steps with disjoint globs, each running an external git update-index concurrently"
collisions=0
for attempt in 2 3 4 5 6 7 8 9; do
  if ! hk_run_pre_commit_with_concurrent_index_writers "$attempt"; then
    if hk_saw_index_lock_collision; then
      collisions=$((collisions + 1))
    fi
    if [ "$attempt" -eq 2 ]; then
      hk_print_output
    fi
  fi
done

echo
if [ "$collisions" -gt 0 ]; then
  echo "DEFECT REPRODUCED: $collisions/8 runs died on index.lock contention between hk's own"
  echo "concurrently-scheduled steps, with no lock planted and nothing stalling. hk cannot know that"
  echo "an opaque fix command writes the index, so it parallelises steps that must not overlap, and"
  echo "one collision aborts every sibling step."
  exit 1
fi

echo "FIXED: hk no longer lets concurrently-scheduled steps collide on the index."
exit 0
