#!/usr/bin/env bash
# CHECKS: the same collision when the git call is hidden inside a script the step invokes.
#
# THIS IS THE DEFECT IN ITS REALISTIC FORM. The sibling check puts `git update-index` directly in the
# fix command, where a config author can at least see it. Here each step runs
# `bash regenerate_and_stage.sh <n>`, an ordinary generator that derives an artifact and stages it
# with the repo's own git — the git invocation is one level down, inside the script.
#
# This is the shape real configs have: a generator, a build recipe, a codegen task that stages what it
# produced. Sentinel's retired pyz-rebuild step was exactly this — `just build-pyz` ran `git add`
# internally — and it collided with a neighbouring step that also wrote the index.
#
# hk has no way to see it. Its step locking keys on declared files, and the declared files here are
# disjoint, so the steps run in parallel and their hidden git calls contend for index.lock. Nothing
# short of reading the script's source could tell hk otherwise, which is why this cannot be fixed by
# better inference — it needs a way to declare index exclusivity in hk.pkl.
#
# This check EXITS NON-ZERO while the defect is present, so its job is RED on purpose.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_hk_partial_commit.sh
. "$here/lib_hk_partial_commit.sh"

hk_scenario_setup "$here" hk_script_spawned_git.pkl || exit 1
hk_index_writer_scenario_files
hk_scenario_commit_base

echo "### six steps with disjoint globs, each invoking a script that runs git add itself"
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
  echo "DEFECT REPRODUCED: $collisions/8 runs died on index.lock contention, with the git call hidden"
  echo "inside a generator script. hk saw only 'bash regenerate_and_stage.sh <n>' and disjoint globs,"
  echo "so it scheduled the steps in parallel. This is the form real configs hit."
  exit 1
fi

echo "FIXED: hk no longer lets script-spawned git calls in parallel steps collide on the index."
exit 0
