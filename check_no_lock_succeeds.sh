#!/usr/bin/env bash
# CHECKS: with no index.lock held at all, hk's pre-commit stash of a partial commit succeeds.
#
# This is the control. It carries no claim about the bug — it exists so that a failure in either
# lock-holding check is attributable to the lock and not to the scenario, the pinned hk, or the
# runner. Green is the expected and only acceptable result, on every hk version.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib_hk_partial_commit.sh
. "$here/lib_hk_partial_commit.sh"

hk_scenario_setup "$here" || exit 1

echo "### control: no index.lock held"
hk_run_pre_commit_with_lock none
rc=$?

echo
if [ "$rc" -eq 0 ]; then
  echo "PASS: hk completed the partial-commit stash with no lock contention."
  exit 0
fi

hk_print_output
echo "SCENARIO BROKEN: hk failed with no lock held at all, so the other two checks prove nothing."
echo "Fix this before reading them: the pinned hk, the runner, or the scenario itself is at fault."
exit 1
