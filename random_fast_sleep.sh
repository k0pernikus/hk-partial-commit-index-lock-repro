#!/usr/bin/env bash
# Sleep a random duration, standing in for a pre-commit step doing its real work.
#
# Usage: random_fast_sleep.sh [min_ms] [max_ms]   (defaults 10 149)
#
# The delay is RANDOM on purpose. Giving every step the same sleep would line them up deliberately and
# manufacture the collision; real steps finish at unrelated moments. Each step draws its own delay, so
# any contention that follows is the scheduler's doing rather than this script's — which is the whole
# claim being made. The cost is that a single pair overlapping is unlikely, so a scenario relies on
# step count, or on steps slow enough to overlap naturally.
set -euo pipefail

minimum="${1:-10}"
maximum="${2:-149}"
span=$((maximum - minimum + 1))

if command -v shuf >/dev/null; then
  milliseconds="$(shuf --input-range="$minimum-$maximum" --head-count=1)"
else
  milliseconds=$(($(od --address-radix=n --read-bytes=2 --format=u2 /dev/urandom) % span + minimum))
fi

sleep "$(printf '%d.%03d' $((milliseconds / 1000)) $((milliseconds % 1000)))"
