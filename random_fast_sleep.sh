#!/usr/bin/env bash
# Sleep a random 0.010–0.149 s, standing in for a fast pre-commit step doing its real work.
#
# The delay is RANDOM on purpose. Giving every step the same sleep would line them up deliberately and
# manufacture the collision; real steps finish at unrelated moments. Each step here draws its own delay,
# so the contention that follows is the scheduler's doing rather than this script's — which is the whole
# claim being made. The cost is that a single pair overlapping is unlikely, so the scenario relies on
# having many steps rather than on synchronising a few.
set -euo pipefail

if command -v shuf >/dev/null; then
  milliseconds="$(shuf --input-range=10-149 --head-count=1)"
else
  milliseconds=$(($(od --address-radix=n --read-bytes=2 --format=u2 /dev/urandom) % 140 + 10))
fi

sleep "$(printf '0.%03d' "$milliseconds")"
