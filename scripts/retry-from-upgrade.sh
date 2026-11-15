#!/usr/bin/env bash
# Finish a region's branch from `<region>-upgrade` on, with a Freight that was already promoted
# before: the fix after a failed upgrade (make demo-kubernetes-fix), or a retry.
#
# Kargo does not promote a Freight a Stage already holds, so neither the upgrade nor the restore
# starts by itself here. This promotes both, in order, and waits for each Promotion and its
# verification (the region stays drained until the restore is verified).
#   scripts/retry-from-upgrade.sh <region> <freight-name|k3s-version>
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
region=${1:?region (eu|us|cz)}; freight=$(freight_name "${2:-}" kubernetes) || exit 1
project=kubernetes

run_stage() {   # <upgrade|restore>
  local stage=$region-$1 start p name phase vphase deadline
  start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ./scripts/promote.sh $project "$region" "$freight" "$1"
  deadline=$(( $(date +%s) + 900 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    p=$(kubectl --context $MGMT -n $project get promotions -o json | jq -c --arg s "$stage" --arg f "$freight" --arg t "$start" '
      [.items[] | select(.spec.stage == $s and .spec.freight == $f and .metadata.creationTimestamp >= $t)] | sort_by(.metadata.creationTimestamp) | last // {}')
    name=$(jq -r '.metadata.name // ""' <<<"$p"); phase=$(jq -r '.status.phase // ""' <<<"$p")
    case $phase in
      Failed|Errored) echo "$stage $phase: $(jq -r '.status.message // ""' <<<"$p")" >&2; exit 1 ;;
      Succeeded)
        vphase=$(kubectl --context $MGMT -n $project get stage "$stage" -o json | jq -r --arg n "$name" '
          if .status.lastPromotion.name == $n then (.status.freightHistory[0].verificationHistory[0].phase // "") else "" end')
        case $vphase in
          Successful) echo "$(date +%T)  $stage: promoted and verified"; return 0 ;;
          Failed|Error|Aborted|Inconclusive) echo "$stage verification $vphase" >&2; exit 1 ;;
        esac ;;
    esac
    sleep 5
  done
  echo "$stage: timeout" >&2; exit 2
}

run_stage upgrade
run_stage restore
echo "$region done"
