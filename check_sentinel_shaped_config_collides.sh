#!/usr/bin/env bash
# CHECKS: whether a REAL, in-use config is exposed to the index race — not one built to collide.
#
# The sibling defect checks stack many steps that each shell out to git, which proves the race exists but
# is not what any real config looks like. This one mirrors sentinel's actual pre-commit hook
# (hk_sentinel_shaped.pkl): six formatter/linter steps that only rewrite files, four generators that
# declare `stage` so HK performs the index write through its own serialised libgit2 add, and exactly ONE
# step that shells out to git — `git update-index --chmod=+x`, verbatim from the real config.
#
# The question it answers is narrow and useful: with only one external git writer, can hk's own staging
# still collide with it? hk serialises its own index writes behind a Repo mutex, but that mutex knows
# nothing about a step's child process, so the two could overlap. Delays are 150-600 ms to match the
# `uv run …` startup every real step pays, which widens the window rather than narrowing it.
#
# The verdict is deliberately asymmetric, because a race cannot be disproved by absence:
#   collision seen -> the real config IS exposed; the fix is a depends edge or a group in hk.pkl.
#   none seen      -> NOT EXPOSED UNDER THIS SHAPE, which is evidence, not proof. Reported as such,
#                     and the job stays green so a red job always means a genuine finding.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_hk_partial_commit.sh
. "$here/lib_hk_partial_commit.sh"

hk_scenario_setup "$here" hk_sentinel_shaped.pkl || exit 1
hk_sentinel_scenario_files
hk_scenario_commit_base

echo "### a real config's shape: 11 steps, 4 hk-staged generators, exactly 1 external git call"
collisions=0
failures=0
for attempt in 2 3 4 5 6 7 8 9; do
  if ! hk_run_pre_commit_sentinel_shaped "$attempt"; then
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
if [ "$collisions" -gt 0 ]; then
  echo "EXPOSED: $collisions/8 runs of a real config's shape died on index.lock contention, with only"
  echo "one step shelling out to git. hk's own staging and that step's child git overlapped. The fix"
  echo "belongs in the config — a depends edge or a group around the git-invoking step."
  exit 1
fi

echo "NOT EXPOSED UNDER THIS SHAPE: 0/8 runs collided ($failures non-collision failures)."
echo "With a single external git writer, hk's serialised staging did not overlap it here. This is"
echo "evidence, not proof — a race cannot be disproved by absence, and a slower or busier machine may"
echo "still lose. It does mean the collision needs two or more steps invoking git, which is what the"
echo "sibling defect checks demonstrate, and that a real config's index.lock failures likely come from"
echo "somewhere other than its own steps."
exit 0
