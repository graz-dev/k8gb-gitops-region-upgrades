#!/usr/bin/env bash
# One-shot view of a pipeline: per stage, the phase of its newest Promotion, the verification, and the Freight.
#   scripts/pipeline-status.sh <project>
set -euo pipefail
project=${1:?project}
kubectl --context k3d-mgmt -n "$project" get stages -o json | jq -r '
  ["STAGE","PROMOTION","VERIFICATION","FREIGHT"],
  (.items | sort_by(.metadata.name) | .[] | [
     .metadata.name,
     (.status.lastPromotion.status.phase // "-"),
     (.status.freightHistory[0].verificationHistory[0].phase // "-"),
     ((.status.lastPromotion.freight.name // "-")[0:7])
  ]) | @tsv' | column -t
