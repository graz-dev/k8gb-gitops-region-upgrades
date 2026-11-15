#!/usr/bin/env bash
# Timeline of a rollout from Kargo's own records: per stage, how long the promotion and the
# verification took. The drain verification polls DNS, so its duration is the measured drain.
#   scripts/timings.sh <project> <freight-name|k3s-version>
set -euo pipefail
project=${1:?project}; MGMT=k3d-mgmt
. "$(dirname "$0")/lib.sh"
f=$(freight_name "${2:-}" "$project") || exit 1
epoch() { date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s; }
{
  echo "stage promotion_start promotion_s verification_s total_s"
  kubectl --context $MGMT -n "$project" get promotions -o json | jq -r --arg f "$f" '
    .items | map(select(.spec.freight == $f and .status.phase == "Succeeded")) | group_by(.spec.stage) | map(last)[]
    | [.spec.stage, .status.startedAt, .status.finishedAt] | @tsv' |
  while IFS=$'\t' read -r stage start end; do
    ver=$(kubectl --context $MGMT -n "$project" get stage "$stage" -o json | jq -r --arg f "$f" '
      [.status.freightHistory[] | select([.items[]?.name] | index($f)) | .verificationHistory[]? | select(.phase=="Successful")] | .[0] | "\(.startTime) \(.finishTime)"')
    s=$(epoch "$start"); e=$(epoch "$end")
    vs=$(epoch "${ver% *}" 2>/dev/null || echo "$e"); ve=$(epoch "${ver#* }" 2>/dev/null || echo "$e")
    echo "$stage ${start:11:8} $((e - s)) $((ve - vs)) $((ve - s))"
  done | sort -k2
} | column -t
