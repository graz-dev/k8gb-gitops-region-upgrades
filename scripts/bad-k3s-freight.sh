#!/usr/bin/env bash
# The failure path of the Kubernetes pipeline: an upgrade that CANNOT complete.
#   scripts/bad-k3s-freight.sh create [region]   make a Freight for a k3s build that does not exist
#                                                and print its tag (default region: eu)
#   scripts/bad-k3s-freight.sh good [region]     print the name of the REAL Freight of the version the
#                                                region runs now (what the fix rolls out)
#
# The bad build is the version the region runs now with a build number that was never published
# (v1.37.2-k3s99 next to the real v1.37.2-k3s1): the kind of mistake a typo or a yanked release
# makes, and a version the drain stage's skip-minor / downgrade check lets through on purpose.
#
# Kargo creates Freight from what its Warehouse discovers, but a Freight is also an ordinary
# resource and its webhook only computes the name, so a human (or a bug) can make a bad one.
# System Upgrade Controller then cordons the node, its upgrade Job cannot pull the image, and the
# Plans never complete: the node check in `<region>-upgrade` times out, the Promotion fails, and the
# region STAYS DRAINED while the others keep serving.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
project=kubernetes
action=${1:?create|good}; region=${2:-eu}
ctx=$(region_ctx "$region")
# what the region runs now, as a Freight tag: v1.37.2+k3s1 -> v1.37.2-k3s1
running=$(kubectl --context "$ctx" get node "${ctx}-server-0" -o jsonpath='{.status.nodeInfo.kubeletVersion}')
real=${running/+/-}
bad=${real%-k3s*}-k3s99

case $action in
  create)
    kubectl --context $MGMT -n $project create -f - >/dev/null <<EOS
apiVersion: kargo.akuity.io/v1alpha1
kind: Freight
metadata:
  generateName: bad-k3s-
  namespace: $project
origin: {kind: Warehouse, name: k3s}
images:
  - {repoURL: docker.io/rancher/k3s-upgrade, tag: $bad}
EOS
    echo "$bad" ;;
  good)
    freight_name "$real" $project ;;
  *) echo "create|good" >&2; exit 2 ;;
esac
