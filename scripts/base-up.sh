#!/usr/bin/env bash
# Bring up k8gb's local multi-cluster setup (edgedns + THREE regional clusters
# test-gslb1/2/3 = geo tags eu/us/cz) with k8gb + Istio, no test apps. Idempotent and
# retrying: registry/chart-repo hiccups are common on flaky networks, and every step
# below can be re-run.
#
# One deviation from `make -C k8gb create-local-clusters`: the regional clusters are
# created here from k8gb's own k3d configs with the k3s image replaced, so the demo can
# START at an older Kubernetes (K3S_START_VERSION) and upgrade it. k8gb's configs pin a
# newer one and ./k8gb is never modified.
set -euo pipefail
cd "$(dirname "$0")/.."

CLUSTERS_NUMBER=${CLUSTERS_NUMBER:-3}
K3S_START_VERSION=${K3S_START_VERSION:-v1.35.9-k3s1}
K8GB_MAKE=(make -C k8gb FULL_LOCAL_SETUP_WITH_APPS=false DEPLOY_APPS=false CLUSTERS_NUMBER="$CLUSTERS_NUMBER")
TRIES=${TRIES:-5}

retry() {
  local n=1
  until "$@"; do
    if [ "$n" -ge "$TRIES" ]; then echo "giving up after $n attempts: $*" >&2; return 1; fi
    echo "attempt $n failed, retrying in 15s: $*" >&2
    n=$((n + 1)); sleep 15
  done
}

expected_clusters() {
  { echo edgedns; for i in $(seq "$CLUSTERS_NUMBER"); do echo "test-gslb$i"; done; } | sort | tr '\n' ' '
}

clusters_present() {
  [ "$(k3d cluster list -o json | jq -r '.[].name' | sort | tr '\n' ' ')" = "$(expected_clusters)" ]
}

create_cluster() {   # <name of the k3d config in k8gb/k3d> (edge-dns, test-gslb1, ...)
  local name=$1 cfg
  cfg=$(mktemp)
  # only the regional clusters get the start version; the edge DNS cluster keeps k8gb's image
  case $name in
    test-gslb*) sed "s#^image: docker.io/rancher/k3s:.*#image: docker.io/rancher/k3s:$K3S_START_VERSION#" "k8gb/k3d/$name.yaml" > "$cfg" ;;
    *)          cp "k8gb/k3d/$name.yaml" "$cfg" ;;
  esac
  k3d cluster create -c "$cfg"
  rm -f "$cfg"
}

create_all() {
  "${K8GB_MAKE[@]}" destroy-full-local-setup >/dev/null 2>&1 || true
  create_cluster edge-dns
  for i in $(seq "$CLUSTERS_NUMBER"); do create_cluster "test-gslb$i"; done
}

if ! clusters_present; then
  # k3d rolls back a half-created cluster, but the shared network may linger.
  retry create_all
fi

# deploy-stable-version = edge DNS + per cluster (k8gb, Istio). helm upgrade -i, so re-runnable.
retry "${K8GB_MAKE[@]}" deploy-stable-version

echo "base-up done ($CLUSTERS_NUMBER regions, k3s $K3S_START_VERSION)"
