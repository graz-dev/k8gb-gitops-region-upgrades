#!/usr/bin/env bash
# Follow one region's branch until `<region>-restore` is verified for the Freight, or
# something fails. Exit 0 = done, 1 = a promotion or verification failed, 2 = timeout.
#   scripts/wait-pipeline.sh <project> <region> [timeout-seconds] [freight-name]
# Freight: a name or a k3s version, as for scripts/promote.sh.
set -uo pipefail
project=${1:?project}; region=${2:?region}; timeout=${3:-1500}
MGMT=k3d-mgmt
. "$(dirname "$0")/lib.sh"
target=$(freight_name "${4:-}" "$project") || exit 2
deadline=$(( $(date +%s) + timeout )); last=""
echo "following freight ${target:0:7} in $project ($region)"
while :; do
  stages=$(kubectl --context $MGMT -n "$project" get stages -o json)
  proms=$(kubectl --context $MGMT -n "$project" get promotions -o json)
  # <stage>=<promotion phase>/<verification phase>, only for the freight we follow
  snap=$(jq -r --arg f "$target" --arg r "$region" '
    .items | map(select(.metadata.name | startswith($r + "-"))) | sort_by(.metadata.name) | map(
      (if .status.lastPromotion.freight.name == $f then (.status.lastPromotion.status.phase // "-") else "-" end) as $p
      | (if .status.lastPromotion.freight.name == $f then (.status.freightHistory[0].verificationHistory[0].phase // "-") else "-" end) as $v
      | "\(.metadata.name)=\($p)/\($v)") | join("  ")' <<<"$stages")
  [ "$snap" != "$last" ] && { echo "$(date +%T)  $snap"; last=$snap; }

  # newest Promotion of each of this region's stages for this freight (an old failure that was retried is history)
  failed=$(jq -r --arg f "$target" --arg r "$region" '
    [.items | map(select(.spec.freight == $f and (.spec.stage | startswith($r + "-")))) | group_by(.spec.stage)[]
     | sort_by(.metadata.creationTimestamp) | last
     | select(.status.phase=="Failed" or .status.phase=="Errored") | "\(.spec.stage): \(.status.message // "")"] | first // empty' <<<"$proms")
  [ -n "$failed" ] && { echo "FAILED promotion -> $failed"; exit 1; }
  # a failed verification only counts if it belongs to the newest Promotion of that stage
  vfail=$(jq -r --arg f "$target" --arg r "$region" --argjson proms "$proms" '
      ($proms.items | map(select(.spec.freight == $f)) | group_by(.spec.stage)
        | map({key: .[0].spec.stage, value: (sort_by(.metadata.creationTimestamp) | last | .metadata.name)}) | from_entries) as $newest
      | [.items[] | select(.metadata.name | startswith($r + "-")) | select(.status.lastPromotion.freight.name == $f)
         | select(.status.lastPromotion.name == $newest[.metadata.name])
         | select((.status.freightHistory[0].verificationHistory[0].phase // "") | test("Failed|Error|Aborted|Inconclusive"))
         | .metadata.name] | first // empty' <<<"$stages")
  [ -n "$vfail" ] && { echo "FAILED verification in stage $vfail"; exit 1; }

  ok=$(jq -r --arg f "$target" --arg r "$region" '.items[] | select(.metadata.name==($r + "-restore"))
      | select(.status.lastPromotion.freight.name == $f and .status.lastPromotion.status.phase == "Succeeded"
               and (.status.freightHistory[0].verificationHistory[0].phase // "") == "Successful") | "yes"' <<<"$stages")
  [ "$ok" = yes ] && { echo "$region done: $region-restore verified"; exit 0; }
  [ "$(date +%s)" -lt "$deadline" ] || { echo "timeout"; exit 2; }
  sleep 3
done
