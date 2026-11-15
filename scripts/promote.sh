#!/usr/bin/env bash
# Start one region's branch of a pipeline: promote the Freight you name (a Freight name or a k3s
# version such as v1.36.6-k3s1) to `<region>-drain`. The rest of that branch (upgrade, restore) promotes by itself once the
# stage upstream is verified. Needs no Kargo CLI: a Promotion is just a resource.
#   scripts/promote.sh <project> <eu|us|cz> <freight-name|k3s-version> [drain|upgrade|restore]
#
# The optional last argument promotes to another stage of the branch: use it to RETRY a stage that
# failed (a Freight already promoted to a stage is not promoted again by itself), e.g.
#   scripts/promote.sh kubernetes cz v1.36.6-k3s1 upgrade
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
project=${1:?project (kubernetes)}; region=${2:?region (eu|us|cz)}
freight=$(freight_name "${3:-}" "$project") || exit 1
stage=${4:-drain}
echo "promoting freight ${freight:0:7} to $project/$region-$stage"
kubectl --context $MGMT -n "$project" create -f - <<EOP
apiVersion: kargo.akuity.io/v1alpha1
kind: Promotion
metadata:
  name: $region-$stage-$(date +%s)
  namespace: $project
spec:
  stage: $region-$stage
  freight: $freight
EOP
