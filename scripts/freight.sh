#!/usr/bin/env bash
# The Freight in the kubernetes project: one per k3s version you can roll out. The list IS the
# notification "a new Kubernetes version exists": nothing is rolled out until you promote one
# (scripts/rollout.sh <version>).
#
#   scripts/freight.sh                 list the Freight, newest first
#   scripts/freight.sh discovered      what the Warehouse has found in the registry (not all of it is Freight)
#   scripts/freight.sh sync            create a Freight for the newest patch of every minor discovered
#   scripts/freight.sh create <tag>    create a Freight for one discovered version, e.g. v1.36.6-k3s1
#
# Why `sync`/`create` exist: Kargo's Warehouse creates a Freight only for the newest version it
# finds. Kubernetes upgrades one minor at a time, so going 1.35 -> 1.36 -> 1.37 needs a Freight
# for the intermediate minors too. A Freight is an ordinary resource built from what the Warehouse
# discovered; nothing here invents a version.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/lib.sh
WH=k3s
REPO=docker.io/rancher/k3s-upgrade

discovered() {   # tag<TAB>digest, newest first
  kubectl --context $MGMT -n kubernetes get warehouse $WH -o json |
    jq -r '.status.discoveredArtifacts.images[]? | select(.repoURL=="'$REPO'") | .references[]? | [.tag, (.digest // "")] | @tsv'
}
have() { kubectl --context $MGMT -n kubernetes get freight -o json | jq -r '.items[].images[0].tag'; }
create() {   # tag digest
  kubectl --context $MGMT -n kubernetes create -f - <<EOS
apiVersion: kargo.akuity.io/v1alpha1
kind: Freight
metadata:
  generateName: k3s-
  namespace: kubernetes
origin: {kind: Warehouse, name: $WH}
images:
  - {repoURL: $REPO, tag: $1, digest: "$2"}
EOS
}

case ${1:-list} in
  list)
    kubectl --context $MGMT -n kubernetes get freight -o json | jq -r '
      ["K3S VERSION","FREIGHT","CREATED","IN STAGES"],
      (.items | sort_by(.images[0].tag | ltrimstr("v") | split("-")[0] | split(".") | map(tonumber)) | reverse | .[] | [
        .images[0].tag, (.metadata.name[0:7]), (.metadata.creationTimestamp[0:19] | sub("T";" ")),
        ((.status.currentlyIn // {}) | keys | join(",") | if . == "" then "-" else . end)]) | @tsv' | column -t -s$'\t' ;;
  discovered)
    echo "Warehouse $WH, newest first (the Freight list above has the ones that were turned into Freight):"
    discovered | cut -f1 | paste -sd' ' - | fold -s -w 100 | sed 's/^/  /' ;;
  sync)
    # right after `make kargo` the Warehouse is still doing its first discovery
    for _ in $(seq 1 60); do [ -n "$(discovered)" ] && break; echo "waiting for the Warehouse to finish its first discovery..."; sleep 10; done
    [ -n "$(discovered)" ] || { echo "the Warehouse discovered nothing (network?)" >&2; exit 1; }
    have_tags=$(have); seen=""
    while IFS=$'\t' read -r tag digest; do
      minor=$(echo "$tag" | cut -d. -f1-2)
      case " $seen " in *" $minor "*) continue;; esac     # newest patch of each minor only
      seen="$seen $minor"
      if grep -qx "$tag" <<<"$have_tags"; then echo "have    $tag"; else echo "create  $tag"; create "$tag" "$digest" >/dev/null; fi
    done < <(discovered) ;;
  create)
    tag=${2:?k3s version, e.g. v1.36.6-k3s1}
    digest=$(discovered | awk -F'\t' -v t="$tag" '$1==t{print $2}')
    grep -qx "$tag" <(discovered | cut -f1) || { echo "$tag was not discovered by the Warehouse (see: scripts/freight.sh discovered)" >&2; exit 1; }
    if grep -qx "$tag" <(have); then echo "Freight for $tag already exists"; else create "$tag" "$digest"; fi ;;
  *) echo "usage: $0 [list|discovered|sync|create <tag>]" >&2; exit 2 ;;
esac
