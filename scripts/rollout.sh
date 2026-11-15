#!/usr/bin/env bash
# Roll one Freight (a k3s version you choose) of a project through the regions, ONE AT A TIME, in the order
# given (default: eu, us, cz). Each region is its own independent branch in Kargo; running them in
# sequence is what keeps one region always serving (the set-rotation task also enforces it).
#   scripts/rollout.sh <project> <freight-name|k3s-version> [region ...]
#   e.g. scripts/rollout.sh kubernetes v1.36.6-k3s1 eu us
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
project=${1:?project}; freight=$(freight_name "${2:-}" "$project") || exit 1; shift 2
regions=("$@"); [ ${#regions[@]} -gt 0 ] || regions=("${REGION_NAMES[@]}")
for r in "${regions[@]}"; do
  ./scripts/promote.sh "$project" "$r" "$freight"
  ./scripts/wait-pipeline.sh "$project" "$r" 900 "$freight"
done
