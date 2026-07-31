#!/usr/bin/env bash
# Stands in for a real generator step: derive an artifact, then stage it with the repo's own git.
#
# This is the shape that hides the index write from hk. hk's step locking keys on the files a step
# DECLARES (its glob, its `stage` list); the git invocation in here is inside a script hk only sees
# as an opaque command, so hk cannot know this step writes the index and will happily run it in
# parallel with another step that does the same. Sentinel's retired pyz-rebuild step had exactly this
# shape: `just build-pyz` ran `git add` internally.
set -euo pipefail

index="$1"

printf 'generated from index_trigger%s\n' "$index" >"generated$index.txt"
git add "generated$index.txt"
